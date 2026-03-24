#!/usr/bin/env bash
set -euo pipefail

echo "=== OpenButt: Setup Token Configuration ==="
echo ""
echo "This script configures a Claude setup token on this server."
echo ""
echo "Step 1: If you haven't already, run this command first (requires a browser):"
echo ""
echo "    claude setup-token"
echo ""
echo "Step 2: Paste the generated token below."
echo ""

read -rsp "Setup token: " TOKEN
echo ""

if [[ -z "$TOKEN" ]]; then
    echo "Error: No token provided."
    exit 1
fi

if [[ "$TOKEN" != sk-ant-* ]]; then
    echo "Error: Token should start with 'sk-ant-'. Got something else."
    exit 1
fi

# Update or append CLAUDE_CODE_OAUTH_TOKEN in ~/.bashrc
if grep -q '^export CLAUDE_CODE_OAUTH_TOKEN=' ~/.bashrc 2>/dev/null; then
    sed -i.bak "s|^export CLAUDE_CODE_OAUTH_TOKEN=.*|export CLAUDE_CODE_OAUTH_TOKEN='$TOKEN'|" ~/.bashrc
    rm -f ~/.bashrc.bak
    echo "Updated CLAUDE_CODE_OAUTH_TOKEN in ~/.bashrc"
else
    echo "" >> ~/.bashrc
    echo "export CLAUDE_CODE_OAUTH_TOKEN='$TOKEN'" >> ~/.bashrc
    echo "Added CLAUDE_CODE_OAUTH_TOKEN to ~/.bashrc"
fi

# Clean up stale OAuth credentials
if [[ -f ~/.claude/.credentials.json ]]; then
    rm -f ~/.claude/.credentials.json
    echo "Removed stale ~/.claude/.credentials.json"
fi

echo ""
echo "Done! Token is configured on this server."
echo ""
echo "Next: Paste the same token into OpenButt Settings > Claude Code > Setup Token."
