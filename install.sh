#!/bin/bash

# Check for root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

# Input domain
read -p "Enter your domain (leave blank for localhost SSL): " USER_DOMAIN
DOMAIN="${USER_DOMAIN}"

# Your password
PASSWORD="your_secure_password"  # <-- Change me!
UUID=$(uuidgen)

# Update and install essentials
apt update -y && apt upgrade -y
apt install -y nginx dropbear openssh-server curl unzip ufw cron

# Remove conflicting services
systemctl stop apache2 || true
systemctl disable apache2 || true
apt purge apache2* -y || true

# SSH configuration
SSHD_CONF="/etc/ssh/sshd_config"
cp "$SSHD_CONF" "${SSHD_CONF}.bak"
sed -i 's/^#Port 22/Port 22/' "$SSHD_CONF"
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' "$SSHD_CONF"
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' "$SSHD_CONF"
sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' "$SSHD_CONF"
sed -i 's/^#UsePAM yes/UsePAM yes/' "$SSHD_CONF"
systemctl restart ssh

# Dropbear on port 445
DROPBEAR_CONF="/etc/default/dropbear"
sed -i 's/^NO_START=1/NO_START=0/' "$DROPBEAR_CONF"
sed -i 's/^#DROPBEAR_PORT=22/DROPBEAR_PORT=445/' "$DROPBEAR_CONF"
systemctl enable dropbear
systemctl restart dropbear

# Firewall rules
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8080/tcp
ufw allow 8443/tcp
ufw allow 9443/tcp
ufw allow 10443/tcp
# Open all UDP ports (1-65535) - be cautious!
# For security, consider opening only needed ports
ufw allow proto udp from any to any port 1:65535
ufw --force enable

# SSL certificates
if [ -n "$DOMAIN" ]; then
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -subj "/CN=$DOMAIN" \
    -keyout /etc/ssl/private/nginx.key \
    -out /etc/ssl/certs/nginx.crt
else
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -subj "/CN=localhost" \
    -keyout /etc/ssl/private/nginx.key \
    -out /etc/ssl/certs/nginx.crt
fi

# Nginx redirect to HTTPS
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name ${DOMAIN:-localhost};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${DOMAIN:-localhost};
    ssl_certificate /etc/ssl/certs/nginx.crt;
    ssl_certificate_key /etc/ssl/private/nginx.key;
    root /var/www/html;
    index index.html index.htm;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
systemctl enable nginx && systemctl restart nginx

# Install Xray
bash <(curl -L -s https://github.com/XTLS/Xray-core/releases/latest/download/install-release.sh)

# TLS certs for Xray
if [ -n "$DOMAIN" ]; then
  openssl req -new -rsa:4096 -days 365 -nodes -x509 \
    -subj "/CN=$DOMAIN" \
    -keyout /etc/ssl/private/xray.key \
    -out /etc/ssl/certs/xray.crt
else
  cp /etc/ssl/certs/nginx.crt /etc/ssl/certs/xray.crt
  cp /etc/ssl/private/nginx.key /etc/ssl/private/xray.key
fi

# Generate UUID for Xray
XRAY_UUID="$UUID"

# Configure Xray with multiple inbounds, including UDP support
cat > /etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$XRAY_UUID", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/ssl/certs/xray.crt",
              "keyFile": "/etc/ssl/private/xray.key"
            }
          ]
        }
      }
    },
    {
      "port": 8080,
      "listen": "127.0.0.1",
      "protocol": "http",
      "settings": {}
    }
  ],
  "outbounds": [
    { "protocol": "federation", "settings": {} }
  ]
}
EOF
systemctl enable xray && systemctl restart xray

# Install Trojan-Go
curl -L -o /tmp/trojan-go.zip https://github.com/trojan-gfw/trojan-go/releases/latest/download/trojan-go-linux-amd64.zip
unzip /tmp/trojan-go.zip -d /usr/local/bin/
chmod +x /usr/local/bin/trojan-go

# Trojan-Go config.json on port 9443 with UDP support
cat > /etc/trojan-go/config.json <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 9443,
  "password": ["$PASSWORD"],
  "ssl": {
    "cert": "/etc/ssl/certs/xray.crt",
    "key": "/etc/ssl/private/xray.key"
  },
  "websocket": {
    "enabled": true,
    "path": "/trojan",
    "host": "${DOMAIN:-localhost}"
  }
}
EOF

# Trojan-Go systemd service
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

# Install Hysteria
curl -L -o /usr/local/bin/hysteria https://github.com/mmmwhy/hysteria/releases/latest/download/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

# Hysteria config.json on port 10443 with UDP
cat > /etc/hysteria/config.json <<EOF
{
  "listen": ":10443",
  "cert": "/etc/ssl/certs/xray.crt",
  "key": "/etc/ssl/private/xray.key",
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
ExecStart=/usr/local/bin/hysteria -config /etc/hysteria/config.json
Restart=on-failure
User=nobody
Group=nogroup
[Install]
WantedBy=multi-user.target
EOF
systemctl enable hysteria && systemctl restart hysteria

# Setup nginx websocket proxy if domain provided
if [ -n "$DOMAIN" ]; then
cat > /etc/nginx/conf.d/ws.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /ws {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
  systemctl restart nginx
fi

# --- Interactive management menu ---
show_panel() {
  clear
  echo "=============================================="
  echo "       PANEL MENU - NETHEAD001"
  echo "=============================================="
  echo " 1) Manage SSH & Dropbear"
  echo " 2) Manage nginx & SSL"
  echo " 3) Manage Xray"
  echo " 4) Manage Trojan-Go"
  echo " 5) Manage Hysteria"
  echo " 6) Service Status & Restart"
  echo " 7) Exit"
  echo "=============================================="
  echo "HARI ini: 17.15 G NETHEAD001: 233.38 G BULAN:"
  echo "=============================================="
  echo "Client: @Rerechan02"
  echo "Script Version: FN Project X Rerechan02"
  echo "=============================================="
}

while true; do
  show_panel
  read -p "Select an option [1-7]: " choice
  case "$choice" in
    1)
      echo "Manage SSH & Dropbear placeholder."
      read -p "Press Enter..."
      ;;
    2)
      echo "Manage nginx & SSL placeholder."
      read -p "Press Enter..."
      ;;
    3)
      echo "Manage Xray placeholder."
      read -p "Press Enter..."
      ;;
    4)
      echo "Manage Trojan-Go placeholder."
      read -p "Press Enter..."
      ;;
    5)
      echo "Manage Hysteria placeholder."
      read -p "Press Enter..."
      ;;
    6)
      echo "Services status:"
      systemctl status nginx xray trojan-go hysteria
      read -p "Press Enter..."
      ;;
    7)
      echo "Exiting menu."
      break
      ;;
    *)
      echo "Invalid choice."
      sleep 2
      ;;
  esac
done

echo "Setup and management panel exited."
