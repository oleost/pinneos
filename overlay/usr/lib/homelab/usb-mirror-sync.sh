#!/bin/sh
# Sync PinneOS slots between two USB sticks.
#
# Direction is determined by comparing the squashfs (airootfs.sfs) modification
# time on each USB's Slot A — the NEWER one is always the source, the OLDER one
# is the destination. No need to know which disk booted.
#
# Usage:
#   usb-mirror-sync.sh [/dev/DISK]
#       With DISK: sync between that disk and the other PinneOS USB found.
#       Without:   auto-detect two PinneOS USBs and sync newer → older.
#
# Triggered by:
#   - pinneos-boot-success.service  (after every successful boot)
#   - udev via udev-mirror-trigger.sh  (mirror USB plugged in)
#   - Cockpit "Mirror USB" sync button  (manual)

set -e
. /etc/homelab/config

log()  { logger -t pinneos-mirror "$*"; }
die()  { log "ERROR: $*"; exit 1; }
info() { log "$*"; echo "$*"; }

SFS_PATH="pinneos/x86_64/airootfs.sfs"

# Returns 0 if the given disk has a PINNEOS_A partition (i.e. is a PinneOS USB).
_is_pinneos_disk() {
    lsblk -lpno LABEL "$1" 2>/dev/null | grep -q "^PINNEOS_A$"
}

# Returns the newest airootfs.sfs mtime (epoch seconds) across BOTH slots on the
# given disk. Updates write to the standby slot (A or B alternately), so we must
# check both to detect which USB has the most recent content.
_slot_mtime() {
    local disk="$1" slot_dev mnt mtime best=0
    for slot in A B; do
        slot_dev=$(lsblk -lpno NAME,LABEL "/dev/$disk" 2>/dev/null \
            | awk -v l="PINNEOS_${slot}" '$2==l{print $1; exit}')
        [ -n "$slot_dev" ] || continue
        mnt=$(mktemp -d)
        if ! mount -o ro,noload "$slot_dev" "$mnt" >/dev/null 2>&1; then
            rmdir "$mnt"
            continue
        fi
        mtime=$(stat -c %Y "$mnt/$SFS_PATH" 2>/dev/null || echo 0)
        umount "$mnt" >/dev/null 2>&1 || true
        rmdir "$mnt" 2>/dev/null || true
        [ "${mtime:-0}" -gt "$best" ] && best="${mtime:-0}"
    done
    echo "$best"
}

# ── Find all PinneOS disks ────────────────────────────────────────────────────

all_pinneos=""
for _d in $(lsblk -lpno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    _is_pinneos_disk "$_d" && all_pinneos="$all_pinneos ${_d##/dev/}"
done
all_pinneos="${all_pinneos# }"

# ── Determine src and dst ────────────────────────────────────────────────────

if [ -n "$1" ]; then
    given="${1##/dev/}"
    # Find the other PinneOS disk (not the one passed as argument)
    other=""
    for _d in $all_pinneos; do
        [ "$_d" = "$given" ] && continue
        other="$_d"
        break
    done
    if [ -z "$other" ]; then
        info "No other PinneOS USB found — nothing to sync"
        exit 0
    fi
    disk_a="$given"
    disk_b="$other"
else
    # Auto-detect: need exactly two PinneOS disks
    count=$(echo "$all_pinneos" | wc -w)
    if [ "$count" -lt 2 ]; then
        info "No mirror USB detected — nothing to sync"
        exit 0
    fi
    disk_a=$(echo "$all_pinneos" | awk '{print $1}')
    disk_b=$(echo "$all_pinneos" | awk '{print $2}')
fi

# Read USB role from the EFI partition's pinneos-role file
_usb_role() {
    local disk="$1" efi_dev mnt role
    efi_dev=$(lsblk -lpno NAME,LABEL "/dev/$disk" 2>/dev/null \
        | awk '$2=="PINNEOS_EFI"{print $1; exit}')
    [ -n "$efi_dev" ] || { echo "primary"; return; }
    mnt=$(mktemp -d)
    if mount -o ro "$efi_dev" "$mnt" 2>/dev/null; then
        role=$(cat "$mnt/pinneos-role" 2>/dev/null | tr -d '[:space:]')
        umount "$mnt" 2>/dev/null || true
    fi
    rmdir "$mnt" 2>/dev/null || true
    echo "${role:-primary}"
}

role_a=$(_usb_role "$disk_a")
role_b=$(_usb_role "$disk_b")

info "USB roles: /dev/$disk_a=$role_a, /dev/$disk_b=$role_b"

if [ "$role_a" = "primary" ] && [ "$role_b" = "backup" ]; then
    src_disk="$disk_a"
    dst_disk="$disk_b"
elif [ "$role_b" = "primary" ] && [ "$role_a" = "backup" ]; then
    src_disk="$disk_b"
    dst_disk="$disk_a"
else
    # No roles set — fall back to mtime comparison
    mtime_a=$(_slot_mtime "$disk_a" | tail -1)
    mtime_b=$(_slot_mtime "$disk_b" | tail -1)
    info "No roles set — comparing mtime: /dev/$disk_a=$mtime_a, /dev/$disk_b=$mtime_b"
    if [ "$mtime_a" -eq "$mtime_b" ]; then
        info "Both USBs are identical — nothing to sync"
        exit 0
    elif [ "$mtime_a" -gt "$mtime_b" ]; then
        src_disk="$disk_a"
        dst_disk="$disk_b"
    else
        src_disk="$disk_b"
        dst_disk="$disk_a"
    fi
fi

info "Source (primary): /dev/$src_disk → Destination (backup): /dev/$dst_disk"

# ── Stale mount cleanup ────────────────────────────────────────────────────────

for _mnt in /mnt/pinneos-slot-src /mnt/pinneos-slot-dst /mnt/pinneos-mirror-efi; do
    umount "$_mnt" 2>/dev/null || true
done

# ── Sync Slot A and Slot B ─────────────────────────────────────────────────────

mkdir -p /mnt/pinneos-slot-src /mnt/pinneos-slot-dst

for slot in A B; do
    src_dev=$(lsblk -lpno NAME,LABEL "/dev/$src_disk" 2>/dev/null \
        | awk -v l="PINNEOS_${slot}" '$2==l{print $1; exit}')
    dst_dev=$(lsblk -lpno NAME,LABEL "/dev/$dst_disk" 2>/dev/null \
        | awk -v l="PINNEOS_${slot}" '$2==l{print $1; exit}')

    if [ -z "$src_dev" ] || [ -z "$dst_dev" ]; then
        log "PINNEOS_${slot} missing on one disk — skipping"
        continue
    fi

    info "Syncing PINNEOS_${slot}: $src_dev → $dst_dev"
    mount -o ro "$src_dev" /mnt/pinneos-slot-src
    mount        "$dst_dev" /mnt/pinneos-slot-dst

    rsync -a --checksum --delete --inplace \
        /mnt/pinneos-slot-src/ /mnt/pinneos-slot-dst/
    sync

    # Lazy fallback: kernel may hold a brief ref after rsync exits
    umount /mnt/pinneos-slot-src 2>/dev/null || umount -l /mnt/pinneos-slot-src
    umount /mnt/pinneos-slot-dst 2>/dev/null || umount -l /mnt/pinneos-slot-dst
    info "PINNEOS_${slot} synced"
done

# ── Sync grubenv (on EFI partition, FAT32 — always GRUB-readable) ─────────────

src_efi=$(lsblk -lpno NAME,LABEL "/dev/$src_disk" 2>/dev/null \
    | awk '$2=="PINNEOS_EFI"{print $1; exit}')
mirror_efi=$(lsblk -lpno NAME,LABEL "/dev/$dst_disk" 2>/dev/null \
    | awk '$2=="PINNEOS_EFI"{print $1; exit}')

if [ -n "$src_efi" ] && [ -n "$mirror_efi" ]; then
    mkdir -p /mnt/pinneos-mirror-efi
    mount "$src_efi" /mnt/pinneos-mirror-efi 2>/dev/null
    current_slot=$(grub-editenv /mnt/pinneos-mirror-efi/grubenv list 2>/dev/null \
        | awk -F= '/^boot_slot/{print $2}')
    umount /mnt/pinneos-mirror-efi 2>/dev/null || true

    mount "$mirror_efi" /mnt/pinneos-mirror-efi
    grub-editenv /mnt/pinneos-mirror-efi/grubenv set boot_slot="${current_slot:-A}"
    grub-editenv /mnt/pinneos-mirror-efi/grubenv set boot_tries=0
    sync
    umount /mnt/pinneos-mirror-efi 2>/dev/null || umount -l /mnt/pinneos-mirror-efi
    info "grubenv synced on EFI (boot_slot=${current_slot:-A}, boot_tries=0)"
fi

info "Mirror sync complete."
