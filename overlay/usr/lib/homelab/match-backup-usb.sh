#!/bin/sh
# Called by udev with the kernel device name (e.g. "sdb").
# Exits 0 if the device matches the registered backup USB UUID, 1 otherwise.
# udev runs this as the PROGRAM for the rule and only fires RUN if exit 0.

UUID_FILE="/etc/homelab/backup-usb-uuid"
DEVICE="/dev/$1"

[ -f "$UUID_FILE" ] || exit 1

expected=$(cat "$UUID_FILE")
[ -z "$expected" ] && exit 1

actual=$(blkid -o value -s UUID "$DEVICE" 2>/dev/null)
[ "$actual" = "$expected" ] && exit 0 || exit 1
