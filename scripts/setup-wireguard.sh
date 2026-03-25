#!/usr/bin/env bash
#
# OpenHole WireGuard Peer Config Generator
# Generates a WireGuard configuration for the iOS peer and provides
# instructions for adding the peer to the server's WireGuard interface.

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }
header()  { printf "\n${BOLD}${CYAN}── %s ──${NC}\n\n" "$*"; }

# ---------------------------------------------------------------------------
# Check for wg command
# ---------------------------------------------------------------------------
if ! command -v wg &>/dev/null; then
    error "WireGuard tools not found. Install them first:
    macOS:   brew install wireguard-tools
    Ubuntu:  sudo apt install wireguard-tools"
fi

# ---------------------------------------------------------------------------
# Config directory
# ---------------------------------------------------------------------------
CONFIG_DIR="$HOME/.openhole"
WG_DIR="$CONFIG_DIR/wireguard"
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

header "WireGuard Peer Configuration for iPhone"

# ---------------------------------------------------------------------------
# Generate keypair for the iPhone peer
# ---------------------------------------------------------------------------
info "Generating WireGuard keypair for iPhone peer..."

IPHONE_PRIVATE_KEY=$(wg genkey)
IPHONE_PUBLIC_KEY=$(echo "$IPHONE_PRIVATE_KEY" | wg pubkey)

success "iPhone private key generated"
success "iPhone public key: $IPHONE_PUBLIC_KEY"

# Save keys
echo "$IPHONE_PRIVATE_KEY" > "$WG_DIR/iphone_private.key"
echo "$IPHONE_PUBLIC_KEY" > "$WG_DIR/iphone_public.key"
chmod 600 "$WG_DIR/iphone_private.key"
chmod 644 "$WG_DIR/iphone_public.key"

# ---------------------------------------------------------------------------
# Gather server information
# ---------------------------------------------------------------------------
header "Server WireGuard details"

echo "You'll need details from your WireGuard server configuration."
echo ""

# Server public key
read -rp "$(printf "${BOLD}Server WireGuard public key:${NC} ")" SERVER_PUBLIC_KEY
if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
    error "Server public key is required"
fi

# Server endpoint
read -rp "$(printf "${BOLD}Server endpoint (host:port, e.g. vpn.example.com:51820):${NC} ")" SERVER_ENDPOINT
if [[ -z "$SERVER_ENDPOINT" ]]; then
    error "Server endpoint is required"
fi

# Add port if not specified
if [[ "$SERVER_ENDPOINT" != *:* ]]; then
    SERVER_ENDPOINT="${SERVER_ENDPOINT}:51820"
    info "Using default port: $SERVER_ENDPOINT"
fi

# Allowed IPs for the iPhone peer (what traffic to route through the tunnel)
echo ""
echo "What traffic should the iPhone route through WireGuard?"
echo "  1) All traffic (0.0.0.0/0, ::/0) - full tunnel"
echo "  2) Only the server's LAN (e.g. 10.0.0.0/24) - split tunnel"
echo "  3) Custom"
read -rp "$(printf "${BOLD}Choice [1]:${NC} ")" TRAFFIC_CHOICE
TRAFFIC_CHOICE="${TRAFFIC_CHOICE:-1}"

case "$TRAFFIC_CHOICE" in
    1)
        ALLOWED_IPS="0.0.0.0/0, ::/0"
        ;;
    2)
        read -rp "$(printf "${BOLD}Server LAN subnet (e.g. 10.0.0.0/24):${NC} ")" LAN_SUBNET
        [[ -z "$LAN_SUBNET" ]] && error "Subnet is required"
        # Also include the WireGuard subnet itself
        read -rp "$(printf "${BOLD}WireGuard subnet (e.g. 10.10.0.0/24):${NC} ")" WG_SUBNET
        if [[ -n "$WG_SUBNET" ]]; then
            ALLOWED_IPS="${WG_SUBNET}, ${LAN_SUBNET}"
        else
            ALLOWED_IPS="$LAN_SUBNET"
        fi
        ;;
    3)
        read -rp "$(printf "${BOLD}Allowed IPs (comma-separated):${NC} ")" ALLOWED_IPS
        [[ -z "$ALLOWED_IPS" ]] && error "Allowed IPs required"
        ;;
    *)
        error "Invalid choice"
        ;;
esac

# iPhone tunnel IP address
echo ""
read -rp "$(printf "${BOLD}iPhone tunnel IP address (e.g. 10.10.0.2/32):${NC} ")" IPHONE_ADDRESS
if [[ -z "$IPHONE_ADDRESS" ]]; then
    error "iPhone tunnel IP is required"
fi

# DNS server
read -rp "$(printf "${BOLD}DNS server [1.1.1.1]:${NC} ")" DNS_SERVER
DNS_SERVER="${DNS_SERVER:-1.1.1.1}"

# Persistent keepalive (useful behind NAT, especially for mobile)
read -rp "$(printf "${BOLD}Persistent keepalive interval (seconds) [25]:${NC} ")" KEEPALIVE
KEEPALIVE="${KEEPALIVE:-25}"

# ---------------------------------------------------------------------------
# Generate iPhone peer config
# ---------------------------------------------------------------------------
header "Generating configuration"

PEER_CONFIG_FILE="$WG_DIR/iphone.conf"

cat > "$PEER_CONFIG_FILE" <<EOF
[Interface]
PrivateKey = ${IPHONE_PRIVATE_KEY}
Address = ${IPHONE_ADDRESS}
DNS = ${DNS_SERVER}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}
PersistentKeepalive = ${KEEPALIVE}
EOF

chmod 600 "$PEER_CONFIG_FILE"
success "iPhone config written to $PEER_CONFIG_FILE"

# ---------------------------------------------------------------------------
# QR code generation
# ---------------------------------------------------------------------------
header "QR Code"

if command -v qrencode &>/dev/null; then
    QR_FILE="$WG_DIR/iphone_qr.png"
    qrencode -t PNG -o "$QR_FILE" -r "$PEER_CONFIG_FILE"
    success "QR code saved to $QR_FILE"

    # Also display in terminal if possible
    if qrencode -t ANSIUTF8 &>/dev/null 2>&1; then
        echo ""
        qrencode -t ANSIUTF8 < "$PEER_CONFIG_FILE"
        echo ""
        info "Scan this QR code with the WireGuard iOS app"
    fi
else
    warn "qrencode not installed. Install it to generate a scannable QR code:"
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "    brew install qrencode"
    else
        echo "    sudo apt install qrencode"
    fi
    echo ""
    info "You can manually import $PEER_CONFIG_FILE into the WireGuard iOS app"
fi

# ---------------------------------------------------------------------------
# Server-side instructions
# ---------------------------------------------------------------------------
header "Server-side configuration"

printf "Add this peer block to your server's WireGuard config\n"
printf "(usually ${CYAN}/etc/wireguard/wg0.conf${NC}):\n\n"

# Extract just the IP without the CIDR suffix for the server-side AllowedIPs
IPHONE_IP_ONLY=$(echo "$IPHONE_ADDRESS" | cut -d/ -f1)

printf "${YELLOW}"
cat <<EOF
# OpenHole iPhone peer
[Peer]
PublicKey = ${IPHONE_PUBLIC_KEY}
AllowedIPs = ${IPHONE_IP_ONLY}/32
EOF
printf "${NC}\n"

echo "Then reload WireGuard on the server:"
printf "  ${CYAN}sudo wg syncconf wg0 <(wg-quick strip wg0)${NC}\n"
echo ""
echo "Or restart the interface:"
printf "  ${CYAN}sudo wg-quick down wg0 && sudo wg-quick up wg0${NC}\n"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Summary"

printf "  iPhone private key:  ${CYAN}%s${NC}\n" "$WG_DIR/iphone_private.key"
printf "  iPhone public key:   ${CYAN}%s${NC}\n" "$WG_DIR/iphone_public.key"
printf "  iPhone config:       ${CYAN}%s${NC}\n" "$PEER_CONFIG_FILE"
printf "  iPhone tunnel IP:    ${CYAN}%s${NC}\n" "$IPHONE_ADDRESS"
printf "  Server endpoint:     ${CYAN}%s${NC}\n" "$SERVER_ENDPOINT"
echo ""
success "WireGuard peer configuration complete"
echo ""
