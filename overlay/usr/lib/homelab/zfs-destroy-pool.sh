#!/bin/sh
# Safely destroy a ZFS pool.
#
# Stops zfs-zed (holds /dev/zfs open) and the systemd <pool>.mount unit
# before attempting destroy, to avoid "pool is busy" errors.
# Restarts zfs-zed afterwards if other pools remain.

set -e
pool="$1"
[ -n "$pool" ] || { echo "Usage: zfs-destroy-pool.sh <pool>"; exit 1; }

log() { echo "$*"; }

# Verify pool exists
zpool list "$pool" >/dev/null 2>&1 || { echo "Pool not found: $pool"; exit 1; }

log "Stopping zfs-zed (releases /dev/zfs handles)..."
systemctl stop zfs-zed.service 2>/dev/null || true

log "Stopping systemd mount unit for $pool (if managed by systemd)..."
systemctl stop "${pool}.mount" 2>/dev/null || true

log "Unmounting all ZFS datasets..."
zfs unmount -a 2>/dev/null || true

log "Destroying pool $pool..."
zpool destroy "$pool"

log "Pool $pool destroyed."

# Restart zed if any pools remain
if zpool list >/dev/null 2>&1 && [ -n "$(zpool list -H -o name 2>/dev/null)" ]; then
    log "Restarting zfs-zed for remaining pools..."
    systemctl start zfs-zed.service 2>/dev/null || true
fi
