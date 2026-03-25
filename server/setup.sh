#!/usr/bin/env bash
# OpenHole WireGuard Setup Script
# Runs on the server (Linux or macOS) to set up WireGuard for the OpenHole iOS app.
#
# Usage:
#   bash setup.sh              # First run: full setup. Subsequent: add new peer.
#   bash setup.sh my-iphone    # Name the peer (used for config filename)
#
# Requirements: sudo access

set -euo pipefail

# ─── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[ok]${NC} $*"; }
info() { echo -e "${BLUE}-->${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*"; exit 1; }

# ─── Config ────────────────────────────────────────────────────────────────────
WG_IFACE="wg0"
WG_PORT=51820
WG_NET_PREFIX="10.8.0"
WG_SERVER_IP="${WG_NET_PREFIX}.1"
WG_SUBNET="${WG_NET_PREFIX}.0/24"
WG_CONFIG_DIR="/etc/wireguard"
WG_FWMARK="0x4f42"
OPENHOLE_DIR="$HOME/.openhole"
PEERS_DIR="$OPENHOLE_DIR/peers"
DUCKDNS_SCRIPT="/usr/local/bin/duckdns-home.sh"

PEER_NAME="${1:-}"

echo ""
echo "  OpenHole WireGuard Setup"
echo "  ────────────────────────"
echo ""

# ─── Sudo ──────────────────────────────────────────────────────────────────────
info "This script needs sudo to configure WireGuard."
sudo -v || die "sudo authentication failed"
( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null; exit" EXIT INT TERM

# ─── Detect OS ─────────────────────────────────────────────────────────────────
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then echo "macos"
    elif command -v apt &>/dev/null; then echo "debian"
    elif command -v pacman &>/dev/null; then echo "arch"
    elif command -v dnf &>/dev/null; then echo "fedora"
    else echo "unknown"; fi
}
OS=$(detect_os)
info "Detected OS: $OS"

# ─── Install WireGuard ─────────────────────────────────────────────────────────
install_wireguard() {
    if command -v wg &>/dev/null; then
        ok "WireGuard already installed"
        return
    fi
    info "Installing WireGuard..."
    case "$OS" in
        debian)  sudo apt-get update -qq && sudo apt-get install -y wireguard wireguard-tools ;;
        arch)    sudo pacman -Sy --noconfirm wireguard-tools ;;
        fedora)  sudo dnf install -y wireguard-tools ;;
        macos)   command -v brew &>/dev/null || die "Homebrew required. Install from https://brew.sh"
                 brew install wireguard-tools ;;
        *)       die "Unsupported OS. Install wireguard-tools manually and re-run." ;;
    esac
    ok "WireGuard installed"
}
install_wireguard

# ─── Detect physical interface (bypass VPN tunnels) ────────────────────────────
detect_physical_iface() {
    if [[ "$OS" == "macos" ]]; then
        route -n get default 2>/dev/null | awk '/interface:/{print $2}' | head -1
    else
        ip route | grep default | grep -vE 'wg|tun' | awk '{print $5}' | head -1
    fi
}
MAIN_IFACE=$(detect_physical_iface)
MAIN_IFACE="${MAIN_IFACE:-eno1}"
info "Physical interface: $MAIN_IFACE"

# ─── Detect public IP (via physical interface, bypassing VPN) ──────────────────
detect_public_ip() {
    local iface="$1"
    local ip=""
    if [[ "$OS" == "macos" ]]; then
        ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || true)
    else
        ip=$(curl -s --max-time 5 --interface "$iface" ifconfig.me 2>/dev/null || true)
        [[ -z "$ip" ]] && ip=$(curl -s --max-time 5 --interface "$iface" api.ipify.org 2>/dev/null || true)
        [[ -z "$ip" ]] && ip=$(curl -s --max-time 5 --interface "$iface" icanhazip.com 2>/dev/null || true)
    fi
    echo "$ip"
}

info "Detecting public IP via $MAIN_IFACE (bypassing VPN)..."
PUBLIC_IP=$(detect_public_ip "$MAIN_IFACE")
if [[ -z "$PUBLIC_IP" ]]; then
    warn "Could not auto-detect public IP."
    read -rp "  Enter your server's public IP or domain: " PUBLIC_IP
fi
ok "Public IP: $PUBLIC_IP"

mkdir -p "$OPENHOLE_DIR" "$PEERS_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# Detect mode: ADD PEER (wg0 running) vs FULL SETUP (first run)
# ═══════════════════════════════════════════════════════════════════════════════

if sudo wg show "$WG_IFACE" &>/dev/null 2>&1; then
    # ─── ADD PEER MODE ─────────────────────────────────────────────────────────
    echo ""
    info "wg0 is already running. Adding a new peer."
    echo ""

    # Find next available IP by parsing existing allowed-ips
    USED_IPS=$(sudo wg show "$WG_IFACE" allowed-ips | awk '{print $2}' | cut -d/ -f1 | sort -t. -k4 -n)
    NEXT_OCTET=2
    for ip in $USED_IPS; do
        octet="${ip##*.}"
        if (( octet >= NEXT_OCTET )); then
            NEXT_OCTET=$((octet + 1))
        fi
    done
    CLIENT_IP="${WG_NET_PREFIX}.${NEXT_OCTET}"
    info "Next available IP: $CLIENT_IP"

    # Read existing server pubkey
    SERVER_PUBKEY=$(sudo wg show "$WG_IFACE" public-key)

    # Generate client keypair
    CLIENT_PRIVKEY=$(wg genkey)
    CLIENT_PUBKEY=$(echo "$CLIENT_PRIVKEY" | wg pubkey)

    # Add peer to running interface
    sudo wg set "$WG_IFACE" peer "$CLIENT_PUBKEY" allowed-ips "${CLIENT_IP}/32"
    ok "Peer added to live wg0"

    # Persist to config file
    sudo bash -c "cat >> $WG_CONFIG_DIR/$WG_IFACE.conf" <<EOF

# Peer ${PEER_NAME:-$CLIENT_IP} (added $(date +%Y-%m-%d))
[Peer]
PublicKey = $CLIENT_PUBKEY
AllowedIPs = ${CLIENT_IP}/32
EOF
    ok "Peer appended to $WG_CONFIG_DIR/$WG_IFACE.conf"

    # Determine endpoint (prefer DuckDNS hostname if configured)
    ENDPOINT="$PUBLIC_IP"
    if [[ -f "$OPENHOLE_DIR/duckdns-domain" ]]; then
        ENDPOINT="$(cat "$OPENHOLE_DIR/duckdns-domain")"
        info "Using DuckDNS endpoint: $ENDPOINT"
    fi

    # Write peer config
    PEER_NUM="$NEXT_OCTET"
    CONF_NAME="${PEER_NAME:-peer-${PEER_NUM}}"
    PEER_CONF_PATH="$PEERS_DIR/${CONF_NAME}.conf"

    cat > "$PEER_CONF_PATH" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = ${CLIENT_IP}/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBKEY
Endpoint = ${ENDPOINT}:${WG_PORT}
AllowedIPs = $WG_SUBNET
PersistentKeepalive = 25
EOF

    # Also write as the "latest" peer.conf for the iOS app
    cp "$PEER_CONF_PATH" "$OPENHOLE_DIR/peer.conf"

    ok "Peer config: $PEER_CONF_PATH"
    ok "Latest config: $OPENHOLE_DIR/peer.conf (fetched by iOS app)"

    echo ""
    echo "  ─── New peer config ───────────────────────────"
    cat "$PEER_CONF_PATH"
    echo ""
    echo "  ────────────────────────────────────────────────"
    echo ""
    ok "Done. Peer $CLIENT_IP added to wg0."
    echo "  In OpenHole: Settings > Import config from server"
    echo ""
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# FULL SETUP MODE (first run)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
info "No existing wg0 found. Running full setup."
echo ""

CLIENT_IP="${WG_NET_PREFIX}.2"

# ─── Generate keys ─────────────────────────────────────────────────────────────
info "Generating keypairs..."
SERVER_PRIVKEY=$(wg genkey)
SERVER_PUBKEY=$(echo "$SERVER_PRIVKEY" | wg pubkey)
CLIENT_PRIVKEY=$(wg genkey)
CLIENT_PUBKEY=$(echo "$CLIENT_PRIVKEY" | wg pubkey)
ok "Keys generated"

# ─── Write server WireGuard config ────────────────────────────────────────────
info "Writing server config..."
sudo mkdir -p "$WG_CONFIG_DIR"
sudo tee "$WG_CONFIG_DIR/$WG_IFACE.conf" > /dev/null <<EOF
[Interface]
PrivateKey = $SERVER_PRIVKEY
Address = $WG_SERVER_IP/24
ListenPort = $WG_PORT
FwMark = $WG_FWMARK
PostUp = ip rule add fwmark $WG_FWMARK lookup main priority 47
PreDown = ip rule del fwmark $WG_FWMARK lookup main priority 47

# Peer ${PEER_NAME:-$CLIENT_IP} (added $(date +%Y-%m-%d))
[Peer]
PublicKey = $CLIENT_PUBKEY
AllowedIPs = ${CLIENT_IP}/32
EOF
sudo chmod 600 "$WG_CONFIG_DIR/$WG_IFACE.conf"
ok "Server config written to $WG_CONFIG_DIR/$WG_IFACE.conf"

# ─── DuckDNS (optional) ───────────────────────────────────────────────────────
echo ""
info "Dynamic DNS setup (recommended for residential connections)"
echo "  DuckDNS provides a free hostname that tracks your IP."
echo "  Without it, the config will use your raw IP ($PUBLIC_IP),"
echo "  which may stop working if your ISP reassigns it."
echo ""
read -rp "  Set up DuckDNS? [y/N] " SETUP_DUCKDNS

ENDPOINT="$PUBLIC_IP"

if [[ "${SETUP_DUCKDNS,,}" == "y" ]]; then
    echo ""
    echo "  Create a free account at https://www.duckdns.org if you haven't."
    echo "  You need your token and a subdomain (e.g. 'myserver' -> myserver.duckdns.org)"
    echo ""
    read -rp "  DuckDNS token: " DUCKDNS_TOKEN
    read -rp "  DuckDNS subdomain (just the name, not .duckdns.org): " DUCKDNS_SUBDOMAIN

    if [[ -z "$DUCKDNS_TOKEN" || -z "$DUCKDNS_SUBDOMAIN" ]]; then
        warn "Missing token or subdomain. Skipping DuckDNS."
    else
        DUCKDNS_DOMAIN="${DUCKDNS_SUBDOMAIN}.duckdns.org"
        ENDPOINT="$DUCKDNS_DOMAIN"

        # Do initial update
        info "Updating DuckDNS..."
        CURRENT_IP=$(detect_public_ip "$MAIN_IFACE")
        DUCK_RESULT=$(curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=${CURRENT_IP}" 2>/dev/null || echo "FAIL")
        if [[ "$DUCK_RESULT" == "OK" ]]; then
            ok "DuckDNS updated: $DUCKDNS_DOMAIN -> $CURRENT_IP"
        else
            warn "DuckDNS update returned: $DUCK_RESULT (check token/subdomain)"
        fi

        # Write update script
        sudo tee "$DUCKDNS_SCRIPT" > /dev/null <<DUCKEOF
#!/usr/bin/env bash
IP=\$(curl -s --max-time 10 --interface "$MAIN_IFACE" ifconfig.me 2>/dev/null)
[[ -n "\$IP" ]] && curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=\$IP" >/dev/null
DUCKEOF
        sudo chmod +x "$DUCKDNS_SCRIPT"

        # Install cron
        CRON_LINE="*/5 * * * * $DUCKDNS_SCRIPT"
        ( crontab -l 2>/dev/null | grep -v "$DUCKDNS_SCRIPT"; echo "$CRON_LINE" ) | crontab -
        ok "DuckDNS cron installed (every 5 min via $MAIN_IFACE)"

        # Save domain for future add-peer runs
        echo "$DUCKDNS_DOMAIN" > "$OPENHOLE_DIR/duckdns-domain"
    fi
fi

# ─── Write iPhone peer config ─────────────────────────────────────────────────
CONF_NAME="${PEER_NAME:-peer-2}"
PEER_CONF_PATH="$PEERS_DIR/${CONF_NAME}.conf"

cat > "$PEER_CONF_PATH" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = ${CLIENT_IP}/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBKEY
Endpoint = ${ENDPOINT}:${WG_PORT}
AllowedIPs = $WG_SUBNET
PersistentKeepalive = 25
EOF

cp "$PEER_CONF_PATH" "$OPENHOLE_DIR/peer.conf"
ok "Peer config: $PEER_CONF_PATH"
ok "Latest config: $OPENHOLE_DIR/peer.conf (fetched by iOS app)"

# ─── Open firewall ─────────────────────────────────────────────────────────────
info "Opening firewall port $WG_PORT/udp..."
if command -v ufw &>/dev/null; then
    sudo ufw allow "$WG_PORT"/udp > /dev/null
    ok "UFW: opened $WG_PORT/udp"
elif command -v firewall-cmd &>/dev/null; then
    sudo firewall-cmd --permanent --add-port="$WG_PORT"/udp > /dev/null
    sudo firewall-cmd --reload > /dev/null
    ok "firewalld: opened $WG_PORT/udp"
elif command -v iptables &>/dev/null; then
    sudo iptables -C INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null || \
        sudo iptables -A INPUT -p udp --dport "$WG_PORT" -j ACCEPT
    ok "iptables: opened $WG_PORT/udp"
else
    warn "No firewall tool found. Make sure UDP $WG_PORT is reachable."
fi

# ─── Start WireGuard ──────────────────────────────────────────────────────────
info "Starting WireGuard..."
if [[ "$OS" == "macos" ]]; then
    sudo wg-quick up "$WG_IFACE"
else
    sudo systemctl enable --now "wg-quick@$WG_IFACE"
fi
ok "WireGuard started and enabled on boot"

# ─── QR code ───────────────────────────────────────────────────────────────────
echo ""
if ! command -v qrencode &>/dev/null; then
    case "$OS" in
        debian) sudo apt-get install -y qrencode -qq 2>/dev/null ;;
        arch)   sudo pacman -Sy --noconfirm qrencode 2>/dev/null ;;
        fedora) sudo dnf install -y qrencode 2>/dev/null ;;
        macos)  brew install qrencode 2>/dev/null ;;
    esac
fi

if command -v qrencode &>/dev/null; then
    echo "  Scan with WireGuard iOS app:"
    echo ""
    qrencode -t ansiutf8 < "$PEER_CONF_PATH"
fi

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  ─── Setup complete ──────────────────────────────────"
ok "Server: $WG_SERVER_IP on $WG_IFACE (FwMark $WG_FWMARK)"
ok "Peer: $CLIENT_IP"
ok "Endpoint: ${ENDPOINT}:${WG_PORT}"
echo ""

echo "  ─── Peer config ───────────────────────────────────"
cat "$PEER_CONF_PATH"
echo ""

# Check if UPnP is available for port forwarding
UPNP_SUCCESS=false
if command -v upnpc &>/dev/null || [[ "$OS" == "debian" ]]; then
    if ! command -v upnpc &>/dev/null; then
        sudo apt-get install -y miniupnpc -qq 2>/dev/null || true
    fi
    if command -v upnpc &>/dev/null; then
        LOCAL_IP=$(ip addr show "$MAIN_IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
        LOCAL_IP="${LOCAL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
        if upnpc -a "$LOCAL_IP" "$WG_PORT" "$WG_PORT" UDP > /dev/null 2>&1; then
            ok "Router port $WG_PORT forwarded via UPnP"
            UPNP_SUCCESS=true
        fi
    fi
fi

if [[ "$UPNP_SUCCESS" == "false" ]]; then
    ROUTER_IP=$(ip route | grep default | grep -vE 'wg|tun' | awk '{print $3}' | head -1)
    LOCAL_IP=$(ip addr show "$MAIN_IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
    echo -e "${YELLOW}  Router port forward required:${NC}"
    echo "  1. Open router admin: http://${ROUTER_IP:-<router-ip>}"
    echo "  2. Forward UDP $WG_PORT -> ${LOCAL_IP:-<server-lan-ip>}:$WG_PORT"
    echo ""
fi

echo "  To add another peer later:  bash setup.sh [name]"
echo "  In OpenHole: Settings > Import config from server"
echo ""
echo "  ─────────────────────────────────────────────────────"
