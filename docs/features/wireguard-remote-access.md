# WireGuard Remote Access

## Goal
Allow OpenButt to connect to the remote server from anywhere — not just the local network. A one-shot setup script runs on the server, sets up a WireGuard tunnel, and outputs a QR code the user scans into the iOS WireGuard app. After that the app works from any network.

## Architecture

```
iPhone (WireGuard peer, 10.8.0.2)
    ↕  WireGuard tunnel (UDP, encrypted)
Router (port 51820 forwarded to server)
    ↕
Server / the server (WireGuard server, 10.8.0.1)
    ↕  SSH over WireGuard internal IP
Claude Code (running on server)
```

- Server is the always-on machine running Claude Code
- WireGuard gives the server a stable virtual IP (10.8.0.1)
- iPhone connects to WireGuard before SSHing — works on any network
- SSH host in OpenButt settings = WireGuard internal IP (10.8.0.1)

## Components

### 1. `server/setup.sh` — runs once on the server
- Detects OS and installs WireGuard tools if missing (apt/brew/pacman)
- Creates a second WireGuard interface `wg0` (won't touch existing VPN interfaces like wgpia0)
- Picks a free internal subnet (default 10.8.0.0/24, auto-adjusts if conflicting)
- Assigns server IP 10.8.0.1, iPhone peer IP 10.8.0.2
- Generates server + iPhone keypairs
- Detects public IP via `curl ifconfig.me`
- Opens firewall port 51820/udp (ufw, iptables, or firewalld)
- Attempts UPnP router port forward via `upnpc` (installs if needed, skips gracefully if UPnP unavailable)
- Enables `wg0` to start on boot (systemd or launchd)
- Outputs iPhone peer config as a QR code (installs `qrencode` if needed)
- Prints manual router instructions if UPnP failed

### 2. System WireGuard app on iPhone
- User scans QR from setup script
- No code in OpenButt needed — iOS system VPN handles the tunnel

### 3. OpenButt app changes (small)
- Add `remoteHost: String` to `AppSettings` (the WireGuard internal IP, e.g. 10.8.0.1)
- Add `localHost: String` to `AppSettings` (LAN IP for when on home network)
- `SSHConnectionManager` does smart host selection:
  - On same LAN (ping local host responds fast) → use `localHost`
  - Otherwise → use `remoteHost` (WireGuard IP)
- Or: just use WireGuard IP always (simpler, works on LAN too, slight latency overhead)
- Settings UI: add remote host field, test connection button

## Setup Script Design

### Sudo handling
```bash
echo "This script needs sudo to install packages and configure WireGuard."
sudo -v   # validate + cache password once
# all subsequent sudo calls use cached creds (valid ~15 min)
```

### OS detection
```bash
detect_os() {
  if command -v apt &>/dev/null; then echo "debian"
  elif command -v brew &>/dev/null; then echo "macos"
  elif command -v pacman &>/dev/null; then echo "arch"
  else echo "unknown"; fi
}
```

### Subnet conflict detection
```bash
# Check if 10.8.0.0/24 is already in use by any interface
ip route | grep "10.8.0" → pick 10.9.0.0/24 instead, etc.
```

### UPnP port forward attempt
```bash
install miniupnpc if missing
upnpc -a $(hostname -I | awk '{print $1}') 51820 51820 UDP
# if exit 0 → success, print confirmation
# if non-zero → print manual router instructions
```

### QR code output
```bash
# Generate wg config for iPhone peer, pipe to qrencode
qrencode -t ansiutf8 < /tmp/openbutt-peer.conf
```

## File Layout
```
OpenButt/
  server/
    setup.sh         ← main setup script (runs on server)
    README.md        ← instructions
  docs/
    features/
      wireguard-remote-access.md  ← this file
```

## Peer Config Generated for iPhone
```ini
[Interface]
PrivateKey = <generated>
Address = 10.8.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = <server public key>
Endpoint = <public IP>:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
```

`AllowedIPs = 10.8.0.0/24` means only WireGuard-destined traffic routes through the tunnel — regular internet traffic goes direct. This avoids the VPN slowing down everything else.

## What the Script Cannot Automate
- Router port forwarding if UPnP is disabled (shows exact steps based on detected router IP)
- Dynamic external IP (if user's ISP changes their public IP, the WireGuard endpoint breaks) — script recommends a free DDNS service like DuckDNS if needed

## Status
- [ ] server/setup.sh — not started
- [ ] AppSettings remote host field — not started
- [ ] SSHConnectionManager host switching — not started
