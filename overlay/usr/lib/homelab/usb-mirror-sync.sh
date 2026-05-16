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

# Returns the mtime (epoch seconds) of airootfs.sfs on Slot A of the given disk.
# Returns 0 if the disk or file cannot be read.
_slot_mtime() {
    local disk="$1" slot_dev mnt mtime
    slot_dev=$(lsblk -lpno NAME,LABEL "/dev/$disk" 2>/dev/null \
        | awk '$2=="PINNEOS_A"{print $1; exit}')
    [ -n "$slot_dev" ] || { echo 0; return; }
    mnt=$(mktemp -d)
    if ! mount -o ro "$slot_dev" "$mnt" 2>/dev/null; then
        rmdir "$mnt"
        echo 0
        return
    fi
    mtime=$(stat -c %Y "$mnt/$SFS_PATH" 2>/dev/null || echo 0)
    umount "$mnt" 2>/dev/null || true
    rmdir "$mnt" 2>/dev/null || true
    echo "${mtime:-0}"
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

# Compare squashfs mtimes to pick sync direction
mtime_a=$(_slot_mtime "$disk_a")
mtime_b=$(_slot_mtime "$disk_b")

info "Comparing: /dev/$disk_a (mtime=$mtime_a) vs /dev/$disk_b (mtime=$mtime_b)"

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

info "Source (newer): /dev/$src_disk → Destination (older): /dev/$dst_disk"

# ── Stale mount cleanup ────────────────────────────────────────────────────────

for _mnt in /mnt/pinneos-slot-src /mnt/pinneos-slot-dst /mnt/pinneos-mirror-persist; do
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

    umount /mnt/pinneos-slot-src /mnt/pinneos-slot-dst
    info "PINNEOS_${slot} synced"
done

# ── Sync grubenv ───────────────────────────────────────────────────────────────

mirror_persist=$(lsblk -lpno NAME,LABEL "/dev/$dst_disk" 2>/dev/null \
    | awk '$2=="PINNEOS_PERSIST"{print $1; exit}')

if [ -n "$mirror_persist" ]; then
    if [ -f "$PERSIST_MOUNT/grubenv" ]; then
        current_slot=$(grub-editenv "$PERSIST_MOUNT/grubenv" list \
            | awk -F= '/^boot_slot/{print $2}')
    else
        boot_persist=$(lsblk -lpno NAME,LABEL "/dev/$src_disk" 2>/dev/null \
            | awk '$2=="PINNEOS_PERSIST"{print $1; exit}')
        mkdir -p /mnt/pinneos-mirror-persist
        mount "$boot_persist" /mnt/pinneos-mirror-persist
        current_slot=$(grub-editenv /mnt/pinneos-mirror-persist/grubenv list \
            | awk -F= '/^boot_slot/{print $2}')
        umount /mnt/pinneos-mirror-persist
    fi

    mkdir -p /mnt/pinneos-mirror-persist
    mount "$mirror_persist" /mnt/pinneos-mirror-persist
    grub-editenv /mnt/pinneos-mirror-persist/grubenv set boot_slot="${current_slot:-A}"
    grub-editenv /mnt/pinneos-mirror-persist/grubenv set boot_tries=0
    sync
    umount /mnt/pinneos-mirror-persist
    info "grubenv synced (boot_slot=${current_slot:-A}, boot_tries=0)"
fi

info "Mirror sync complete."
