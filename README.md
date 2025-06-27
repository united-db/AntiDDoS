# AntiDDoS
```
yum update && yum Upgrade
sudo hostnamectl set-hostname Proxy
yum install wget vim nano perl-libwww-perl.noarch perl-Time-HiRes
yum install epel-release
yum install nginx
systemctl enable nginx
systemctl restart nginx
systemctl status nginx

nano /etc/nginx/nginx.conf
**************************************************************************
#Sostituire Con le Righe Sottostanti
**************************************************************************
server {
        listen       80 default_server;
        listen       [::]:80 default_server;
		server_name  _;
        root         /usr/share/nginx/html;

        # Load configuration files for the default server block.
        include /etc/nginx/default.d/*.conf;

        location / {
                proxy_buffers 16 4k;
                proxy_pass http://localhost;
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
        }        
**************************************************************************
yum install firewalld
systemctl enable firewalld
systemctl start firewalld
systemctl status firewalld

firewall-cmd --state
firewall-cmd --zone=public --permanent --add-service=http
firewall-cmd --zone=public --permanent --add-service=https
firewall-cmd --zone=public --permanent --list-services
**************************************************************************
nano /etc/firewalld/firewalld.conf
#sulla riga AllowZoneDrifting=yes sostituire yes con no
**************************************************************************
firewall-cmd --zone=public --add-port=80/tcp --permanent
firewall-cmd --zone=public --permanent --list-ports
systemctl restart firewalld
systemctl status firewalld
systemctl status nginx

#########################################################################
**************************************************************************
**************************************************************************
sudo yum update
sudo yum install httpd
sudo systemctl start httpd.service
sudo firewall-cmd --permanent --add-port=11111/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload
sudo nano /etc/httpd/conf/httpd.conf
****Cercare Listen 80****
****Sotituire Con Listen 11111****
sudo systemctl restart httpd.service
sudo firewall-cmd --permanent --add-port=11111/tcp
sudo firewall-cmd --reload
sudo yum install php php-mysql
sudo systemctl restart httpd
**************************************************************************
cd /usr/local
wget https://github.com/united-db/AntiDDoS/archive/refs/heads/master.zip
yum install -y zip unzip
unzip master.zip
mv AntiDDoS-master/ ddos
cd ddos
chmod +x ddos.sh
./ddos.sh -c
**************************************************************************
ln -sf /usr/local/ddos/ban.ip.list /var/www/html/report.txt
ln -s /usr/local/ddos/ignore.ip.list /root/
**************************************************************************
nano /etc/crontab
#****AGGIUNGERE RIGHE E SALVARE****

0-59/1 * * * * root /usr/local/ddos/ddos.sh
0-59/1 * * * * root rm -rf /tmp/ban.*
0-59/1 * * * * root rm -rf /tmp/systemd-private*
0-59/1 * * * * root truncate -s 0 /var/log/nginx/access.log
0-59/1 * * * * root truncate -s 0 /var/log/nginx/error.log
0-59/1 * * * * root truncate -s 0 /var/log/audit/audit.*
0-59/1 * * * * root truncate -s 0 /var/log/httpd/access_log
0-59/1 * * * * root truncate -s 0 /var/log/httpd/error_log
0-59/1 * * * * root truncate -s 0 /var/log/secure
0-59/1 * * * * root truncate -s 0 /var/log/btmp
0-59/1 * * * * root truncate -s 0 /var/log/lastlog
0-59/1 * * * * root truncate -s 0 /var/log/cron
0-59/1 * * * * root truncate -s 0 /var/log/messages
0-59/1 * * * * root truncate -s 0 /var/log/tallylog
0-59/1 * * * * root truncate -s 0 /var/log/dmesg
**************************************************************************
systemctl restart firewalld && systemctl restart nginx
systemctl status firewalld && systemctl status nginx
cat /dev/null > ~/.bash_history && history -c && exit
**************************************************************************
**************************************************************************
**************************************************************************
#CONTROLLO RICHIESTE IP:
/usr/local/ddos/ddos.sh
**************************************************************************
#LISTA IP BANNATI:
iptables -L INPUT -v -n
http://localhost:11111/report.txt
**************************************************************************
#SBANNARE UN IP:
iptables -D INPUT -s IP_DA_SBANNARE -j DROP
nano /usr/local/ddos/ban.ip.list
**************************************************************************
truncate -s 0 /var/www/html/report.txt && systemctl restart firewalld && systemctl restart nginx && systemctl restart httpd && systemctl status firewalld && systemctl status nginx && systemctl status httpd
**************************************************************************
**************************************************************************
**************************************************************************
