#!/bin/bash
# Wake the Windows PC and start Docker stacks (trade_bot).
# Run on the Pi: sudo /opt/pi-hole-nas-orchestrator/wake_stack.sh

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/pi-hole-nas-orchestrator}"
CONF="${CONF:-/etc/pi-hole-nas-orchestrator.conf}"

if [[ -f "$CONF" ]]; then
	# shellcheck source=/dev/null
	source "$CONF"
else
	echo "Missing $CONF — copy config.example and edit." >&2
	exit 1
fi

: "${PC_IP:?PC_IP not set}"
: "${PC_MAC:?PC_MAC not set}"
: "${PC_USER:?PC_USER not set}"
: "${SSH_KEY:?SSH_KEY not set}"

PING_TIMEOUT="${PING_TIMEOUT:-120}"
SSH_TIMEOUT="${SSH_TIMEOUT:-180}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
WOL_BROADCAST="${WOL_BROADCAST:-}"
STACKS="${STACKS:-trade_bot}"
TRADE_BOT_PATH="${TRADE_BOT_PATH:-${PC_TRADE_BOT_PATH:-}}"

log() { echo "[wake_stack $(date -Is)] $*"; }

send_wol() {
	if command -v wakeonlan >/dev/null 2>&1; then
		if [[ -n "$WOL_BROADCAST" ]]; then
			wakeonlan -i "$WOL_BROADCAST" "$PC_MAC"
		else
			wakeonlan "$PC_MAC"
		fi
	elif command -v etherwake >/dev/null 2>&1; then
		etherwake -i "${WOL_IFACE:-eth0}" "$PC_MAC"
	else
		# Python fallback (no extra package)
		python3 - "$PC_MAC" "$WOL_BROADCAST" <<'PY'
import socket, sys
mac = sys.argv[1].replace(":", "").replace("-", "")
broadcast = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "255.255.255.255"
payload = bytes.fromhex("FF" * 6 + mac * 16)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.sendto(payload, (broadcast, 9))
PY
	fi
}

wait_for_ping() {
	local deadline=$((SECONDS + PING_TIMEOUT))
	while (( SECONDS < deadline )); do
		if ping -c1 -W2 "$PC_IP" >/dev/null 2>&1; then
			log "PC responding to ping ($PC_IP)"
			return 0
		fi
		sleep 2
	done
	log "ERROR: PC did not respond to ping within ${PING_TIMEOUT}s"
	return 1
}

wait_for_ssh() {
	local deadline=$((SECONDS + SSH_TIMEOUT))
	while (( SECONDS < deadline )); do
		if nc -z -w3 "$PC_IP" 22 2>/dev/null; then
			log "SSH port open on $PC_IP"
			return 0
		fi
		sleep 2
	done
	log "ERROR: SSH not reachable within ${SSH_TIMEOUT}s"
	return 1
}

ssh_pc() {
	ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
		-o ConnectTimeout=15 -i "$SSH_KEY" "${PC_USER}@${PC_IP}" "$@"
}

start_trade_bot() {
	[[ -n "$TRADE_BOT_PATH" ]] || { log "TRADE_BOT_PATH empty; skip trade_bot"; return 0; }
	log "Starting trade_bot via SSH..."
	# Paths with spaces must be quoted inside PowerShell.
	ssh_pc "powershell -NoProfile -Command \"Set-Location -LiteralPath '${TRADE_BOT_PATH}'; docker compose up -d\""
}

wait_for_health() {
	local deadline=$((SECONDS + HEALTH_TIMEOUT))
	while (( SECONDS < deadline )); do
		if ssh_pc "powershell -NoProfile -Command \"try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 http://127.0.0.1:8000/health | Out-Null; exit 0 } catch { exit 1 }\""; then
			log "trade_bot API health OK"
			return 0
		fi
		sleep 10
	done
	log "WARNING: API health not confirmed (stack may still be starting)"
	return 0
}

main() {
	log "WOL → $PC_MAC ($PC_IP)"
	send_wol

	# PC might already be awake — still try ping/ssh/start.
	if ! ping -c1 -W2 "$PC_IP" >/dev/null 2>&1; then
		wait_for_ping
	fi
	wait_for_ssh

	for stack in $STACKS; do
		case "$stack" in
		trade_bot) start_trade_bot ;;
		*) log "Unknown stack: $stack (skip)" ;;
		esac
	done

	if [[ " $STACKS " == *" trade_bot "* ]]; then
		wait_for_health
	fi

	log "Done."
}

main "$@"
