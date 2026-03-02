#!/usr/bin/env bash
# OpenButt Credential Sync Setup
# Installs a launchd agent on macOS that syncs Claude Code OAuth credentials
# from the local keychain to one or more remote servers every 2 hours.
#
# This keeps server tokens fresh so the iOS app never hits expired tokens.
# Claude Code on the Mac refreshes its own token automatically; this script
# pushes the fresh token to all configured servers via SSH.
#
# Targets are stored in ~/.claude/sync-targets.conf (one per line):
#   user@host:ssh_key_path
#
# Usage:
#   bash setup-credentials-sync.sh                    # Interactive setup
#   bash setup-credentials-sync.sh --add              # Add another target
#   bash setup-credentials-sync.sh --uninstall        # Remove everything
#
# Requirements:
#   - macOS (uses Keychain + launchd)
#   - SSH key access to each target server (key-based, no password prompt)
#   - Claude Code authenticated on this Mac

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[ok]${NC} $*"; }
info() { echo -e "${BLUE}-->${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*"; exit 1; }

SYNC_SCRIPT="$HOME/.claude/sync-credentials.sh"
TARGETS_FILE="$HOME/.claude/sync-targets.conf"
PLIST_PATH="$HOME/Library/LaunchAgents/com.openbutt.sync-credentials.plist"
LABEL="com.openbutt.sync-credentials"
INTERVAL=7200  # 2 hours

# ─── Uninstall ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    info "Removing credential sync..."
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH" "$SYNC_SCRIPT" "$TARGETS_FILE"
    ( crontab -l 2>/dev/null | grep -v "sync-credentials" ) | crontab - 2>/dev/null || true
    ok "Credential sync removed"
    exit 0
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

add_target() {
    echo ""
    read -rp "  SSH user@host (e.g. ckm@10.0.0.250): " SERVER_ADDR
    [[ -n "$SERVER_ADDR" ]] || die "Server address required"

    DEFAULT_KEY="$HOME/.ssh/id_ed25519"
    read -rp "  SSH key path [$DEFAULT_KEY]: " SSH_KEY
    SSH_KEY="${SSH_KEY:-$DEFAULT_KEY}"
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    [[ -f "$SSH_KEY" ]] || die "SSH key not found: $SSH_KEY"

    info "Testing SSH connection..."
    if ! ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes "$SERVER_ADDR" "echo ok" &>/dev/null; then
        die "Cannot SSH to $SERVER_ADDR with key $SSH_KEY"
    fi
    ok "SSH connection works"

    # Store with ~ for portability
    DISPLAY_KEY="${SSH_KEY/#$HOME/\~}"

    # Check for duplicates
    if [[ -f "$TARGETS_FILE" ]] && grep -qF "$SERVER_ADDR" "$TARGETS_FILE"; then
        warn "$SERVER_ADDR already in targets file"
    else
        echo "$SERVER_ADDR:$DISPLAY_KEY" >> "$TARGETS_FILE"
        ok "Added $SERVER_ADDR"
    fi
}

# ─── Add mode ─────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--add" ]]; then
    echo ""
    echo "  Add Sync Target"
    echo "  ────────────────"
    [[ "$OSTYPE" == "darwin"* ]] || die "This script only runs on macOS"
    add_target

    echo ""
    info "Current targets:"
    grep -v '^#' "$TARGETS_FILE" | grep -v '^$' | while IFS=: read -r addr key; do
        echo "    $addr ($key)"
    done
    echo ""

    # Run sync now
    info "Syncing to new target..."
    bash "$SYNC_SCRIPT" 2>/dev/null && ok "Sync succeeded" || warn "Sync failed — check log"
    exit 0
fi

# ─── Full setup ───────────────────────────────────────────────────────────────
echo ""
echo "  OpenButt Credential Sync"
echo "  ────────────────────────"
echo ""

[[ "$OSTYPE" == "darwin"* ]] || die "This script only runs on macOS (uses Keychain + launchd)"

# Check Claude Code credentials exist
MAC_USER="$(whoami)"
if ! security find-generic-password -s "Claude Code-credentials" -a "$MAC_USER" -w &>/dev/null; then
    die "No Claude Code credentials in keychain. Run 'claude' first to authenticate."
fi
ok "Found Claude Code credentials in keychain"

# ─── Configure targets ───────────────────────────────────────────────────────
mkdir -p "$(dirname "$TARGETS_FILE")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_TARGETS="$SCRIPT_DIR/sync-targets.conf"

if [[ -f "$TARGETS_FILE" ]] && grep -v '^#' "$TARGETS_FILE" | grep -q .; then
    info "Existing targets found:"
    grep -v '^#' "$TARGETS_FILE" | grep -v '^$' | while IFS=: read -r addr key; do
        echo "    $addr ($key)"
    done
    echo ""
    read -rp "  Add another target? [y/N] " ADD_MORE
    if [[ "${ADD_MORE,,}" == "y" ]]; then
        add_target
    fi
elif [[ -f "$REPO_TARGETS" ]] && grep -v '^#' "$REPO_TARGETS" | grep -q .; then
    # Seed from repo copy
    cp "$REPO_TARGETS" "$TARGETS_FILE"
    info "Loaded targets from repo ($(basename "$REPO_TARGETS")):"
    grep -v '^#' "$TARGETS_FILE" | grep -v '^$' | while IFS=: read -r addr key; do
        echo "    $addr ($key)"
    done
    echo ""
    read -rp "  Add another target? [y/N] " ADD_MORE
    if [[ "${ADD_MORE,,}" == "y" ]]; then
        add_target
    fi
else
    cat > "$TARGETS_FILE" <<EOF
# OpenButt credential sync targets
# Format: user@host:ssh_key_path
# One target per line. Lines starting with # are ignored.

EOF
    info "No targets configured yet. Let's add your first server."
    add_target
fi

# Keep repo copy in sync
if [[ -f "$REPO_TARGETS" ]] || [[ -d "$SCRIPT_DIR" ]]; then
    cp "$TARGETS_FILE" "$REPO_TARGETS" 2>/dev/null || true
fi

# ─── Write sync script ───────────────────────────────────────────────────────
cat > "$SYNC_SCRIPT" <<'SYNCEOF'
#!/bin/bash
# Sync Claude Code credentials from macOS keychain to remote servers
# Installed by: server/setup-credentials-sync.sh
# Runs via launchd every 2 hours

LOG="$HOME/.claude/sync-credentials.log"
TARGETS_FILE="$HOME/.claude/sync-targets.conf"
CREDS_PATH="~/.claude/.credentials.json"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# Cap log at 200 lines
if [[ -f "$LOG" ]] && (( $(wc -l < "$LOG") > 200 )); then
    tail -100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# Check targets file
if [[ ! -f "$TARGETS_FILE" ]]; then
    log "ERROR: no targets file at $TARGETS_FILE"
    exit 1
fi

# Read credentials from macOS keychain
CREDS=$(security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null)
if [[ -z "$CREDS" ]]; then
    log "ERROR: no credentials in keychain"
    exit 1
fi

# Check the token is actually valid before syncing
EXPIRES_AT=$(echo "$CREDS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('claudeAiOauth',{}).get('expiresAt',0))" 2>/dev/null)
NOW_MS=$(python3 -c "import time; print(int(time.time()*1000))")
REMAINING=$(( (EXPIRES_AT - NOW_MS) / 1000 ))

if (( REMAINING < 300 )); then
    log "SKIP: local token expires in ${REMAINING}s (too stale to sync)"
    exit 1
fi

# Sync to each target
FAILED=0
SYNCED=0

while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue

    REMOTE="${line%%:*}"
    SSH_KEY="${line#*:}"
    SSH_KEY="${SSH_KEY/#\~/$HOME}"

    if ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE" \
        "mkdir -p ~/.claude && echo '$CREDS' > $CREDS_PATH && chmod 600 $CREDS_PATH" 2>/dev/null; then
        log "OK: synced to $REMOTE (expires in ${REMAINING}s)"
        SYNCED=$((SYNCED + 1))
    else
        log "ERROR: SSH write failed for $REMOTE"
        FAILED=$((FAILED + 1))
    fi
done < "$TARGETS_FILE"

if (( FAILED > 0 )); then
    log "DONE: $SYNCED synced, $FAILED failed"
fi
SYNCEOF

chmod +x "$SYNC_SCRIPT"
ok "Sync script: $SYNC_SCRIPT"

# ─── Remove old cron entry if present ─────────────────────────────────────────
if crontab -l 2>/dev/null | grep -q "sync-credentials"; then
    ( crontab -l 2>/dev/null | grep -v "sync-credentials" ) | crontab -
    ok "Removed old cron entry"
fi

# ─── Install launchd agent ────────────────────────────────────────────────────
mkdir -p "$(dirname "$PLIST_PATH")"

cat > "$PLIST_PATH" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$SYNC_SCRIPT</string>
	</array>
	<key>StartInterval</key>
	<integer>$INTERVAL</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/dev/null</string>
	<key>StandardOutPath</key>
	<string>/dev/null</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
ok "launchd agent installed and loaded"

# ─── Run once now ─────────────────────────────────────────────────────────────
info "Running initial sync..."
if bash "$SYNC_SCRIPT"; then
    ok "Initial sync succeeded"
else
    warn "Initial sync failed — check $HOME/.claude/sync-credentials.log"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "  ─── Setup complete ──────────────────────────────────"
ok "Syncs every $(( INTERVAL / 3600 )) hours + on login/wake"
echo ""
info "Targets:"
grep -v '^#' "$TARGETS_FILE" | grep -v '^$' | while IFS=: read -r addr key; do
    echo "    $addr ($key)"
done
echo ""
ok "Script: $SYNC_SCRIPT"
ok "Targets: $TARGETS_FILE"
ok "Log: $HOME/.claude/sync-credentials.log"
ok "Agent: $PLIST_PATH"
echo ""
echo "  Add more targets: bash $(basename "$0") --add"
echo "  Uninstall:        bash $(basename "$0") --uninstall"
echo ""
