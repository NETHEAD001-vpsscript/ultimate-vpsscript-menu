bash
#!/bin/bash

# ==================================================
# NETHEAD001 VPS AUTO INSTALLER v10
# SAFE BUILD - NO SSH LOCKOUT
# UBUNTU 22 / DEBIAN 12
# ==================================================

set -euo pipefail

INSTALL_PASS="nethead001"

# ==================================================
# COLORS
# ==================================================

RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ==================================================
# FUNCTIONS
# ==================================================

log() {
echo -e "${CYAN}[INFO]${NC} $1"
}

warn() {
echo -e "${YELLOW}[WARN]${NC} $1"
}

fail() {
echo -e "${RED}[FATAL]${NC} $1"
exit 1
}

# ==================================================
# ROOT + PASSWORD CHECK
# ==================================================

clear

echo -e "${CYAN}=================================================${NC}"
echo -e "${GREEN}      NETHEAD001 VPS INSTALLER v10${NC}"
echo -e "${CYAN}=================================================${NC}"

echo
read -p "Enter Installer Password: " PASS

[[ "$PASS" != "$INSTALL_PASS" ]] && fail "Wrong Password"
[[ "$(id -u)" != "0" ]] && fail "Run as root"

# ==================================================
# NETWORK CHECK
# ==================================================

log "Checking internet connection..."

for i in {1..10}; do
ping -c1 1.1.1.1 >/dev/null 2>&1 && break
sleep 2
done

ping -c1 1.1.1.1 >/dev/null 2>&1 || fail "No internet connection"

# ==================================================
# UPDATE SYSTEM
# ==================================================

log "Updating system..."

export DEBIAN_FRONTEND=noninteractive

apt update -y
apt upgrade -y

# ==================================================
# REMOVE CONFLICT SERVICES
# ==================================================

log "Removing conflicting services..."

systemctl stop apache2 2>/dev/null || true
systemctl disable apache2 2>/dev/null || true

apt purge apache2* -y 2>/dev/null || true

# ==================================================
# INSTALL REQUIRED PACKAGES
# ==================================================

log "Installing packages..."

apt install -y \
curl \
wget \
sudo \
nginx \
dropbear \
stunnel4 \
haproxy \
cron \
socat \
jq \
unzip \
net-tools \
ufw \
openssl \
ca-certificates \
gnupg \
lsb-release \
vnstat \
fail2ban \
python3 \
screen \
htop \
neofetch \
openssh-server

# ==================================================
# ENABLE BBR
# ==================================================

log "Enabling BBR..."

grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || cat >> /etc/sysctl.conf <<EOF

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.ipv4.tcp_syncookies=1
EOF

sysctl -p >/dev/null 2>&1 || true

# ==================================================
# CREATE SWAP
# ==================================================

if ! swapon --show | grep -q "/swapfile"; then

log "Creating swap..."

fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

grep -q "/swapfile" /etc/fstab || \
echo '/swapfile none swap sw 0 0' >> /etc/fstab

fi

# ==================================================
# SSH SAFE CONFIG
# ==================================================

log "Configuring SSH safely..."

SSHD="/etc/ssh/sshd_config"

cp "$SSHD" "${SSHD}.bak"

sed -i '/^Port /d' "$SSHD"
sed -i '/^PermitRootLogin /d' "$SSHD"
sed -i '/^PasswordAuthentication /d' "$SSHD"
sed -i '/^PubkeyAuthentication /d' "$SSHD"
sed -i '/^Banner /d' "$SSHD"

cat >> "$SSHD" <<EOF

Port 22
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
Banner /etc/issue.net
EOF

# ==================================================
# SSH / DROPBEAR BANNER
# ==================================================

log "Installing SSH banner..."

cat > /etc/issue.net <<'EOF'

=================================================
             NETHEAD001 VPS SERVER
=================================================

AUTHORIZED ACCESS ONLY

• Premium VPS Services
• High Speed SSH / XRAY / WS
• Stable Gaming & Streaming
• 24/7 Server Support

BUY PREMIUM VPS:
DM @nethead001

Unauthorized access is prohibited.

=================================================

EOF

if ! sshd -t; then
cp "${SSHD}.bak" "$SSHD"
fail "SSH config invalid - rollback restored"
fi

systemctl enable ssh
systemctl restart ssh

# ==================================================
# FIREWALL
# ==================================================

log "Configuring firewall..."

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 109/tcp
ufw allow 110/tcp
ufw allow 444/tcp
ufw allow 8443/tcp
ufw allow 36712/udp

ufw --force enable

# ==================================================
# ENABLE SERVICES
# ==================================================

systemctl enable nginx
systemctl enable dropbear
systemctl enable stunnel4
systemctl enable haproxy
systemctl enable
