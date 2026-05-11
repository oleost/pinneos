#!/bin/bash
# pinneos-backup: ZFS snapshot + send/receive backup for PinneOS
#
# Usage:
#   backup.sh create --dest DEST_POOL [--mode system-apps|full] [--label NAME]
#   backup.sh list   --dest DEST_POOL
#   backup.sh prune  --dest DEST_POOL [--keep N]
#
# Modes:
#   system-apps  (default) — backs up system/ and apps/ datasets
#   full                   — backs up system/, apps/, and storage/
#
# Dest can be:
#   A pool name:         tank2
#   A dataset path:      backup-pool/pinneos
#   An external mount:   /mnt/external (sends to a .zfs stream file)

set -euo pipefail
. /etc/homelab/config

SNAPSHOT_PREFIX="pinneos-backup"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
KEEP_SNAPSHOTS=7  # default retention

log()  { logger -t pinneos-backup "$*"; echo "[backup] $*"; }
die()  { log "ERROR: $*"; exit 1; }

usage() {
    echo "Usage: backup.sh create --dest DEST [--mode system-apps|full] [--label NAME]"
    echo "       backup.sh list   --dest DEST"
    echo "       backup.sh prune  --dest DEST [--keep N]"
    exit 1
}

# ── Detect main pool ──────────────────────────────────────────────────────────
main_pool() {
    zpool list -H -o name 2>/dev/null | while read -r pool; do
        val=$(zfs get -H -o value "$ZFS_MANAGED_PROPERTY" "$pool" 2>/dev/null)
        [ "$val" = "yes" ] && echo "$pool" && return
    done
}

# ── Datasets to include per mode ─────────────────────────────────────────────
datasets_for_mode() {
    local pool="$1" mode="$2"
    echo "${pool}/${DATASET_SYSTEM}"
    echo "${pool}/${DATASET_APPS}"
    [ "$mode" = "full" ] && echo "${pool}/${DATASET_STORAGE}"
    return 0
}

# ── Find the most recent shared snapshot between source and dest dataset ─────
last_common_snapshot() {
    local src="$1" dst="$2"
    # List snapshot names on source (newest first), check if dest has each one
    zfs list -H -t snapshot -o name -s creation -r "$src" 2>/dev/null \
        | grep "@${SNAPSHOT_PREFIX}" \
        | tac \
        | while read -r snap; do
            name="${snap##*@}"
            if zfs list "${dst}@${name}" >/dev/null 2>&1; then
                echo "$name"
                return
            fi
        done
}

# ── Destination: pool/dataset or file path ────────────────────────────────────
dest_is_zfs() {
    # Returns true if DEST looks like a zpool/dataset (not a filesystem path)
    [[ "$1" != /* ]]
}

# ── CMD: create ───────────────────────────────────────────────────────────────
cmd_create() {
    local dest="" mode="system-apps" label=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dest)  dest="$2";  shift 2 ;;
            --mode)  mode="$2";  shift 2 ;;
            --label) label="$2"; shift 2 ;;
            *) usage ;;
        esac
    done

    [ -n "$dest" ] || usage
    [ "$mode" = "system-apps" ] || [ "$mode" = "full" ] || \
        die "Unknown mode '$mode'. Use: system-apps or full"

    local pool
    pool=$(main_pool) || die "No PinneOS-managed ZFS pool found."

    local snap_name="${SNAPSHOT_PREFIX}-${TIMESTAMP}"
    [ -n "$label" ] && snap_name="${SNAPSHOT_PREFIX}-${label}-${TIMESTAMP}"

    log "Starting $mode backup → $dest (snapshot: $snap_name)"

    local datasets
    datasets=$(datasets_for_mode "$pool" "$mode")

    for dataset in $datasets; do
        # Skip datasets that don't exist
        zfs list "$dataset" >/dev/null 2>&1 || { log "Skipping $dataset (not found)"; continue; }

        log "Snapshotting $dataset..."
        zfs snapshot -r "${dataset}@${snap_name}"

        if dest_is_zfs "$dest"; then
            local dest_dataset="${dest}/${dataset##*/}"
            local common
            common=$(last_common_snapshot "$dataset" "$dest_dataset")

            if [ -n "$common" ]; then
                log "Incremental send: $dataset (@$common → @$snap_name)..."
                zfs send -Rp -i "@${common}" "${dataset}@${snap_name}" \
                    | zfs receive -F "$dest_dataset"
            else
                log "Full send: $dataset → $dest_dataset..."
                # Ensure parent dataset exists on destination
                zfs create -p "${dest_dataset%/*}" 2>/dev/null || true
                zfs send -Rp "${dataset}@${snap_name}" \
                    | zfs receive -F "$dest_dataset"
            fi

            # Tag backup metadata on destination
            zfs set "pinneos:backup-source=${pool}" "$dest_dataset"
            zfs set "pinneos:backup-mode=${mode}"  "$dest_dataset"
            zfs set "pinneos:backup-time=${TIMESTAMP}" "${dest_dataset}@${snap_name}"

        else
            # File-based backup (zfs send → compressed file)
            mkdir -p "$dest"
            local out_file="${dest}/${dataset##*/}-${snap_name}.zfs.zst"
            log "File send: $dataset → $out_file..."
            zfs send -Rp "${dataset}@${snap_name}" | zstd -T0 -3 > "$out_file"
            sha256sum "$out_file" > "${out_file}.sha256"
        fi

        log "$dataset — done."
    done

    log "Backup complete. Snapshot: $snap_name"

    # Prune old snapshots automatically
    cmd_prune --dest "$dest" --keep "$KEEP_SNAPSHOTS" --pool "$pool" --mode "$mode"
}

# ── CMD: list ─────────────────────────────────────────────────────────────────
cmd_list() {
    local dest=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dest) dest="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    [ -n "$dest" ] || usage

    if dest_is_zfs "$dest"; then
        echo "Backups at $dest:"
        echo "─────────────────────────────────────────────────────"
        zfs list -t snapshot -o name,creation,used -s creation -r "$dest" 2>/dev/null \
            | grep "$SNAPSHOT_PREFIX" \
            | column -t \
            || echo "(none found)"
    else
        echo "Backups at $dest:"
        ls -lh "${dest}"/*.zfs.zst 2>/dev/null || echo "(none found)"
    fi
}

# ── CMD: prune ────────────────────────────────────────────────────────────────
cmd_prune() {
    local dest="" keep="$KEEP_SNAPSHOTS" pool="" mode="system-apps"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dest) dest="$2";  shift 2 ;;
            --keep) keep="$2";  shift 2 ;;
            --pool) pool="$2";  shift 2 ;;
            --mode) mode="$2";  shift 2 ;;
            *) usage ;;
        esac
    done

    [ -z "$pool" ] && pool=$(main_pool)
    local datasets
    datasets=$(datasets_for_mode "$pool" "$mode")

    for dataset in $datasets; do
        local snaps
        snaps=$(zfs list -H -t snapshot -o name -S creation "$dataset" 2>/dev/null \
            | grep "@${SNAPSHOT_PREFIX}" || true)
        local count
        count=$(echo "$snaps" | grep -c . || true)
        if [ "$count" -gt "$keep" ]; then
            echo "$snaps" | tail -n "+$((keep + 1))" | while read -r old; do
                log "Pruning old snapshot: $old"
                zfs destroy "$old"
            done
        fi
    done
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
CMD="${1:-}"
shift || true

case "$CMD" in
    create) cmd_create "$@" ;;
    list)   cmd_list   "$@" ;;
    prune)  cmd_prune  "$@" ;;
    *)      usage ;;
esac
