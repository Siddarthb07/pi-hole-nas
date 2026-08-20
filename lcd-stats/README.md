# 16x2 I2C LCD stats

Rotates four screens (2 metrics each, ~5s):

| Screen | Line 1 | Line 2 |
|--------|--------|--------|
| Pi-hole | Blocked % today | Queries today |
| System | Temperature | Memory used % |
| NAS | Free space | Samba OK/DOWN |
| Network | IPv4 address | Gateway OK/DOWN |

Example:

```text
Blocked 42%
Queries 12.4k
```

```text
Temp 48C
Memory 35%
```

```text
Free 128G
Samba OK
```

```text
192.168.1.30
Gateway OK
```

Pi-hole numbers come from `pihole api stats/summary` (v6). Old FTL port 4711 is not used.

`LCD_UPSIDE_DOWN=0` (default): normal orientation. Set `LCD_UPSIDE_DOWN=1` if the panel is mounted upside down (swaps rows and reverses each line).

## Wire (once)

| LCD (PCF8574) | Pi |
|---------------|-----|
| VCC | 5V (pin 2) |
| GND | GND (pin 6) |
| SDA | GPIO2 (pin 3) |
| SCL | GPIO3 (pin 5) |

Power off before wiring. Then SSH only — no monitor needed.

## Install over SSH

```bash
ssh sid@192.168.1.30
```

**One command** (after the LCD is plugged in):

```bash
curl -fsSL https://raw.githubusercontent.com/Siddarthb07/pi-hole-nas/master/lcd-stats/install.sh | sudo bash
```

What it does: enables I2C, installs Python deps, clones this repo’s `lcd-stats`, detects the backpack address (`0x27` / `0x3f`), installs and starts `pihole-lcd.service`.

If I2C was just enabled and `/dev/i2c-1` is missing, it reboots. After reboot, run the same `curl ... | sudo bash` again.

Force address / hold time:

```bash
curl -fsSL https://raw.githubusercontent.com/Siddarthb07/pi-hole-nas/master/lcd-stats/install.sh | sudo LCD_ADDRESS=0x3f LCD_HOLD=5 bash
```

## Useful SSH commands

```bash
sudo i2cdetect -y 1
systemctl status pihole-lcd
journalctl -u pihole-lcd -f
sudo systemctl restart pihole-lcd
sudo pihole api stats/summary
DRY_RUN=1 /opt/pi-hole-nas-lcd/venv/bin/python /opt/pi-hole-nas-lcd/lcd_stats.py
sudo systemctl stop pihole-lcd
```

## Update an existing install over SSH

```bash
curl -fsSL https://raw.githubusercontent.com/Siddarthb07/pi-hole-nas/master/lcd-stats/install.sh | sudo bash
```
