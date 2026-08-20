#!/bin/bash
# Install 16x2 I2C LCD stats over SSH only.
# Usage on the Pi:
#   curl -fsSL https://raw.githubusercontent.com/Siddarthb07/pi-hole-nas/master/lcd-stats/install.sh | sudo bash
# Or from a cloned repo:
#   sudo bash lcd-stats/install.sh

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Siddarthb07/pi-hole-nas.git}"
BRANCH="${BRANCH:-master}"
INSTALL_DIR="${INSTALL_DIR:-/opt/pi-hole-nas-lcd}"
NAS_PATH="${NAS_PATH:-/srv/nas}"
HOLD="${LCD_HOLD:-5}"
FORCE_ADDRESS="${LCD_ADDRESS:-}"

if [[ "$(id -u)" -ne 0 ]]; then
	echo "Run with sudo." >&2
	exit 1
fi

echo "=== Pi-hole NAS LCD install (SSH) ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3-venv python3-dev i2c-tools git

# Enable I2C if raspi-config exists (Raspberry Pi OS)
if command -v raspi-config >/dev/null 2>&1; then
	raspi-config nonint do_i2c 0 || true
fi

# Load module now if possible
modprobe i2c-dev 2>/dev/null || true

if [[ ! -e /dev/i2c-1 ]]; then
	echo ""
	echo "I2C device /dev/i2c-1 not present yet."
	echo "Rebooting in 5s so I2C comes up. Re-run the same curl|bash after login."
	echo "To skip reboot: REBOOT=0 curl ... | sudo bash"
	if [[ "${REBOOT:-1}" == "1" ]]; then
		sleep 5
		systemctl reboot
	fi
	exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Fetching lcd-stats from $REPO_URL ($BRANCH)..."
git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP/repo"
SRC="$TMP/repo/lcd-stats"

mkdir -p "$INSTALL_DIR"
cp "$SRC/lcd_stats.py" "$SRC/requirements.txt" "$INSTALL_DIR/"
chmod 755 "$INSTALL_DIR/lcd_stats.py"

if [[ ! -d "$INSTALL_DIR/venv" ]]; then
	python3 -m venv "$INSTALL_DIR/venv"
fi
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

detect_address() {
	local bus="${1:-1}"
	# Prefer common LCD backpack addresses
	local hit
	hit=$(i2cdetect -y "$bus" 2>/dev/null | awk '
		NR>1 {
			for (i=2; i<=NF; i++) {
				if ($i ~ /^[0-9a-fA-F][0-9a-fA-F]$/) {
					printf "0x%s\n", $i
				}
			}
		}' | awk '
		BEGIN { pick="" }
		tolower($0)=="0x27" { print; exit }
		tolower($0)=="0x3f" { pick=$0 }
		pick=="" { pick=$0 }
		END { if (pick!="") print pick }
	')
	echo "$hit"
}

ADDR="$FORCE_ADDRESS"
if [[ -z "$ADDR" ]]; then
	ADDR=$(detect_address 1 || true)
fi
if [[ -z "$ADDR" ]]; then
	echo "No I2C device found on bus 1. Is the LCD wired (VCC/GND/SDA/SCL)?"
	echo "Continuing with default 0x27 — fix wiring and set LCD_ADDRESS if needed."
	ADDR="0x27"
else
	echo "Detected I2C address: $ADDR"
fi

cat > /etc/systemd/system/pihole-lcd.service <<EOF
[Unit]
Description=16x2 I2C LCD stats for Pi-hole + NAS
After=network-online.target smbd.service pihole-FTL.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=LCD_ADDRESS=${ADDR}
Environment=LCD_HOLD=${HOLD}
Environment=NAS_PATH=${NAS_PATH}
Environment=LCD_UPSIDE_DOWN=${LCD_UPSIDE_DOWN:-1}
ExecStart=${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/lcd_stats.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pihole-lcd.service

echo ""
echo "Service status:"
systemctl --no-pager --full status pihole-lcd.service || true
echo ""
echo "Done. LCD should rotate: Pi-hole → System → NAS → Network."
echo "Logs: journalctl -u pihole-lcd -f"
echo "Dry run: DRY_RUN=1 ${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/lcd_stats.py"
echo "Stop:    systemctl stop pihole-lcd"
