#!/bin/sh
# Called by udev when a PINNEOS_A partition is added (i.e. a PinneOS USB is plugged in).
# Resolves the parent disk and starts the mirror sync service for that disk.
#
# Argument: kernel device name of the partition (e.g. "sdb3"), passed as %k by udev.
#
# We trigger on the partition event rather than the disk event because at disk-add
# time the kernel has not yet enumerated child partitions, making it impossible to
# confirm via lsblk that the disk is a PinneOS USB.

part="/dev/$1"
disk=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
[ -n "$disk" ] || exit 0

systemctl start "pinneos-usb-mirror-sync@${disk}.service"
