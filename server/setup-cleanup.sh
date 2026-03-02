#!/usr/bin/env bash
# OpenButt Session Cleanup Setup
# Installs a cron job that kills orphaned Claude processes left behind when
# the iOS app disconnects without calling terminate() (force-close, SSH drop,
# backgrounding, etc.).
#
# Usage:
#   bash setup-cleanup.sh              # Install cleanup cron (every 5 min)
#   bash setup-cleanup.sh --uninstall  # Remove cron and cleanup script
#
# How it works:
#   ClaudeProcess.swift launches: nohup sh -c 'tail -f /tmp/ob-{UUID}.in | claude ...'
#   If the app disconnects, the nohup'd process tree lives forever.
#   The cleanup script finds ob-* input files that haven't been written to
#   in STALE_MINUTES, kills the associated process tree, and removes temp files.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[ok]${NC} $*"; }
info() { echo -e "${BLUE}-->${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

CLEANUP_SCRIPT="$HOME/.openbutt/cleanup-sessions.sh"
CRON_INTERVAL="0 4"

# ─── Uninstall ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    info "Removing cleanup cron and script..."
    ( crontab -l 2>/dev/null | grep -v "cleanup-sessions.sh" ) | crontab - 2>/dev/null || true
    rm -f "$CLEANUP_SCRIPT"
    ok "Cleanup removed"
    exit 0
fi

echo ""
echo "  OpenButt Session Cleanup"
echo "  ────────────────────────"
echo ""

# ─── Write cleanup script ────────────────────────────────────────────────────
mkdir -p "$(dirname "$CLEANUP_SCRIPT")"

cat > "$CLEANUP_SCRIPT" << 'CLEANUP'
#!/usr/bin/env bash
# Kills orphaned OpenButt Claude sessions whose input files are stale.
# Intended to run via cron every 5 minutes.

STALE_MINUTES=10
LOGFILE="$HOME/.openbutt/cleanup.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }

# Cap log at 1000 lines
if [[ -f "$LOGFILE" ]] && (( $(wc -l < "$LOGFILE") > 1000 )); then
    tail -500 "$LOGFILE" > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"
fi

killed=0

for infile in /tmp/ob-*.in; do
    [[ -f "$infile" ]] || continue

    # Extract session ID from filename
    session_id="${infile#/tmp/ob-}"
    session_id="${session_id%.in}"
    outfile="/tmp/ob-${session_id}.out"

    # Check if input file is stale (not modified in STALE_MINUTES)
    if [[ "$(uname)" == "Darwin" ]]; then
        age_sec=$(( $(date +%s) - $(stat -f %m "$infile") ))
    else
        age_sec=$(( $(date +%s) - $(stat -c %Y "$infile") ))
    fi
    age_min=$(( age_sec / 60 ))

    if (( age_min < STALE_MINUTES )); then
        continue
    fi

    # Find the sh -c process that owns this session's tail -f
    pids=$(pgrep -f "tail -f $infile" 2>/dev/null || true)

    if [[ -z "$pids" ]]; then
        # No process found, just clean up stale files
        rm -f "$infile" "$outfile"
        log "cleaned stale files for $session_id (no process found, ${age_min}m old)"
        continue
    fi

    # Kill each matching process tree
    for pid in $pids; do
        # Kill children (claude process) then parent (sh -c wrapper)
        pkill -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
    done

    rm -f "$infile" "$outfile"
    killed=$((killed + 1))
    log "killed orphaned session $session_id (${age_min}m stale, pids: $pids)"
done

if (( killed > 0 )); then
    log "cleaned up $killed orphaned session(s)"
fi
CLEANUP

chmod +x "$CLEANUP_SCRIPT"
ok "Cleanup script written to $CLEANUP_SCRIPT"

# ─── Install cron ─────────────────────────────────────────────────────────────
CRON_LINE="$CRON_INTERVAL * * * * $CLEANUP_SCRIPT"

# Remove existing entry if present, then add fresh
( crontab -l 2>/dev/null | grep -v "cleanup-sessions.sh"; echo "$CRON_LINE" ) | crontab -
ok "Cron installed: daily at 4am"

# ─── Run it once now to clean up any current orphans ──────────────────────────
info "Running cleanup now..."
bash "$CLEANUP_SCRIPT"
ok "Initial cleanup complete"

# ─── Check current state ─────────────────────────────────────────────────────
orphan_count=$(ls /tmp/ob-*.in 2>/dev/null | wc -l || echo 0)
claude_count=$(pgrep -fc "claude" 2>/dev/null || echo 0)

echo ""
echo "  Status:"
echo "    Orphaned session files: $orphan_count"
echo "    Claude processes:       $claude_count"
echo ""
echo "  Log: $HOME/.openbutt/cleanup.log"
echo "  Uninstall: bash $(realpath "$0") --uninstall"
echo ""
