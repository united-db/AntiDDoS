#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# INSTALLER PROXY + ANTIDDOS - UBUNTU 22.04 LTS
#
# - Ripara automaticamente i repository APT HTTP -> HTTPS.
# - Nginx ascolta sulla porta 80 e inoltra verso IP:PORTA scelti nel setup.
# - Modifica solo il server block predefinito di Ubuntu Nginx.
# - Apache2 ascolta sulla porta 11111 e pubblica /report.txt.
# - AntiDDoS viene installato in /usr/local/ddos.
# - L'IP del server protetto viene inserito in ignore.ip.list.
# - I ban vengono gestiti direttamente tramite iptables.
# - NON installa/usa UFW o firewalld.
###############################################################################

HOSTNAME_PROXY="Proxy"
NGINX_SITE="/etc/nginx/sites-available/default"
APACHE_PORTS="/etc/apache2/ports.conf"
APACHE_SITE="/etc/apache2/sites-available/000-default.conf"

DDOS_DIR="/usr/local/ddos"
DDOS_ZIP="/tmp/AntiDDoS-master.zip"
DDOS_TMP="/tmp/AntiDDoS-master"
IGNORE_FILE="${DDOS_DIR}/ignore.ip.list"
BAN_FILE="${DDOS_DIR}/ban.ip.list"
INSTALL_INFO="/root/proxy-install-info.txt"

STAMP="$(date +%Y%m%d_%H%M%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

separator() {
    echo
    echo "======================================================================"
    echo " $1"
    echo "======================================================================"
    echo
}

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[ATTENZIONE]${NC} $*"; }
fail() { echo; echo -e "${RED}[ERRORE]${NC} $*"; echo; exit 1; }

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.${STAMP}.bak"
        ok "Backup creato: ${file}.${STAMP}.bak"
    fi
}

valid_ipv4() {
    local ip="$1"
    local IFS=.
    local -a parts
    read -r -a parts <<< "$ip"
    [[ ${#parts[@]} -eq 4 ]] || return 1
    for octet in "${parts[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
    done
    return 0
}

valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

error_handler() {
    local exit_code=$?
    local line="$1"
    local command="$2"
    echo
    echo -e "${RED}======================================================================"
    echo " ERRORE DURANTE L'INSTALLAZIONE"
    echo "======================================================================${NC}"
    echo
    echo "Codice:  ${exit_code}"
    echo "Riga:    ${line}"
    echo "Comando: ${command}"
    echo
    exit "$exit_code"
}

trap 'error_handler "$LINENO" "$BASH_COMMAND"' ERR

###############################################################################
# BANNER
###############################################################################

clear || true

echo
echo "======================================================================"
echo "          INSTALLER PROXY + ANTIDDOS - UBUNTU 22.04 LTS"
echo "======================================================================"
echo
echo " NGINX      Reverse Proxy porta 80"
echo " APACHE2    Report AntiDDoS porta 11111"
echo " ANTIDDOS   /usr/local/ddos"
echo " IPTABLES   Ban IP"
echo " FIREWALL   Nessun UFW / firewalld"
echo
echo "======================================================================"
echo

###############################################################################
# CONTROLLO ROOT E SISTEMA
###############################################################################

separator "CONTROLLO ROOT E UBUNTU"

[[ ${EUID} -eq 0 ]] || fail "Eseguire lo script come ROOT: sudo -i"
[[ -r /etc/os-release ]] || fail "/etc/os-release non trovato."

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] || \
    fail "Questo installer è destinato a Ubuntu. Sistema rilevato: ${ID:-sconosciuto}"

if [[ "${VERSION_ID:-}" != "22.04" ]]; then
    warn "Versione rilevata: ${VERSION_ID:-sconosciuta}. Lo script è preparato per Ubuntu 22.04 LTS."
fi

ok "Sistema rilevato: ${PRETTY_NAME:-Ubuntu}"

###############################################################################
# HOSTNAME
###############################################################################

separator "CONFIGURAZIONE HOSTNAME"

backup_file /etc/hosts
hostnamectl set-hostname "${HOSTNAME_PROXY}"

if ! grep -Eq "(^|[[:space:]])${HOSTNAME_PROXY}([[:space:]]|$)" /etc/hosts; then
    echo "127.0.1.1 ${HOSTNAME_PROXY}" >> /etc/hosts
fi

ok "Hostname: $(hostname)"

###############################################################################
# RIPARAZIONE REPOSITORY UBUNTU
###############################################################################

separator "CONTROLLO E RIPARAZIONE REPOSITORY APT"

export DEBIAN_FRONTEND=noninteractive
APT_BACKUP_DIR="/root/apt-sources-backup-${STAMP}"
mkdir -p "${APT_BACKUP_DIR}"

if [[ -f /etc/apt/sources.list ]]; then
    cp -a /etc/apt/sources.list "${APT_BACKUP_DIR}/sources.list"
fi

if [[ -d /etc/apt/sources.list.d ]]; then
    cp -a /etc/apt/sources.list.d "${APT_BACKUP_DIR}/sources.list.d"
fi

info "Converto i mirror Ubuntu HTTP in HTTPS..."

APT_SOURCE_FILES=()
[[ -f /etc/apt/sources.list ]] && APT_SOURCE_FILES+=(/etc/apt/sources.list)

while IFS= read -r -d '' src; do
    APT_SOURCE_FILES+=("$src")
done < <(
    find /etc/apt/sources.list.d -maxdepth 1 -type f \
        \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null || true
)

for src in "${APT_SOURCE_FILES[@]}"; do
    sed -i -E \
        -e 's#http://([[:alnum:].-]+\.)?archive\.ubuntu\.com/ubuntu/?#https://archive.ubuntu.com/ubuntu#g' \
        -e 's#http://security\.ubuntu\.com/ubuntu/?#https://security.ubuntu.com/ubuntu#g' \
        -e 's#http://ports\.ubuntu\.com/ubuntu-ports/?#https://ports.ubuntu.com/ubuntu-ports#g' \
        "$src"
done

ok "Backup repository: ${APT_BACKUP_DIR}"

apt-get clean
rm -rf /var/lib/apt/lists/*
mkdir -p /var/lib/apt/lists/partial

info "Eseguo apt-get update usando IPv4..."

if ! apt-get \
    -o Acquire::ForceIPv4=true \
    -o Acquire::Retries=3 \
    -o APT::Update::Error-Mode=any \
    update; then

    echo
    warn "APT non riesce a raggiungere i repository Ubuntu neppure via HTTPS."
    warn "Verifica che la VPS possa uscire su TCP 443."
    echo

    echo "Test DNS archive.ubuntu.com:"
    getent ahostsv4 archive.ubuntu.com | head || true
    echo
    echo "Test HTTPS archive.ubuntu.com:"
    curl -4 -I --connect-timeout 10 --max-time 15 \
        https://archive.ubuntu.com/ubuntu/dists/jammy/InRelease || true
    echo

    fail "Repository Ubuntu non raggiungibili."
fi

ok "Repository Ubuntu raggiungibili."

###############################################################################
# AGGIORNAMENTO SISTEMA
###############################################################################

separator "AGGIORNAMENTO SISTEMA"

apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=3 -y upgrade

###############################################################################
# INSTALLAZIONE PACCHETTI
###############################################################################

separator "INSTALLAZIONE PACCHETTI"

# Evita che nginx/apache2 tentino di partire automaticamente durante dpkg
# mentre entrambi hanno ancora la porta 80 di default.
POLICY_RC_CREATED=0

if [[ ! -e /usr/sbin/policy-rc.d ]]; then
    cat > /usr/sbin/policy-rc.d <<'POLICYEOF'
#!/bin/sh
exit 101
POLICYEOF
    chmod 755 /usr/sbin/policy-rc.d
    POLICY_RC_CREATED=1
fi

if ! apt-get \
    -o Acquire::ForceIPv4=true \
    -o Acquire::Retries=3 \
    install -y \
        wget \
        curl \
        vim \
        nano \
        zip \
        unzip \
        perl \
        libwww-perl \
        python3 \
        cron \
        iproute2 \
        net-tools \
        iptables \
        nginx \
        apache2 \
        php \
        libapache2-mod-php \
        php-mysql; then

    [[ ${POLICY_RC_CREATED} -eq 1 ]] && rm -f /usr/sbin/policy-rc.d
    fail "Installazione pacchetti fallita. Controllare la connettività APT."
fi

[[ ${POLICY_RC_CREATED} -eq 1 ]] && rm -f /usr/sbin/policy-rc.d

dpkg --configure -a

perl -MTime::HiRes -e 'exit 0' || \
    fail "Modulo Perl Time::HiRes non disponibile."

systemctl enable --now cron
ok "Pacchetti Ubuntu installati e cron attivo."

###############################################################################
# INPUT SERVER DA PROTEGGERE
###############################################################################

separator "CONFIGURAZIONE SERVER DA PROTEGGERE"

echo -e "${WHITE}Inserisci IP e porta del server ORIGINALE da proteggere.${NC}"
echo
echo "Esempio:"
echo "    IP:       185.100.100.50"
echo "    PORTA:    80"
echo
echo "Nginx verrà configurato con:"
echo "    proxy_pass http://185.100.100.50:80;"
echo

while true; do
    read -rp "IP SERVER DA PROTEGGERE: " BACKEND_IP
    if valid_ipv4 "${BACKEND_IP}"; then
        break
    fi
    warn "IPv4 non valido. Riprova."
done

while true; do
    read -rp "PORTA SERVER DA PROTEGGERE [80]: " BACKEND_PORT
    BACKEND_PORT="${BACKEND_PORT:-80}"
    if valid_port "${BACKEND_PORT}"; then
        break
    fi
    warn "Porta non valida. Inserire un valore da 1 a 65535."
done

echo
echo "----------------------------------------------------------------------"
echo "SERVER DA PROTEGGERE: ${BACKEND_IP}:${BACKEND_PORT}"
echo "PROXY_PASS:            http://${BACKEND_IP}:${BACKEND_PORT};"
echo "WHITELIST ANTIDDOS:    ${BACKEND_IP}"
echo "----------------------------------------------------------------------"
echo

###############################################################################
# IP PUBBLICO VPS PROXY
###############################################################################

separator "RILEVAMENTO IP PUBBLICO VPS PROXY"

PROXY_PUBLIC_IP=""

for service in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com"
do
    candidate="$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$service" 2>/dev/null | tr -d '[:space:]' || true)"
    if valid_ipv4 "$candidate" 2>/dev/null; then
        PROXY_PUBLIC_IP="$candidate"
        break
    fi
done

if [[ -n "$PROXY_PUBLIC_IP" ]]; then
    ok "IP pubblico VPS: ${PROXY_PUBLIC_IP}"
else
    warn "Impossibile rilevare automaticamente l'IP pubblico della VPS."
fi

cat > "${INSTALL_INFO}" <<INFOEOF
INSTALLAZIONE PROXY + ANTIDDOS - UBUNTU 22.04
Data: $(date)
Hostname Proxy: $(hostname)
IP pubblico VPS Proxy: ${PROXY_PUBLIC_IP:-NON_RILEVATO}
Server protetto: ${BACKEND_IP}
Porta server protetto: ${BACKEND_PORT}
Proxy Pass: http://${BACKEND_IP}:${BACKEND_PORT}
Whitelist AntiDDoS: ${BACKEND_IP}
Report: http://${PROXY_PUBLIC_IP:-IP_PUBBLICO_VPS}:11111/report.txt
INFOEOF
chmod 600 "${INSTALL_INFO}"

###############################################################################
# TEST BACKEND
###############################################################################

separator "TEST PRELIMINARE SERVER PROTETTO"

BACKEND_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "http://${BACKEND_IP}:${BACKEND_PORT}/" || true)"

if [[ -n "$BACKEND_CODE" && "$BACKEND_CODE" != "000" ]]; then
    ok "Backend raggiungibile. HTTP ${BACKEND_CODE}"
else
    warn "Backend non raggiungibile al test iniziale. Continuo comunque."
fi

###############################################################################
# NGINX - MODIFICA SOLO SERVER BLOCK PREDEFINITO UBUNTU
###############################################################################

separator "CONFIGURAZIONE NGINX"

[[ -f "${NGINX_SITE}" ]] || fail "File Nginx Ubuntu non trovato: ${NGINX_SITE}"

backup_file "${NGINX_SITE}"
NGINX_BACKUP="${NGINX_SITE}.${STAMP}.bak"

export BACKEND_IP BACKEND_PORT NGINX_SITE

python3 <<'PY'
import os
import re
import sys

path = os.environ["NGINX_SITE"]
backend_ip = os.environ["BACKEND_IP"]
backend_port = os.environ["BACKEND_PORT"]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

server_start = None
server_end = None
pattern = re.compile(r'(?m)^[ \t]*server[ \t]*\{')

for match in pattern.finditer(text):
    start = match.start()
    opening_brace = text.find("{", match.start(), match.end())
    if opening_brace < 0:
        continue

    depth = 0
    end = None
    in_single = False
    in_double = False
    escaped = False
    in_comment = False
    i = opening_brace

    while i < len(text):
        ch = text[i]

        if in_comment:
            if ch == "\n":
                in_comment = False
            i += 1
            continue

        if escaped:
            escaped = False
            i += 1
            continue

        if ch == "\\" and (in_single or in_double):
            escaped = True
            i += 1
            continue

        if not in_single and not in_double and ch == "#":
            in_comment = True
            i += 1
            continue

        if ch == "'" and not in_double:
            in_single = not in_single
            i += 1
            continue

        if ch == '"' and not in_single:
            in_double = not in_double
            i += 1
            continue

        if in_single or in_double:
            i += 1
            continue

        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
        i += 1

    if end is None:
        continue

    block = text[start:end]
    if re.search(r'(?m)^[ \t]*listen[ \t]+80[ \t]+default_server[ \t]*;', block):
        server_start = start
        server_end = end
        break

if server_start is None or server_end is None:
    print("ERRORE: server block con 'listen 80 default_server;' non trovato.", file=sys.stderr)
    sys.exit(1)

new_server = f'''server {{
        listen       80 default_server;
        listen       [::]:80 default_server;
        server_name  _;
        root         /var/www/html;

        location / {{
                proxy_buffers 16 4k;
                proxy_pass http://{backend_ip}:{backend_port};
                proxy_http_version  1.1;
                proxy_cache_bypass  $http_upgrade;

                proxy_set_header Upgrade           $http_upgrade;
                proxy_set_header Connection        "upgrade";
                proxy_set_header Host              $host;
                proxy_set_header X-Real-IP         $remote_addr;
                proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_set_header X-Forwarded-Host  $host;
                proxy_set_header X-Forwarded-Port  $server_port;
        }}
}}'''

new_text = text[:server_start] + new_server + text[server_end:]

with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(new_text)

print(f"proxy_pass http://{backend_ip}:{backend_port};")
PY

if nginx -t; then
    ok "Configurazione Nginx valida."
else
    warn "Configurazione Nginx non valida: ripristino backup."
    cp -a "${NGINX_BACKUP}" "${NGINX_SITE}"
    nginx -t || true
    fail "Configurazione Nginx originale ripristinata."
fi

systemctl enable nginx
systemctl restart nginx
ok "Nginx attivo."

echo
grep --color=never -n "proxy_pass" "${NGINX_SITE}" || true
echo

###############################################################################
# APACHE2 UBUNTU - PORTA 11111
###############################################################################

separator "CONFIGURAZIONE APACHE2 PORTA 11111"

[[ -f "${APACHE_PORTS}" ]] || fail "File Apache2 non trovato: ${APACHE_PORTS}"
[[ -f "${APACHE_SITE}" ]] || fail "VirtualHost Apache2 non trovato: ${APACHE_SITE}"

backup_file "${APACHE_PORTS}"
backup_file "${APACHE_SITE}"
APACHE_PORTS_BACKUP="${APACHE_PORTS}.${STAMP}.bak"
APACHE_SITE_BACKUP="${APACHE_SITE}.${STAMP}.bak"

if grep -Eq '^[[:space:]]*Listen[[:space:]]+80[[:space:]]*$' "${APACHE_PORTS}"; then
    sed -i -E 's/^[[:space:]]*Listen[[:space:]]+80[[:space:]]*$/Listen 11111/' "${APACHE_PORTS}"
elif ! grep -Eq '^[[:space:]]*Listen[[:space:]]+11111[[:space:]]*$' "${APACHE_PORTS}"; then
    echo "Listen 11111" >> "${APACHE_PORTS}"
fi

if grep -Eq '<VirtualHost[[:space:]]+\*:80>' "${APACHE_SITE}"; then
    sed -i -E 's#<VirtualHost[[:space:]]+\*:80>#<VirtualHost *:11111>#' "${APACHE_SITE}"
elif ! grep -Eq '<VirtualHost[[:space:]]+\*:11111>' "${APACHE_SITE}"; then
    warn "VirtualHost :80 non trovato in ${APACHE_SITE}."
fi

if apache2ctl configtest; then
    ok "Configurazione Apache2 valida."
else
    cp -a "${APACHE_PORTS_BACKUP}" "${APACHE_PORTS}"
    cp -a "${APACHE_SITE_BACKUP}" "${APACHE_SITE}"
    fail "Errore Apache2: configurazioni ripristinate."
fi

systemctl enable apache2
systemctl restart apache2
ok "Apache2 attivo sulla porta 11111."

###############################################################################
# ANTIDDOS
###############################################################################

separator "INSTALLAZIONE ANTIDDOS"

rm -f "${DDOS_ZIP}"
rm -rf "${DDOS_TMP}"

wget -O "${DDOS_ZIP}" \
    "https://github.com/united-db/AntiDDoS/archive/refs/heads/master.zip"

unzip -q "${DDOS_ZIP}" -d /tmp
[[ -d "${DDOS_TMP}" ]] || fail "AntiDDoS-master non trovato dopo l'estrazione."

if [[ -d "${DDOS_DIR}" ]]; then
    mv "${DDOS_DIR}" "${DDOS_DIR}.${STAMP}.bak"
    ok "Backup vecchio AntiDDoS: ${DDOS_DIR}.${STAMP}.bak"
fi

mv "${DDOS_TMP}" "${DDOS_DIR}"
chmod 755 "${DDOS_DIR}"
chmod +x "${DDOS_DIR}/ddos.sh"
touch "${BAN_FILE}" "${IGNORE_FILE}"
chmod 644 "${BAN_FILE}" "${IGNORE_FILE}"

###############################################################################
# PATCH COMPATIBILITA' UBUNTU + BAN PERMANENTI
###############################################################################

separator "PATCH ANTIDDOS PER UBUNTU 22.04"

# Il repository originale usa /bin/sh ma contiene sintassi Bash.
sed -i '1c#!/usr/bin/env bash' "${DDOS_DIR}/ddos.sh"

# Su Ubuntu il servizio si chiama cron, non crond.
sed -i 's/service[[:space:]]\+crond[[:space:]]\+restart/service cron restart/g' "${DDOS_DIR}/ddos.sh"

# Percorso reale di iptables su Ubuntu.
IPTABLES_PATH="$(command -v iptables || true)"
[[ -n "$IPTABLES_PATH" ]] || fail "iptables non trovato."

if grep -qE '^IPT=' "${DDOS_DIR}/ddos.conf"; then
    sed -i "s|^IPT=.*|IPT=\"${IPTABLES_PATH}\"|" "${DDOS_DIR}/ddos.conf"
fi

###############################################################################
# RIMUOVE LO SBAN AUTOMATICO
#
# Vengono rimossi:
#   - funzione unbanip() { ... }
#   - chiamata "unbanip"
#   - blocco email finale
#
# In questo modo un IP bannato resta in DROP finché non viene rimosso
# manualmente o tramite il comando reset-antiddos-bans.
###############################################################################

export DDOS_SCRIPT="${DDOS_DIR}/ddos.sh"

python3 <<'PY'
import os
import re
import sys

path = os.environ["DDOS_SCRIPT"]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

# Individua e rimuove la funzione unbanip() usando il bilanciamento delle graffe.
m = re.search(r'(?m)^[ \t]*unbanip[ \t]*\(\)[ \t]*\n?[ \t]*\{', text)

if m:
    start = m.start()
    brace = text.find("{", m.start(), m.end())
    depth = 0
    end = None

    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                while end < len(text) and text[end] in " \t\r\n":
                    end += 1
                break

    if end is None:
        print("ERRORE: impossibile determinare la fine di unbanip().", file=sys.stderr)
        sys.exit(1)

    text = text[:start] + text[end:]

# Rimuove l'eventuale chiamata standalone a unbanip.
text = re.sub(
    r'(?m)^[ \t]*unbanip[ \t]*;?[ \t]*\r?\n',
    '',
    text
)

# Rimuove il blocco email:
#   dt=`date`
#   if [ $EMAIL_TO != "" ]; then
#       ...
#   fi
lines = text.splitlines(keepends=True)
out = []
i = 0

while i < len(lines):
    stripped = lines[i].strip()

    if stripped in ("dt=`date`", "dt=$(date)"):
        j = i + 1

        if j < len(lines) and "EMAIL_TO" in lines[j] and lines[j].lstrip().startswith("if "):
            depth = 0
            found_fi = False

            while j < len(lines):
                s = lines[j].strip()

                if s.startswith("if "):
                    depth += 1
                elif s == "fi":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        found_fi = True
                        break

                j += 1

            if found_fi:
                i = j
                continue

    out.append(lines[i])
    i += 1

text = "".join(out)

with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(text)
PY

###############################################################################
# RIMUOVE BAN_PERIOD E EMAIL_TO DAL DDOS.CONF
###############################################################################

sed -i     -e '/^[[:space:]]*BAN_PERIOD[[:space:]]*=/d'     -e '/^[[:space:]]*EMAIL_TO[[:space:]]*=/d'     "${DDOS_DIR}/ddos.conf"

###############################################################################
# VERIFICA PATCH
###############################################################################

if grep -Eq '^[[:space:]]*unbanip[[:space:]]*\(\)' "${DDOS_DIR}/ddos.sh"; then
    fail "La funzione unbanip() è ancora presente in ddos.sh."
fi

if grep -Eq '^[[:space:]]*unbanip[[:space:]]*;?[[:space:]]*$' "${DDOS_DIR}/ddos.sh"; then
    fail "La chiamata unbanip è ancora presente in ddos.sh."
fi

if grep -Eq '^[[:space:]]*(BAN_PERIOD|EMAIL_TO)[[:space:]]*=' "${DDOS_DIR}/ddos.conf"; then
    fail "BAN_PERIOD o EMAIL_TO sono ancora presenti in ddos.conf."
fi

chmod +x "${DDOS_DIR}/ddos.sh"

ok "AntiDDoS adattato a Ubuntu."
ok "Sban automatico DISABILITATO."
ok "BAN_PERIOD rimosso."
ok "EMAIL_TO rimosso."
ok "I ban resteranno permanenti fino allo sban manuale/reset."

###############################################################################
# WHITELIST SERVER PROTETTO
###############################################################################

separator "WHITELIST ANTIDDOS SERVER PROTETTO"

cp -a "${IGNORE_FILE}" "${IGNORE_FILE}.${STAMP}.bak" || true

if grep -Fxq "${BACKEND_IP}" "${IGNORE_FILE}"; then
    ok "${BACKEND_IP} già presente nella whitelist."
else
    echo "${BACKEND_IP}" >> "${IGNORE_FILE}"
    ok "${BACKEND_IP} aggiunto a ${IGNORE_FILE}."
fi

if ! grep -Fxq "${BACKEND_IP}" "${IGNORE_FILE}"; then
    fail "Impossibile inserire ${BACKEND_IP} nella whitelist AntiDDoS."
fi

ln -sfn "${IGNORE_FILE}" /root/ignore.ip.list

echo
echo "IP IMMUNE AL BAN: ${BACKEND_IP}"
echo "FILE:             ${IGNORE_FILE}"
echo
cat "${IGNORE_FILE}"
echo

###############################################################################
# REPORT
###############################################################################

separator "CONFIGURAZIONE REPORT"

mkdir -p /var/www/html
ln -sfn "${BAN_FILE}" /var/www/html/report.txt
chmod 755 "${DDOS_DIR}"
chmod 644 "${BAN_FILE}" "${IGNORE_FILE}"

systemctl restart apache2
ok "Report creato: /var/www/html/report.txt -> ${BAN_FILE}"

###############################################################################
# CRON ANTIDDOS
###############################################################################

separator "CONFIGURAZIONE CRON ANTIDDOS"

cd "${DDOS_DIR}"
bash ./ddos.sh -c

if [[ -f /etc/cron.d/ddos.cron ]]; then
    chmod 644 /etc/cron.d/ddos.cron
    ok "Cron AntiDDoS configurato."
    cat /etc/cron.d/ddos.cron
else
    fail "/etc/cron.d/ddos.cron non creato."
fi

systemctl restart cron

###############################################################################
# COMANDO RESET BAN
###############################################################################

RESET_SCRIPT="/usr/local/sbin/reset-antiddos-bans"

cat > "${RESET_SCRIPT}" <<'RESETEOF'
#!/usr/bin/env bash
set -u
BAN_FILE="/usr/local/ddos/ban.ip.list"

[[ -f "$BAN_FILE" ]] || { echo "Ban list non trovata: $BAN_FILE"; exit 1; }

while IFS= read -r ip; do
    ip="$(printf '%s' "$ip" | tr -d '\r' | xargs)"
    [[ -z "$ip" ]] && continue

    while iptables -C INPUT -s "$ip" -j DROP 2>/dev/null; do
        iptables -D INPUT -s "$ip" -j DROP || break
    done
done < "$BAN_FILE"

truncate -s 0 "$BAN_FILE"

echo "=== PULIZIA BAN ANTIDDOS COMPLETATA ==="
echo "Lista ban:"
cat "$BAN_FILE"
echo
echo "Regole DROP rimaste in INPUT:"
iptables -L INPUT -v -n --line-numbers | grep DROP || true
RESETEOF

chmod 755 "${RESET_SCRIPT}"
ok "Comando reset ban creato: ${RESET_SCRIPT}"

###############################################################################
# PULIZIA FILE TEMPORANEI
###############################################################################

rm -f "${DDOS_ZIP}"
rm -rf "${DDOS_TMP}" 2>/dev/null || true

###############################################################################
# VERIFICHE FINALI
###############################################################################

separator "VERIFICA NGINX"
nginx -t
systemctl restart nginx

echo
grep --color=never -n "proxy_pass" "${NGINX_SITE}" || true
echo

separator "VERIFICA SERVER PROTETTO"
BACKEND_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "http://${BACKEND_IP}:${BACKEND_PORT}/" || true)"
echo "http://${BACKEND_IP}:${BACKEND_PORT} -> HTTP ${BACKEND_CODE:-ERRORE}"

separator "VERIFICA PROXY NGINX"
PROXY_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "http://127.0.0.1/" || true)"
echo "http://127.0.0.1/ -> HTTP ${PROXY_CODE:-ERRORE}"

separator "VERIFICA REPORT APACHE2"
REPORT_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    "http://127.0.0.1:11111/report.txt" || true)"
echo "http://127.0.0.1:11111/report.txt -> HTTP ${REPORT_CODE:-ERRORE}"

separator "VERIFICA WHITELIST"
if grep -Fxq "${BACKEND_IP}" "${IGNORE_FILE}"; then
    ok "${BACKEND_IP} presente in ignore.ip.list: immune al ban AntiDDoS."
else
    fail "${BACKEND_IP} NON presente in ignore.ip.list."
fi

separator "STATO SERVIZI"
for service in nginx apache2 cron; do
    printf '%-12s : ' "$service"
    systemctl is-active "$service" || true
done

separator "PORTE IN ASCOLTO"
ss -lntp | grep -E ':80[[:space:]]|:11111[[:space:]]' || true

separator "IPTABLES INPUT"
iptables -L INPUT -v -n || true

###############################################################################
# RIEPILOGO
###############################################################################

separator "INSTALLAZIONE COMPLETATA"

echo -e "${GREEN}INSTALLAZIONE COMPLETATA${NC}"
echo
echo "=============================================================="
echo " VPS PROXY"
echo "=============================================================="
echo "Hostname:       $(hostname)"
echo "IP pubblico:    ${PROXY_PUBLIC_IP:-NON_RILEVATO}"
echo
echo "=============================================================="
echo " NGINX"
echo "=============================================================="
echo "Porta Proxy:    80"
echo "Backend IP:     ${BACKEND_IP}"
echo "Backend porta:  ${BACKEND_PORT}"
echo "Proxy Pass:     http://${BACKEND_IP}:${BACKEND_PORT}"
echo "Config Ubuntu:  ${NGINX_SITE}"
echo
echo "=============================================================="
echo " WHITELIST ANTIDDOS"
echo "=============================================================="
echo "IP immune:      ${BACKEND_IP}"
echo "File:           ${IGNORE_FILE}"
echo "Link rapido:    /root/ignore.ip.list"
echo
echo "=============================================================="
echo " ANTIDDOS"
echo "=============================================================="
echo "Directory:      ${DDOS_DIR}"
echo "Controllo:      /usr/local/ddos/ddos.sh"
echo "IP bannati:     cat /usr/local/ddos/ban.ip.list"
echo "IP immuni:      cat /usr/local/ddos/ignore.ip.list"
echo "Reset ban:      reset-antiddos-bans"
echo
echo "=============================================================="
echo " REPORT"
echo "=============================================================="
if [[ -n "${PROXY_PUBLIC_IP}" ]]; then
    echo "http://${PROXY_PUBLIC_IP}:11111/report.txt"
else
    echo "IP pubblico non rilevato. Porta report: 11111/report.txt"
fi
echo
echo "=============================================================="
echo " SBANNARE UN SINGOLO IP"
echo "=============================================================="
echo "iptables -D INPUT -s IP_DA_SBANNARE -j DROP"
echo "nano /usr/local/ddos/ban.ip.list"
echo
echo "=============================================================="
echo " PULIRE TUTTI I BAN ANTIDDOS"
echo "=============================================================="
echo "reset-antiddos-bans"
echo
echo "=============================================================="
echo " BACKUP"
echo "=============================================================="
echo "Nginx:          ${NGINX_SITE}.${STAMP}.bak"
echo "Apache ports:   ${APACHE_PORTS}.${STAMP}.bak"
echo "Apache site:    ${APACHE_SITE}.${STAMP}.bak"
echo "APT sources:    ${APT_BACKUP_DIR}"
echo "Dati setup:     ${INSTALL_INFO}"
echo
echo "======================================================================"
echo "                              FINE"
echo "======================================================================"
echo
