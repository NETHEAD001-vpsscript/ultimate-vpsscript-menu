#!/bin/bash
set -euo pipefail

# =================== Configuration ===================
REQUIRED_PASSWORD="nethead001techgeniusvpsscript"
MARK_FILE="/etc/setup_completed"

# Prompt for password
read -s -p "Enter the script password: " input_password
echo
if [ "$input_password" != "$REQUIRED_PASSWORD" ]; then
  echo "Invalid password. Exiting."
  exit 1
fi

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

# Skip if already completed
if [ -f "$MARK_FILE" ]; then
  echo "Setup already completed."
  # Create 'menu' command if not exists
  if ! command -v menu &>/dev/null; then
    ln -sf /root/menu.sh /usr/local/bin/menu
    chmod +x /root/menu.sh
  fi
  exit 0
fi

# =================== Update system & install dependencies ===================
echo "Updating package list..."
apt update
apt upgrade -y

REQUIRED_PKGS=(nginx dropbear openssh-server curl unzip ufw certbot python3-certbot-nginx)
for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -l | grep -qw "$pkg"; then
    apt install -y "$pkg"
  fi
done

# Verify essential commands
for cmd in curl unzip; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is not installed."
    exit 1
  fi
done

# =================== Backup default configs ===================
mkdir -p /root/backup_configs
cp /etc/ssh/sshd_config /root/backup_configs/sshd_config.bak || true
cp /etc/default/dropbear /root/backup_configs/dropbear.bak || true
cp /etc/nginx/sites-available/default /root/backup_configs/nginx_default.bak || true

# =================== User input: domain ===================
read -p "Enter your domain (must point to your VPS IP): " DOMAIN

# =================== Validate domain DNS resolution ===================
echo "Validating domain DNS resolution..."
if ! dig +short "$DOMAIN" | grep -q '[^[:space:]]'; then
  echo "Error: Domain '$DOMAIN' does not resolve to an IP. Please check DNS settings."
  exit 1
fi

# =================== Check SSL certificate validity ===================
SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

if [ -f "$SSL_CERT" ] && [ -f "$SSL_KEY" ]; then
  echo "Existing SSL certificate found. Validating..."
  if openssl x509 -enddate -noout -in "$SSL_CERT" | grep -q 'notAfter'; then
    expiry_date=$(openssl x509 -enddate -noout -in "$SSL_CERT" | cut -d= -f2)
    expiry_epoch=$(date -d "$expiry_date" +%s)
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    if [ "$days_left" -lt 30 ]; then
      echo "SSL certificate expires in less than 30 days. Will attempt renewal."
    else
      echo "SSL certificate is valid for $days_left more days."
    fi
  else
    echo "Unable to validate existing SSL certificate. Proceeding to obtain a new one."
  fi
else
  echo "No existing SSL certificate found. Will obtain new certificate."
fi

# =================== Obtain SSL certificate via certbot ===================
echo "Obtaining SSL certificate for $DOMAIN..."
if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  echo "SSL certificate for $DOMAIN already exists."
else
  certbot certonly --nginx --non-interactive --agree-tos --register-unsafely-without-email -d "$DOMAIN" || {
    echo "Failed to obtain SSL certificate. Check certbot logs."
    exit 1
  }
fi

# Verify SSL files exist after certbot
if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
  echo "SSL certificate files missing after certbot. Exiting."
  exit 1
fi

# =================== Configure nginx ===================
echo "Configuring nginx..."
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
systemctl enable nginx
systemctl restart nginx

# =================== Configure SSH & Dropbear ===================
echo "Configuring SSH..."
sed -i 's/^#Port 22/Port 22/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh

echo "Configuring Dropbear..."
sed -i 's/^NO_START=1/NO_START=0/' /etc/default/dropbear
sed -i 's/^#DROPBEAR_PORT=22/DROPBEAR_PORT=445/' /etc/default/dropbear
systemctl enable dropbear
systemctl restart dropbear

# =================== Firewall setup ===================
echo "Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing
for port in 22 80 443 8080 8443 9443 53 109 3303 143 8888 8181 8282 8383 7100 7200 7300 10443; do
  ufw allow "$port"/tcp
done
ufw --force enable

# =================== Install Xray ===================
echo "Installing Xray..."
if ! command -v xray &>/dev/null; then
  bash <(curl -L -s https://github.com/XTLS/Xray-core/releases/latest/download/install-release.sh)
fi

# Generate UUID for Xray
UUID=$(uuidgen)

# =================== Configure Xray ===================
echo "Configuring Xray..."
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
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
EOF
systemctl enable xray
systemctl restart xray

# =================== Install Trojan-Go ===================
echo "Installing Trojan-Go..."
if [ ! -f /usr/local/bin/trojan-go ]; then
  curl -L -o /tmp/trojan-go.zip https://github.com/trojan-gfw/trojan-go/releases/latest/download/trojan-go-linux-amd64.zip
  unzip /tmp/trojan-go.zip -d /usr/local/bin/
  chmod +x /usr/local/bin/trojan-go
fi

TROJAN_PASSWORD=$(uuidgen)
cat > /etc/trojan-go/config.json <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 9443,
  "password": ["$TROJAN_PASSWORD"],
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

# Trojan-Go systemd service
if [ ! -f /etc/systemd/system/trojan-go.service ]; then
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
  systemctl enable trojan-go
  systemctl restart trojan-go
fi

# =================== Install Hysteria ===================
echo "Installing Hysteria..."
if [ ! -f /usr/local/bin/hysteria ]; then
  curl -L -o /usr/local/bin/hysteria https://github.com/mmmwhy/hysteria/releases/latest/download/hysteria-linux-amd64
  chmod +x /usr/local/bin/hysteria
fi

cat > /etc/hysteria/config.json <<EOF
{
  "listen": ":10443",
  "cert": "$SSL_CERT",
  "key": "$SSL_KEY",
  "protocol": "udp",
  "obfs": "websocket",
  "obfs_url": "/hysteria",
  "auth": "password",
  "password": "$TROJAN_PASSWORD"
}
EOF

# Hysteria systemd
if [ ! -f /etc/systemd/system/hysteria.service ]; then
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
fi

# =================== Create server management menu ===================
echo "Creating server management menu..."
cat > /root/menu.sh <<'EOF'
#!/bin/bash
# Uncomment if client functions are used
# source /root/client_functions.sh

get_status() {
  systemctl is-active "$1" &>/dev/null && echo "ON" || echo "OFF"
}
check_hysteria() {
  if systemctl is-active hysteria &>/dev/null; then
    if ss -lnt | grep -q ':10443'; then echo "ON"; else echo "OFF"; fi
  else
    echo "OFF"
  fi
}
build_status_line() {
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

# =================== Mark setup as complete ===================
touch "$MARK_FILE"

echo "Setup complete! Use 'menu' command to manage your server."
