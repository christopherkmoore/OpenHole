# OpenHole - Design Document

## Overview

An open-source native iOS app that gives full remote access to Claude Code running on any Linux/macOS desktop. The app communicates over SSH, sending prompts and receiving structured JSON responses. Claude Code runs natively on the remote machine with full filesystem access.

Designed to be self-hostable by anyone with a spare computer and a Claude subscription. No cloud services, no third-party dependencies, fully private.

**License:** MIT (or similar permissive)
**Repo:** Will be published to GitHub

## Architecture

```
┌─────────────┐         SSH (Citadel)        ┌───────────────────┐
│   iPhone    │ ◄──────────────────────────► │   Your Server     │
│  (SwiftUI)  │    WireGuard when remote     │   (Linux/macOS)   │
│             │                              │                   │
│  Chat UI    │── append to .in file ──────► │  tail -f .in |    │
│  File Tree  │◄── poll .out file ────────── │  claude -p ...    │
│  Diff View  │                              │  > .out 2>&1 &    │
│  Approvals  │                              │                   │
│             │                              │  /tmp/ob-{id}.in  │
│  Push Notif │◄─── APNs ◄── notify.sh ──── │  /tmp/ob-{id}.out │
└─────────────┘                              └───────────────────┘
```

## Claude Code Interface

We use the CLI's bidirectional streaming JSON mode:

```bash
claude --output-format stream-json --input-format stream-json --verbose
```

### Output Events (stdout, JSONL - one JSON object per line)

| Event Type | What It Is | How We Render |
|---|---|---|
| `system` (init) | Session start, tools list, model info | Status bar / session info |
| `assistant` | Claude's complete response (text + tool_use blocks) | Chat bubbles, tool cards |
| `user` | Tool results fed back to Claude | Collapsible result cards |
| `stream_event` | Partial tokens (with `--include-partial-messages`) | Live typing animation |
| `result` | Final summary (cost, tokens, duration, errors) | Session stats footer |

### Input Events (stdin, JSONL)

```json
{"type":"user","message":{"role":"user","content":"Fix the bug in auth.ts"},"session_id":"<from-init>"}
```

### Permission Handling

Uses a persistent process model with `--allowedTools` for pre-approved tools:

1. User builds up an approved tool set over time (stored in keychain)
2. Process starts with `--allowedTools "Read Write Edit ..."` to pre-approve known tools
3. If Claude hits an unapproved tool, the `result` event includes `permission_denials`
4. iOS app shows approval banner — user can approve (adds to `--allowedTools`, restarts process, retries) or skip
5. `--permission-mode plan` is the recommended default (safest for mobile)

This replaces the earlier one-shot approach which couldn't handle interactive approvals at all.

### Session Management

- Capture `session_id` from the `system` init message
- Resume with `--resume <session-id>`
- Fork with `--resume <session-id> --fork-session`
- Sessions stored at `~/.claude/projects/` on your server
- Persistent process stays alive across messages (no re-spawn per message)
- Process restarts with `--resume` on SSH reconnect or tool approval changes

## iOS App

### Tech Stack

- **SwiftUI** - UI framework
- **Citadel** (orlandos-nl) - SSH library, pure Swift, built on Apple's SwiftNIO SSH
  - SPM native, actively maintained, iOS compatible
  - Supports PTY, key auth, streaming output, SFTP
- **APNs** - native push notifications via .p8 key on your server

### Screens

#### 1. Chat (main screen)
- Message bubbles for user prompts and Claude responses
- Markdown rendering for code blocks, inline code, lists
- Tool call cards (expandable) showing tool name + input + output
- Approve/Deny buttons for permission requests
- Live streaming text as Claude types (via stream_event deltas)
- Input bar at bottom with send button
- Session picker (resume previous sessions)

#### 2. Files
- Tree view of the project directory on your server
- Tap a file to view contents (syntax highlighted)
- Fetched via SFTP or `ls`/`cat` over a second SSH channel
- Pull to refresh

#### 3. Diff
- After each assistant turn that includes Edit/Write tool calls, show the diff
- Extract old_string/new_string from Edit tool inputs
- Render as unified diff with red/green highlighting
- Could also run `git diff` on your server for accurate diffs

#### 4. Settings
- SSH connection config (host, user, key)
- Claude Code settings (model, permission mode, system prompt)
- Push notification preferences
- Session management (list, resume, delete)

### SSH Connection

- Auth via Ed25519 key pair (generate on iPhone, add pubkey to your server)
- Or import existing `your server` private key into the app's keychain
- Two SSH channels: one for claude CLI, one for file operations
- Reconnect logic for network changes

### Push Notifications

- iOS app registers for APNs on launch, gets device token
- Device token sent to your server (written to `~/.openhole/device_token`)
- your server runs a small Node.js or Python script when Claude finishes a long task
- Uses .p8 key from Apple Developer portal to send directly to APNs
- No intermediate server needed

## Server Setup (any Linux/macOS machine)

### Prerequisites
- Node.js >= 22 (for Claude Code)
- Claude Code CLI installed
- Logged in to Claude (`claude login`)
- SSH server running with key-based auth

### Setup Script (`scripts/setup-server.sh`)

An interactive setup script that:
1. Checks prerequisites (node, claude, ssh)
2. Creates `~/.openhole/` config directory
3. Generates an SSH keypair for the iOS app (or accepts an existing pubkey)
4. Adds the pubkey to `~/.ssh/authorized_keys`
5. Optionally sets up WireGuard for remote access
6. Optionally sets up APNs push notifications (prompts for .p8 key path, team ID, key ID)
7. Writes `~/.openhole/config.json` with all settings
8. Tests that `claude` CLI works

### Server-Side Components
- `~/.openhole/` - config directory
  - `config.json` - settings (host, port, allowed dirs, notification prefs)
  - `device_token` - iOS device token for push notifications (written by app)
  - `AuthKey.p8` - APNs key (optional, for push notifications)
- `scripts/notify.sh` - script to send push notifications
- `scripts/setup-wireguard.sh` - generates WireGuard peer config for iPhone

### WireGuard (for remote access, optional)
- `scripts/setup-wireguard.sh` generates:
  - A new WireGuard peer config for the iPhone
  - QR code you can scan from the WireGuard iOS app
- Works with existing WireGuard setups or creates a new interface
- Users without WireGuard can use Tailscale or any other tunnel

## Network Access

Options for reaching your server from outside the local network:

1. **WireGuard on iPhone** - cleanest, direct tunnel to server's WireGuard IP
2. **Tailscale** - easier setup, handles NAT traversal automatically
3. **SSH jump host** - phone → intermediate host (public IP) → your server

Option 1 is preferred for full control and privacy.

## Build Phases

### Phase 1: Foundation
- [ ] Install Claude Code on your server, verify `claude login` works
- [ ] Test `--output-format stream-json --input-format stream-json` manually
- [ ] Create Xcode project with Citadel SPM dependency
- [ ] Basic SSH connection from iOS to your server
- [ ] Spawn claude process, send a prompt, receive and parse response

### Phase 2: Chat UI
- [ ] Chat view with message bubbles
- [ ] Streaming text display (parse stream_events)
- [ ] Tool call rendering (expandable cards)
- [ ] Input bar with send
- [ ] Basic error handling and reconnection

### Phase 3: File Browser & Diffs
- [ ] File tree view via SFTP or ls commands
- [ ] File content viewer with syntax highlighting
- [ ] Diff view extracted from Edit/Write tool calls
- [ ] Git diff integration

### Phase 4: Approvals & Session Management
- [ ] Permission request routing to iOS (approve/deny buttons)
- [ ] Session list, resume, fork
- [ ] Session persistence across app launches

### Phase 5: Push Notifications & Polish
- [ ] APNs setup (p8 key, device token flow)
- [ ] Notification script on your server
- [ ] WireGuard config for phone
- [ ] App signing with developer cert
- [ ] Background connection handling

## Decisions

- File browser is read-only for now (view files, see diffs, all editing through Claude)
- Voice input from the start (iOS Speech framework, transcribe and send as text prompt)
- WireGuard on iPhone for remote access (free, open source, existing infra on your server)
- No terminal emulator - structured JSON chat UI is cleaner on mobile
- Single session at a time to start, multi-session later if needed

## Open Questions

- How to handle large file diffs on a phone screen?
- Best UX for long-running tasks (background the app, get push when done?)
