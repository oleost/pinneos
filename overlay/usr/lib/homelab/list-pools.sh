#!/bin/sh
# Output: pool<TAB>managed_value  — one line per pool
# Called by Cockpit JS pool picker (fetchZfsPools).
export PATH=/usr/bin:/usr/sbin:/sbin:/bin
zpool list -H -o name 2>/dev/null | while IFS= read -r p; do
    v=$(zfs get -H -o value pinneos:managed "$p" 2>/dev/null)
    printf '%s\t%s\n' "$p" "$v"
done
