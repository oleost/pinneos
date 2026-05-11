#!/bin/bash
# pinneos-restore: Restore PinneOS datasets from a ZFS backup
#
# Usage:
#   restore.sh list   --source SOURCE_POOL_OR_PATH
#   restore.sh run    --source SOURCE [--snapshot NAME] --dest DEST_POOL
#                     [--mode system-apps|full]
#
# The restore command is intentionally available in Recovery Mode
# (no active pool needed) so it can be used after a hardware migration.
#
# After restore:
#   1. Run: zfs set pinneos:managed=yes DEST_POOL
#   2. Reboot — pinneos-zfs-import.service will import the restored pool

set -euo pipefail
. /etc/homelab/config 2>/dev/null || {
    # Config may not be mounted in recovery mode — use safe defaults
    ZFS_MANAGED_PROPERTY="pinneos:managed"
    DATASET_SYSTEM="system"
    DATASET_APPS="apps"
    DATASET_STORAGE="storage"
}

log()  { logger -t pinneos-restore "$*" 2>/dev/null; echo "[restore] $*"; }
warn() { echo "[restore] WARNING: $*"; }
die()  { echo "[restore] ERROR: $*" >&2; exit 1; }

usage() {
    cat << 'EOF'
Usage:
  restore.sh list --source POOL_OR_PATH
  restore.sh run  --source POOL_OR_PATH [--snapshot NAME] \
                  --dest DEST_POOL [--mode system-apps|full]

Options:
  --source    Backup source: ZFS pool/dataset or directory with .zfs.zst files
  --snapshot  Snapshot name to restore (default: most recent)
  --dest      Destination ZFS pool (must already exist, will be populated)
  --mode      system-apps (default) or full (includes storage/)

Examples:
  # List available backups
  restore.sh list --source backup-pool

  # Restore system+apps to a new pool
  restore.sh run --source backup-pool --dest new-tank

  # Restore a specific snapshot
  restore.sh run --source backup-pool --snapshot pinneos-backup-2024-01-01T12:00:00Z \
                 --dest new-tank --mode full
EOF
    exit 1
}

source_is_zfs() { [[ "$1" != /* ]]; }

# ── List available backups at source ─────────────────────────────────────────
cmd_list() {
    local source=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) source="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    [ -n "$source" ] || usage

    if source_is_zfs "$source"; then
        echo "Available backup snapshots at: $source"
        echo "─────────────────────────────────────────────────────────────"

        local found=0
        for dataset in system apps storage; do
            local ds="${source}/${dataset}"
            if zfs list "$ds" >/dev/null 2>&1; then
                echo ""
                echo "  Dataset: $ds"
                zfs list -H -t snapshot -o name,creation,used -S creation "$ds" 2>/dev/null \
                    | grep "pinneos-backup" \
                    | awk '{printf "    %-55s  %s  %s\n", $1, $2, $3}' \
                    || echo "    (no backup snapshots)"
                found=1
            fi
        done

        [ "$found" -eq 0 ] && echo "  (no backup datasets found at $source)"

        echo ""
        echo "Backup metadata:"
        zfs get -H pinneos:backup-source,pinneos:backup-mode,pinneos:backup-time \
            "$source" 2>/dev/null | awk '{print "  "$2": "$3}' || true
    else
        echo "Available backup files at: $source"
        ls -lh "${source}"/*.zfs.zst 2>/dev/null | awk '{print "  "$NF, $5}' \
            || echo "  (none found)"
    fi
}

# ── Run a restore ─────────────────────────────────────────────────────────────
cmd_run() {
    local source="" snapshot="" dest="" mode="system-apps"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)   source="$2";   shift 2 ;;
            --snapshot) snapshot="$2"; shift 2 ;;
            --dest)     dest="$2";     shift 2 ;;
            --mode)     mode="$2";     shift 2 ;;
            *) usage ;;
        esac
    done

    [ -n "$source" ] || usage
    [ -n "$dest"   ] || usage
    [ "$mode" = "system-apps" ] || [ "$mode" = "full" ] || \
        die "Unknown mode. Use: system-apps or full"

    # Verify destination pool exists
    zpool list "$dest" >/dev/null 2>&1 || \
        die "Destination pool '$dest' not found. Create it first with: zpool create $dest ..."

    # Determine which datasets to restore
    local datasets=("$DATASET_SYSTEM" "$DATASET_APPS")
    [ "$mode" = "full" ] && datasets+=("$DATASET_STORAGE")

    log "Restore starting: $source → $dest (mode: $mode)"
    echo ""
    echo "  Source:      $source"
    echo "  Destination: $dest"
    echo "  Mode:        $mode (datasets: ${datasets[*]})"
    echo ""

    for dataset in "${datasets[@]}"; do
        local src_ds="${source}/${dataset}"
        local dst_ds="${dest}/${dataset}"

        if source_is_zfs "$source"; then
            # ZFS pool/dataset source
            if ! zfs list "$src_ds" >/dev/null 2>&1; then
                warn "Source dataset $src_ds not found — skipping."
                continue
            fi

            # Pick snapshot to restore from
            local snap="$snapshot"
            if [ -z "$snap" ]; then
                snap=$(zfs list -H -t snapshot -o name -S creation "$src_ds" 2>/dev/null \
                    | grep "pinneos-backup" \
                    | head -1 \
                    | sed 's/.*@//')
                [ -n "$snap" ] || die "No backup snapshots found on $src_ds"
                log "Using most recent snapshot: $snap"
            fi

            # Verify snapshot exists
            zfs list "${src_ds}@${snap}" >/dev/null 2>&1 || \
                die "Snapshot '${src_ds}@${snap}' not found."

            echo "  Restoring $dataset from @${snap}..."

            # Warn if destination dataset already exists
            if zfs list "$dst_ds" >/dev/null 2>&1; then
                warn "$dst_ds already exists and will be overwritten."
                read -rp "  Continue? [y/N] " ans
                [ "$ans" = "y" ] || { log "Skipped $dataset."; continue; }
            fi

            zfs send -Rp "${src_ds}@${snap}" | zfs receive -F "$dst_ds"

        else
            # File-based source
            local snap="$snapshot"
            local file

            if [ -n "$snap" ]; then
                file="${source}/${dataset}-${snap}.zfs.zst"
            else
                # Find the most recent file for this dataset
                file=$(ls -t "${source}/${dataset}-pinneos-backup-"*.zfs.zst 2>/dev/null \
                    | head -1)
                [ -n "$file" ] || { warn "No backup file for $dataset — skipping."; continue; }
                log "Using most recent file: $(basename "$file")"
            fi

            [ -f "$file" ] || die "Backup file not found: $file"

            # Verify checksum if available
            if [ -f "${file}.sha256" ]; then
                echo "  Verifying checksum for $(basename "$file")..."
                sha256sum -c "${file}.sha256" --status || \
                    die "Checksum mismatch — backup file may be corrupted."
            fi

            echo "  Restoring $dataset from $(basename "$file")..."
            zstd -d -T0 -c "$file" | zfs receive -F "$dst_ds"
        fi

        log "$dataset — restored."
    done

    echo ""
    echo "  ✓ Restore complete."
    echo ""
    echo "  Next steps:"
    echo "    1. Mark the pool as PinneOS-managed:"
    echo "       zfs set ${ZFS_MANAGED_PROPERTY}=yes $dest"
    echo ""
    echo "    2. If this is a new main pool, update GRUB to use it."
    echo "       (Or use the Cockpit ZFS panel → 'Set as main pool')"
    echo ""
    echo "    3. Reboot."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
CMD="${1:-}"
shift || true

case "$CMD" in
    list) cmd_list "$@" ;;
    run)  cmd_run  "$@" ;;
    *)    usage ;;
esac
