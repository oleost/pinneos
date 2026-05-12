#!/bin/bash
# PinneOS ISO build script — runs inside the Docker build container.
# Usage: docker run ... pinneos-builder [version]

set -euo pipefail
VERSION="${1:-dev}"
WORK="/tmp/pinneos-work"
PROFILE="${WORK}-profile"
OUT="/out"

echo "==> PinneOS build starting (version: $VERSION)"

# Import the archzfs signing key so pacman trusts the repo during build
echo "==> Setting up archzfs signing key..."
pacman-key --init
pacman-key --populate
# Key for archzfs.com
pacman-key --recv-keys DDF7DB817396A49B2A2723F7403BD972F75D9D76 2>/dev/null || \
    curl -s https://archzfs.com/archzfs.gpg | pacman-key --add -
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76

# Start from archiso's releng profile (provides working GRUB/EFI/syslinux configs)
echo "==> Preparing profile..."
cp -r /usr/share/archiso/configs/releng "${PROFILE}"

# Override with our customisations (packages, pacman.conf, profiledef, scripts)
rsync -a /profile/ "${PROFILE}/"

# Merge our runtime overlay into airootfs (systemd units, scripts, config)
cp -a /overlay/. "${PROFILE}/airootfs/"

# Stamp the version into the live image
echo "$VERSION" > "${PROFILE}/airootfs/etc/pinneos-version"

echo "==> Running mkarchiso (first run downloads ~1 GB of packages — takes 10-20 min)..."
mkarchiso -v -w "${WORK}" -o "${OUT}" "${PROFILE}"

# Rename output to our naming convention
find "${OUT}" -maxdepth 1 -name "*.iso" \
    -exec mv {} "${OUT}/pinneos-${VERSION}-x86_64.iso" \;

echo "==> Done: ${OUT}/pinneos-${VERSION}-x86_64.iso"

# ── Build A/B USB image (.img.zst) ────────────────────────────────────────────
echo "==> Building A/B USB image..."
ISO="${OUT}/pinneos-${VERSION}-x86_64.iso"
IMG_RAW="${OUT}/pinneos-${VERSION}-x86_64.img"
IMG_ZST="${IMG_RAW}.zst"

# Partition byte offsets (all in MiB, converted below):
#   p1 bios_boot:      2–3 MiB   (1 MiB, no filesystem)
#   p2 PINNEOS_EFI:    3–515 MiB (512 MiB, FAT32)
#   p3 PINNEOS_A:    515–2563 MiB (2048 MiB, ext4)
#   p4 PINNEOS_B:   2563–4611 MiB (2048 MiB, ext4)
#   p5 PINNEOS_PERSIST: 4611 MiB → end (689 MiB, F2FS)
MiB=$((1024 * 1024))

echo "    Allocating 5300 MiB raw image..."
dd if=/dev/zero of="${IMG_RAW}" bs=1M count=5300 status=progress conv=fsync

# In Docker --privileged the container sees the HOST /dev. The host may already
# be using loop0-N (snap, docker overlay2, etc.), so losetup -f picks a high
# number whose /dev node hasn't been created yet.  We query which number the
# kernel considers free, create that node, then attach — repeating on race.
attach_loop() {
    # attach_loop FILE [extra losetup args...]
    # Uses losetup -f --show which calls LOOP_CTL_GET_FREE (dynamic kernel allocation).
    # If it fails because the /dev/loopN node is missing ("is lost"), we create it and retry.
    local file="$1"; shift
    local dev num tries=10 errf
    errf="/tmp/_losetup_err_$$"

    while [ "${tries}" -gt 0 ]; do
        dev=$(losetup -f --show "$@" "${file}" 2>"${errf}")
        if [ -n "${dev}" ]; then
            rm -f "${errf}"; echo "${dev}"; return 0
        fi
        # Create the missing device node mentioned in the error and retry
        if grep -q 'is lost' "${errf}" 2>/dev/null; then
            local lost
            lost=$(grep -oE '/dev/loop[0-9]+' "${errf}" | head -1)
            if [ -n "${lost}" ]; then
                num="${lost##*/loop}"
                mknod "${lost}" b 7 "${num}" 2>/dev/null || true
            fi
        fi
        tries=$(( tries - 1 ))
    done
    cat "${errf}" >&2 2>/dev/null; rm -f "${errf}"
    echo "ERROR: could not attach loop device for ${file}" >&2; return 1
}

# Full-disk loop device — used only for partitioning and GRUB BIOS install.
DISK_LOOP=$(attach_loop "${IMG_RAW}")

EFI_LOOP="" SLOTA_LOOP="" SLOTB_LOOP="" PERSIST_LOOP=""

ISO_MNT="/tmp/pinneos-iso-mnt"
EFI_MNT="/tmp/pinneos-efi-mnt"
SLOT_A_MNT="/tmp/pinneos-slota-mnt"
PERSIST_MNT="/tmp/pinneos-persist-mnt"
mkdir -p "${ISO_MNT}" "${EFI_MNT}" "${SLOT_A_MNT}" "${PERSIST_MNT}"

cleanup_img() {
    for mnt in "${ISO_MNT}" "${EFI_MNT}" "${SLOT_A_MNT}" "${PERSIST_MNT}"; do
        mountpoint -q "${mnt}" 2>/dev/null && umount "${mnt}" 2>/dev/null || true
    done
    for ldev in "${EFI_LOOP:-}" "${SLOTA_LOOP:-}" "${SLOTB_LOOP:-}" \
                "${PERSIST_LOOP:-}" "${DISK_LOOP:-}"; do
        [ -n "${ldev}" ] && losetup -d "${ldev}" 2>/dev/null || true
    done
}
trap cleanup_img EXIT

parted -s "${DISK_LOOP}" \
    mklabel gpt \
    mkpart bios_boot          2MiB    3MiB \
    mkpart PINNEOS_EFI fat32  3MiB  515MiB \
    mkpart PINNEOS_A   ext4 515MiB 2563MiB \
    mkpart PINNEOS_B   ext4 2563MiB 4611MiB \
    mkpart PINNEOS_PERSIST ext4 4611MiB 100% \
    set 1 bios_grub on \
    set 2 esp on

# Create one loop device per partition using explicit byte offsets.
# This is the only approach that works reliably inside Docker --privileged.
EFI_LOOP=$(    attach_loop "${IMG_RAW}" -o $((   3 * MiB)) --sizelimit $((  512 * MiB)))
SLOTA_LOOP=$(  attach_loop "${IMG_RAW}" -o $((  515 * MiB)) --sizelimit $((2048 * MiB)))
SLOTB_LOOP=$(  attach_loop "${IMG_RAW}" -o $((2563 * MiB)) --sizelimit $((2048 * MiB)))
PERSIST_LOOP=$(attach_loop "${IMG_RAW}" -o $((4611 * MiB)) --sizelimit $((  689 * MiB)))

echo "    Formatting partitions..."
mkfs.fat  -F32 -n PINNEOS_EFI  "${EFI_LOOP}"
mkfs.ext4 -L PINNEOS_A -q -F   "${SLOTA_LOOP}"
mkfs.ext4 -L PINNEOS_B -q -F   "${SLOTB_LOOP}"
mkfs.f2fs -l PINNEOS_PERSIST -f "${PERSIST_LOOP}"

# Slot B only needs formatting — detach it now to free a loop slot
losetup -d "${SLOTB_LOOP}"; SLOTB_LOOP=""

# Mount ISO via explicit loop device (avoids "mount -o loop" hitting the same node issue)
ISO_LOOP=$(attach_loop "${ISO}" -r)
mount "${ISO_LOOP}" "${ISO_MNT}"

echo "    Copying live system to Slot A..."
mount "${SLOTA_LOOP}" "${SLOT_A_MNT}"
mkdir -p "${SLOT_A_MNT}/pinneos/x86_64"
cp "${ISO_MNT}/pinneos/boot/x86_64/vmlinuz-linux-lts"       "${SLOT_A_MNT}/vmlinuz"
cp "${ISO_MNT}/pinneos/boot/x86_64/initramfs-linux-lts.img" "${SLOT_A_MNT}/initramfs.img"
cp "${ISO_MNT}/pinneos/x86_64/airootfs.sfs"                 "${SLOT_A_MNT}/pinneos/x86_64/airootfs.sfs"
[ -f "${ISO_MNT}/pinneos/x86_64/airootfs.sha512" ] && \
    cp "${ISO_MNT}/pinneos/x86_64/airootfs.sha512" "${SLOT_A_MNT}/pinneos/x86_64/"
sync
umount "${SLOT_A_MNT}"; losetup -d "${SLOTA_LOOP}"; SLOTA_LOOP=""
umount "${ISO_MNT}";    losetup -d "${ISO_LOOP}";   ISO_LOOP=""

echo "    Installing GRUB (UEFI + BIOS)..."
mount "${EFI_LOOP}" "${EFI_MNT}"

# UEFI: copies files only, no EFI variable writes (--removable --no-nvram)
grub-install \
    --target=x86_64-efi \
    --efi-directory="${EFI_MNT}" \
    --boot-directory="${EFI_MNT}/grub" \
    --removable \
    --no-nvram \
    --recheck \
    "${DISK_LOOP}"

# BIOS: writes boot record to MBR + core.img to bios_boot partition via DISK_LOOP
grub-install \
    --target=i386-pc \
    --boot-directory="${EFI_MNT}/grub" \
    --recheck \
    "${DISK_LOOP}"

cp /grub/grub.cfg.template "${EFI_MNT}/grub/grub.cfg"
sync
umount "${EFI_MNT}"; losetup -d "${EFI_LOOP}"; EFI_LOOP=""
losetup -d "${DISK_LOOP}"; DISK_LOOP=""

echo "    Initializing grubenv (boot_slot=A, boot_tries=0)..."
mount "${PERSIST_LOOP}" "${PERSIST_MNT}"
grub-editenv "${PERSIST_MNT}/grubenv" create
grub-editenv "${PERSIST_MNT}/grubenv" set boot_slot=A
grub-editenv "${PERSIST_MNT}/grubenv" set boot_tries=0
sync
umount "${PERSIST_MNT}"; losetup -d "${PERSIST_LOOP}"; PERSIST_LOOP=""
trap - EXIT

echo "    Compressing to .img.zst (zstd -9)..."
zstd -T0 -9 --rm "${IMG_RAW}" -o "${IMG_ZST}"

echo ""
echo "==> Build complete:"
echo "    ISO: ${OUT}/pinneos-${VERSION}-x86_64.iso"
echo "    IMG: ${OUT}/pinneos-${VERSION}-x86_64.img.zst"
