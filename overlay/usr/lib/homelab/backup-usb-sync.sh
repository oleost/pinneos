#!/bin/sh
# Sync the active boot slot to the backup USB stick.
# Called by udev (on plug-in) and by the 24h post-update timer.
#
# Identification: disk serial number (not partition UUID — cloned USBs share identical UUIDs).

set -e
. /etc/homelab/config

SERIAL_FILE="/etc/homelab/backup-usb-serial"
PERSIST_MOUNT="/run/pinneos/persist"
GRUBENV="$PERSIST_MOUNT/grubenv"

log() { logger -t pinneos-backup-usb "$*"; }
die() { log "ERROR: $*"; exit 1; }

[ -f "$SERIAL_FILE" ] || die "No backup USB registered."
expected_serial=$(cat "$SERIAL_FILE")
[ -n "$expected_serial" ] || die "Backup serial file is empty."

# Find the backup disk by serial number
backup_disk=""
for disk in $(lsblk -lpno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    actual=$(udevadm info --query=property "$disk" 2>/dev/null \
        | awk -F= '/^ID_SERIAL_SHORT=/{print $2; exit}')
    if [ "$actual" = "$expected_serial" ]; then
        backup_disk="${disk##/dev/}"
        break
    fi
done
[ -n "$backup_disk" ] || die "Backup USB (serial=$expected_serial) not connected."
log "Backup disk: /dev/$backup_disk"

# Clean up any stale mounts from a previous failed run
umount /mnt/pinneos-active       2>/dev/null || true
umount /mnt/pinneos-backup       2>/dev/null || true
umount /mnt/pinneos-backup-persist 2>/dev/null || true

# Determine active boot slot from grubenv
active_slot=$(grub-editenv "$GRUBENV" list | grep boot_slot | cut -d= -f2)
[ -n "$active_slot" ] || die "Could not read boot_slot from grubenv"
log "Active slot: $active_slot"

# Find boot disk via persist mount — unambiguous even when both USBs share partition labels/UUIDs
persist_src=$(findmnt -n -o SOURCE "$PERSIST_MOUNT" 2>/dev/null) \
    || die "Persist partition not mounted at $PERSIST_MOUNT"
boot_disk=$(lsblk -no pkname "$persist_src" 2>/dev/null)
[ -n "$boot_disk" ] || die "Could not determine boot disk from persist mount ($persist_src)"

[ "/dev/$boot_disk" != "/dev/$backup_disk" ] \
    || die "Boot disk and backup disk are the same (/dev/$boot_disk) — refusing sync."

# Active slot partition on the boot disk
active_dev=$(lsblk -lpno NAME,LABEL "/dev/$boot_disk" 2>/dev/null \
    | awk -v lbl="PINNEOS_${active_slot}" '$2==lbl {print $1; exit}')
[ -n "$active_dev" ] || die "PINNEOS_${active_slot} not found on boot disk /dev/$boot_disk"

# Matching slot partition on the backup disk (slot A→A, slot B→B)
backup_slot_dev=$(lsblk -lpno NAME,LABEL "/dev/$backup_disk" 2>/dev/null \
    | awk -v lbl="PINNEOS_${active_slot}" '$2==lbl {print $1; exit}')
[ -n "$backup_slot_dev" ] || die "PINNEOS_${active_slot} not found on backup disk /dev/$backup_disk"

log "Syncing $active_dev → $backup_slot_dev..."

mkdir -p /mnt/pinneos-active /mnt/pinneos-backup
mount -o ro "$active_dev"       /mnt/pinneos-active
mount        "$backup_slot_dev" /mnt/pinneos-backup

rsync -a --checksum --delete --inplace /mnt/pinneos-active/ /mnt/pinneos-backup/
sync

umount /mnt/pinneos-active /mnt/pinneos-backup

# Update grubenv on the backup USB's persist partition
backup_persist=$(lsblk -lpno NAME,LABEL "/dev/$backup_disk" 2>/dev/null \
    | awk '$2=="PINNEOS_PERSIST" {print $1; exit}')
if [ -n "$backup_persist" ]; then
    mkdir -p /mnt/pinneos-backup-persist
    mount "$backup_persist" /mnt/pinneos-backup-persist
    grub-editenv /mnt/pinneos-backup-persist/grubenv set boot_slot="$active_slot"
    grub-editenv /mnt/pinneos-backup-persist/grubenv set boot_tries=0
    sync
    umount /mnt/pinneos-backup-persist
fi

log "Backup USB sync complete."
