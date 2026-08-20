#!/bin/bash
# Paste on the Pi over SSH to see why LCD / Pi-hole readings fail.
set -u
echo "=== services ==="
systemctl is-active pihole-lcd pihole-FTL smbd 2>&1 || true
echo "=== i2c ==="
ls -l /dev/i2c-1 2>&1 || true
sudo i2cdetect -y 1 2>&1 || true
echo "=== pihole api (first 500 chars) ==="
sudo pihole api stats/summary 2>&1 | head -c 500; echo
echo "=== cli_pw readable? ==="
sudo test -r /etc/pihole/cli_pw && echo yes || echo no
echo "=== lcd service logs ==="
journalctl -u pihole-lcd -n 40 --no-pager 2>&1 || true
echo "=== dry run one cycle ==="
if [[ -x /opt/pi-hole-nas-lcd/venv/bin/python ]]; then
  timeout 12 env DRY_RUN=1 LCD_UPSIDE_DOWN=0 /opt/pi-hole-nas-lcd/venv/bin/python /opt/pi-hole-nas-lcd/lcd_stats.py 2>&1 || true
else
  echo "LCD not installed at /opt/pi-hole-nas-lcd"
fi
echo "=== done ==="
