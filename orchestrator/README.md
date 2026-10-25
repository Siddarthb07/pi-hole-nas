# Wake-before-market + remote homelab

Pi 3 wakes your Windows PC and starts **trade_bot** before market open. **Tailscale** on the Pi lets you trigger the same flow from your phone when you are away.

```
Phone (Tailscale) ──SSH──► Pi 3 ──WOL + SSH──► Windows PC ──► docker compose up -d
                └── optional subnet route ──► Pi-hole, Samba, trade_bot dashboard
```

## What you get

| Feature | How |
|---------|-----|
| PC off overnight | Pi sends WOL at **08:45 IST** (NSE) and optional **19:00 IST** (US — tune for DST) |
| trade_bot auto-start | Pi SSHs to Windows → `docker compose up -d` in `trade_bot` |
| Away from home | Tailscale to Pi → `sudo systemctl start wake-stack.service` |
| Pi-hole / NAS remote | Tailscale on Pi + optional subnet routing |

## One-time setup

### 1. Pi — install orchestrator

SSH to the Pi:

```bash
curl -fsSL https://raw.githubusercontent.com/Siddarthb07/pi-hole-nas/master/orchestrator/install.sh | sudo bash
sudo nano /etc/pi-hole-nas-orchestrator.conf   # PC_IP, PC_MAC, PC_USER
```

Install prints an SSH **public key** — keep that line for step 2.

### 2. Windows — WOL + OpenSSH + Pi key

Admin PowerShell on the PC:

```powershell
cd C:\Users\siddu\Projects\pi-hole-nas\orchestrator\windows
.\enable-wol.ps1
.\enable-openssh.ps1
.\install-pi-ssh-key.ps1 -PublicKey 'ssh-ed25519 AAAA... pi-hole-nas-orchestrator'
```

Paste the MAC from `enable-wol.ps1` into the Pi config. Enable **WOL in BIOS** if shutdown-wake fails.

### 3. Pi — test wake manually

```bash
sudo systemctl start wake-stack.service
journalctl -u wake-stack -e
```

Expect: WOL → ping → SSH → docker up → health check via SSH to `localhost:8000`.

### 4. Pi — enable market timers

```bash
sudo systemctl enable --now wake-nse.timer    # Mon–Fri 08:45 IST
# optional US session:
sudo systemctl enable --now wake-us.timer     # edit time for EST/EDT
systemctl list-timers wake-*
```

### 5. Pi — Tailscale

```bash
curl -fsSL https://raw.githubusercontent.com/Siddarthb07/pi-hole-nas/master/orchestrator/tailscale/install.sh | sudo bash
sudo tailscale up
```

Details: [`tailscale/README.md`](tailscale/README.md).

## Daily use

**Automatic:** PC wakes and trade_bot starts on timer days — nothing to do.

**Manual from home (Pi SSH):**

```bash
sudo systemctl start wake-stack.service
```

**Manual from phone (Tailscale connected):**

```bash
ssh sid@rpi
sudo systemctl start wake-stack.service
```

**Open trade_bot dashboard remotely:**

- **Easy:** install Tailscale on the PC too → `http://<pc-tailscale-ip>:3000`
- **Via Pi subnet route:** approve `192.168.1.0/24` on the Pi in Tailscale admin → use PC’s LAN IP from phone

## Files

| Path | Purpose |
|------|---------|
| `config.example` | Template → `/etc/pi-hole-nas-orchestrator.conf` |
| `wake_stack.sh` | WOL + SSH + docker compose |
| `wake-nse.timer` | NSE pre-open schedule |
| `wake-us.timer` | US open schedule (adjust for DST) |
| `windows/*.ps1` | One-time PC setup |
| `tailscale/` | Remote access install |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| PC never wakes | BIOS WOL; cable to motherboard port; disable ErP/Eco mode |
| Ping OK, SSH fails | Run `enable-openssh.ps1`; check Windows firewall |
| SSH OK, docker fails | Pi user must run docker Desktop logged-in session, or use Docker Desktop “Start when Windows starts” + WOL to S0 |
| Health timeout | Normal on slow boots; check `docker compose ps` on PC |
| Timer wrong time | `timedatectl set-timezone Asia/Kolkata` on Pi |

**Docker note:** After cold boot, Docker Desktop may need ~1–2 min. The script waits up to 5 min for `/health`. If you use Docker Engine without Desktop, adjust the SSH command in `wake_stack.sh`.

## ESP8266 (optional later)

MQTT topic `homelab/cmd/wake` → Pi subscriber → `systemctl start wake-stack` — same as pressing “start stack” without SSH. Not required for the core flow.
