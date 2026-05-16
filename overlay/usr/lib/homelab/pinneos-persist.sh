#!/bin/sh
# Mount the PINNEOS_PERSIST partition.
# Runs early in boot. If PINNEOS_PERSIST doesn't exist (live ISO boot),
# exits silently — nothing to do.
# Note: grubenv is on PINNEOS_EFI (FAT32); boot_tries reset is done by boot-success.sh.

PERSIST_MNT="/run/pinneos/persist"

mkdir -p "$PERSIST_MNT"

findfs LABEL=PINNEOS_PERSIST >/dev/null 2>&1 || exit 0

mount -L PINNEOS_PERSIST "$PERSIST_MNT" || exit 0
