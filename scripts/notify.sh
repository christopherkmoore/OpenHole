#!/usr/bin/env bash
#
# OpenButt APNs Push Notification Sender
# Sends push notifications to the iOS app via Apple Push Notification service.
# Uses JWT (ES256) authentication with a .p8 key file.
#
# Usage:
#   ./notify.sh "Your message here"
#   echo "Your message" | ./notify.sh
#   ./notify.sh              # reads message from stdin interactively

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }
info()  { printf "${YELLOW}[INFO]${NC}  %s\n" "$*" >&2; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
CONFIG_DIR="$HOME/.openbutt"
CONFIG_FILE="$CONFIG_DIR/config.json"
DEVICE_TOKEN_FILE="$CONFIG_DIR/device_token"

if [[ ! -f "$CONFIG_FILE" ]]; then
    error "Config file not found: $CONFIG_FILE (run setup-server.sh first)"
fi

if [[ ! -f "$DEVICE_TOKEN_FILE" ]]; then
    error "Device token file not found: $DEVICE_TOKEN_FILE (register your iOS device first)"
fi

# Parse config - use jq if available, otherwise python3 / grep fallback
parse_json() {
    local key="$1"
    if command -v jq &>/dev/null; then
        jq -r "$key" "$CONFIG_FILE"
    elif command -v python3 &>/dev/null; then
        python3 -c "import json,sys; d=json.load(open('$CONFIG_FILE')); print(eval('d$key'.replace('.','[\"').replace('[\"','[\"',1) + '\"]' * key.count('.')))" 2>/dev/null
    else
        error "Either jq or python3 is required to parse config"
    fi
}

APNS_ENABLED=$(parse_json '.apns.enabled')
if [[ "$APNS_ENABLED" != "true" ]]; then
    error "APNs is not enabled in config. Run setup-server.sh to configure."
fi

APNS_KEY_PATH=$(parse_json '.apns.key_path')
APNS_TEAM_ID=$(parse_json '.apns.team_id')
APNS_KEY_ID=$(parse_json '.apns.key_id')
APNS_BUNDLE_ID=$(parse_json '.apns.bundle_id')
DEVICE_TOKEN=$(tr -d '[:space:]' < "$DEVICE_TOKEN_FILE")

# Validate required values
[[ -z "$APNS_KEY_PATH" || "$APNS_KEY_PATH" == "null" ]] && error "APNs key path not set in config"
[[ -z "$APNS_TEAM_ID" || "$APNS_TEAM_ID" == "null" ]] && error "APNs team ID not set in config"
[[ -z "$APNS_KEY_ID" || "$APNS_KEY_ID" == "null" ]] && error "APNs key ID not set in config"
[[ -z "$APNS_BUNDLE_ID" || "$APNS_BUNDLE_ID" == "null" ]] && error "APNs bundle ID not set in config"
[[ -z "$DEVICE_TOKEN" ]] && error "Device token is empty"
[[ ! -f "$APNS_KEY_PATH" ]] && error "APNs key file not found: $APNS_KEY_PATH"

# ---------------------------------------------------------------------------
# Get the message
# ---------------------------------------------------------------------------
if [[ $# -gt 0 ]]; then
    MESSAGE="$*"
elif [[ ! -t 0 ]]; then
    # Reading from stdin (piped input)
    MESSAGE=$(cat)
else
    printf "Enter notification message: "
    read -r MESSAGE
fi

if [[ -z "$MESSAGE" ]]; then
    error "Message cannot be empty"
fi

# ---------------------------------------------------------------------------
# Generate JWT for APNs authentication (ES256)
# ---------------------------------------------------------------------------
info "Generating JWT..."

# Base64url encode helper (portable: works on both macOS and Linux)
base64url_encode() {
    openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

# JWT Header
JWT_HEADER=$(printf '{"alg":"ES256","kid":"%s"}' "$APNS_KEY_ID" | base64url_encode)

# JWT Claims - issued at now, expire in 55 minutes (APNs max is 1 hour)
IAT=$(date +%s)
JWT_CLAIMS=$(printf '{"iss":"%s","iat":%d}' "$APNS_TEAM_ID" "$IAT" | base64url_encode)

# Sign with ES256
JWT_HEADER_CLAIMS="${JWT_HEADER}.${JWT_CLAIMS}"
JWT_SIGNATURE=$(printf '%s' "$JWT_HEADER_CLAIMS" | \
    openssl dgst -sha256 -sign "$APNS_KEY_PATH" | base64url_encode)

JWT="${JWT_HEADER_CLAIMS}.${JWT_SIGNATURE}"

# ---------------------------------------------------------------------------
# Build the APNs payload
# ---------------------------------------------------------------------------
# Escape the message for JSON
if command -v jq &>/dev/null; then
    PAYLOAD=$(jq -nc --arg msg "$MESSAGE" '{aps: {alert: {title: "OpenButt", body: $msg}, sound: "default", "content-available": 1}}')
else
    # Manual escaping for JSON (handles quotes and backslashes)
    ESCAPED_MSG=$(printf '%s' "$MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g')
    PAYLOAD="{\"aps\":{\"alert\":{\"title\":\"OpenButt\",\"body\":\"${ESCAPED_MSG}\"},\"sound\":\"default\",\"content-available\":1}}"
fi

# ---------------------------------------------------------------------------
# Send the push notification
# ---------------------------------------------------------------------------
info "Sending push notification to device..."
info "Device token: ${DEVICE_TOKEN:0:8}...${DEVICE_TOKEN: -8}"

APNS_URL="https://api.push.apple.com/3/device/${DEVICE_TOKEN}"

HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
    --http2 \
    -H "authorization: bearer ${JWT}" \
    -H "apns-topic: ${APNS_BUNDLE_ID}" \
    -H "apns-push-type: alert" \
    -H "apns-priority: 10" \
    -H "apns-expiration: 0" \
    -d "$PAYLOAD" \
    "$APNS_URL" 2>&1) || true

# Split response body and status code
HTTP_BODY=$(echo "$HTTP_RESPONSE" | head -n -1)
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n 1)

# ---------------------------------------------------------------------------
# Handle the response
# ---------------------------------------------------------------------------
case "$HTTP_STATUS" in
    200)
        ok "Push notification sent successfully"
        ;;
    400)
        error "Bad request: ${HTTP_BODY}"
        ;;
    403)
        error "Authentication failed (check your .p8 key, team ID, and key ID): ${HTTP_BODY}"
        ;;
    404)
        error "Device token is invalid or inactive: ${HTTP_BODY}"
        ;;
    405)
        error "Method not allowed (must use POST with HTTP/2): ${HTTP_BODY}"
        ;;
    410)
        error "Device token is no longer active: ${HTTP_BODY}"
        ;;
    413)
        error "Payload too large (max 4096 bytes): ${HTTP_BODY}"
        ;;
    429)
        error "Too many requests for this device token: ${HTTP_BODY}"
        ;;
    500|503)
        error "APNs server error (try again later): ${HTTP_BODY}"
        ;;
    *)
        error "Unexpected response (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"
        ;;
esac
