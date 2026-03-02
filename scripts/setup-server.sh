#!/usr/bin/env bash
#
# OpenButt Server Setup Script
# Interactive setup for the OpenButt server environment.
# Creates config directory, manages SSH keys, optionally configures APNs,
# and verifies the Claude CLI is available and authenticated.

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
NC='\033[0m' # No Color

info()    { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*"; }
header()  { printf "\n${BOLD}${CYAN}── %s ──${NC}\n\n" "$*"; }

prompt_yn() {
    local question="$1" default="${2:-y}"
    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "$(printf "${BOLD}%s${NC} [Y/n] " "$question")" yn
        yn="${yn:-y}"
    else
        read -rp "$(printf "${BOLD}%s${NC} [y/N] " "$question")" yn
        yn="${yn:-n}"
    fi
    [[ "$yn" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
header "Checking prerequisites"

# --- Node.js >= 22 ---
if ! command -v node &>/dev/null; then
    error "Node.js is not installed. Please install Node.js >= 22."
    exit 1
fi

NODE_VERSION=$(node -v | sed 's/^v//')
NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)

if (( NODE_MAJOR < 22 )); then
    error "Node.js $NODE_VERSION found, but >= 22 is required."
    exit 1
fi
success "Node.js $NODE_VERSION"

# --- Claude CLI ---
if ! command -v claude &>/dev/null; then
    error "Claude CLI not found. Install it with: npm install -g @anthropic-ai/claude-code"
    exit 1
fi
success "Claude CLI found"

# --- SSH server ---
check_sshd() {
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: check Remote Login via launchctl
        if launchctl list com.openssh.sshd &>/dev/null 2>&1; then
            return 0
        fi
        # Fallback: check if sshd process is running
        if pgrep -qx sshd 2>/dev/null; then
            return 0
        fi
        return 1
    else
        # Linux: check systemd or process
        if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
            return 0
        fi
        if pgrep -qx sshd 2>/dev/null; then
            return 0
        fi
        return 1
    fi
}

if check_sshd; then
    success "SSH server is running"
else
    warn "SSH server does not appear to be running."
    if [[ "$(uname)" == "Darwin" ]]; then
        warn "Enable it in System Settings > General > Sharing > Remote Login"
    else
        warn "Start it with: sudo systemctl enable --now sshd"
    fi
    if ! prompt_yn "Continue anyway?" "n"; then
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Config directory
# ---------------------------------------------------------------------------
header "Setting up config directory"

CONFIG_DIR="$HOME/.openbutt"
CONFIG_FILE="$CONFIG_DIR/config.json"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
success "Created $CONFIG_DIR"

# ---------------------------------------------------------------------------
# SSH keypair for iOS app
# ---------------------------------------------------------------------------
header "SSH key setup"

SSH_KEY_PATH="$CONFIG_DIR/ios_ed25519"

if [[ -f "$SSH_KEY_PATH" ]]; then
    info "Existing iOS SSH key found at $SSH_KEY_PATH"
    if ! prompt_yn "Regenerate key?" "n"; then
        success "Keeping existing key"
        GENERATE_KEY=false
    else
        GENERATE_KEY=true
    fi
else
    GENERATE_KEY=true
fi

USE_EXISTING_PUBKEY=false

if $GENERATE_KEY; then
    if prompt_yn "Do you have an existing public key to import?" "n"; then
        read -rp "$(printf "${BOLD}Path to public key:${NC} ")" EXISTING_PUBKEY_PATH
        EXISTING_PUBKEY_PATH="${EXISTING_PUBKEY_PATH/#\~/$HOME}"
        if [[ ! -f "$EXISTING_PUBKEY_PATH" ]]; then
            error "File not found: $EXISTING_PUBKEY_PATH"
            exit 1
        fi
        cp "$EXISTING_PUBKEY_PATH" "$SSH_KEY_PATH.pub"
        chmod 644 "$SSH_KEY_PATH.pub"
        USE_EXISTING_PUBKEY=true
        success "Imported public key"
    else
        info "Generating Ed25519 keypair for iOS app..."
        ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "openbutt-ios@$(hostname)"
        chmod 600 "$SSH_KEY_PATH"
        chmod 644 "$SSH_KEY_PATH.pub"
        success "Generated keypair at $SSH_KEY_PATH"
    fi
fi

# Add pubkey to authorized_keys
PUBKEY=$(cat "$SSH_KEY_PATH.pub")
AUTH_KEYS="$HOME/.ssh/authorized_keys"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

if grep -qF "$PUBKEY" "$AUTH_KEYS" 2>/dev/null; then
    info "Public key already in authorized_keys"
else
    echo "$PUBKEY" >> "$AUTH_KEYS"
    success "Added public key to $AUTH_KEYS"
fi

if ! $USE_EXISTING_PUBKEY && [[ -f "$SSH_KEY_PATH" ]]; then
    echo ""
    info "Private key (copy this to the iOS app or transfer securely):"
    printf "${YELLOW}"
    cat "$SSH_KEY_PATH"
    printf "${NC}\n"
fi

# ---------------------------------------------------------------------------
# APNs push notification setup (optional)
# ---------------------------------------------------------------------------
header "APNs Push Notification Setup"

APNS_ENABLED=false
APNS_KEY_PATH=""
APNS_TEAM_ID=""
APNS_KEY_ID=""
APNS_BUNDLE_ID=""

if prompt_yn "Configure APNs push notifications?" "n"; then
    APNS_ENABLED=true

    read -rp "$(printf "${BOLD}Path to .p8 key file:${NC} ")" APNS_KEY_PATH
    APNS_KEY_PATH="${APNS_KEY_PATH/#\~/$HOME}"
    if [[ ! -f "$APNS_KEY_PATH" ]]; then
        error "File not found: $APNS_KEY_PATH"
        exit 1
    fi
    # Copy the key into our config dir for safe keeping
    cp "$APNS_KEY_PATH" "$CONFIG_DIR/apns_key.p8"
    chmod 600 "$CONFIG_DIR/apns_key.p8"
    APNS_KEY_PATH="$CONFIG_DIR/apns_key.p8"
    success "Copied APNs key to $APNS_KEY_PATH"

    read -rp "$(printf "${BOLD}Apple Team ID:${NC} ")" APNS_TEAM_ID
    if [[ -z "$APNS_TEAM_ID" ]]; then
        error "Team ID is required"
        exit 1
    fi

    read -rp "$(printf "${BOLD}APNs Key ID:${NC} ")" APNS_KEY_ID
    if [[ -z "$APNS_KEY_ID" ]]; then
        error "Key ID is required"
        exit 1
    fi

    read -rp "$(printf "${BOLD}App Bundle ID:${NC} ")" APNS_BUNDLE_ID
    if [[ -z "$APNS_BUNDLE_ID" ]]; then
        error "Bundle ID is required"
        exit 1
    fi

    success "APNs configured"
fi

# ---------------------------------------------------------------------------
# Server settings
# ---------------------------------------------------------------------------
header "Server settings"

DEFAULT_PORT=2222
read -rp "$(printf "${BOLD}SSH port for OpenButt [${DEFAULT_PORT}]:${NC} ")" SSH_PORT
SSH_PORT="${SSH_PORT:-$DEFAULT_PORT}"

SERVER_HOST=$(hostname)
read -rp "$(printf "${BOLD}Server hostname or IP [${SERVER_HOST}]:${NC} ")" INPUT_HOST
SERVER_HOST="${INPUT_HOST:-$SERVER_HOST}"

# ---------------------------------------------------------------------------
# Claude CLI verification
# ---------------------------------------------------------------------------
header "Verifying Claude CLI"

if claude --version &>/dev/null; then
    CLAUDE_VERSION=$(claude --version 2>&1 | head -1)
    success "Claude CLI version: $CLAUDE_VERSION"
else
    warn "Could not determine Claude CLI version"
fi

# Check if claude is authenticated
info "Checking Claude CLI authentication..."
AUTH_STATUS=$(claude auth status 2>&1 | head -1)

if echo "$AUTH_STATUS" | grep -q '"loggedIn": true'; then
    success "Claude CLI is authenticated"
else
    warn "Claude CLI is not logged in."
    echo ""
    info "To authenticate, run:"
    echo ""
    printf "  ${CYAN}claude auth login${NC}\n"
    echo ""
    info "This will print a URL. Open it in any browser (phone, laptop, etc.),"
    info "complete the sign-in, and the CLI will pick up the token automatically."
    echo ""
    info "If you're on a headless server with no display, that's fine —"
    info "you just need a browser on ANY device to open the URL."
    echo ""
    if prompt_yn "Run 'claude auth login' now?" "y"; then
        claude auth login
        # Verify it worked
        if claude auth status 2>&1 | grep -q '"loggedIn": true'; then
            success "Claude CLI is now authenticated"
        else
            warn "Authentication may not have completed. You can retry later."
        fi
    else
        warn "Skipping authentication. Run 'claude auth login' before using OpenButt."
    fi
fi

# ---------------------------------------------------------------------------
# Write config.json
# ---------------------------------------------------------------------------
header "Writing configuration"

# Build JSON with proper escaping via a heredoc and jq (if available) or printf
write_config() {
    if command -v jq &>/dev/null; then
        jq -n \
            --arg host "$SERVER_HOST" \
            --argjson port "$SSH_PORT" \
            --arg ssh_key "$SSH_KEY_PATH.pub" \
            --arg user "$(whoami)" \
            --argjson apns_enabled "$APNS_ENABLED" \
            --arg apns_key "$APNS_KEY_PATH" \
            --arg apns_team "$APNS_TEAM_ID" \
            --arg apns_key_id "$APNS_KEY_ID" \
            --arg apns_bundle "$APNS_BUNDLE_ID" \
            '{
                server: {
                    host: $host,
                    port: $port,
                    user: $user,
                    ssh_public_key: $ssh_key
                },
                apns: {
                    enabled: $apns_enabled,
                    key_path: $apns_key,
                    team_id: $apns_team,
                    key_id: $apns_key_id,
                    bundle_id: $apns_bundle
                },
                claude: {
                    max_turns: 25,
                    timeout_seconds: 300
                }
            }' > "$CONFIG_FILE"
    else
        # Fallback: write JSON manually
        cat > "$CONFIG_FILE" <<JSONEOF
{
  "server": {
    "host": "${SERVER_HOST}",
    "port": ${SSH_PORT},
    "user": "$(whoami)",
    "ssh_public_key": "${SSH_KEY_PATH}.pub"
  },
  "apns": {
    "enabled": ${APNS_ENABLED},
    "key_path": "${APNS_KEY_PATH}",
    "team_id": "${APNS_TEAM_ID}",
    "key_id": "${APNS_KEY_ID}",
    "bundle_id": "${APNS_BUNDLE_ID}"
  },
  "claude": {
    "max_turns": 25,
    "timeout_seconds": 300
  }
}
JSONEOF
    fi
}

write_config
chmod 600 "$CONFIG_FILE"
success "Configuration written to $CONFIG_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Setup Complete"

printf "${GREEN}${BOLD}OpenButt server is configured!${NC}\n\n"
printf "  Config directory:  ${CYAN}%s${NC}\n" "$CONFIG_DIR"
printf "  Config file:       ${CYAN}%s${NC}\n" "$CONFIG_FILE"
printf "  SSH public key:    ${CYAN}%s${NC}\n" "$SSH_KEY_PATH.pub"
if $APNS_ENABLED; then
    printf "  APNs:              ${GREEN}Enabled${NC}\n"
else
    printf "  APNs:              ${YELLOW}Not configured${NC}\n"
fi
printf "  Server:            ${CYAN}%s@%s:%s${NC}\n" "$(whoami)" "$SERVER_HOST" "$SSH_PORT"
echo ""
info "Next steps:"
echo "  1. Transfer the private key to the iOS app (if newly generated)"
echo "  2. Start the OpenButt server with: openbutt-server start"
if ! $APNS_ENABLED; then
    echo "  3. Run this script again to configure APNs push notifications"
fi
echo ""
