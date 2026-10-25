#!/bin/bash
# Install wake-before-market orchestrator on the Pi.
# Usage on the Pi:
#   curl -fsSL https://raw.githubusercontent.com/Siddarthb07/pi-hole-nas/master/orchestrator/install.sh | sudo bash
# Or from a cloned repo:
#   sudo bash orchestrator/install.sh

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Siddarthb07/pi-hole-nas.git}"
BRANCH="${BRANCH:-master}"
INSTALL_DIR="${INSTALL_DIR:-/opt/pi-hole-nas-orchestrator}"
CONF="/etc/pi-hole-nas-orchestrator.conf"

if [[ "$(id -u)" -ne 0 ]]; then
	echo "Run with sudo." >&2
	exit 1
fi

echo "=== Pi-hole NAS orchestrator install ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y wakeonlan netcat-openbsd openssh-client git

# Timezone for market timers
if timedatectl list-timezones | grep -qx 'Asia/Kolkata'; then
	timedatectl set-timezone Asia/Kolkata || true
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ -f "$(dirname "$0")/wake_stack.sh" ]]; then
	SRC="$(dirname "$0")"
else
	echo "Fetching orchestrator from $REPO_URL ($BRANCH)..."
	git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP/repo"
	SRC="$TMP/repo/orchestrator"
fi

mkdir -p "$INSTALL_DIR"
install -m755 "$SRC/wake_stack.sh" "$INSTALL_DIR/wake_stack.sh"

if [[ ! -f "$CONF" ]]; then
	install -m600 "$SRC/config.example" "$CONF"
	echo ""
	echo "Created $CONF — edit PC_IP, PC_MAC, PC_USER before enabling timers."
fi

# SSH key for passwordless wake (copy pubkey to Windows OpenSSH)
SSH_DIR=/root/.ssh
KEY="$SSH_DIR/pc_wake"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
if [[ ! -f "$KEY" ]]; then
	ssh-keygen -t ed25519 -N "" -f "$KEY" -C "pi-hole-nas-orchestrator"
	echo ""
	echo "=== Add this public key to Windows (OpenSSH authorized_keys) ==="
	cat "${KEY}.pub"
	echo "================================================================"
	echo "On Windows (Admin PowerShell): orchestrator/windows/install-pi-ssh-key.ps1"
fi

install -m644 "$SRC/wake-stack.service" /etc/systemd/system/wake-stack.service
install -m644 "$SRC/wake-nse.timer" /etc/systemd/system/wake-nse.timer
install -m644 "$SRC/wake-us.timer" /etc/systemd/system/wake-us.timer

systemctl daemon-reload
systemctl enable wake-stack.service

echo ""
echo "Manual test (after editing $CONF and Windows setup):"
echo "  sudo systemctl start wake-stack.service"
echo "  journalctl -u wake-stack -e"
echo ""
echo "Enable NSE timer (Mon–Fri 08:45 IST):"
echo "  sudo systemctl enable --now wake-nse.timer"
echo ""
echo "Optional US timer (Mon–Fri 19:00 IST — adjust for DST):"
echo "  sudo systemctl enable --now wake-us.timer"
echo ""
echo "Timer status: systemctl list-timers wake-*"
