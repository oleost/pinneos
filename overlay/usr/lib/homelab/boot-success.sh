#!/bin/sh
# Confirm successful boot by resetting boot_tries=0 in the grubenv.
# Runs via pinneos-boot-success.service on every boot.
# Without this, GRUB auto-rolls back to the previous slot after 2 reboots.

. /etc/homelab/config

log() { logger -t pinneos-boot "$*"; }

PERSIST_MOUNT="/run/pinneos/persist"

# Find the EFI partition (FAT32) on the boot USB — grubenv lives there.
# GRUB cannot read F2FS/ext4 persist, so grubenv must be on FAT32 EFI.
boot_label=$(grep -o 'archisolabel=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2)
boot_part=$(findfs "LABEL=$boot_label" 2>/dev/null)
boot_disk=$(lsblk -no PKNAME "$boot_part" 2>/dev/null | head -1)
efi_dev=""
if [ -n "$boot_disk" ]; then
    efi_dev=$(lsblk -rno NAME,LABEL "/dev/$boot_disk" 2>/dev/null \
        | awk '$2=="PINNEOS_EFI"{print "/dev/"$1}' | head -1)
fi

usb_role="primary"
if [ -n "$efi_dev" ]; then
    mnt=$(mktemp -d)
    if mount "$efi_dev" "$mnt" 2>/dev/null; then
        grub-editenv "$mnt/grubenv" set boot_tries=0
        usb_role=$(cat "$mnt/pinneos-role" 2>/dev/null | tr -d '[:space:]' || echo "primary")
        umount "$mnt" 2>/dev/null || true
        log "boot_tries reset to 0 on EFI partition ($efi_dev), role=$usb_role"
    fi
    rmdir "$mnt" 2>/dev/null || true
elif [ -f "$PERSIST_MOUNT/grubenv" ]; then
    # Fallback: old persist location (pre-v0.3.2 USBs)
    grub-editenv "$PERSIST_MOUNT/grubenv" set boot_tries=0
    log "boot_tries reset to 0 on persist (legacy fallback)"
else
    log "Warning: could not find grubenv to reset boot_tries"
fi

# Warn loudly if booting from backup USB
if [ "$usb_role" = "backup" ]; then
    log "WARNING: Booted from BACKUP USB — primary USB may be missing or failed"
    # Send Gotify notification if configured
    gotify_url=$(cat /etc/homelab/gotify-url 2>/dev/null | tr -d '[:space:]')
    gotify_token=$(cat /etc/homelab/gotify-token 2>/dev/null | tr -d '[:space:]')
    if [ -n "$gotify_url" ] && [ -n "$gotify_token" ]; then
        curl -sf -X POST "$gotify_url/message" \
            -H "X-Gotify-Key: $gotify_token" \
            -F "title=PinneOS: Backup USB booted" \
            -F "message=System is running from the BACKUP USB stick. Check if the primary USB is connected and functional." \
            -F "priority=7" >/dev/null 2>&1 || true
    fi
fi

# Trigger mirror sync — only after confirmed boot.
# Syncs primary → backup so backup stays current after a successful update.
# --no-block: don't wait for sync to complete (large squashfs takes minutes).
systemctl start --no-block pinneos-usb-mirror-sync.service 2>/dev/null || true
log "USB mirror sync triggered (role=$usb_role)"
