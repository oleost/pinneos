#!/bin/sh
# Import PinneOS-managed ZFS pools at boot.
# Uses scan mode (not cache) for reliability across hardware changes.

. /etc/homelab/config

log() { logger -t pinneos-zfs "$*"; }

log "Scanning for ZFS pools..."

# Wait for udev to settle (devices to be enumerated)
udevadm settle --timeout=30

# Import all available pools.
# -f: force import even if hostid differs (expected when booting a rebuilt ISO)
# -N: do not mount datasets yet
# -a: all available pools
zpool import -f -a -N 2>/dev/null || true

zfs_mounted=0

# Find pools tagged as PinneOS-managed and mount their datasets
for pool in $(zpool list -H -o name 2>/dev/null); do
    managed=$(zfs get -H -o value "$ZFS_MANAGED_PROPERTY" "$pool" 2>/dev/null)
    if [ "$managed" = "yes" ]; then
        # Check for native encryption — if enabled, defer mounting until user unlocks via Cockpit
        enc=$(zfs get -H -o value encryption "$pool" 2>/dev/null)
        if [ "$enc" != "off" ] && [ "$enc" != "-" ]; then
            log "Pool $pool is encrypted — deferring mount, waiting for Cockpit unlock"
            mkdir -p /run/pinneos
            printf '%s' "$pool" > /run/pinneos/unlock-needed
            break
        fi

        log "Mounting datasets on pool: $pool"
        zfs mount -a 2>/dev/null || true

        # Bind-mount apps dataset to Docker data directory
        apps_mp=$(zfs get -H -o value mountpoint "$pool/$DATASET_APPS" 2>/dev/null)
        if [ -n "$apps_mp" ] && [ "$apps_mp" != "none" ]; then
            mkdir -p "$DOCKER_DATA_DIR"
            mount --bind "$apps_mp" "$DOCKER_DATA_DIR"
            zfs_mounted=1
        fi

        # Set storage dataset ownership for app containers (PUID=1000 / PGID=1000).
        # Only top-level dirs — don't recurse over potentially TBs of user data.
        storage_mp=$(zfs get -H -o value mountpoint "${pool}/${DATASET_STORAGE}" 2>/dev/null)
        if [ -n "$storage_mp" ] && [ "$storage_mp" != "none" ] && [ -d "$storage_mp" ]; then
            chown homelab:homelab "$storage_mp"
            find "$storage_mp" -maxdepth 1 -mindepth 1 -type d \
                -exec chown homelab:homelab {} \;
        fi

        log "Pool $pool ready."
        break
    fi
done

# No ZFS pool available — mount a tmpfs so Docker's overlay2 driver works.
# The live root is already an overlayfs (squashfs+tmpfs); overlay2-on-overlayfs
# is not supported, but overlay2-on-tmpfs is.
if [ "$zfs_mounted" = "0" ]; then
    log "No managed ZFS pool found — mounting tmpfs at $DOCKER_DATA_DIR"
    mkdir -p "$DOCKER_DATA_DIR"
    mount -t tmpfs -o mode=0710,uid=0,gid=0 tmpfs "$DOCKER_DATA_DIR"
fi
