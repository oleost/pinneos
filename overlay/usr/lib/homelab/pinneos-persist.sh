#!/bin/sh
# Mount the PINNEOS_PERSIST partition and reset the GRUB boot counter.
# Runs early in boot. If PINNEOS_PERSIST doesn't exist (live ISO boot),
# exits silently — nothing to do.

PERSIST_MNT="/run/pinneos/persist"
GRUBENV="$PERSIST_MNT/grubenv"

mkdir -p "$PERSIST_MNT"

findfs LABEL=PINNEOS_PERSIST >/dev/null 2>&1 || exit 0

mount -L PINNEOS_PERSIST "$PERSIST_MNT" || exit 0

# We booted successfully — reset the GRUB try counter so rollback doesn't trigger.
grub-editenv "$GRUBENV" set boot_tries=0
