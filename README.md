<p align="center">
  <img src="docs/banner.png?v=2" alt="OpenHole" width="800">
</p>

<p align="center">
  <strong>Claude Code on your iPhone. Self-hosted. No cloud. Just SSH.</strong>
</p>

---

A native iOS app for controlling [Claude Code](https://docs.anthropic.com/en/docs/claude-code) remotely from your iPhone. Claude Code runs on your Linux or macOS desktop with full filesystem access — OpenHole is the mobile front-end.

## What It Does

- **Chat with Claude Code** from your phone with full markdown rendering
- **Approve or deny tool calls** (file edits, bash commands, etc.) with visual diff previews
- **Browse files** on the remote machine
- **Voice input** — speak your prompts instead of typing
- **Session management** — resume previous conversations, pick up where you left off
- **WireGuard VPN** — works from anywhere, not just your home network
- **Siri / Shortcuts** — trigger prompts via Shortcuts app or Siri voice commands

## How It Works

```
┌─────────────┐         SSH (Citadel)        ┌───────────────────┐
│   iPhone    │ ◄──────────────────────────► │   Your Server     │
│  (SwiftUI)  │    WireGuard when remote     │   (Linux/macOS)   │
│             │                              │                   │
│  Chat UI    │── append to .in file ──────► │  tail -f .in |    │
│  File Tree  │◄── poll .out file ────────── │  claude -p ...    │
│  Diff View  │                              │  > .out 2>&1      │
│  Approvals  │                              │                   │
└─────────────┘                              └───────────────────┘
```

OpenHole spawns a persistent Claude Code process on your server using `tail -f` as a pipe. Messages are appended to an input file, responses are polled from an output file. The process stays alive across messages — no re-spawning per prompt.

## Requirements

### Server (your desktop/laptop)
- Linux or macOS
- Node.js >= 22
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- SSH server with key-based auth

### iPhone
- iOS 17.0+
- Xcode 16+ (to build from source)

### Optional
- WireGuard (for remote access outside your LAN)

## Quick Start

### 1. Set up the server

```bash
git clone https://github.com/christopherkmoore/OpenHole.git
cd OpenHole
bash scripts/setup-server.sh
```

The setup script checks prerequisites, generates an SSH keypair for your phone, and configures `~/.openbutt/` on the server.

### 2. Build the iOS app

The Xcode project is not included in the repo — it's generated from `project.yml` using [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd ios

# Install xcodegen and Go (needed for WireGuard)
brew install xcodegen go

# Build the WireGuard Go bridge (required before first build)
make -C Packages/WireGuardApple/Sources/WireGuardKitGo

# Create Local.xcconfig with your Apple development team ID
echo "DEVELOPMENT_TEAM = YOUR_TEAM_ID" > Local.xcconfig

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open OpenButt.xcodeproj
```

> **Finding your Team ID:** Open Xcode > Settings > Accounts > select your Apple ID > look for the Team ID under your team name. For personal accounts, it's a 10-character alphanumeric string.

Build and run on your iPhone (simulator won't work — SSH requires a real device on the network). If you get a linker error about `libwg-go`, re-run the `make` step above.

### 3. Configure the app

1. Open Settings in the app
2. Enter your server's local IP, SSH port, and username
3. Import your SSH private key — paste the contents of the private key file into Settings > SSH Key
4. Hit "Test Connection" to verify
5. Start chatting

> **SSH keys must be Ed25519.** The setup script generates one automatically. If using your own key, it must be an Ed25519 key in OpenSSH format (`ssh-keygen -t ed25519`). RSA and ECDSA keys are not supported.

There is no server process to start — the app connects via SSH and spawns Claude Code processes directly.

### WireGuard (optional, for remote access)

If you want to use OpenHole from outside your home network:

```bash
bash server/setup.sh
```

This sets up a WireGuard server on your desktop and generates a peer config for your iPhone. See [server/README.md](server/README.md) for details on port forwarding, DuckDNS, and double NAT.

## Project Structure

```
OpenHole/
├── ios/
│   ├── project.yml              # XcodeGen spec
│   ├── OpenButt/
│   │   ├── App/                 # Entry point, settings, root views
│   │   ├── Claude/              # Stream-JSON parser, session state machine, OAuth
│   │   ├── Intents/             # Siri / Shortcuts integration
│   │   ├── SSH/                 # Citadel SSH, persistent process, WireGuard
│   │   ├── Services/            # Logging, voice input, push notifications
│   │   └── Views/
│   │       ├── Chat/            # Message bubbles, tool cards, input bar
│   │       ├── Files/           # Remote file browser
│   │       ├── Diff/            # Diff viewer for Edit/Write tools
│   │       └── Settings/        # Configuration UI
│   └── OpenButtTunnel/          # WireGuard network extension
├── scripts/
│   ├── setup-server.sh          # Interactive server setup
│   ├── setup-wireguard.sh       # WireGuard peer config generator
│   └── notify.sh                # APNs push notification sender
├── server/
│   ├── setup.sh                 # WireGuard server setup (Linux/macOS)
│   ├── setup-cleanup.sh         # Orphaned session cleanup (cron)
│   ├── setup-credentials-sync.sh # OAuth token sync from Mac (launchd)
│   └── README.md                # Detailed server setup guide
├── config/
│   └── example-config.json      # Example server config
└── docs/                        # Architecture and feature docs
```

## Key Features

### Tool Approval Flow

When Claude tries to use a tool (read a file, run a command, edit code), you see the tool call with its inputs. Approve individual tools or approve all at once. Approved tools are remembered across sessions.

### Inline Diffs

`Edit` and `Write` tool calls render as inline diffs with red/green highlighting. Long diffs expand to fullscreen with horizontal scroll.

### Session Persistence

Sessions are stored on the server. Resume any previous conversation from the session picker. The app remembers your active session across launches.

### OAuth Token Refresh

Claude Code OAuth tokens expire every ~8 hours. The app automatically detects expiration, refreshes the token directly from your phone, and writes the updated credentials back to the server. No manual intervention needed.

### Voice Input

Tap the microphone button to speak your prompt. Uses iOS Speech Recognition to transcribe and send as text.

## Customization

### Bundle ID

The default bundle ID is `com.openbutt.ai`. If you need to change it (e.g., for multiple installations), update these files:

- `ios/project.yml` — `bundleIdPrefix` and `PRODUCT_BUNDLE_IDENTIFIER` (both targets)
- `ios/project.yml` — `com.apple.security.application-groups` (both targets)
- `ios/OpenButt/Resources/OpenButt.entitlements`
- `ios/OpenButtTunnel/OpenButtTunnel.entitlements`
- `ios/OpenButt/App/AppSettings.swift` — `privateKeyTag` and `keychainKey`
- `ios/OpenButt/SSH/WireGuardManager.swift` — static constants
- `ios/OpenButt/Services/Logger.swift` — subsystem identifiers
- `ios/OpenButtTunnel/PacketTunnelProvider.swift` — keychain access group

### Claude Model

Default model is `claude-sonnet-4-6`. Change in Settings > Claude Code > Model. Available options: Sonnet, Opus, Haiku.

### Permission Mode

Controls how Claude handles tool permissions. Options:
- **Accept Edits** (default) — auto-approves read-only tools, prompts for writes
- **Default** — prompts for everything
- **Don't Ask** — auto-approves everything (use with caution)
- **Bypass Permissions** — no restrictions (dangerous)

## Server-Side Files

The setup script creates `~/.openbutt/` on your server:

| File | Purpose |
|------|---------|
| `cleanup-sessions.sh` | Kills orphaned Claude processes (run via cron) |
| `peer.conf` | WireGuard peer config for iPhone (if configured) |
| `device_token` | APNs device token (written by the app) |
| `config.json` | Server configuration |

### Session Cleanup

The setup script installs a daily cron job to kill orphaned Claude processes, or run manually:

```bash
bash server/setup-cleanup.sh
```

### Credential Sync (macOS only)

Only needed if Claude Code is authenticated on your Mac but you SSH into a different machine (e.g., a Linux server). This syncs your Mac's fresh OAuth tokens to the remote server via SSH so the iOS app never hits expired tokens.

```bash
bash server/setup-credentials-sync.sh
```

Installs a launchd agent that pushes tokens every 2 hours. Not needed if Claude Code runs directly on the machine you SSH into.

## Known Limitations

- **AskUserQuestion tool** — Claude Code's interactive question tool doesn't work natively in `-p` mode. The app uses a workaround (shows the question UI, sends the answer as a plain message). A proper WebSocket bridge is planned.
- **No terminal emulator** — this is a structured chat UI, not a terminal. All interaction goes through Claude.
- **File browser is read-only** — viewing only. All editing happens through Claude's tool calls.
- **Single active session** — one Claude process at a time. Switch between saved sessions via the session picker.

## Dependencies

| Package | License | Purpose |
|---------|---------|---------|
| [Citadel](https://github.com/orlandos-nl/Citadel) | MIT | Pure Swift SSH client |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | MIT | Markdown rendering |
| [WireGuardKit](https://www.wireguard.com/) | MIT | VPN tunnel (local package) |

## License

MIT — see [LICENSE](LICENSE).
