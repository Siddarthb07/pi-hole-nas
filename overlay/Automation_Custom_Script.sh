#!/bin/bash
# DietPi post first-run: NAS share at /srv/nas
# Mount the first USB disk that already has a filesystem. Never format.
set -euo pipefail

LOG=/var/lib/dietpi/logs/nas-setup.log
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "===== nas-setup $(date -Is) ====="

NAS_MOUNT=/srv/nas
FALLBACK=/mnt/dietpi_userdata/nas
SMB_CONF=/etc/samba/smb.conf
DIETPI_USER=dietpi

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
	UID_NUM=$(id -u "$DIETPI_USER")
	GID_NUM=$(id -g "$DIETPI_USER")
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

chown "$DIETPI_USER:$DIETPI_USER" "$NAS_MOUNT" 2>/dev/null || true
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
	valid users = ${DIETPI_USER}
	force user = ${DIETPI_USER}
EOF
	echo "added [share] to $SMB_CONF"
fi

systemctl restart smbd 2>/dev/null || systemctl restart nmbd 2>/dev/null || true
echo "nas-setup done. share path=$(findmnt -n -o SOURCE,TARGET $NAS_MOUNT || echo $NAS_MOUNT)"
