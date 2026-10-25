#!/bin/bash
# Install Tailscale on the Pi for remote homelab access.
# Usage on the Pi:
#   curl -fsSL https://raw.githubusercontent.com/Siddarthb07/pi-hole-nas/master/orchestrator/tailscale/install.sh | sudo bash

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
	echo "Run with sudo." >&2
	exit 1
fi

echo "=== Tailscale install (Pi) ==="

if ! command -v tailscale >/dev/null 2>&1; then
	curl -fsSL https://tailscale.com/install.sh | sh
else
	echo "Tailscale already installed: $(tailscale version 2>/dev/null || true)"
fi

echo ""
echo "Authenticate this Pi to your tailnet:"
echo "  sudo tailscale up"
echo ""
echo "Optional — expose Pi-hole admin only to your tailnet (no public internet):"
echo "  sudo tailscale serve --bg http://127.0.0.1:80"
echo ""
echo "Optional — let phone reach LAN devices (PC, Samba) via Pi subnet router:"
echo "  sudo tailscale up --advertise-routes=192.168.1.0/24 --accept-routes"
echo "  Then approve the route in Tailscale admin → Machines → pi → Subnet routes"
echo ""
echo "After tailscale up, note MagicDNS name: tailscale status"
echo "From phone (Tailscale app connected): SSH → wake stack:"
echo "  ssh <pi-user>@<pi-magic-dns> 'sudo systemctl start wake-stack.service'"
