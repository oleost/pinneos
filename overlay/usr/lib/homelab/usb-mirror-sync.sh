#!/bin/sh
# Sync all PinneOS slots from the boot USB to a mirror USB.
#
# Both Slot A and Slot B are rsynced, and grubenv is copied, making the mirror
# an exact duplicate of the boot USB. GRUB can then boot from either stick
# interchangeably — no registration, no "primary vs backup" distinction.
#
# Usage:
#   usb-mirror-sync.sh [/dev/DISK]
#       With DISK: sync boot USB → that specific disk.
#       Without:   auto-detect the first non-boot PinneOS USB found.
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

# Find the disk that the running system booted from.
# Uses the archisolabel kernel parameter (e.g. PINNEOS_A or PINNEOS_B) which
# archiso sets, then traces that partition back to its parent disk.
_boot_disk() {
    local label part
    label=$(grep -o 'archisolabel=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2)
    [ -n "$label" ] || return 1
    part=$(findfs "LABEL=$label" 2>/dev/null) || return 1
    lsblk -no PKNAME "$part" 2>/dev/null | head -1
}

# Returns 0 if the given disk device has a PINNEOS_A partition (i.e. is a PinneOS USB).
_is_pinneos_disk() {
    lsblk -lpno LABEL "$1" 2>/dev/null | grep -q "^PINNEOS_A$"
}

boot_disk=$(_boot_disk) || die "Cannot determine boot disk from kernel cmdline"
info "Boot disk: /dev/$boot_disk"

# ── Determine mirror target ────────────────────────────────────────────────────

if [ -n "$1" ]; then
    mirror_disk="${1##/dev/}"
    [ "$mirror_disk" != "$boot_disk" ] \
        || die "/dev/$mirror_disk is the boot disk — refusing sync to self"
    _is_pinneos_disk "/dev/$mirror_disk" \
        || die "/dev/$mirror_disk has no PINNEOS_A partition — not a PinneOS USB"
else
    mirror_disk=""
    for _d in $(lsblk -lpno NAME,TYPE | awk '$2=="disk"{print $1}'); do
        _candidate="${_d##/dev/}"
        [ "$_candidate" = "$boot_disk" ] && continue
        if _is_pinneos_disk "$_d"; then
            mirror_disk="$_candidate"
            break
        fi
    done
    [ -n "$mirror_disk" ] || die "No mirror USB detected"
fi

info "Mirror disk: /dev/$mirror_disk"

# ── Stale mount cleanup ────────────────────────────────────────────────────────

for _mnt in /mnt/pinneos-slot-src /mnt/pinneos-slot-dst /mnt/pinneos-mirror-persist; do
    umount "$_mnt" 2>/dev/null || true
done

# ── Sync Slot A and Slot B ─────────────────────────────────────────────────────

mkdir -p /mnt/pinneos-slot-src /mnt/pinneos-slot-dst

for slot in A B; do
    src_dev=$(lsblk -lpno NAME,LABEL "/dev/$boot_disk" 2>/dev/null \
        | awk -v l="PINNEOS_${slot}" '$2==l{print $1; exit}')
    dst_dev=$(lsblk -lpno NAME,LABEL "/dev/$mirror_disk" 2>/dev/null \
        | awk -v l="PINNEOS_${slot}" '$2==l{print $1; exit}')

    if [ -z "$src_dev" ] || [ -z "$dst_dev" ]; then
        log "PINNEOS_${slot} missing on one disk — skipping"
        continue
    fi

    info "Syncing PINNEOS_${slot}: $src_dev → $dst_dev"
    mount -o ro "$src_dev" /mnt/pinneos-slot-src
    mount        "$dst_dev" /mnt/pinneos-slot-dst

    # --inplace: overwrite files in place instead of creating a temp copy.
    # Required because the 2 GB slot partition has < 700 MB free when occupied
    # by the existing squashfs — not enough room for a side-by-side temp file.
    rsync -a --checksum --delete --inplace \
        /mnt/pinneos-slot-src/ /mnt/pinneos-slot-dst/
    sync

    umount /mnt/pinneos-slot-src /mnt/pinneos-slot-dst
    info "PINNEOS_${slot} synced"
done

# ── Sync grubenv ───────────────────────────────────────────────────────────────
# Copy boot_slot from the boot USB to the mirror so both agree on which slot is
# active. Reset boot_tries to 0 — the mirror is a known-good copy.

mirror_persist=$(lsblk -lpno NAME,LABEL "/dev/$mirror_disk" 2>/dev/null \
    | awk '$2=="PINNEOS_PERSIST"{print $1; exit}')

if [ -n "$mirror_persist" ]; then
    # Prefer the already-mounted persist partition to avoid a double-mount error.
    if [ -f "$PERSIST_MOUNT/grubenv" ]; then
        current_slot=$(grub-editenv "$PERSIST_MOUNT/grubenv" list \
            | awk -F= '/^boot_slot/{print $2}')
    else
        boot_persist=$(lsblk -lpno NAME,LABEL "/dev/$boot_disk" 2>/dev/null \
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
