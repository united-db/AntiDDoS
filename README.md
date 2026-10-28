# Proxy Reverse Proxy + AntiDDoS — Ubuntu 22.04 LTS

Installer interattivo per configurare una VPS **Ubuntu 22.04 LTS** come **reverse proxy HTTP Nginx**, con **Apache2 per il report** e **AntiDDoS basato su iptables**.

> **Ambito:** questa configurazione protegge e inoltra il traffico HTTP in ingresso sulla porta **80**. Non configura automaticamente HTTPS/TLS sulla porta 443, né protegge da attacchi volumetrici che saturano la banda della VPS. L'installer non configura UFW o firewalld: verificare le regole firewall già presenti e quelle del provider.

## Architettura

```text
Client Internet
      |
      | HTTP :80
      v
VPS Proxy (Ubuntu 22.04)
  |-- Nginx :80 --------> Server originale (IP e porta scelti durante il setup)
  |-- Apache2 :11111 ---> /report.txt (elenco IP bloccati)
  |-- AntiDDoS ---------> iptables INPUT (DROP IP)
  `-- cron -------------> esecuzione periodica AntiDDoS
```

## Prerequisiti

- VPS con Ubuntu 22.04 LTS e accesso `root` (o `sudo`).
- Connettività ai repository APT e a GitHub (`raw.githubusercontent.com`).
- Indirizzo IPv4 e porta HTTP del server originale da proteggere.
- Porta **80/TCP** abilitata nel firewall del provider. Abilitare **11111/TCP** solo se è necessario consultare il report da remoto, limitandola agli IP autorizzati.
- Backup o snapshot della VPS prima dell'installazione, soprattutto se sono già presenti configurazioni Nginx, Apache2 o iptables.

**Sicurezza:** il report contiene gli indirizzi IP bloccati. Evitare di esporre la porta 11111 pubblicamente: limitarne l'accesso all'IP dell'amministratore o utilizzare un altro sistema di autenticazione/protezione.

## Installazione automatica da GitHub

**Non è più necessario caricare o spostare manualmente lo script sulla VPS.** Collegarsi via SSH e ottenere una shell `root`:

```bash
sudo -i
```

Quindi eseguire **questo unico comando**:

```bash
apt-get update && apt-get install -y wget && wget -O /root/install_proxy_ubuntu22.sh https://raw.githubusercontent.com/united-db/AntiDDoS/master/install_proxy_ubuntu22.sh && chmod +x /root/install_proxy_ubuntu22.sh && bash /root/install_proxy_ubuntu22.sh
```

Il comando:

1. Aggiorna l'indice dei pacchetti APT e installa `wget` se manca.
2. Scarica l'installer dal repository GitHub in `/root/install_proxy_ubuntu22.sh`.
3. Rende eseguibile il file scaricato.
4. Avvia la configurazione interattiva di proxy, report e AntiDDoS.

Durante l'installazione vengono richiesti, ad esempio:

```text
IP SERVER DA PROTEGGERE: 185.100.100.50
PORTA SERVER DA PROTEGGERE [80]: 80
```

Gli indirizzi sono **esempi**: inserire l'IP e la porta HTTP reali del backend. Nginx inoltrerà il traffico a `http://IP_BACKEND:PORTA` e l'IP del backend sarà aggiunto alla whitelist AntiDDoS.

> **Attenzione:** il file viene scaricato dal ramo `master`, che può cambiare. Prima di eseguirlo con privilegi `root` su sistemi di produzione, è preferibile verificare il contenuto e fissare un commit GitHub attendibile. Scaricare uno script da Internet ed eseguirlo come root comporta rischi.

### Aggiornamento dei pacchetti Ubuntu (facoltativo)

Se si desidera aggiornare completamente i pacchetti di sistema **prima** di installare il proxy, eseguire separatamente:

```bash
apt update && apt upgrade -y && apt autoremove -y && apt autoclean
```

Questa operazione può aggiornare servizi già installati e rimuovere pacchetti non più necessari. Non è indispensabile per scaricare lo script; valutare un riavvio se richiesto dagli aggiornamenti.

### Rieseguire un installer già scaricato

Se il file è ancora presente in `/root`, non serve riscaricarlo:

```bash
bash /root/install_proxy_ubuntu22.sh
```

**Non rieseguire l'installer su una VPS già configurata senza backup:** potrebbe sovrascrivere impostazioni Nginx/Apache e ricreare l'installazione AntiDDoS. Questa non è una procedura di semplice aggiornamento.

## Operazioni effettuate dallo script

1. Verifica i privilegi `root` e rileva il sistema operativo (progettato per Ubuntu 22.04 LTS).
2. Imposta l'hostname `Proxy` e aggiorna `/etc/hosts`.
3. Salva una copia dei repository APT, converte specifici mirror Ubuntu da HTTP a HTTPS, aggiorna l'indice APT e i pacchetti.
4. Installa gli strumenti necessari, Nginx, Apache2, PHP, iptables e cron.
5. Richiede l'IP e la porta del backend e tenta di rilevare l'IP pubblico della VPS.
6. Esegue un controllo preliminare del backend.
7. Configura il server block predefinito Nginx per `proxy_pass http://IP_BACKEND:PORTA;` sulla porta 80.
8. Configura Apache2 sulla porta 11111 per pubblicare il report.
9. Installa `united-db/AntiDDoS` in `/usr/local/ddos`, applica le modifiche di compatibilità Bash/Ubuntu e rimuove la funzione di sblocco automatico `unbanip`.
10. Elimina `BAN_PERIOD` ed `EMAIL_TO` dalla configurazione AntiDDoS.
11. Aggiunge l'IP del backend a `ignore.ip.list`.
12. Collega `/var/www/html/report.txt` all'elenco dei ban, configura cron, crea il comando `reset-antiddos-bans` ed esegue le verifiche finali.

## Porte e percorsi

| Componente | Porta | Percorso principale |
|---|---|---|
| Nginx reverse proxy | `80/TCP` | `/etc/nginx/sites-available/default` |
| Apache2 (report) | `11111/TCP` | `/etc/apache2/ports.conf` e `/etc/apache2/sites-available/000-default.conf` |
| AntiDDoS | — | `/usr/local/ddos/ddos.sh` |
| Configurazione AntiDDoS | — | `/usr/local/ddos/ddos.conf` |
| IP bannati | — | `/usr/local/ddos/ban.ip.list` |
| IP esclusi dai ban | — | `/usr/local/ddos/ignore.ip.list` |
| Pianificazione AntiDDoS | — | `/etc/cron.d/ddos.cron` |
| Report | `11111/TCP` | `/var/www/html/report.txt` → `/usr/local/ddos/ban.ip.list` |
| Riepilogo installazione | — | `/root/proxy-install-info.txt` (permessi 600) |
| Installer scaricato | — | `/root/install_proxy_ubuntu22.sh` |

## Controlli dopo l'installazione

Verificare servizi, configurazioni e porte in ascolto:

```bash
systemctl status nginx apache2 cron --no-pager
nginx -t
apache2ctl configtest
ss -lntp | grep -E ':80\b|:11111\b'
```

Controllare la destinazione del reverse proxy:

```bash
grep -n 'proxy_pass' /etc/nginx/sites-available/default
curl -I http://127.0.0.1/
```

Verificare il report locale:

```bash
curl http://127.0.0.1:11111/report.txt
```

Da remoto, **soltanto se l'accesso è stato limitato e autorizzato**:

```text
http://IP_PUBBLICO_VPS:11111/report.txt
```

## AntiDDoS: monitoraggio e gestione

### Eseguire un controllo manuale

```bash
bash /usr/local/ddos/ddos.sh
```

### Visualizzare gli IP bannati

```bash
cat /usr/local/ddos/ban.ip.list
iptables -L INPUT -v -n --line-numbers
```

### Sbloccare un singolo IP

Sostituire `203.0.113.10` con un indirizzo reale da sbloccare:

```bash
IP="203.0.113.10"
iptables -D INPUT -s "$IP" -j DROP
sed -i "\\|^${IP//./\\.}$|d" /usr/local/ddos/ban.ip.list
```

`iptables -D` rimuove una sola regola corrispondente. Se ci sono regole DROP duplicate, verificarle prima di rimuoverle. Eliminare anche l'IP dal file dei ban per mantenere coerenti elenco e firewall.

### Sbloccare tutti gli IP AntiDDoS

**Solo quando si desidera davvero azzerare i ban:**

```bash
reset-antiddos-bans
```

Il comando rimuove le regole `INPUT DROP` riferite agli IP presenti in `ban.ip.list` e svuota l'elenco. Non cancella tutto il firewall né necessariamente altre regole DROP.

**Non eseguire automaticamente `truncate -s 0 /var/www/html/report.txt`:** il report è un link simbolico al file `ban.ip.list`; svuotarlo direttamente può rendere incoerente lo stato dei ban rispetto a iptables. Utilizzare invece `reset-antiddos-bans` quando è necessario il reset.

### Modificare la whitelist

```bash
nano /usr/local/ddos/ignore.ip.list
```

Inserire un IPv4 per riga. Il backend viene aggiunto automaticamente durante l'installazione. Per leggere la lista:

```bash
cat /usr/local/ddos/ignore.ip.list
```

### Modificare la soglia AntiDDoS

```bash
nano /usr/local/ddos/ddos.conf
```

Controllare `NO_OF_CONNECTIONS` e gli altri parametri disponibili. Non reinserire `BAN_PERIOD` per rendere persistenti i ban: l'installer disabilita lo sblocco temporizzato.

### Verificare il cron

```bash
cat /etc/cron.d/ddos.cron
systemctl status cron --no-pager
```

La frequenza effettiva dipende dal valore `FREQ` in `ddos.conf` e dal cron generato da `ddos.sh -c` (frequenza prevista: ogni minuto). **Non aggiungere un secondo job in `/etc/crontab`** se esiste già quello configurato.

## Ban permanenti: cosa significa

AntiDDoS, nella versione predisposta dall'installer, **non programma più lo sblocco automatico in base a `BAN_PERIOD`**. I ban restano attivi finché le relative regole firewall non vengono rimosse o il firewall viene ripristinato.

**Dopo un riavvio:** l'installer non garantisce la persistenza o il ripristino delle regole iptables. Le regole possono sparire mentre gli IP restano in `ban.ip.list`. Occorre un meccanismo separato di persistenza o risincronizzazione, da progettare e testare tenendo conto delle altre regole firewall.

## Gestione servizi

```bash
systemctl restart nginx apache2 cron
systemctl status nginx apache2 cron --no-pager
```

Per consultare i log:

```bash
journalctl -u nginx -n 100 --no-pager
journalctl -u apache2 -n 100 --no-pager
journalctl -u cron -n 100 --no-pager
tail -n 100 /var/log/nginx/error.log
tail -n 100 /var/log/apache2/error.log
```

Non utilizzare vecchi cron che cancellano indiscriminatamente `/tmp/systemd-private*`, cronologia della shell o log di audit e sicurezza: possono interrompere servizi e impedire diagnosi. Usare `logrotate` per gestire i log.

## Backup e ripristino

Durante l'installazione lo script crea backup con data e ora dei file Nginx/Apache modificati, delle eventuali configurazioni precedenti AntiDDoS e dei repository APT. Verificare i percorsi riportati nel riepilogo dell'installer.

```bash
cat /root/proxy-install-info.txt
```

Prima di ripetere l'installazione su una macchina già configurata, eseguire uno snapshot o backup completo. Lo script può sostituire il server block Nginx predefinito, modificare Apache2 e sostituire la directory AntiDDoS dopo averne creato una copia.

## Note e limiti di sicurezza

- Questa soluzione configura il proxy **HTTP**, non HTTPS/TLS.
- Le regole `iptables DROP` non mitigano gli attacchi DDoS che saturano la connettività a monte della VPS.
- La whitelist AntiDDoS evita i ban generati dallo script; non equivale a una regola firewall generale `ACCEPT`.
- Proteggere il backend da accessi diretti non autorizzati, se si vuole obbligare il traffico a passare dal proxy.
- Le soglie basate sul numero di connessioni possono provocare falsi positivi, in particolare per client dietro NAT.
- Non vengono configurati il firewall del provider, UFW o firewalld.
- Il ramo GitHub `master` può variare: in produzione verificare il codice prima di eseguirlo con privilegi `root`.

## Progetto upstream

- Repository AntiDDoS: https://github.com/united-db/AntiDDoS
- Installer automatico: https://raw.githubusercontent.com/united-db/AntiDDoS/master/install_proxy_ubuntu22.sh
- File locale dopo il download: `/root/install_proxy_ubuntu22.sh`
