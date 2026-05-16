#!/bin/sh
# Mark the boot USB as primary or backup.
# Writes role files to the EFI partition (FAT32, readable by GRUB and Linux).
#
# Usage:
#   set-usb-role.sh primary    Mark this USB as the primary boot device
#   set-usb-role.sh backup     Mark this USB as the backup/mirror device

set -e

role="${1:-}"
case "$role" in
    primary|backup) ;;
    *) echo "Usage: set-usb-role.sh primary|backup" >&2; exit 1 ;;
esac

boot_label=$(grep -o 'archisolabel=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2)
boot_part=$(findfs "LABEL=$boot_label" 2>/dev/null)
boot_disk=$(lsblk -no PKNAME "$boot_part" 2>/dev/null | head -1)
efi_dev=$(lsblk -rno NAME,LABEL "/dev/$boot_disk" 2>/dev/null \
    | awk '$2=="PINNEOS_EFI"{print "/dev/"$1}' | head -1)

[ -n "$efi_dev" ] || { echo "ERROR: Cannot find EFI partition on boot USB" >&2; exit 1; }

mnt=$(mktemp -d)
trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true' EXIT

mount "$efi_dev" "$mnt"
printf '%s\n' "$role" > "$mnt/pinneos-role"
if [ "$role" = "backup" ]; then
    touch "$mnt/pinneos-backup"
else
    rm -f "$mnt/pinneos-backup"
fi
sync

echo "USB role set to: $role (EFI: $efi_dev)"
