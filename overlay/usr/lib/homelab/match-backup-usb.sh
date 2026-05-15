#!/bin/sh
# Called by udev with the kernel device name (e.g. "sdb").
# Exits 0 if the device matches the registered backup USB, 1 otherwise.
# Uses disk serial number — partition UUIDs are identical on cloned USBs.

SERIAL_FILE="/etc/homelab/backup-usb-serial"
DISK="/dev/$1"

[ -f "$SERIAL_FILE" ] || exit 1
expected=$(cat "$SERIAL_FILE")
[ -z "$expected" ] && exit 1

actual=$(udevadm info --query=property "$DISK" 2>/dev/null \
    | awk -F= '/^ID_SERIAL_SHORT=/{print $2; exit}')
[ "$actual" = "$expected" ] && exit 0
exit 1
