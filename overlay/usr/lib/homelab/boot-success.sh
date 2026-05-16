#!/bin/sh
# Confirm successful boot by resetting boot_tries=0 in the grubenv.
# Runs via pinneos-boot-success.service on every boot.
# Without this, GRUB auto-rolls back to the previous slot after 2 reboots.

. /etc/homelab/config

log() { logger -t pinneos-boot "$*"; }

PERSIST_MOUNT="/run/pinneos/persist"

# Find the grubenv on the BOOT USB (same logic as update.sh).
# Avoids the ambiguity when a backup USB with identical labels is plugged in.
boot_label=$(grep -o 'archisolabel=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2)
boot_part=$(findfs "LABEL=$boot_label" 2>/dev/null)
boot_disk=$(lsblk -no PKNAME "$boot_part" 2>/dev/null | head -1)
persist_dev=""
if [ -n "$boot_disk" ]; then
    persist_dev=$(lsblk -rno NAME,LABEL "/dev/$boot_disk" 2>/dev/null \
        | awk '$2=="PINNEOS_PERSIST"{print "/dev/"$1}' | head -1)
fi

# Record boot disk early so usb-mirror-sync.sh can identify it later when a
# second USB (with identical labels) is plugged in.
if [ -n "$boot_disk" ]; then
    mkdir -p /run/pinneos
    echo "$boot_disk" > /run/pinneos/boot-disk
    log "Boot disk recorded: /dev/$boot_disk"
fi

if [ -n "$persist_dev" ]; then
    mnt=$(mktemp -d)
    if mount "$persist_dev" "$mnt" 2>/dev/null; then
        grub-editenv "$mnt/grubenv" set boot_tries=0
        umount "$mnt" 2>/dev/null || true
        log "boot_tries reset to 0 on $persist_dev"
    fi
    rmdir "$mnt" 2>/dev/null || true
elif [ -f "$PERSIST_MOUNT/grubenv" ]; then
    grub-editenv "$PERSIST_MOUNT/grubenv" set boot_tries=0
    log "boot_tries reset to 0 on mounted persist"
else
    log "Warning: could not find grubenv to reset boot_tries"
fi

# Trigger mirror sync — keeps both USB sticks identical.
# --no-block: don't wait for sync to complete (can take minutes for large squashfs).
# Exits silently if no mirror USB is connected.
systemctl start --no-block pinneos-usb-mirror-sync.service 2>/dev/null || true
log "USB mirror sync triggered"
