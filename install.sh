#!/bin/bash
set -euo pipefail

# --- Password Authentication ---
REQUIRED_PASSWORD="nethead001techgeniusvpsscript"

read -s -p "Enter the script password: " input_password
echo
if [ "$input_password" != "$REQUIRED_PASSWORD" ]; then
  echo "Invalid password. Exiting."
  exit 1
fi

MARK_FILE="/etc/setup_completed"

# --- Functions for Client Configurations ---
create_hysteria_client_config() {
  local cname="$1"
  local cpass="$2"
  local config_dir="/root/hysteria_clients_configs"
  mkdir -p "$config_dir"
  cat > "$config_dir/${cname}_client.json" <<EOF
{
  "server": "$(hostname -I | awk '{print $1}')",
  "port": 10443,
  "protocol": "udp",
  "obfs": "websocket",
  "obfs_url": "/hysteria",
  "auth": "password",
  "password": "$cpass"
}
EOF
  echo "Hysteria client config for '$cname' created at $config_dir/${cname}_client.json"
}

create_ssh_client() {
  local username="$1"
  local password="$2"
  useradd -m -s /bin/bash "$username"
  echo "$username:$password" | chpasswd
  echo "$username|$password" >> /root/ssh_clients.txt
  echo "SSH user '$username' created with password '$password'."
}

create_dropbear_client() {
  local username="$1"
  local password="$2"
  echo "$username|$password" >> /root/dropbear_clients.txt
  echo "Dropbear credentials for '$username' saved."
}

create_xray_client() {
  local cname="$1"
  local cuuid="$2"
  local config_dir="/root/xray_clients_configs"
  mkdir -p "$config_dir"
  cat > "$config_dir/${cname}_client.json" <<EOF
{
  "v": "2",
  "ps": "$cname",
  "add": "$(hostname -I | awk '{print $1}')",
  "port": 443,
  "id": "$cuuid",
  "aid": 0,
  "net": "ws",
  "type": "none",
  "host": "$(hostname -I | awk '{print $1}')",
  "path": "/vlessws",
  "tls": "true"
}
EOF
  echo "Xray client config for '$cname' created."
}

create_trojan_client() {
  local cname="$1"
  local password="$2"
  echo "$cname|$password" >> /root/trojan_clients.txt
  echo "Trojan client '$cname' added with password '$password'."
}

# --- Check for root ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

# Skip if already installed
if [ -f "$MARK_FILE" ]; then
  echo "Setup already completed."
  exit 0
fi

# --- Basic setup ---
read -p "Enter your domain (must point to your VPS IP): " DOMAIN

# Update & install essentials
apt update && apt upgrade -y
apt install -y nginx dropbear openssh-server curl unzip ufw certbot python3-certbot-nginx

# Backup configs
mkdir -p /root/backup_configs
cp /etc/ssh/sshd_config /root/backup_configs/sshd_config.bak || true
cp /etc/default/dropbear /root/backup_configs/dropbear.bak || true
cp /etc/nginx/sites-available/default /root/backup_configs/nginx_default.bak || true

# --- SSH & Dropbear setup ---
sed -i 's/^#Port 22/Port 22/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh

sed -i 's/^NO_START=1/NO_START=0/' /etc/default/dropbear
sed -i 's/^#DROPBEAR_PORT=22/DROPBEAR_PORT=445/' /etc/default/dropbear
systemctl enable dropbear && systemctl restart dropbear

# Firewall rules
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp 80/tcp 443/tcp 8080/tcp 8443/tcp 9443/tcp 10443/tcp
ufw allow 53/tcp 109/tcp 3303/tcp 143/tcp 8888/tcp 8181/tcp 8282/tcp 8383/tcp 7100/tcp 7200/tcp 7300/tcp
ufw --force enable

# --- SSL certificate ---
echo "Obtaining SSL for $DOMAIN..."
certbot certonly --nginx --non-interactive --agree-tos --register-unsafely-without-email -d "$DOMAIN"

SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

# --- Nginx config ---
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    root /var/www/html;
    index index.html index.htm;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
systemctl enable nginx && systemctl restart nginx

# --- Install Xray ---
bash <(curl -L -s https://github.com/XTLS/Xray-core/releases/latest/download/install-release.sh)
UUID=$(uuidgen)

# Xray config
cat > /etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "$SSL_CERT",
              "keyFile": "$SSL_KEY"
            }
          ]
        },
        "wsSettings": {
          "path": "/vlessws",
          "headers": { "Host": "$DOMAIN" }
        }
      }
    }
  ],
  "outbounds": [{"protocol": "fregedom", "settings": {}}]
}
EOF
systemctl enable xray && systemctl restart xray

# --- Trojan-GFW / Trojan-Go ---
PASSWORD=$(uuidgen)
curl -L -o /tmp/trojan-go.zip https://github.com/trojan-gfw/trojan-go/releases/latest/download/trojan-go-linux-amd64.zip
unzip /tmp/trojan-go.zip -d /usr/local/bin/
chmod +x /usr/local/bin/trojan-go

# Trojan-Go config
cat > /etc/trojan-go/config.json <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 9443,
  "password": ["$PASSWORD"],
  "ssl": {
    "cert": "$SSL_CERT",
    "key": "$SSL_KEY"
  },
  "websocket": {
    "enabled": true,
    "path": "/trojan",
    "host": "$DOMAIN"
  }
}
EOF

# Trojan-Go systemd
cat > /etc/systemd/system/trojan-go.service <<EOF
[Unit]
Description=Trojan-Go Service
After=network.target
[Service]
ExecStart=/usr/local/bin/trojan-go -config /etc/trojan-go/config.json
Restart=on-failure
User=nobody
Group=nogroup
[Install]
WantedBy=multi-user.target
EOF
systemctl enable trojan-go && systemctl restart trojan-go

# --- Install Hysteria ---
curl -L -o /usr/local/bin/hysteria https://github.com/mmmwhy/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

# Hysteria config
cat > /etc/hysteria/config.json <<EOF
{
  "listen": ":10443",
  "cert": "$SSL_CERT",
  "key": "$SSL_KEY",
  "protocol": "udp",
  "obfs": "websocket",
  "obfs_url": "/hysteria",
  "auth": "password",
  "password": "$PASSWORD"
}
EOF

# Hysteria systemd
cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria Server
After=network.target
[Service]
ExecStart=/usr/local/bin/hysteria -c /etc/hysteria/config.json
Restart=on-failure
User=nobody
Group=nogroup
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hysteria
systemctl restart hysteria

# --- Create Clients and Configs ---
create_ssh_client "clientssh1" "Pass1234"
create_dropbear_client "clientdb1" "Pass1234"
Xray_UUID=$(uuidgen)
create_xray_client "clientxray1" "$Xray_UUID"
TROJAN_PASS=$(uuidgen)
create_trojan_client "clienttrojan1" "$TROJAN_PASS"
HYSTERIA_PASS=$(uuidgen)
create_hysteria_client_config "clienthysteria1" "$HYSTERIA_PASS"

# --- Create Main Menu & Client Management ---
cat > /root/menu.sh <<'EOF'
#!/bin/bash
# Source functions
source /root/client_functions.sh

# Main Menu Script
function get_status() {
  systemctl is-active "$1" &>/dev/null && echo "ON" || echo "OFF"
}
function check_hysteria() {
  if systemctl is-active hysteria &>/dev/null; then
    if ss -lnt | grep -q ':10443'; then echo "ON"; else echo "OFF"; fi
  else
    echo "OFF"
  fi
}
function build_status_line() {
  echo "==============================="
  echo " SSH: $(get_status ssh)"
  echo " DROPBEAR: $(get_status dropbear)"
  echo " NGINX: $(get_status nginx)"
  echo " XRAY: $(get_status xray)"
  echo " TROJAN: $(get_status trojan-go)"
  echo " WS: $(check_hysteria)"
  echo "==============================="
}
build_status_line
echo ""
echo "======== SERVER MANAGEMENT ========"
echo "1) Restart SSH"
echo "2) Restart Dropbear"
echo "3) Restart Nginx"
echo "4) Restart Xray"
echo "5) Restart Trojan"
echo "6) Restart Hysteria"
echo "7) Manage SSH Clients"
echo "8) Manage Dropbear Clients"
echo "9) Manage Xray Clients"
echo "10) Manage Trojan Clients"
echo "11) Manage Hysteria Clients"
echo "0) Exit"
read -p "Choose: " choice
case "$choice" in
  1) service ssh restart; bash /root/menu.sh ;;
  2) systemctl restart dropbear; bash /root/menu.sh ;;
  3) systemctl restart nginx; bash /root/menu.sh ;;
  4) systemctl restart xray; bash /root/menu.sh ;;
  5) systemctl restart trojan-go; bash /root/menu.sh ;;
  6) systemctl restart hysteria; bash /root/menu.sh ;;
  7) bash /root/manage_ssh_clients.sh; bash /root/menu.sh ;;
  8) bash /root/manage_dropbear_clients.sh; bash /root/menu.sh ;;
  9) bash /root/manage_xray_clients.sh; bash /root/menu.sh ;;
  10) bash /root/manage_trojan_clients.sh; bash /root/menu.sh ;;
  11) bash /root/manage_hysteria_clients.sh; bash /root/menu.sh ;;
  0) echo "Goodbye!"; exit ;;
  *) bash /root/menu.sh ;;
esac
EOF
chmod +x /root/menu.sh

# --- Client Management Scripts ---

# SSH Clients Management
cat > /root/manage_ssh_clients.sh <<'EOF'
#!/bin/bash
# Source functions
source /root/client_functions.sh
while true; do
  clear
  echo "=== SSH Clients Management ==="
  echo "1) List SSH Users"
  echo "2) Add SSH User"
  echo "3) Remove SSH User"
  echo "0) Back"
  read -p "Choice: " c
  case "$c" in
    1) cat /root/ssh_clients.txt; read -n1 -s -r -p "Press any key"; ;;
    2)
      read -p "Username: " u
      read -p "Password: " p
      create_ssh_client "$u" "$p"
      ;;
    3)
      nl /root/ssh_clients.txt
      read -p "Number to remove: " n
      sed -i "${n}d" /root/ssh_clients.txt
      ;;
    0) break ;;
  esac
done
EOF
chmod +x /root/manage_ssh_clients.sh

# Dropbear Clients Management
cat > /root/manage_dropbear_clients.sh <<'EOF'
#!/bin/bash
# Source functions
source /root/client_functions.sh
while true; do
  clear
  echo "=== Dropbear Clients Management ==="
  echo "1) List Dropbear Credentials"
  echo "2) Add Dropbear Credential"
  echo "3) Remove Dropbear Credential"
  echo "0) Back"
  read -p "Choice: " c
  case "$c" in
    1) cat /root/dropbear_clients.txt; read -n1 -s -r -p "Press any key"; ;;
    2)
      read -p "Username: " u
      read -p "Password: " p
      create_dropbear_client "$u" "$p"
      ;;
    3)
      nl /root/dropbear_clients.txt
      read -p "Number to remove: " n
      sed -i "${n}d" /root/dropbear_clients.txt
      ;;
    0) break ;;
  esac
done
EOF
chmod +x /root/manage_dropbear_clients.sh

# Xray Clients Management
cat > /root/manage_xray_clients.sh <<'EOF'
#!/bin/bash
# Source functions
source /root/client_functions.sh
while true; do
  clear
  echo "=== Xray Clients Management ==="
  echo "1) List Xray Clients"
  echo "2) Add Xray Client"
  echo "3) Remove Xray Client"
  echo "0) Back"
  read -p "Choice: " c
  case "$c" in
    1)
      ls /root/xray_clients_configs/
      read -n1 -s -r -p "Press any key"
      ;;
    2)
      read -p "Client Name: " cname
      cuuid=$(uuidgen)
      create_xray_client "$cname" "$cuuid"
      ;;
    3)
      ls /root/xray_clients_configs/ | grep _client.json
      read -p "Enter number to remove: " n
      sed -i "${n}d" /root/xray_clients_configs/$(ls /root/xray_clients_configs/ | grep _client.json | sed -n "${n}p")
      ;;
    0) break ;;
  esac
done
EOF
chmod +x /root/manage_xray_clients.sh

# Trojan Clients Management
cat > /root/manage_trojan_clients.sh <<'EOF'
#!/bin/bash
# Source functions
source /root/client_functions.sh
while true; do
  clear
  echo "=== Trojan Clients Management ==="
  echo "1) List Trojan Clients"
  echo "2) Add Trojan Client"
  echo "3) Remove Trojan Client"
  echo "0) Back"
  read -p "Choice: " c
  case "$c" in
    1) cat /root/trojan_clients.txt; read -n1 -s -r -p "Press any key" ;;
    2)
      read -p "Client Name: " cname
      password=$(uuidgen)
      create_trojan_client "$cname" "$password"
      ;;
    3)
      nl /root/trojan_clients.txt
      read -p "Number to remove: " n
      sed -i "${n}d" /root/trojan_clients.txt
      ;;
    0) break ;;
  esac
done
EOF
chmod +x /root/manage_trojan_clients.sh

# --- Final message ---
echo "Setup complete! Use /root/menu.sh to manage your server."
echo "Use the client config files and credentials generated for clients."

# --- Mark setup complete ---
touch "$MARK_FILE"
