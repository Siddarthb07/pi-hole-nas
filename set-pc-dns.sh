#!/bin/sh
# Point this Mac at Pi-hole DNS, or revert to DHCP/router DNS.
# Does not change the router. Only this Mac is filtered.
# Usage:
#   sudo ./set-pc-dns.sh 192.168.1.30
#   sudo ./set-pc-dns.sh --revert
#   sudo ./set-pc-dns.sh --service "Wi-Fi" 192.168.1.30

set -eu

SERVICE=""
REVERT=0
PI_IP=""

while [ $# -gt 0 ]; do
	case "$1" in
		--revert|-r)
			REVERT=1
			shift
			;;
		--service|-s)
			SERVICE=$2
			shift 2
			;;
		-h|--help)
			echo "Usage: sudo $0 [--service Wi-Fi] <pi-ip>"
			echo "       sudo $0 [--service Wi-Fi] --revert"
			exit 0
			;;
		*)
			PI_IP=$1
			shift
			;;
	esac
done

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo." >&2
	exit 1
fi

if [ -z "$SERVICE" ]; then
	SERVICE=$(networksetup -listallnetworkservices | awk '
		NR==1 { next }
		$0 ~ /^\*/ { next }
		tolower($0) ~ /wi-?fi/ { print; exit }
	')
	if [ -z "$SERVICE" ]; then
		SERVICE=$(networksetup -listallnetworkservices | awk '
			NR==1 { next }
			$0 ~ /^\*/ { next }
			tolower($0) ~ /ethernet|usb 10\/100|thunderbolt ethernet|usb lan/ { print; exit }
		')
	fi
	if [ -z "$SERVICE" ]; then
		echo "No Wi-Fi/Ethernet service found. List with: networksetup -listallnetworkservices" >&2
		exit 1
	fi
fi

if [ "$REVERT" -eq 1 ]; then
	networksetup -setdnsservers "$SERVICE" Empty
	echo "Reverted DNS on '$SERVICE' to automatic/router."
else
	case "$PI_IP" in
		*[!0-9.]*)
			echo "Pass the Pi IPv4, e.g. sudo $0 192.168.1.30" >&2
			exit 1
			;;
		"")
			echo "Pass the Pi IPv4, e.g. sudo $0 192.168.1.30" >&2
			exit 1
			;;
	esac
	networksetup -setdnsservers "$SERVICE" "$PI_IP"
	echo "Set DNS on '$SERVICE' to $PI_IP"
	echo "Pi-hole admin: http://$PI_IP/admin"
	echo "Turn off Safari/Chrome/Firefox Secure DNS (DoH) or ads will still load."
fi

dscacheutil -flushcache
killall -HUP mDNSResponder 2>/dev/null || true
echo "DNS cache flushed."
echo "Current:"
networksetup -getdnsservers "$SERVICE"
