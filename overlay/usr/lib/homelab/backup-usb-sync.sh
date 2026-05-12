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
[ -n "$active_slot" ] || die "Could not read boot_slot from grubenv"

# Both USBs have identical partition labels, so look up the active slot only on
# the boot disk. The persist partition is always mounted from the boot USB at
# early boot, so its source device tells us which disk is the boot USB.
persist_src=$(findmnt -n -o SOURCE "$PERSIST_MOUNT" 2>/dev/null) || die "Persist partition not mounted at $PERSIST_MOUNT"
boot_disk=$(lsblk -no pkname "$persist_src" 2>/dev/null)
[ -n "$boot_disk" ] || die "Could not determine boot disk from persist mount ($persist_src)"
active_dev=$(lsblk -lpno NAME,LABEL "/dev/$boot_disk" 2>/dev/null \
    | awk -v label="PINNEOS_${active_slot}" '$2==label {print $1; exit}')
[ -n "$active_dev" ] || die "PINNEOS_${active_slot} not found on boot disk /dev/$boot_disk"

mkdir -p /mnt/pinneos-active
mount "$active_dev" /mnt/pinneos-active -o ro

# Sync slot contents (squashfs, vmlinuz, initramfs)
rsync -a --checksum --delete /mnt/pinneos-active/ /mnt/pinneos-backup/
sync

umount /mnt/pinneos-active /mnt/pinneos-backup

# Update grubenv on the backup USB's persist partition so it boots the same slot.
# GRUB itself is static (installed at image-build time) and doesn't need reinstalling.
backup_disk=$(lsblk -no pkname "$backup_dev" 2>/dev/null)
backup_persist=$(lsblk -lpno NAME,LABEL "/dev/$backup_disk" 2>/dev/null \
    | awk '$2=="PINNEOS_PERSIST" {print $1; exit}')
if [ -n "$backup_persist" ]; then
    BACKUP_PERSIST_MNT="/mnt/pinneos-backup-persist"
    mkdir -p "$BACKUP_PERSIST_MNT"
    mount "$backup_persist" "$BACKUP_PERSIST_MNT"
    grub-editenv "$BACKUP_PERSIST_MNT/grubenv" set boot_slot="$active_slot"
    grub-editenv "$BACKUP_PERSIST_MNT/grubenv" set boot_tries=0
    sync
    umount "$BACKUP_PERSIST_MNT"
fi

log "Backup USB sync complete."
