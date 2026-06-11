#!/bin/bash

# Your domain
DOMAIN="vipvps.techgeniusnethead001.store"
CONFIG_DIR="/root/client_configs"

# Gather server info
OS_INFO=$(lsb_release -ds)
IP=$(curl -s http://checkip.amazonaws.com)
ISP=$(curl -s ipinfo.io/org)
CITY=$(curl -s ipinfo.io/city)

# Generate random passwords
HYSTERIA_PASS=$(openssl rand -hex 16)
TROJAN_PASS=$(openssl rand -hex 16)

# Ensure configs directory
mkdir -p "$CONFIG_DIR"

# Functions

install_dependencies() {
  echo "Installing dependencies..."
  apt update -y && apt upgrade -y
  apt install -y curl wget unzip nginx certbot python3-certbot-nginx openssh-server socat jq
  echo "Dependencies installed."
}

setup_ssl() {
  echo "Setting up SSL certificate..."
  certbot certonly --standalone --non-interactive --agree-tos -d "$DOMAIN"
  echo "SSL setup completed."
}

configure_nginx() {
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
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    root /var/www/html;
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  systemctl enable nginx && systemctl restart nginx
  echo "Nginx configured."
}

install_xray() {
  echo "Installing Xray..."
  if ! command -v xray &>/dev/null; then
    curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
    unzip /tmp/xray.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/xray
  fi
  XRAY_UUID=$(uuidgen)
  cat > /etc/xray/config.json <<EOF
{
  "inbounds": [{
    "port": 10000,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$XRAY_UUID"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
          "keyFile": "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        }],
        "alpn": ["h2", "http/1.1"]
      },
      "wsSettings": {
        "path": "/vless"
      }
    }
  }],
  "outbounds": [{"protocol": "federation"}]
}
EOF
  cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=/usr/local/bin/xray -c /etc/xray/config.json
Restart=on-failure
User=nobody
Group=nogroup
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable xray && systemctl restart xray
  echo "Xray installed and started."
}

install_trojan() {
  echo "Installing Trojan-GFW..."
  if ! command -v trojan-go &>/dev/null; then
    curl -L -o /tmp/trojan.zip https://github.com/trojan-gfw/trojan-go/releases/latest/download/trojan-go-linux-amd64.zip
    unzip /tmp/trojan.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/trojan-go
  fi
  cat > /etc/trojan-go/config.json <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 9443,
  "password": ["$TROJAN_PASS"],
  "ssl": {
    "cert": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
    "key": "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  },
  "websocket": {
    "enabled": true,
    "path": "/trojan",
    "host": "$DOMAIN"
  }
}
EOF
  cat > /etc/systemd/system/trojan-go.service <<EOF
[Unit]
Description=Trojan-Go Service
After=network.target
[Service]
ExecStart=/usr/local/bin/trojan-go -c /etc/trojan-go/config.json
Restart=on-failure
User=nobody
Group=nogroup
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable trojan-go && systemctl restart trojan-go
  echo "Trojan installed and started."
}

install_hysteria() {
  echo "Installing Hysteria..."
  if ! command -v hysteria &>/dev/null; then
    curl -L -o /usr/local/bin/hysteria https://github.com/mmmwhy/hysteria/releases/latest/download/hysteria-linux-amd64
    chmod +x /usr/local/bin/hysteria
  fi
  cat > /etc/hysteria/config.json <<EOF
{
  "listen": ":10443",
  "cert": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
  "key": "/etc/letsencrypt/live/$DOMAIN/privkey.pem",
  "protocol": "udp",
  "obfs": "websocket",
  "obfs_url": "/hysteria",
  "auth": "password",
  "password": "$HYSTERIA_PASS"
}
EOF
  cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria Service
After=network.target
[Service]
ExecStart=/usr/local/bin/hysteria -c /etc/hysteria/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable hysteria && systemctl restart hysteria
  echo "Hysteria installed and started."
}

generate_ssh_client() {
  local USERNAME=$1
  local PASSWORD=$2
  local EXPIRES=$(chage -l "$USERNAME" | grep "Account expires" | awk -F: '{print $2}' | xargs)
  local EXPIRED_DATE=$(date -d "$EXPIRES" +"%b %d, %Y")
  cat <<EOF

═══════════════════════════
<=      SSH ACCOUNT      =>
═══════════════════════════

Username     : $USERNAME
Password     : $PASSWORD
Host/IP      : $DOMAIN
Limit IP     : 50
Port ssl/tls : 443
Port non tls : 80, 2082
Port ssh   : 22, 3303, 53
Dropbear   : 109, 69, 143
Udp Range  : 1-65535, 56-7789
Http Proxy : 8888
OHP All    : 8181, 8282, 8383
BadVpn     : 7100, 7200, 7300
════════════════════════════
<=   Detail Information   =>
ISP           : $ISP
CITY          : $CITY
REGION        : Ohio
════════════════════════════
<=   DNSTT  Information   =>
Port         : 5300
Publik Key   : 4871757def381e0b542a6aec8b9f5925326a87e1a9a29902c4524499fa104023
Nameserver   : ns.vpsssh.nethead001techgenius.site

════════════════════════════
<=  Chisel  Information  =>
Port TLS     : 9443
Port HTTP    : 8000
TLS Usage    : chisel client wss://$DOMAIN:9443 R:5000:localhost:22
HTTP Usage   : chisel client ws://$DOMAIN:8000 R:5000:localhost:22

════════════════════════════
Port OVPN  : 1194 TCP / 2200 UDP
OVPN TCP  : http://$DOMAIN:8081/tcp.ovpn
OVPN UDP  : http://$DOMAIN:8081/udp.ovpn

════════════════════════════
Payload Ws => GET / HTTP/1.1\r\nHost: $DOMAIN\r\nUpgrade: websocket\r\n\r\n
════════════════════════════
Payload Ovpn => GET /ovpn HTTP/1.1\r\nHost: $DOMAIN\r\nUpgrade: websocket\r\n\r\n
════════════════════════════
Expired => $EXPIRED_DATE
════════════════════════════
EOF
}

generate_xray_full_config() {
  local REMARK="trial382"
  local HOSTNAME="vpsssh.nethead001techgenius.site"
  local WILDCARD="bug.com.vpsssh.nethead001techgenius.site"
  local EXPIRED="60 Minutes"
  local PASSWORD="trial382"
  local PORT_WS_HTTPS=443
  local PORT_WS_HTTP=80
  local PATH_WS="/trojan | /trojanws"
  local PATH_HTTP="/dinda | /dindaputri"
  local SERVICE_NAME="trojan-grpc"
  local ISP="AS16509 Amazon.com, Inc."
  local CITY="Columbus"
  local REGION="Ohio"
  local PUBKEY="4871757def381e0b542a6aec8b9f5925326a87e1a9a29902c4524499fa104023"
  local NS="ns.vpsssh.nethead001techgenius.site"
  cat <<EOF
═══════════════════════════
<=      X-Ray Trojan Account  =>
═══════════════════════════

Remarks    : $REMARK
Hostname   : $HOSTNAME
WildCard   : $WILDCARD
Expired    : $EXPIRED
Password   : $PASSWORD
═══════════════════════════
WS HTTPS   : $PORT_WS_HTTPS
WS HTTP    : $PORT_WS_HTTP
Path WS    : $PATH_WS
Path HTTP  : $PATH_HTTP
ServiceName: $SERVICE_NAME
═══════════════════════════
<=   Detail Information   =>
ISP           : $ISP
CITY          : $CITY
REGION        : $REGION
═══════════════════════════
<=   DNSTT  Information   =>
Port         : 5300
Publik Key   : $PUBKEY
Nameserver   : $NS
═══════════════════════════
WebSocket  : trojan://$PASSWORD@$HOSTNAME:443?path=%2ftrojanws&security=tls&host=$HOSTNAME&type=ws&sni=$HOSTNAME#$PASSWORD
HTTP TLS   : trojan://$PASSWORD@$HOSTNAME:443?path=/dinda&security=tls&host=$HOSTNAME&type=httpupgrade&sni=$HOSTNAME#$PASSWORD
gRPC       : trojan://$PASSWORD@$HOSTNAME:443?mode=gun&security=tls&authority=$HOSTNAME&type=grpc&serviceName=$SERVICE_NAME&sni=$HOSTNAME#$PASSWORD
═══════════════════════════
EOF
}

# Function to add or update Xray user
add_xray_user() {
  echo "Adding or updating Xray user credentials."
  read -p "Enter username: " username

  # Generate UUID for new user
  user_uuid=$(uuidgen)

  # Path to your Xray config
  CONFIG_FILE="/etc/xray/config.json"

  # Backup current config
  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

  # Check if jq is installed
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not installed. Installing jq..."
    apt install -y jq
  fi

  # Append new user
  jq --arg id "$user_uuid" \
     '.inbounds[0].settings.clients += [{"id": $id}]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

  # Restart Xray
  systemctl restart xray

  echo "Added/Updated Xray user with UUID: $user_uuid"
  echo "Use this UUID in your client configuration."
}

# Main menu loop
while true; do
  echo "==== SCRIPT MENU ===="
  echo "01) Setup Server"
  echo "02) Add User"
  echo "03) Show Server Info"
  echo "04) Show Xray Trojan Panel Config"
  echo "05) Generate SSH Client Info"
  echo "06) Show Xray Panel Full Config"
  echo "07) Install All Services"
  echo "08) Restart All Services"
  echo "09) Renew SSL Certificate"
  echo "10) Add/Update Xray User"
  echo "00) Exit"
  read -p "Select option: " opt
  case "$opt" in
    01)
      echo "You will install dependencies, SSL, nginx, and core services. Proceed? (y/n)"
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        install_dependencies
        setup_ssl
        configure_nginx
        install_xray
        install_trojan
        install_hysteria
        echo "Setup completed."
      fi
      ;;
    02)
      echo "Adding new system user..."
      read -p "Username: " username
      read -p "Password: " password
      echo "Expiry days: "
      read -r days
      useradd -m "$username"
      echo "$username:$password" | chpasswd
      chage -E $(date -d "+$days days" +%Y-%m-%d) "$username"
      echo "User added: $username"
      generate_ssh_client "$username" "$password"
      ;;
    03)
      echo "Server Info:"
      echo "OS: $OS_INFO"
      echo "IP: $IP"
      echo "Domain: $DOMAIN"
      echo "ISP: $ISP"
      echo "City: $CITY"
      ;;
    04)
      echo "Generate full Xray Trojan Panel Config? (y/n)"
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        generate_xray_full_config
      fi
      ;;
    05)
      read -p "Enter username: " username
      if id "$username" &>/dev/null; then
        PASSWORD=$(grep "^$username:" /etc/shadow | cut -d':' -f2)
        generate_ssh_client "$username" "$PASSWORD"
      else
        echo "User not found!"
      fi
      ;;
    06)
      echo "Generate full Xray config? (y/n)"
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        generate_xray_full_config
      fi
      ;;
    07)
      echo "Install all services? (y/n)"
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        install_dependencies
        setup_ssl
        configure_nginx
        install_xray
        install_trojan
        install_hysteria
        echo "All services installed."
      fi
      ;;
    08)
      echo "Restart all services? (y/n)"
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl restart nginx xray trojan-go hysteria
        echo "Services restarted."
      fi
      ;;
    09)
      echo "Renew SSL certificate? (y/n)"
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        setup_ssl
        systemctl restart nginx
        echo "SSL renewed and nginx restarted."
      fi
      ;;
    10)
      add_xray_user
      ;;
    00)
      echo "Exiting..."
      exit 0
      ;;
    *)
      echo "Invalid option."
      ;;
  esac
done
