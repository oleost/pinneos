#!/usr/bin/env bash
# Start a scrub on all managed ZFS pools and wait for completion.
set -euo pipefail

MANAGED_POOLS=$(zpool list -H -o name 2>/dev/null | while read -r pool; do
    val=$(zfs get -H -o value pinneos:managed "$pool" 2>/dev/null)
    [ "$val" = "yes" ] && echo "$pool"
done)

if [ -z "$MANAGED_POOLS" ]; then
    echo "pinneos-zfs-scrub: no managed pools found, skipping"
    exit 0
fi

for pool in $MANAGED_POOLS; do
    echo "pinneos-zfs-scrub: starting scrub on $pool"
    zpool scrub "$pool"
done

# Wait for all scrubs to finish
for pool in $MANAGED_POOLS; do
    while zpool status "$pool" | grep -q "scrub in progress"; do
        sleep 60
    done
    STATUS=$(zpool status "$pool" | grep "scan:" | head -1)
    echo "pinneos-zfs-scrub: $pool — $STATUS"

    if zpool status "$pool" | grep -q "errors: No known data errors"; then
        echo "pinneos-zfs-scrub: $pool — OK"
    else
        echo "pinneos-zfs-scrub: $pool — ERRORS DETECTED" >&2
        zpool status "$pool" >&2
        exit 1
    fi
done
