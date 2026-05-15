#!/bin/sh
# PinneOS USB image updater — A/B slot scheme
# Triggered manually from Cockpit or CLI.
#
# Asset preference: .img.gz (raw disk image, slots pre-formatted) over .iso.
# IMG.gz partition layout: p1=EFI, p2=Slot A (source), p3=Slot B, p4=Persist.
#
# Usage:
#   update.sh                        # Download latest from GitHub
#   update.sh --file /path/to.img.gz # Install from local file (skips download)

set -e
. /etc/homelab/config

PERSIST_MOUNT="/run/pinneos/persist"
GRUBENV="$PERSIST_MOUNT/grubenv"

log()  { logger -t pinneos-update "$*"; echo "$*"; }
die()  { log "ERROR: $*"; exit 1; }

current_slot() { grub-editenv "$GRUBENV" list | grep boot_slot | cut -d= -f2; }
other_slot()   { [ "$(current_slot)" = "A" ] && echo B || echo A; }

slot_dev() {
    case "$1" in
        A) echo "$(findfs LABEL=PINNEOS_A)" ;;
        B) echo "$(findfs LABEL=PINNEOS_B)" ;;
    esac
}

# Parse arguments
local_file=""
if [ "$1" = "--file" ]; then
    local_file="$2"
    [ -n "$local_file" ] || die "--file requires a path argument"
    [ -f "$local_file" ] || die "File not found: $local_file"
fi

# Need ~7 GB free: 1.2 GB download + 5.5 GB decompressed image.
# Prefer a ZFS storage dataset (TBs of space); fall back to /tmp on RAM systems.
_find_workbase() {
    for mp in $(zfs list -H -o mountpoint 2>/dev/null | grep -v '^none$\|^-$'); do
        free_kb=$(df -k "$mp" 2>/dev/null | awk 'NR==2{print $4}')
        [ -n "$free_kb" ] && [ "$free_kb" -gt 7340032 ] && echo "$mp" && return 0
    done
    free_kb=$(df -k /tmp 2>/dev/null | awk 'NR==2{print $4}')
    [ -n "$free_kb" ] && [ "$free_kb" -gt 7340032 ] && echo "/tmp" && return 0
    return 1
}
workbase=$(_find_workbase) || die "No location with 7+ GB free. Attach a ZFS pool or use 'Install from file' to upload the image directly."
tmpdir=$(mktemp -d "${workbase}/.pinneos-update-XXXXXX")
src_mnt=$(mktemp -d)
slot_mnt="/mnt/pinneos-slot-target"
loop_dev=""
img_mode=0

cleanup() {
    umount "$src_mnt"  2>/dev/null || true
    umount "$slot_mnt" 2>/dev/null || true
    [ -n "$loop_dev" ] && losetup -d "$loop_dev" 2>/dev/null || true
    rm -rf "$tmpdir" "$src_mnt"
}
trap cleanup EXIT

if [ -n "$local_file" ]; then
    # Local file install — skip download and version check
    case "$local_file" in
        *.img.gz)
            log "Decompressing $local_file..."
            gzip -dc "$local_file" > "$tmpdir/new.img"
            log "Mounting raw image (partition 3 = Slot A)..."
            loop_dev=$(losetup -f --show -P "$tmpdir/new.img")
            mount -o ro "${loop_dev}p3" "$src_mnt"
            img_mode=1
            ;;
        *.img)
            log "Mounting raw image (partition 3 = Slot A)..."
            loop_dev=$(losetup -f --show -P "$local_file")
            mount -o ro "${loop_dev}p3" "$src_mnt"
            img_mode=1
            ;;
        *.iso)
            log "Mounting ISO..."
            mount -o loop,ro "$local_file" "$src_mnt"
            img_mode=0
            ;;
        *)
            die "Unknown file type: $local_file (expected .img.gz, .img, or .iso)"
            ;;
    esac
else
    # 1. Fetch latest release manifest
    log "Checking for updates (channel: $UPDATE_CHANNEL)..."
    manifest=$(curl -sf "$UPDATE_CHECK_URL") || die "Could not reach update server."
    latest=$(echo "$manifest" | jq -r '.tag_name' | sed 's/^v//')
    current=$(cat /etc/homelab/version 2>/dev/null || echo "unknown")

    if [ "$latest" = "$current" ]; then
        log "Already up to date ($current)."
        exit 0
    fi

    log "Update available: $current → $latest"

    # 2. Prefer IMG.gz (raw disk image); fall back to ISO
    img_url=$(echo "$manifest" | jq -r '.assets[] | select(.name | endswith(".img.gz")) | .browser_download_url' | head -1)
    iso_url=$(echo "$manifest" | jq -r '.assets[] | select(.name | endswith(".iso"))    | .browser_download_url' | head -1)

    [ -n "$img_url" ] || [ -n "$iso_url" ] || \
        die "No .img.gz or .iso asset found in release $latest."

    # 3. Download, verify, and mount source
    if [ -n "$img_url" ]; then
        sum_url=$(echo "$manifest" | jq -r \
            '.assets[] | select(.name | endswith(".img.gz.sha256")) | .browser_download_url' \
            | head -1)
        [ -n "$sum_url" ] || die "No .img.gz.sha256 found for $latest."

        log "Downloading $latest (img.gz)..."
        curl -LfsS --http1.1 "$img_url" -o "$tmpdir/new.img.gz" || die "Download failed (img.gz)"
        curl -LfsS --http1.1 "$sum_url" -o "$tmpdir/new.img.gz.sha256" || die "Download failed (sha256)"

        log "Verifying checksum..."
        expected=$(awk '{print $1}' "$tmpdir/new.img.gz.sha256")
        actual=$(sha256sum "$tmpdir/new.img.gz" | awk '{print $1}')
        [ "$expected" = "$actual" ] || die "Checksum verification failed (expected $expected, got $actual)"

        log "Decompressing image..."
        gzip -d "$tmpdir/new.img.gz"   # produces new.img

        log "Mounting raw image (partition 3 = Slot A)..."
        loop_dev=$(losetup -f --show -P "$tmpdir/new.img")
        mount -o ro "${loop_dev}p3" "$src_mnt"
        img_mode=1
    else
        sum_url=$(echo "$manifest" | jq -r \
            '.assets[] | select(.name | endswith(".iso.sha256")) | .browser_download_url' \
            | head -1)
        [ -n "$sum_url" ] || die "No .iso.sha256 found for $latest."

        log "Downloading $latest (iso)..."
        curl -LfsS --http1.1 "$iso_url" -o "$tmpdir/new.iso" || die "Download failed (iso)"
        curl -LfsS --http1.1 "$sum_url" -o "$tmpdir/new.iso.sha256" || die "Download failed (sha256)"

        log "Verifying checksum..."
        expected=$(awk '{print $1}' "$tmpdir/new.iso.sha256")
        actual=$(sha256sum "$tmpdir/new.iso" | awk '{print $1}')
        [ "$expected" = "$actual" ] || die "Checksum verification failed (expected $expected, got $actual)"

        log "Mounting ISO..."
        mount -o loop,ro "$tmpdir/new.iso" "$src_mnt"
    fi
fi

# 4. Write kernel, initramfs, and squashfs to standby slot
target=$(other_slot)
target_dev=$(slot_dev "$target")
log "Writing to slot $target ($target_dev)..."

mkdir -p "$slot_mnt"
mount "$target_dev" "$slot_mnt"

if [ "$img_mode" = "1" ]; then
    # Slot A from the IMG already has files in the final slot layout
    log "Copying kernel..."
    cp "$src_mnt/vmlinuz"       "$slot_mnt/vmlinuz"
    log "Copying initramfs..."
    cp "$src_mnt/initramfs.img" "$slot_mnt/initramfs.img"
    log "Copying squashfs..."
    mkdir -p "$slot_mnt/pinneos/x86_64"
    cp "$src_mnt/pinneos/x86_64/airootfs.sfs" \
       "$slot_mnt/pinneos/x86_64/airootfs.sfs"
    cp "$src_mnt/pinneos/x86_64/airootfs.sfs.sha512" \
       "$slot_mnt/pinneos/x86_64/airootfs.sfs.sha512" 2>/dev/null || true
else
    # ISO uses archiso path layout
    log "Copying kernel..."
    cp "$src_mnt/pinneos/boot/x86_64/vmlinuz-linux-lts" \
       "$slot_mnt/vmlinuz"
    log "Copying initramfs..."
    cp "$src_mnt/pinneos/boot/x86_64/initramfs-linux-lts.img" \
       "$slot_mnt/initramfs.img"
    log "Copying squashfs..."
    mkdir -p "$slot_mnt/pinneos/x86_64"
    cp "$src_mnt/pinneos/x86_64/airootfs.sfs" \
       "$slot_mnt/pinneos/x86_64/airootfs.sfs"
    cp "$src_mnt/pinneos/x86_64/airootfs.sfs.sha512" \
       "$slot_mnt/pinneos/x86_64/airootfs.sfs.sha512" 2>/dev/null || true
fi

sync
log "Slot $target written successfully."

# 5. Atomic slot switch
grub-editenv "$GRUBENV" set boot_slot="$target" boot_tries=0
log "Slot switched to $target. Reboot to apply update."

# 6. Arm the backup USB sync timer (fires 24h from now)
systemctl start pinneos-backup-usb-sync-delay.timer 2>/dev/null || true
