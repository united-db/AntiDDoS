# Proxy Reverse Proxy + AntiDDoS — Ubuntu 22.04 LTS

Installer interattivo per configurare una VPS Ubuntu 22.04 LTS come **reverse proxy HTTP Nginx**, con **Apache2 per il report** e **AntiDDoS basato su iptables**.

> **Ambito:** questa configurazione protegge e inoltra il traffico HTTP in ingresso sulla porta **80**. Non configura automaticamente HTTPS/TLS sulla porta 443, né fornisce protezione contro attacchi volumetrici che saturano la banda della VPS. L'installer non configura UFW o firewalld; eventuali firewall del provider e regole già presenti rimangono da verificare.

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

- VPS con Ubuntu 22.04 LTS, accesso `root` e connettività ai repository APT e a GitHub.
- Indirizzo IPv4 e porta HTTP del server originale da proteggere.
- Porte necessarie abilitate nel firewall del provider: **80/TCP** per il proxy; **11111/TCP** solo se si desidera consultare il report da remoto.
- Backup o snapshot della VPS prima dell'esecuzione, specialmente se Nginx o Apache2 sono già configurati.

**Sicurezza:** il report contiene gli IP bloccati. È preferibile non esporre pubblicamente la porta 11111: consentire l'accesso solo al proprio IP di amministrazione mediante firewall del provider o altre restrizioni. Non pubblicare il report senza controllo degli accessi.

## Installazione automatica

Copiare `install_proxy_ubuntu22.sh` sulla VPS in /root, poi accedere come `root`:

```bash
sudo -i
cd /root
chmod +x install_proxy_ubuntu22.sh
bash ./install_proxy_ubuntu22.sh
```

L'installer chiede:

```text
IP SERVER DA PROTEGGERE: 185.100.100.50
PORTA SERVER DA PROTEGGERE [80]: 80
```

Gli indirizzi sono **esempi**: usare i dati reali del proprio backend. Al termine Nginx invierà il traffico a `http://IP_BACKEND:PORTA`, e l'IP del backend sarà aggiunto alla whitelist AntiDDoS.

### Operazioni effettuate dallo script

1. Verifica i permessi di root e il sistema operativo (progettato per Ubuntu 22.04).
2. Imposta l'hostname `Proxy` e aggiorna `/etc/hosts`.
3. Salva una copia dei repository APT, converte specifici mirror Ubuntu HTTP in HTTPS, aggiorna l'indice APT e i pacchetti.
4. Installa gli strumenti, Nginx, Apache2, PHP, iptables e cron.
5. Richiede l'IP e la porta del server originale; prova a rilevare l'IP pubblico della VPS.
6. Esegue un test preliminare del backend.
7. Modifica il server block predefinito di Nginx per `proxy_pass http://IP_BACKEND:PORTA;` sulla porta 80.
8. Configura Apache2 sulla porta 11111.
9. Scarica `united-db/AntiDDoS` da GitHub in `/usr/local/ddos`, corregge la compatibilità Bash/Ubuntu e **rimuove la funzione di sblocco automatico `unbanip`**.
10. Elimina `BAN_PERIOD` ed `EMAIL_TO` dalla configurazione AntiDDoS (niente timer di sban e niente notifiche email del vecchio script).
11. Inserisce l'IP del server protetto in `ignore.ip.list`.
12. Crea `/var/www/html/report.txt` come link all'elenco dei ban, configura cron, crea il comando `reset-antiddos-bans` ed esegue verifiche finali.

**Nota:** lo script scarica il ramo `master` di AntiDDoS; poiché il contenuto remoto può cambiare, è consigliabile revisionarlo e fissare una versione verificata prima dell'uso in produzione.

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

## Controlli dopo l'installazione

```bash
systemctl status nginx apache2 cron
nginx -t
apache2ctl configtest
ss -lntp | grep -E ':80\b|:11111\b'
```

Controllare la destinazione del reverse proxy:

```bash
grep -n 'proxy_pass' /etc/nginx/sites-available/default
curl -I http://127.0.0.1/
```

Controllare il report locale:

```bash
curl http://127.0.0.1:11111/report.txt
```

Da remoto, **solo se la porta è consentita e opportunamente protetta**:

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

### Sbloccare un solo IP

Sostituire `203.0.113.10` con l'IP effettivo:

```bash
IP="203.0.113.10"
iptables -D INPUT -s "$IP" -j DROP
sed -i "\\|^${IP//./\\.}$|d" /usr/local/ddos/ban.ip.list
```

Il comando `iptables -D` rimuove **una** regola corrispondente; se esistono più regole DROP identiche, verificare con `iptables -C` e rimuovere le eventuali duplicazioni. Assicurarsi inoltre di togliere l'IP dal file dei ban, altrimenti AntiDDoS continuerà a considerarlo già bannato.

### Sbloccare tutti gli IP AntiDDoS

```bash
reset-antiddos-bans
```

Questo comando rimuove le regole `INPUT DROP` relative agli indirizzi contenuti in `ban.ip.list` e svuota l'elenco. Non equivale a cancellare tutto il firewall e non rimuove necessariamente ogni altra regola DROP del sistema.

### Modificare la whitelist

```bash
nano /usr/local/ddos/ignore.ip.list
```

Inserire **un IPv4 per riga**. Il backend configurato durante l'installazione viene aggiunto automaticamente. Per visualizzare gli IP ignorati:

```bash
cat /usr/local/ddos/ignore.ip.list
```

### Modificare la soglia AntiDDoS

```bash
nano /usr/local/ddos/ddos.conf
```

Controllare il valore di `NO_OF_CONNECTIONS` e gli altri parametri disponibili nella versione installata. **Non** aggiungere `BAN_PERIOD` come soluzione per rendere persistenti i ban: l'installer elimina la funzione di sblocco temporizzato.

### Verificare il cron

```bash
cat /etc/cron.d/ddos.cron
systemctl status cron
```

La frequenza effettiva dipende da `FREQ` in `ddos.conf` e dal cron generato da `ddos.sh -c` (impostazione prevista: ogni minuto). **Non aggiungere una seconda voce in `/etc/crontab`** se il job esiste già, per evitare esecuzioni duplicate.

## Ban permanenti: cosa significa

Nella versione installata, AntiDDoS **non pianifica più uno sblocco dopo `BAN_PERIOD`**. I ban rimangono applicati fino a un intervento manuale o a un reset.

**Attenzione al riavvio:** l'installer attuale non configura la persistenza delle regole iptables, né il loro ripristino dal file `ban.ip.list` al boot. Dopo un riavvio, le regole potrebbero sparire, anche se l'IP resta nel file dei ban. Per garantire una protezione coerente dopo il reboot occorre progettare e testare un meccanismo separato di salvataggio/ripristino o risincronizzazione, tenendo conto delle altre regole firewall già presenti.

## Gestione servizi

```bash
systemctl restart nginx
systemctl restart apache2
systemctl restart cron
systemctl status nginx apache2 cron
```

Log utili:

```bash
journalctl -u nginx -n 100 --no-pager
journalctl -u apache2 -n 100 --no-pager
journalctl -u cron -n 100 --no-pager
tail -n 100 /var/log/nginx/error.log
tail -n 100 /var/log/apache2/error.log
```

**Non usare** i vecchi cron che cancellavano ogni minuto `/tmp/systemd-private*`, la cronologia della shell o i log di audit, accesso e sicurezza: possono interferire con i servizi e impedire diagnosi e analisi degli incidenti. Per la rotazione dei log utilizzare `logrotate` e le configurazioni standard di Ubuntu.

## Backup e ripristino

Durante l'installazione vengono create copie di backup, marcate con data e ora, dei file Nginx/Apache modificati, dell'eventuale directory AntiDDoS esistente e dei repository APT. Nel riepilogo finale sono riportati i percorsi dei backup.

Per esaminare i dati di configurazione scelti:

```bash
cat /root/proxy-install-info.txt
```

Prima di rieseguire l'installer su una macchina configurata, eseguire un backup completo: lo script sovrascrive il server block predefinito Nginx, interviene sulle impostazioni Apache e sostituisce la directory AntiDDoS (dopo averne creato il backup).

## Note e limiti di sicurezza

- Il proxy è **HTTP**: HTTPS non viene configurato automaticamente.
- Il solo `iptables DROP` non garantisce mitigazione di attacchi DDoS volumetrici; per questi servono protezioni di rete a monte.
- La whitelist AntiDDoS riguarda lo script di ban, **non** costituisce di per sé una regola firewall `ACCEPT`.
- Il server originale deve essere configurato per accettare il traffico dal proxy e, se richiesto, evitare l'accesso pubblico diretto che aggirerebbe il proxy.
- Lo script originale AntiDDoS è datato: la classificazione tramite numero di connessioni può causare falsi positivi (es. utenti dietro NAT). Verificare soglie e comportamento prima di affidargli traffico importante.
- Lo script non configura automaticamente il firewall del provider né un servizio generale di gestione firewall.

## Progetto upstream

AntiDDoS: https://github.com/united-db/AntiDDoS

Installer locale: `install_proxy_ubuntu22.sh`.
