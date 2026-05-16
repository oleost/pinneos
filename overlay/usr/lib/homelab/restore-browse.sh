#!/bin/bash
# Mount a backup snapshot as a read-only clone for file browsing.
#
# Usage:
#   restore-browse.sh mount  --source POOL_OR_DATASET [--snapshot NAME]
#   restore-browse.sh unmount
#
# mount: clones the snapshot to tank/restore-staging, mounts read-only at
#        /mnt/pinneos-restore, prints the mount path.
# unmount: destroys the staging clone and removes the mount point.

set -euo pipefail
. /etc/homelab/config

STAGING_BASE="restore-staging"
MOUNT_BASE="/mnt/pinneos-restore"
STATE_FILE="/run/pinneos/restore-browse-pool"

log() { echo "[restore-browse] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

main_pool() {
    zpool list -H -o name 2>/dev/null | while read -r pool; do
        val=$(zfs get -H -o value "$ZFS_MANAGED_PROPERTY" "$pool" 2>/dev/null)
        [ "$val" = "yes" ] && echo "$pool" && return
    done
}

cmd_mount() {
    local source="" snapshot=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)   source="$2";   shift 2 ;;
            --snapshot) snapshot="$2"; shift 2 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
    [ -n "$source" ] || die "Missing --source"

    local pool
    pool=$(main_pool) || die "No managed ZFS pool found"

    # Resolve snapshot: use given name or find most recent pinneos-backup-* on source
    if [ -z "$snapshot" ]; then
        snapshot=$(zfs list -H -t snapshot -o name -S creation -r "$source" 2>/dev/null \
            | grep "@pinneos-backup" | head -1 | sed 's/.*@//')
        [ -n "$snapshot" ] || die "No pinneos-backup snapshots found on $source"
        log "Using most recent snapshot: $snapshot"
    fi

    local staging="${pool}/${STAGING_BASE}"

    # Clean up any leftover staging clone
    if zfs list "$staging" >/dev/null 2>&1; then
        log "Removing previous staging clone..."
        zfs destroy -r "$staging" 2>/dev/null || true
    fi

    # Find and clone each matching sub-dataset snapshot
    local found=0
    while IFS= read -r snap_full; do
        local ds="${snap_full%%@*}"
        local ds_suffix="${ds#"$source"}"
        local clone_dest="${staging}${ds_suffix}"

        log "Cloning ${snap_full} → ${clone_dest}..."
        # Create parent if needed
        local parent="${clone_dest%/*}"
        [ "$parent" = "$clone_dest" ] || zfs create -p "$parent" 2>/dev/null || true
        zfs clone -o readonly=on "$snap_full" "$clone_dest"
        found=1
    done < <(zfs list -H -t snapshot -o name -r "$source" 2>/dev/null | grep "@${snapshot}$")

    [ "$found" -eq 1 ] || die "Snapshot '$snapshot' not found under '$source'"

    # Mount point
    local staging_mp
    staging_mp=$(zfs get -H -o value mountpoint "$staging" 2>/dev/null)
    [ -n "$staging_mp" ] && [ "$staging_mp" != "none" ] || staging_mp="/${staging}"

    mkdir -p "$MOUNT_BASE"
    # Bind-mount so we expose a single clean path regardless of ZFS mountpoint
    if ! mountpoint -q "$MOUNT_BASE" 2>/dev/null; then
        mount --bind "$staging_mp" "$MOUNT_BASE"
    fi

    # Save pool name for unmount
    mkdir -p /run/pinneos
    echo "$pool" > "$STATE_FILE"

    log "Snapshot '$snapshot' mounted at $MOUNT_BASE"
    log "Copy files with: cp -r $MOUNT_BASE/path/to/file /destination/"
    echo "MOUNT_PATH:${MOUNT_BASE}"
}

cmd_unmount() {
    local pool=""
    [ -f "$STATE_FILE" ] && pool=$(cat "$STATE_FILE")

    if mountpoint -q "$MOUNT_BASE" 2>/dev/null; then
        umount "$MOUNT_BASE" 2>/dev/null || true
    fi
    rmdir "$MOUNT_BASE" 2>/dev/null || true

    if [ -n "$pool" ]; then
        local staging="${pool}/${STAGING_BASE}"
        if zfs list "$staging" >/dev/null 2>&1; then
            log "Destroying staging clone ${staging}..."
            zfs destroy -r "$staging"
        fi
    fi

    rm -f "$STATE_FILE"
    log "Unmounted and cleaned up."
}

CMD="${1:-}"
shift || true
case "$CMD" in
    mount)   cmd_mount   "$@" ;;
    unmount) cmd_unmount "$@" ;;
    *) echo "Usage: restore-browse.sh mount|unmount [options]" >&2; exit 1 ;;
esac
