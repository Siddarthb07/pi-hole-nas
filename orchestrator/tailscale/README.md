# Tailscale on the Pi homelab

Tailscale turns your Pi 3 into something you can reach from your phone anywhere — without opening router ports.

## Install

On the Pi (after orchestrator is optional but recommended):

```bash
curl -fsSL https://raw.githubusercontent.com/Siddarthb07/pi-hole-nas/master/orchestrator/tailscale/install.sh | sudo bash
sudo tailscale up
```

Sign in with Google/GitHub/etc. when the URL appears.

Check status:

```bash
tailscale status
tailscale ip -4
```

Your Pi gets a stable name like `rpi.tail1234.ts.net` (MagicDNS).

## What to use it for

### 1. Wake trade_bot from away

With orchestrator installed:

```bash
# From phone Termius / Blink / any SSH client (Tailscale VPN on)
ssh sid@rpi
sudo systemctl start wake-stack.service
journalctl -u wake-stack -n 30 --no-pager
```

Same as the 08:45 timer, but on demand.

### 2. Pi-hole admin remotely

**Option A — Tailscale Serve (HTTPS to your tailnet only):**

```bash
sudo tailscale serve --bg http://127.0.0.1:80
```

Open `https://rpi.<tailnet>.ts.net/admin` from a device on Tailscale.

**Option B — direct:** `http://100.x.y.z/admin` using the Pi’s Tailscale IP from `tailscale ip -4`.

### 3. Samba / LAN devices without Tailscale on every device

Advertise your home subnet through the Pi (Pi 3 can handle light routing):

```bash
# Replace with your LAN, e.g. 192.168.1.0/24
sudo tailscale up --advertise-routes=192.168.1.0/24
```

Then in [Tailscale admin](https://login.tailscale.com/admin/machines):

1. Find the Pi → **Edit route settings**
2. Approve **192.168.1.0/24**

On your phone (Tailscale app on):

- Pi-hole: `http://192.168.1.30/admin` (your Pi LAN IP)
- Samba: Files app → `smb://192.168.1.30/share`
- trade_bot: `http://192.168.1.50:3000` (PC LAN IP — only after wake)

Subnet routing only works while the Pi is powered and on your home network.

### 4. Tailscale on the Windows PC (simplest dashboard access)

Install Tailscale on Windows from https://tailscale.com/download

Then from phone: `http://100.x.y.z:3000` using the PC’s Tailscale IP — no subnet routes needed.

Good combo:

- **Pi:** always-on, WOL orchestrator, Pi-hole, subnet router
- **PC:** Tailscale for dashboard when awake

## Security notes

- Do not expose Pi-hole to the public internet; Tailscale is tailnet-only.
- Subnet routes let any tailnet device reach your LAN — use Tailscale ACLs if you share the tailnet.
- Wake-stack SSH key on Pi is root-only (`/root/.ssh/pc_wake`); keep Pi OS updated.

## Quick reference

| Goal | Command / URL |
|------|----------------|
| Pi SSH | `ssh user@rpi` or `@100.x.y.z` |
| Wake PC + trade_bot | `sudo systemctl start wake-stack.service` |
| Pi-hole admin | `https://rpi.<tailnet>.ts.net/admin` (with serve) |
| Timer status | `systemctl list-timers wake-*` |
| Leave tailnet | `sudo tailscale down` |
