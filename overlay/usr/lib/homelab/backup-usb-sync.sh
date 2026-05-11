#!/bin/sh
# Sync the active boot slot to the backup USB stick.
# Called by udev (on plug-in) and by the 24h post-update timer.

set -e
. /etc/homelab/config

BACKUP_UUID_FILE="/etc/homelab/backup-usb-uuid"
PERSIST_MOUNT="/run/pinneos/persist"
GRUBENV="$PERSIST_MOUNT/grubenv"

log() { logger -t pinneos-backup-usb "$*"; }
die() { log "ERROR: $*"; exit 1; }

[ -f "$BACKUP_UUID_FILE" ] || die "No backup USB registered. Run setup wizard first."

expected_uuid=$(cat "$BACKUP_UUID_FILE")
backup_dev="${1:-}"

# If no device passed, find it by UUID
if [ -z "$backup_dev" ]; then
    backup_dev=$(findfs "UUID=$expected_uuid" 2>/dev/null) || die "Backup USB not found."
fi

# Verify UUID matches what was registered
actual_uuid=$(blkid -o value -s UUID "$backup_dev" 2>/dev/null)
[ "$actual_uuid" = "$expected_uuid" ] || die "UUID mismatch — refusing to sync to unrecognised device."

log "Backup USB found at $backup_dev. Starting sync..."

# Mount backup USB
mkdir -p /mnt/pinneos-backup
mount "$backup_dev" /mnt/pinneos-backup

# Determine active slot
active_slot=$(grub-editenv "$GRUBENV" list | grep boot_slot | cut -d= -f2)
active_label="PINNEOS_${active_slot}"
active_dev=$(findfs "LABEL=$active_label")

mkdir -p /mnt/pinneos-active
mount "$active_dev" /mnt/pinneos-active -o ro

# Sync slot contents
rsync -a --checksum --delete /mnt/pinneos-active/ /mnt/pinneos-backup/
sync

# Ensure backup USB is bootable
grub-install --boot-directory=/mnt/pinneos-backup/boot --removable \
    "$(lsblk -no pkname "/dev/$(basename "$backup_dev")")"

umount /mnt/pinneos-active /mnt/pinneos-backup

log "Backup USB sync complete."
