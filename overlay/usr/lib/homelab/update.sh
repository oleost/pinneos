#!/bin/sh
# PinneOS USB image updater — A/B slot scheme
# Triggered manually from Cockpit or CLI.

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

# 1. Fetch latest release manifest
log "Checking for updates (channel: $UPDATE_CHANNEL)..."
manifest=$(curl -sf "$UPDATE_CHECK_URL") || die "Could not reach update server."
latest=$(echo "$manifest" | jq -r '.tag_name')
current=$(cat /etc/homelab/version 2>/dev/null || echo "unknown")

if [ "$latest" = "$current" ]; then
    log "Already up to date ($current)."
    exit 0
fi

log "Update available: $current → $latest"

# 2. Download new ISO and checksum
base_url=$(echo "$manifest" | jq -r '.assets[] | select(.name | endswith(".iso")) | .browser_download_url')
sum_url=$(echo "$manifest"  | jq -r '.assets[] | select(.name | endswith(".iso.sha256")) | .browser_download_url')

[ -n "$base_url" ] || die "No .iso asset found in release $latest."

tmpdir=$(mktemp -d)
iso_mnt=$(mktemp -d)
slot_mnt="/mnt/pinneos-slot-target"
trap 'umount "$iso_mnt" 2>/dev/null; umount "$slot_mnt" 2>/dev/null; rm -rf "$tmpdir" "$iso_mnt"' EXIT

log "Downloading $latest..."
curl -Lf "$base_url" -o "$tmpdir/new.iso"
curl -Lf "$sum_url"  -o "$tmpdir/new.iso.sha256"

# 3. Verify checksum
(cd "$tmpdir" && sha256sum -c new.iso.sha256) || die "Checksum verification failed."

# 4. Extract slot content from ISO and write to standby slot
target=$(other_slot)
target_dev=$(slot_dev "$target")
log "Writing to slot $target ($target_dev)..."

# Mount the ISO read-only via loop device
mount -o loop,ro "$tmpdir/new.iso" "$iso_mnt"

# Mount the target slot partition (ext4)
mkdir -p "$slot_mnt"
mount "$target_dev" "$slot_mnt"

log "Copying kernel..."
cp "$iso_mnt/pinneos/boot/x86_64/vmlinuz-linux-lts" "$slot_mnt/vmlinuz"

log "Copying initramfs..."
cp "$iso_mnt/pinneos/boot/x86_64/initramfs-linux-lts.img" "$slot_mnt/initramfs.img"

log "Copying squashfs..."
mkdir -p "$slot_mnt/pinneos/x86_64"
cp "$iso_mnt/pinneos/x86_64/airootfs.sfs" "$slot_mnt/pinneos/x86_64/airootfs.sfs"
# Copy integrity file if present
cp "$iso_mnt/pinneos/x86_64/airootfs.sfs.sha512" \
   "$slot_mnt/pinneos/x86_64/airootfs.sfs.sha512" 2>/dev/null || true

sync
umount "$iso_mnt"
umount "$slot_mnt"
log "Slot $target written successfully."

# 5. Atomic slot switch
grub-editenv "$GRUBENV" set boot_slot="$target" boot_tries=0
log "Slot switched to $target. Reboot to apply update."

# 6. Arm the backup USB sync timer (fires 24h from now)
systemctl start pinneos-backup-usb-sync-delay.timer

# 7. Notify web panel
# TODO: send event to Homepage / Cockpit notification endpoint
