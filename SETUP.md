# Pi-hole + NAS setup

Ad blocking is **per-PC only**. Do not change router DNS. Phones, TVs, and guests stay unfiltered.

```
Flash OS  ->  apply-overlay.ps1  ->  first boot  ->  set-pc-dns.ps1  ->  map \\rpi\share
```

`apply-overlay.ps1` detects DietPi vs Raspberry Pi OS from the SD card.

## Commands (after the OS is on the SD card)

In PowerShell, SD card still in the PC:

```powershell
cd C:\Users\siddu\Projects\pi-hole-nas
Set-ExecutionPolicy -Scope Process Bypass
.\apply-overlay.ps1
```

Raspberry Pi OS will prompt for username, password, and hostname. DietPi will not; change `AUTO_SETUP_GLOBAL_PASSWORD` in `dietpi.txt` instead.

After the Pi has booted (15–40 min), find its IP (`ping rpi` or the router client list). Then **Administrator** PowerShell on each PC you want filtered:

```powershell
cd C:\Users\siddu\Projects\pi-hole-nas
Set-ExecutionPolicy -Scope Process Bypass
.\set-pc-dns.ps1 -PiIP <pi-ip>
```

Undo:

```powershell
.\set-pc-dns.ps1 -Revert
```

Mac (same Pi IP, only that Mac is filtered):

```bash
cd /path/to/pi-hole-nas
chmod +x set-pc-dns.sh
sudo ./set-pc-dns.sh 192.168.1.30
```

Undo on Mac:

```bash
sudo ./set-pc-dns.sh --revert
```

One-liner without the script:

```bash
sudo networksetup -setdnsservers Wi-Fi 192.168.1.30
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

Non-interactive Raspberry Pi OS overlay (skips prompts):

```powershell
.\apply-overlay.ps1 -User siddu -Password 'your-password' -Hostname rpi
```

---

## 1. Gear

- Raspberry Pi 3, 4, or 5
- 16 GB+ microSD (32 GB is more comfortable)
- Ethernet cable (use this, not Wi-Fi, for Pi-hole)
- Official-quality 5V power supply
- USB SSD or HDD recommended for NAS data. SD-only still works for small files. The drive must already be formatted (exFAT, NTFS, or ext4). This overlay will not format it.

## 2. Install Raspberry Pi Imager on Windows

Download: https://www.raspberrypi.com/software/

## 3. Flash the OS (pick one)

### Option A: Raspberry Pi OS Lite (64-bit)

1. Imager → Raspberry Pi OS (other) → **Raspberry Pi OS Lite (64-bit)**.
2. Use Imager OS customisation: hostname `rpi`, your username, password, enable SSH, Wi-Fi only if you have no Ethernet. Use Imager 2.0.6+ for current (Trixie) images.
3. Write, wait until Windows remounts the boot drive (`cmdline.txt` or `user-data` on it).
4. Run `.\apply-overlay.ps1` (commands at the top). Use the **same username** as Imager.

### Option B: DietPi

1. Imager → Other specific-purpose OS → **DietPi** for your Pi model.
2. **Do not** use Imager OS customisation. DietPi uses `dietpi.txt`.
3. Write, wait until Windows remounts the boot drive (`dietpi.txt` on it).
4. Run `.\apply-overlay.ps1`.

## 4. Optional before you eject

**Raspberry Pi OS:** prompts already set user/password/hostname. Leave DHCP, then reserve the Pi’s MAC in the router so the IP does not drift.

**DietPi:** open `dietpi.txt` on the boot drive.

1. Set `AUTO_SETUP_GLOBAL_PASSWORD=` to something only you know (`root` / `dietpi` login and Samba).
2. Keep a stable IP: leave `AUTO_SETUP_DHCP_TO_STATIC=1`, or set `AUTO_SETUP_NET_USESTATIC=1` plus STATIC IP/mask/gateway for your LAN (`ipconfig` → Default Gateway).
3. Wi-Fi only if you have no Ethernet: copy `overlay\dietpi-wifi.txt.example` to the boot drive as `dietpi-wifi.txt`, fill SSID/key, set `AUTO_SETUP_NET_WIFI_ENABLED=1` and `AUTO_SETUP_NET_WIFI_COUNTRY_CODE=IN`. Ethernet is still better for DNS.

Eject the SD card safely.

## 5. First boot

1. SD card in the Pi, Ethernet in, USB disk plugged in if you have one, then power on.
2. First boot needs internet and can take **15–40 minutes**. Do not pull power.
3. Find the Pi IP in the router DHCP list, or:

   ```powershell
   ping rpi
   ```

4. SSH:

   ```powershell
   ssh <user>@<pi-ip>
   ```

   Raspberry Pi OS log: `/var/log/pi-hole-nas-firstboot.log`  
   DietPi logs: `/var/lib/dietpi/logs/dietpi-firstrun-setup.log` and `/var/lib/dietpi/logs/nas-setup.log`

## 6. Point only your PCs at Pi-hole

Do **not** change router DNS. Run `set-pc-dns.ps1` as in the commands at the top. Do not add a second public DNS (Windows may skip Pi-hole).

Leave phones and everything else unchanged.

Pi-hole admin: `http://<pi-ip>/admin`  
Web password: the password you set in the overlay prompt (Raspberry Pi OS) or `AUTO_SETUP_GLOBAL_PASSWORD` (DietPi).

### Turn off Secure DNS on filtered PCs

Encrypted DNS bypasses Pi-hole, so ads still load.

- **Windows 11:** Settings → Network & internet → Ethernet or Wi-Fi → DNS server assignment → IPv4 → **Off** for encrypted DNS (or “Insecure only”).
- **Edge:** Settings → Privacy, search, and services → Security → Use secure DNS → Off.
- **Chrome:** Settings → Privacy and security → Security → Use secure DNS → Off.

## 7. Map the NAS on Windows

File Explorer → This PC → Map network drive:

- Folder: `\\rpi\share` or `\\<pi-ip>\share`
- Username / password: the overlay user (Raspberry Pi OS) or `dietpi` / global password (DietPi)

The share is available to any PC on the LAN. It is separate from ad blocking.

If a USB disk was plugged in and already formatted, files live on that disk. Otherwise they live on the SD card (small/home files only).

## 8. Optional: 16x2 I2C LCD stats

Wire VCC/GND/SDA/SCL, then **SSH only**:

```bash
ssh sid@192.168.1.30
curl -fsSL https://raw.githubusercontent.com/Siddarthb07/pi-hole-nas/master/lcd-stats/install.sh | sudo bash
```

Rotates four screens (2 metrics each):

| Category | Line 1 | Line 2 |
|----------|--------|--------|
| Pi-hole | Block % today | Queries today |
| System | CPU temperature | RAM used % |
| NAS | Free space | Samba OK/DOWN |
| Network | IPv4 | Gateway OK/DOWN |

Details: [`lcd-stats/README.md`](lcd-stats/README.md).

## 9. Optional later: whole-house blocking

If you ever want every device filtered, set the router’s LAN DNS to the Pi’s IP. That is not part of this setup.

## If something fails

- Raspberry Pi OS log: `/var/log/pi-hole-nas-firstboot.log`
- DietPi logs: `/var/lib/dietpi/logs/dietpi-firstrun-setup.log`, `/var/lib/dietpi/logs/nas-setup.log`
- `apply-overlay.ps1` says no boot partition: wait for Windows to remount the card; pass `-BootDrive E` if needed.
- No `\\rpi\share`: try `\\<pi-ip>\share`, confirm Samba (`systemctl status smbd`).
- USB not used: the disk had no filesystem. Format it on a PC first, then reboot the Pi with the disk attached.
- Ads still show: Secure DNS is still on, or the PC is not using the Pi as DNS (`ipconfig /all` → DNS Servers).
