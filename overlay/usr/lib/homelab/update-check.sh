#!/bin/sh
# Check GitHub Releases for a newer PinneOS image.
# Writes result to a state file read by the Cockpit plugin / Homepage widget.

. /etc/homelab/config

STATE_FILE="/run/pinneos/update-available"
current=$(cat /etc/homelab/version 2>/dev/null || echo "unknown")

manifest=$(curl -sf --max-time 10 "$UPDATE_CHECK_URL") || exit 0
latest=$(echo "$manifest" | jq -r '.tag_name // empty')

[ -n "$latest" ] || exit 0

if [ "$latest" != "$current" ]; then
    echo "$latest" > "$STATE_FILE"
else
    rm -f "$STATE_FILE"
fi
