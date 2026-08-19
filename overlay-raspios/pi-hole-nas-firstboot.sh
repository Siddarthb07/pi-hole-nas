#!/bin/bash
# Raspberry Pi OS first boot: Pi-hole + Samba NAS share at /srv/nas
# Never formats USB disks. Reads /boot/firmware/pi-hole-nas.env (or /boot).
LOG=/var/log/pi-hole-nas-firstboot.log
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
set -uo pipefail
echo "===== pi-hole-nas-firstboot $(date -Is) ====="

BOOT=/boot/firmware
if [[ ! -f "$BOOT/pi-hole-nas-firstboot.sh" && -f /boot/pi-hole-nas-firstboot.sh ]]; then
	BOOT=/boot
fi

ENV_FILE="$BOOT/pi-hole-nas.env"
if [[ -f "$ENV_FILE" ]]; then
	# shellcheck disable=SC1090
	source "$ENV_FILE"
fi
NAS_USER=${NAS_USER:-pi}
NAS_PASSWORD=${NAS_PASSWORD:-}
HOSTNAME_SET=${HOSTNAME:-rpi}
NAS_MOUNT=/srv/nas
FALLBACK=/srv/nas-local
SMB_CONF=/etc/samba/smb.conf

hostnamectl set-hostname "$HOSTNAME_SET" || true
if grep -q '^127.0.1.1' /etc/hosts; then
	sed -i "s/^127.0.1.1.*/127.0.1.1\t${HOSTNAME_SET}/" /etc/hosts
else
	echo -e "127.0.1.1\t${HOSTNAME_SET}" >> /etc/hosts
fi

if id "$NAS_USER" >/dev/null 2>&1; then
	echo "user $NAS_USER exists"
else
	adduser --disabled-password --gecos "" "$NAS_USER"
	usermod -aG sudo,adm,dialout,cdrom,audio,video,plugdev,games,users,netdev,gpio,i2c,spi "$NAS_USER" 2>/dev/null || \
		usermod -aG sudo,adm,dialout,cdrom,audio,video,plugdev,games,users,netdev "$NAS_USER"
	echo "created user $NAS_USER"
fi
if [[ -n "$NAS_PASSWORD" ]]; then
	echo "${NAS_USER}:${NAS_PASSWORD}" | chpasswd
fi

echo "waiting for network"
ok=0
for _ in $(seq 1 90); do
	if ping -c1 -W2 9.9.9.9 >/dev/null 2>&1 || ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
		ok=1
		break
	fi
	sleep 2
done
if [[ "$ok" -ne 1 ]]; then
	echo "network not ready; continuing anyway"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y || true
apt-get install -y samba samba-common-bin avahi-daemon curl ca-certificates || true

mkdir -p "$NAS_MOUNT" "$FALLBACK"

root_disk() {
	local src pk
	src=$(findmnt -n -o SOURCE / || true)
	[[ -n "$src" ]] || return 0
	pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)
	if [[ -n "$pk" ]]; then
		echo "$pk"
		return 0
	fi
	basename "$src" | sed -E 's/p?[0-9]+$//'
}

ROOT_DISK=$(root_disk)
echo "root disk: ${ROOT_DISK:-unknown}"

find_usb_partition() {
	local disk tran part fstype
	while read -r disk tran; do
		[[ "$tran" == "usb" ]] || continue
		[[ -n "$ROOT_DISK" && "$disk" == "$ROOT_DISK" ]] && continue
		while read -r part fstype; do
			[[ -n "$fstype" && "$fstype" != "swap" ]] || continue
			[[ "$part" == "$disk" ]] && continue
			echo "/dev/$part $fstype"
			return 0
		done < <(lsblk -nr -o NAME,FSTYPE "/dev/$disk")
	done < <(lsblk -dn -o NAME,TRAN)
	return 1
}

USB_INFO=$(find_usb_partition || true)
MOUNT_OPTS="defaults,nofail,x-systemd.device-timeout=8s"

if [[ -n "$USB_INFO" ]]; then
	USB_PART=${USB_INFO%% *}
	USB_FSTYPE=${USB_INFO##* }
	echo "usb partition: $USB_PART fstype=$USB_FSTYPE"
	UID_NUM=$(id -u "$NAS_USER")
	GID_NUM=$(id -g "$NAS_USER")
	case "$USB_FSTYPE" in
		vfat|fat|fat32|exfat|ntfs|ntfs3)
			MOUNT_OPTS="${MOUNT_OPTS},uid=${UID_NUM},gid=${GID_NUM},umask=002"
			;;
	esac
	UUID=$(blkid -s UUID -o value "$USB_PART" || true)
	if [[ -n "$UUID" ]]; then
		FSTAB_LINE="UUID=${UUID} ${NAS_MOUNT} auto ${MOUNT_OPTS} 0 2"
		if ! grep -q " ${NAS_MOUNT} " /etc/fstab; then
			echo "$FSTAB_LINE" >> /etc/fstab
			echo "fstab added: $FSTAB_LINE"
		fi
		mount "$NAS_MOUNT" || mount -t "$USB_FSTYPE" -o "$MOUNT_OPTS" "$USB_PART" "$NAS_MOUNT" || {
			echo "USB mount failed; using SD fallback"
			USB_INFO=""
		}
	else
		echo "no UUID on $USB_PART; using SD fallback"
		USB_INFO=""
	fi
fi

if [[ -z "$USB_INFO" ]]; then
	echo "no usable USB filesystem; sharing $FALLBACK"
	if ! findmnt -n "$NAS_MOUNT" >/dev/null 2>&1; then
		if ! grep -q " ${NAS_MOUNT} " /etc/fstab; then
			echo "$FALLBACK $NAS_MOUNT none bind,nofail 0 0" >> /etc/fstab
		fi
		mount --bind "$FALLBACK" "$NAS_MOUNT" || true
	fi
fi

chown "$NAS_USER:$NAS_USER" "$NAS_MOUNT" 2>/dev/null || true
chmod 775 "$NAS_MOUNT" 2>/dev/null || true

if [[ -f "$SMB_CONF" ]] && ! grep -q '^\[share\]' "$SMB_CONF"; then
	cat >> "$SMB_CONF" <<EOF

[share]
	comment = Personal NAS
	path = ${NAS_MOUNT}
	browseable = yes
	writeable = yes
	create mask = 0664
	directory mask = 0775
	valid users = ${NAS_USER}
	force user = ${NAS_USER}
EOF
	echo "added [share] to $SMB_CONF"
fi

if [[ -n "$NAS_PASSWORD" ]] && command -v smbpasswd >/dev/null; then
	printf '%s\n%s\n' "$NAS_PASSWORD" "$NAS_PASSWORD" | smbpasswd -a "$NAS_USER" -s || true
fi
systemctl enable --now smbd nmbd avahi-daemon 2>/dev/null || systemctl enable --now smbd 2>/dev/null || true

if [[ ! -e /usr/local/bin/pihole ]]; then
	mkdir -p /etc/pihole
	if [[ -f "$BOOT/pihole.toml" ]]; then
		cp "$BOOT/pihole.toml" /etc/pihole/pihole.toml
	else
		cat > /etc/pihole/pihole.toml <<'TOML'
[dns]
  upstreams = [ "9.9.9.9", "149.112.112.112" ]
  listeningMode = "LOCAL"
[webserver]
  port = "80o,443os"
TOML
	fi
	echo "installing Pi-hole (unattended)"
	if curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended; then
		echo "Pi-hole install finished"
	else
		echo "Pi-hole install failed; see this log"
	fi
	if command -v pihole >/dev/null && [[ -n "$NAS_PASSWORD" ]]; then
		pihole setpassword "$NAS_PASSWORD" || true
	fi
else
	echo "Pi-hole already present"
fi

rm -f "$ENV_FILE" || true
touch /var/lib/pi-hole-nas-ready
echo "firstboot done"
