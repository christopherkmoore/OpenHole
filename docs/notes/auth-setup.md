# Claude Code Authentication on Headless Servers

## How It Works

`claude auth login` works on headless servers (no monitor/browser needed):

1. Run `claude auth login` on the server (via SSH)
2. It prints an OAuth URL
3. Open that URL in **any browser on any device** (your phone, laptop, etc.)
4. Complete the sign-in on claude.ai
5. The CLI on the server automatically picks up the token

The redirect goes to `platform.claude.com` (not localhost), so the browser doesn't need to be on the same machine.

## Quick Setup

```bash
# SSH into your server
ssh user@yourserver

# Run login — it prints a URL to open in any browser
claude auth login

# Verify it worked
claude auth status
```

## Environment Variable (for automation)

Claude Code also supports passing a token directly:

```bash
# These env vars are recognized by Claude Code:
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3
CLAUDE_CODE_OAUTH_CLIENT_ID=...
```

## Credential Storage

- **macOS**: Stored in the system keychain under `"Claude Code-credentials"`
- **Linux with desktop**: Uses gnome-keyring or kwallet via libsecret
- **Linux headless**: File-based fallback at `~/.claude/.credentials.json`

## Token Refresh (iOS)

OAuth tokens expire every ~8 hours (`expires_in: 28800`). The iOS app handles this automatically via `OAuthManager`:

1. Before starting any session, reads `~/.claude/.credentials.json` from the server via SSH
2. Checks if `expiresAt` is within 5 minutes of now
3. If expiring/expired, POSTs directly from iPhone to `https://platform.claude.com/v1/oauth/token`:
   ```json
   {
     "grant_type": "refresh_token",
     "refresh_token": "...",
     "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
     "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers"
   }
   ```
4. Response includes new `access_token`, `refresh_token` (single-use), and `expires_in`
5. Writes updated credentials back to `~/.claude/.credentials.json` on the server via SSH

If a 401/expired error is detected mid-session, the app auto-refreshes and resumes.

## Troubleshooting

If auth fails:
- Make sure the server has internet access (needs to reach `claude.ai` and `platform.claude.com`)
- Try `claude auth status` to see current state
- The OAuth URL is one-time use — if it expires, just run `claude auth login` again

## Known Issues: Non-Interactive SSH Auth

### Problem

Running `claude auth login` non-interactively over SSH (e.g. `ssh user@host 'claude auth login'`) does not work reliably. The CLI uses Ink (a React-based TUI framework) which requires a persistent interactive terminal. When invoked non-interactively, the process exits before the OAuth callback can complete.

### What We Tried

1. **`ssh user@host 'claude auth login'`** — Process exits immediately after printing the URL. OAuth completes in the browser but the CLI is already dead.

2. **`ssh -tt` (force PTY allocation)** — Same result. The pseudo-terminal closes when the SSH command pipeline ends.

3. **`script -q /dev/null -c "claude auth login"`** — PTY emulation via `script` command. Process still exits prematurely.

4. **`nohup` + background process** — Ink detects no TTY and fails to render or accept input.

5. **tmux session** — `tmux new-session -d -s login "claude auth login"` keeps the process alive. The URL is captured via `tmux capture-pane -p -J`. OAuth completes in the browser and a code is displayed. However, sending the code back via `tmux send-keys` does not work — Ink's input handling doesn't pick up keystrokes injected this way.

6. **tmux with `tee`** — Piping through `tee` to capture output breaks Ink's TUI input handling entirely.

7. **Chrome DevTools MCP** — Attempted to automate the OAuth flow in a browser via MCP tools. Hits the claude.ai login page which requires Google/email sign-in — not a self-contained solution.

### What Works

- **Interactive SSH session**: If a user SSHes in and runs `claude auth login` directly in their terminal, it works perfectly. The URL prints, they open it in any browser, OAuth completes, token is saved. This is the intended flow and what the setup script uses.

- **Credential transfer**: Copying credentials from an already-authenticated machine works. On macOS, credentials are in the keychain under `"Claude Code-credentials"`. On Linux headless, the file-based fallback location needs to be determined.

- **`CLAUDE_CODE_OAUTH_TOKEN` env var**: If you have a token, you can bypass `claude auth login` entirely.

### TODO

- [x] Determine where Linux headless Claude Code stores credentials → `~/.claude/.credentials.json`
- [ ] Investigate whether `claude auth login` has a `--no-interactive` or `--code` flag for pasting OAuth codes directly
- [ ] Consider adding a lightweight auth helper to the setup script that can exchange an OAuth code without Ink's TUI
- [ ] Test if newer versions of Claude Code improve headless auth support
