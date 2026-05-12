#!/bin/sh
# Called by udev with the kernel device name (e.g. "sdb").
# Exits 0 if the device matches the registered backup USB UUID, 1 otherwise.
# udev runs this as the PROGRAM for the rule and only fires RUN if exit 0.

UUID_FILE="/etc/homelab/backup-usb-uuid"
DISK="/dev/$1"

[ -f "$UUID_FILE" ] || exit 1

expected=$(cat "$UUID_FILE")
[ -z "$expected" ] && exit 1

# The stored UUID is a partition UUID (PINNEOS_A). Scan all partitions of the
# disk and match against any of them — the disk node itself has no filesystem UUID.
for part in $(lsblk -lpno NAME "$DISK" 2>/dev/null | grep -v "^${DISK}$"); do
    actual=$(blkid -o value -s UUID "$part" 2>/dev/null)
    [ "$actual" = "$expected" ] && exit 0
done
exit 1
