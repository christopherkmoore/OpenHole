# OpenButt Server Setup

Sets up a WireGuard VPN on your server so the OpenButt iOS app can connect remotely from anywhere.

## Prerequisites

- A Linux server (Debian/Ubuntu, Arch, Fedora) or macOS
- sudo access
- Your server's router admin page (for port forwarding)
- (Optional) A free [DuckDNS](https://www.duckdns.org) account for dynamic DNS

## Quick Start

```bash
bash setup.sh
```

The script will walk you through everything interactively. When it finishes, you'll get a peer config and a QR code.

## What It Does

1. Installs WireGuard if not already present
2. Creates a `wg0` interface with a `10.8.0.0/24` subnet
3. Detects your real public IP via the physical network interface (bypasses active VPNs)
4. Adds `FwMark` routing rules so wg0 traffic doesn't conflict with other WireGuard tunnels on the same machine
5. Opens UDP 51820 on the local firewall
6. Attempts UPnP port forwarding on your router
7. Optionally sets up DuckDNS so the config survives IP changes
8. Generates a peer config for the iOS app
9. Enables WireGuard to auto-start on boot

## Adding More Peers

Run the script again. It detects the existing wg0 and enters **add-peer mode** — allocates the next available IP and hot-reloads the config without restarting the tunnel.

```bash
# Auto-named (peer-3, peer-4, etc.)
bash setup.sh

# Named peer
bash setup.sh my-ipad
```

Peer configs are saved to:
- `~/.openbutt/peer.conf` — always the latest (what the iOS app fetches)
- `~/.openbutt/peers/<name>.conf` — archive of all generated peers

## After Running

### 1. Port forward your router

If UPnP didn't work (the script will tell you), manually forward on your router:

| Field | Value |
|-------|-------|
| Protocol | **UDP** |
| External Port | **51820** |
| Internal IP | Your server's LAN IP (e.g. `192.168.1.100`) |
| Internal Port | **51820** |

### 2. Configure OpenButt app settings

Open the app → Settings and fill in:

| Field | Value | Purpose |
|-------|-------|---------|
| **Local Host** | Your server's LAN IP (e.g. `192.168.1.100`) | Used when you're on the same WiFi as the server |
| **Remote Host (WireGuard)** | `10.8.0.1` | Used when you're away — SSH goes through the WireGuard tunnel |
| **Port** | `22` | |
| **Username** | Your server username | |
| **SSH Key** | Import your key if not already set | |

### 3. Import the WireGuard config (must be on local WiFi)

**You need to be on the same network as your server for this step.** The app will SSH to the Local Host to fetch the WireGuard config.

Open the app → Settings → **Import config from server**

This is a one-time fetch. The app downloads `~/.openbutt/peer.conf` from your server over SSH and saves the WireGuard config locally on your phone. After this, you don't need local access again — the config lives on the device.

Alternatively, scan the QR code that `setup.sh` printed with the standalone [WireGuard iOS app](https://apps.apple.com/app/wireguard/id1441195209).

### 4. How it works after setup

- **On home WiFi**: The app SSHs directly to the Local Host. WireGuard is not used.
- **Away from home**: The app detects the local connection fails, automatically activates WireGuard using the saved config, then SSHs to the Remote Host (`10.8.0.1`) through the tunnel.

## DuckDNS (Dynamic DNS)

If your ISP assigns dynamic IPs, the script can set up [DuckDNS](https://www.duckdns.org) to keep a hostname pointed at your current IP:

1. Create a free account at [duckdns.org](https://www.duckdns.org)
2. Add a subdomain (e.g. `myserver`)
3. Copy your token
4. When the script asks "Set up DuckDNS?", enter your token and subdomain

This installs a cron job that updates the IP every 5 minutes via the physical interface (not through any VPN), and uses the hostname in peer configs instead of a raw IP.

## FwMark (Multi-Tunnel Compatibility)

If your server runs other WireGuard tunnels (e.g. a commercial VPN, a site-to-site tunnel), their routing rules can capture wg0's response packets. The script sets `FwMark = 0x4f42` on wg0 and adds a policy routing rule at priority 47 that sends marked packets through the main routing table, bypassing other tunnels' catch-all routes.

You don't need to configure this — it's automatic.

## Double NAT (ISP Modem/ONT → Your Router)

Many ISPs provide a modem, ONT (fiber terminal), or gateway device that does NAT before your own router. This creates **double NAT** — your server sits behind two layers of port forwarding. This is very common and the most likely reason WireGuard doesn't work from outside your network even after setting up port forwarding on your router.

### How to tell if you have double NAT

1. Check your router's **WAN/Internet IP**. If it starts with `192.168.x.x`, `10.x.x.x`, or `172.16-31.x.x`, you're behind another NAT device.
2. Compare to your **public IP** (visit [whatismyip.com](https://whatismyip.com)). If they're different, there's another device doing NAT upstream.

### How to fix it

You need to forward UDP port 51820 on **both** devices:

```
Internet → ISP Device:51820 → Your Router:51820 → Server:51820
```

1. **Find the ISP device's admin page.** It's usually at the gateway address of your router's WAN interface. Common addresses: `192.168.1.1`, `192.168.1.254`, `192.168.0.1`
2. **Find your router's IP on the ISP device's network.** Check the ISP device's "connected devices" or "LAN" page. Your router will show up by its MAC address or hostname.
3. **Add a port forwarding rule on the ISP device:**

| Field | Value |
|-------|-------|
| Protocol | **UDP** |
| External Port | **51820** |
| Internal IP | Your router's IP on the ISP network |
| Internal Port | **51820** |

4. Keep your existing port forwarding rule on your own router (forwarding 51820 to your server's LAN IP).

### Common ISP devices

| Device | Admin page | Notes |
|--------|-----------|-------|
| Huawei HG8145V5 (Telmex fiber) | `192.168.1.254` | Diversion rules > Port Forwarding. Select the WAN connection, set internal host to your router's IP. |
| Arris/Motorola gateways | `192.168.0.1` | Advanced > Port Forwarding |
| AT&T BGW-210/320 | `192.168.1.254` | Firewall > NAT/Gaming, or use IP Passthrough to disable NAT entirely |

### Alternative: Bridge mode / IP Passthrough

If your ISP device supports it, you can put it in **bridge mode** (or enable "IP Passthrough") so it stops doing NAT entirely. This gives your router the public IP directly, eliminating the double NAT. Check your ISP device's admin page or search for "[your device model] bridge mode."

### NAT Filtering

Some routers have a "NAT Filtering" setting (often under WAN Setup). If set to "Secured", it may block unsolicited inbound UDP. Change it to **Open** for WireGuard to work.

## Troubleshooting

**Can't connect from outside your network?**
1. **Check for double NAT** — see section above. This is the #1 issue.
2. Verify port forwarding is set up on your router (and ISP device if double NAT)
3. Check the server firewall: `sudo ufw status` or `sudo iptables -L -n | grep 51820`
4. Run `sudo tcpdump -i <interface> udp port 51820 -n` on the server (replace `<interface>` with your network interface, e.g. `eth0`, `eno1`), then toggle WireGuard on your phone. If you see **no packets**, the issue is upstream (port forwarding or ISP device). If you see packets but can't connect, the issue is WireGuard config.
5. Test reachability: `nc -u -z -w 3 <your-ip-or-hostname> 51820`

**WireGuard connects briefly then disconnects (status cycling)?**
- This usually means packets aren't reaching the server. Check port forwarding on all devices in the chain.
- Check NAT Filtering settings on your router — set to Open.

**App says "Connected" over WireGuard but chat/files are empty?**
- Make sure "Remote Host (WireGuard)" is set to `10.8.0.1` in the app settings. This is the server's address inside the WireGuard tunnel — without it, the app doesn't know where to SSH when using WireGuard.

**Config has wrong IP / connection times out?**
- The script detects your IP via the physical interface. If it got the wrong one, edit `~/.openbutt/peer.conf` and fix the `Endpoint` line

**Multiple VPN tunnels interfering?**
- Check `ip rule list` — you should see a `fwmark 0x4f42` rule at priority 47
- Check `sudo wg show wg0` — should show `fwmark: 0x4f42`
- If missing, restart: `sudo wg-quick down wg0 && sudo wg-quick up wg0`

**Want to remove a peer?**
- Edit `/etc/wireguard/wg0.conf`, remove the `[Peer]` block, then `sudo wg syncconf wg0 <(wg-quick strip wg0)`
