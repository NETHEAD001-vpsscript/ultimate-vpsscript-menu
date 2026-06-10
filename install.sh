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

# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

# Skip if already done
if [ -f "$MARK_FILE" ]; then
  echo "Setup already completed."
  if ! command -v menu &>/dev/null; then
    ln -sf /root/menu.sh /usr/local/bin/menu
    chmod +x /root/menu.sh
  fi
  exit 0
fi

# ------------------- Update & dependencies -------------------
echo "Updating system..."
apt update && apt upgrade -y

REQUIRED_PKGS=(nginx dropbear openssh-server curl unzip ufw certbot python3-certbot-nginx)
for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -l | grep -qw "$pkg"; then
    apt install -y "$pkg"
  fi
done

# ------------------- Backup configs -------------------
mkdir -p /root/backup_configs
cp /etc/ssh/sshd_config /root/backup_configs/sshd_config.bak || true
cp /etc/default/dropbear /root/backup_configs/dropbear.bak || true
cp /etc/nginx/sites-available/default /root/backup_configs/nginx_default.bak || true

# ------------------- Domain & SSL -------------------
read -p "Enter your domain (must point to your VPS IP): " DOMAIN
echo "Validating domain DNS..."
if ! dig +short "$DOMAIN" | grep -q '[^[:space:]]'; then
  echo "Domain does not resolve. Check DNS."
  exit 1
fi

SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

if [ -f "$SSL_CERT" ] && [ -f "$SSL_KEY" ]; then
  echo "Existing SSL found, validating expiry..."
  expiry=$(openssl x509 -enddate -noout -in "$SSL_CERT" | cut -d= -f2)
  expiry_epoch=$(date -d "$expiry" +%s)
  now=$(date +%s)
  days_left=$(( (expiry_epoch - now) / 86400 ))
  if [ "$days_left" -lt 30 ]; then
    echo "SSL expiring soon, renewing..."
    certbot renew
  else
    echo "SSL valid for $days_left days."
  fi
else
  echo "Obtaining SSL cert..."
  certbot certonly --nginx --non-interactive --agree-tos -d "$DOMAIN" -m admin@$DOMAIN || {
    echo "Certbot failed."
    exit 1
  }
fi

# ------------------- nginx setup -------------------
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

# ------------------- SSH & Dropbear -------------------
sed -i 's/^#Port 22/Port 22/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh

sed -i 's/^NO_START=1/NO_START=0/' /etc/default/dropbear
sed -i 's/^#DROPBEAR_PORT=22/DROPBEAR_PORT=445/' /etc/default/dropbear
systemctl enable dropbear
systemctl restart dropbear

# ------------------- UFW Firewall -------------------
ufw default deny incoming
ufw default allow outgoing
for port in 22 80 443 8080 8443 9443 53 109 3303 143 8888 8181 8282 8383 7100 7200 7300 10443; do
  ufw allow "$port"/tcp
done
ufw --force enable

# ------------------- Install & Configure XRAY -------------------
if ! command -v xray &>/dev/null; then
  bash <(curl -L -s https://github.com/XTLS/Xray-core/releases/latest/download/install-release.sh)
fi
UUID=$(uuidgen)
cat > /etc/xray/config.json <<EOF
{
  "inbounds": [{
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
        "certificates": [{
          "certificateFile": "$SSL_CERT",
          "keyFile": "$SSL_KEY"
        }]
      },
      "wsSettings": {
        "path": "/vlessws",
        "headers": { "Host": "$DOMAIN" }
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
systemctl enable xray
systemctl restart xray

# ------------------- Trojan-Go -------------------
if [ ! -f /usr/local/bin/trojan-go ]; then
  curl -L -o /tmp/trojan-go.zip https://github.com/trojan-gfw/trojan-go/releases/latest/download/trojan-go-linux-amd64.zip
  unzip /tmp/trojan-go.zip -d /usr/local/bin/
  chmod +x /usr/local/bin/trojan-go
fi
TROJAN_PASS=$(uuidgen)
cat > /etc/trojan-go/config.json <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 9443,
  "password": ["$TROJAN_PASS"],
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
# Trojan systemd
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

# ------------------- Hysteria -------------------
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
  "password": "$TROJAN_PASS"
}
EOF
if ! systemctl list-units --type=service | grep hysteria; then
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

# ------------------- Create server menu -------------------
cat > /root/menu.sh <<'EOF'
#!/bin/bash
# Server management menu
service_status() {
  systemctl is-active "$1" &>/dev/null && echo "ON" || echo "OFF"
}
check_hysteria() {
  systemctl is-active hysteria &>/dev/null && ss -lnt | grep -q ':10443' && echo "ON" || echo "OFF"
}
build_line() {
  echo "==============================="
  echo " SSH: $(service_status ssh)"
  echo " DROPBEAR: $(service_status dropbear)"
  echo " NGINX: $(service_status nginx)"
  echo " XRAY: $(service_status xray)"
  echo " TROJAN: $(service_status trojan-go)"
  echo " WS: $(check_hysteria)"
  echo "==============================="
}
build_line
echo ""
echo "======= SERVER MANAGEMENT ========"
echo "1) Restart SSH"
echo "2) Restart Dropbear"
echo "3) Restart Nginx"
echo "4) Restart XRAY"
echo "5) Restart Trojan"
echo "6) Restart Hysteria"
echo "0) Exit"
read -p "Choose: " ch
case "$ch" in
  1) systemctl restart ssh; bash /root/menu.sh ;;
  2) systemctl restart dropbear; bash /root/menu.sh ;;
  3) systemctl restart nginx; bash /root/menu.sh ;;
  4) systemctl restart xray; bash /root/menu.sh ;;
  5) systemctl restart trojan-go; bash /root/menu.sh ;;
  6) systemctl restart hysteria; bash /root/menu.sh ;;
  0) echo "Goodbye!"; exit ;;
  *) bash /root/menu.sh ;;
esac
EOF
chmod +x /root/menu.sh
ln -sf /root/menu.sh /usr/local/bin/menu
chmod +x /usr/local/bin/menu

# ------------------- Mark setup complete -------------------
touch "$MARK_FILE"

echo "Setup complete! Type 'menu' to manage your server."
