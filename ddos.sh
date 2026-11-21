#!/usr/bin/env bash
# AntiDDoS - monitor TCP/UDP per Ubuntu 22.04
# Ban senza scadenza automatica. Sblocco tramite iptables e ban.ip.list.
set -Eeuo pipefail

DDOS_DIR=/usr/local/ddos
CONF="$DDOS_DIR/ddos.conf"
BANNED_IP_LIST="$DDOS_DIR/ban.ip.list"
IGNORE_IP_LIST="$DDOS_DIR/ignore.ip.list"
# Range Cloudflare (generato da update-cloudflare-ips). Supporta CIDR.
CF_IP_LIST="$DDOS_DIR/cloudflare.ip.list"
CRON=/etc/cron.d/ddos.cron

usage() {
  cat <<'HELP'
AntiDDoS - Ubuntu 22.04
Uso: ddos.sh [numero_connessioni | -c | --cron | -h | --help]
  numero_connessioni  Soglia di ban (predefinita da ddos.conf, oppure 150)
  -c, --cron          Installa/aggiorna il cron AntiDDoS
  -h, --help          Mostra questa guida
I ban non scadono automaticamente.
HELP
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[[ $EUID -eq 0 ]] || { echo 'ERRORE: eseguire come root.' >&2; exit 1; }
[[ -f "$CONF" ]] || { echo "ERRORE: manca $CONF" >&2; exit 1; }
# Carica la configurazione esistente (file affidabile e modificabile solo da root).
# shellcheck source=/dev/null
source "$CONF"

NO_OF_CONNECTIONS="${NO_OF_CONNECTIONS:-150}"
FREQ="${FREQ:-1}"
FILTER_STATE="${FILTER_STATE:-0}"
IGNORE_DEFAULT_IP="${IGNORE_DEFAULT_IP:-1}"
IPT="${IPT:-$(command -v iptables)}"

[[ "$NO_OF_CONNECTIONS" =~ ^[0-9]+$ ]] && (( NO_OF_CONNECTIONS >= 1 )) || {
  echo 'ERRORE: NO_OF_CONNECTIONS deve essere un intero positivo.' >&2; exit 1;
}
[[ "$FREQ" =~ ^[0-9]+$ ]] && (( FREQ >= 1 && FREQ <= 59 )) || {
  echo 'ERRORE: FREQ deve essere tra 1 e 59.' >&2; exit 1;
}
[[ "$IGNORE_DEFAULT_IP" == 0 || "$IGNORE_DEFAULT_IP" == 1 ]] || {
  echo 'ERRORE: IGNORE_DEFAULT_IP deve essere 0 oppure 1.' >&2; exit 1;
}
command -v ss >/dev/null || { echo 'ERRORE: manca ss (iproute2).' >&2; exit 1; }
command -v flock >/dev/null || { echo 'ERRORE: manca flock (util-linux).' >&2; exit 1; }
[[ -x "$IPT" ]] || { echo "ERRORE: iptables non eseguibile: $IPT" >&2; exit 1; }

install_cron() {
  cat > "$CRON" <<CRONEOF
SHELL=/bin/bash
*/$FREQ * * * * root /usr/local/ddos/ddos.sh >/dev/null 2>&1
CRONEOF
  chmod 644 "$CRON"
  systemctl enable --now cron
  systemctl reload cron || systemctl restart cron
  echo "Cron AntiDDoS attivo ogni $FREQ minuto/i: $CRON"
}

case "${1:-}" in
  -c|--cron) install_cron; exit 0 ;;
  '') ;;
  *)
    if [[ "$1" =~ ^[0-9]+$ ]] && (( $# == 1 )) && (( 10#$1 >= 1 )); then
      NO_OF_CONNECTIONS=$((10#$1))
    else
      usage >&2; exit 1
    fi
    ;;
esac

# Impedisce esecuzioni sovrapposte da cron e dalla shell.
exec 9>/run/ddos.lock
flock -n 9 || { echo 'AntiDDoS già in esecuzione.'; exit 0; }

touch "$BANNED_IP_LIST" "$IGNORE_IP_LIST"

is_ipv4() {
  local ip=$1 part
  local -a parts
  local IFS=.
  read -r -a parts <<< "$ip"
  (( ${#parts[@]} == 4 )) || return 1
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$part <= 255 )) || return 1
  done
}

is_reserved() {
  local ip=$1 a b c d
  IFS=. read -r a b c d <<< "$ip"
  # Esclude loopback, reti private/link-local, CGNAT, multicast e riservati.
  (( a == 0 || a == 10 || a == 127 || a >= 224 ||
     (a == 100 && b >= 64 && b <= 127) ||
     (a == 169 && b == 254) ||
     (a == 172 && b >= 16 && b <= 31) ||
     (a == 192 && b == 168) ))
}

ip_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

# Whitelist: IP singoli e reti CIDR IPv4 (ignore.ip.list + cloudflare.ip.list).
# Righe vuote e commenti (#) ignorati.
declare -A ignore_exact=()
ignore_nets=()
load_ignore() {
  local file line ip bits mask
  for file in "$IGNORE_IP_LIST" "$CF_IP_LIST"; do
    [[ -r "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line=${line%%#*}
      line=${line//[[:space:]]/}
      [[ -n "$line" ]] || continue
      if [[ "$line" == */* ]]; then
        ip=${line%/*}; bits=${line#*/}
        is_ipv4 "$ip" || continue
        [[ "$bits" =~ ^[0-9]{1,2}$ ]] && (( 10#$bits <= 32 )) || continue
        bits=$((10#$bits))
        mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
        ignore_nets+=("$(( $(ip_to_int "$ip") & mask )) $mask")
      elif is_ipv4 "$line"; then
        ignore_exact["$line"]=1
      fi
    done < "$file"
  done
}

is_ignored() {
  local ip=$1 n entry net mask
  [[ -n "${ignore_exact[$ip]:-}" ]] && return 0
  n=$(ip_to_int "$ip")
  for entry in "${ignore_nets[@]}"; do
    read -r net mask <<< "$entry"
    (( (n & mask) == net )) && return 0
  done
  return 1
}

load_ignore

# Indici FILTER_STATE previsti dal progetto originale.
STATES=(all connected synchronized syn-sent syn-recv established fin-wait-1 fin-wait-2 time-wait close-wait last-ack closing closed)
IFS=: read -r -a selected <<< "$FILTER_STATE"
(( ${#selected[@]} > 0 )) || selected=(0)

# Evita che 'all' venga combinato con stati specifici (conteggi duplicati).
if [[ " ${selected[*]} " == *" 0 "* ]]; then selected=(0); fi

peers_file=$(mktemp /tmp/ddos-peers.XXXXXXXX)
trap 'rm -f "$peers_file"' EXIT

for index in "${selected[@]}"; do
  [[ "$index" =~ ^[0-9]+$ ]] && (( index < ${#STATES[@]} )) || {
    echo "ERRORE: FILTER_STATE non valido: $index" >&2; exit 1;
  }
  # -H: nessuna intestazione. La quinta colonna è Peer Address:Port.
  ss -Hntu state "${STATES[index]}" | awk '{print $5}' >> "$peers_file"
done

declare -A counts=()
while IFS= read -r peer; do
  # Per i peer IPv4 la forma è A.B.C.D:porta; esclude IPv6 e voci '*'.
  ip=${peer%:*}
  is_ipv4 "$ip" || continue
  counts["$ip"]=$(( ${counts["$ip"]:-0} + 1 ))
done < "$peers_file"

# Ordina per numero di connessioni. Evita problemi con spazi e ordinamento lessicale.
for ip in "${!counts[@]}"; do
  printf '%s %s\n' "${counts[$ip]}" "$ip"
done | sort -k1,1nr -k2,2 | while read -r connections ip; do
  printf '%6d %s\n' "$connections" "$ip"
  (( connections >= NO_OF_CONNECTIONS )) || continue
  if [[ "$IGNORE_DEFAULT_IP" == 1 ]] && is_reserved "$ip"; then continue; fi
  is_ignored "$ip" && continue
  grep -Fqx -- "$ip" "$BANNED_IP_LIST" && continue

  if "$IPT" -C INPUT -s "$ip" -j DROP 2>/dev/null; then
    echo "[GIÀ BLOCCATO] $ip (regola iptables già presente)"
    continue
  fi
  if "$IPT" -I INPUT -s "$ip" -j DROP; then
    printf '%s\n' "$ip" >> "$BANNED_IP_LIST"
    echo "[BANNATO] $ip - $connections connessioni"
  else
    echo "[ERRORE] Ban fallito: $ip" >&2
  fi
done
