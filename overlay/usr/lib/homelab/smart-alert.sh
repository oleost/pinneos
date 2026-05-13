#!/usr/bin/env bash
# Called by smartd when a disk failure or temperature warning is detected.
# Logs to journal. If Gotify is configured, sends a push notification.
set -euo pipefail

DEVICE="${SMARTD_DEVICE:-unknown}"
MESSAGE="${SMARTD_MESSAGE:-SMART alert}"
FAILTYPE="${SMARTD_FAILTYPE:-unknown}"

logger -t pinneos-smart -p daemon.err "SMART ALERT on $DEVICE ($FAILTYPE): $MESSAGE"

GOTIFY_URL_FILE="/etc/homelab/gotify-url"
GOTIFY_TOKEN_FILE="/etc/homelab/gotify-token"

if [ -f "$GOTIFY_URL_FILE" ] && [ -f "$GOTIFY_TOKEN_FILE" ]; then
    GOTIFY_URL=$(cat "$GOTIFY_URL_FILE")
    GOTIFY_TOKEN=$(cat "$GOTIFY_TOKEN_FILE")
    curl -s -X POST "${GOTIFY_URL}/message" \
        -H "X-Gotify-Key: ${GOTIFY_TOKEN}" \
        -F "title=PinneOS: Disk Warning on ${DEVICE}" \
        -F "message=${MESSAGE}" \
        -F "priority=8" || true
fi
