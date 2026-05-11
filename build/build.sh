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

# Layout: 1MB bios_boot + 512MB EFI + 2GB Slot A + 2GB Slot B + ~700MB Persist
echo "    Allocating 5300 MiB raw image..."
dd if=/dev/zero of="${IMG_RAW}" bs=1M count=5300 status=progress conv=fsync

# Attach loop device first, then partition it (more reliable than -fP on the raw file)
LODEV=$(losetup -f --show "${IMG_RAW}")

parted -s "${LODEV}" \
    mklabel gpt \
    mkpart bios_boot        2MiB    3MiB \
    mkpart PINNEOS_EFI fat32  3MiB  515MiB \
    mkpart PINNEOS_A   ext4 515MiB  2563MiB \
    mkpart PINNEOS_B   ext4 2563MiB 4611MiB \
    mkpart PINNEOS_PERSIST ext4 4611MiB 100% \
    set 1 bios_grub on \
    set 2 esp on

# Force kernel to create partition device nodes
partx -a "${LODEV}" 2>/dev/null || partprobe "${LODEV}" 2>/dev/null || true
sleep 1

ISO_MNT="/tmp/pinneos-iso-mnt"
EFI_MNT="/tmp/pinneos-efi-mnt"
SLOT_A_MNT="/tmp/pinneos-slota-mnt"
PERSIST_MNT="/tmp/pinneos-persist-mnt"
mkdir -p "${ISO_MNT}" "${EFI_MNT}" "${SLOT_A_MNT}" "${PERSIST_MNT}"

cleanup_img() {
    for mnt in "${ISO_MNT}" "${EFI_MNT}" "${SLOT_A_MNT}" "${PERSIST_MNT}"; do
        mountpoint -q "${mnt}" 2>/dev/null && umount "${mnt}" 2>/dev/null || true
    done
    [ -n "${LODEV:-}" ] && losetup -d "${LODEV}" 2>/dev/null || true
}
trap cleanup_img EXIT

EFI="${LODEV}p2"
SLOT_A="${LODEV}p3"
SLOT_B="${LODEV}p4"
PERSIST="${LODEV}p5"

echo "    Formatting partitions..."
mkfs.fat  -F32 -n PINNEOS_EFI  "${EFI}"
mkfs.ext4 -L PINNEOS_A -q -F   "${SLOT_A}"
mkfs.ext4 -L PINNEOS_B -q -F   "${SLOT_B}"
mkfs.f2fs -l PINNEOS_PERSIST -f "${PERSIST}"

mount -o loop,ro "${ISO}" "${ISO_MNT}"

echo "    Copying live system to Slot A..."
mount "${SLOT_A}" "${SLOT_A_MNT}"
mkdir -p "${SLOT_A_MNT}/pinneos/x86_64"
cp "${ISO_MNT}/pinneos/boot/x86_64/vmlinuz-linux-lts"       "${SLOT_A_MNT}/vmlinuz"
cp "${ISO_MNT}/pinneos/boot/x86_64/initramfs-linux-lts.img" "${SLOT_A_MNT}/initramfs.img"
cp "${ISO_MNT}/pinneos/x86_64/airootfs.sfs"                 "${SLOT_A_MNT}/pinneos/x86_64/airootfs.sfs"
[ -f "${ISO_MNT}/pinneos/x86_64/airootfs.sha512" ] && \
    cp "${ISO_MNT}/pinneos/x86_64/airootfs.sha512" "${SLOT_A_MNT}/pinneos/x86_64/"
sync
umount "${SLOT_A_MNT}"

echo "    Installing GRUB (UEFI + BIOS)..."
mount "${EFI}" "${EFI_MNT}"

grub-install \
    --target=x86_64-efi \
    --efi-directory="${EFI_MNT}" \
    --boot-directory="${EFI_MNT}/grub" \
    --removable \
    --no-nvram \
    --recheck \
    "${LODEV}"

grub-install \
    --target=i386-pc \
    --boot-directory="${EFI_MNT}/grub" \
    --recheck \
    "${LODEV}"

cp /grub/grub.cfg.template "${EFI_MNT}/grub/grub.cfg"
sync
umount "${EFI_MNT}"
umount "${ISO_MNT}"

echo "    Initializing grubenv (boot_slot=A, boot_tries=0)..."
mount "${PERSIST}" "${PERSIST_MNT}"
grub-editenv "${PERSIST_MNT}/grubenv" create
grub-editenv "${PERSIST_MNT}/grubenv" set boot_slot=A
grub-editenv "${PERSIST_MNT}/grubenv" set boot_tries=0
sync
umount "${PERSIST_MNT}"

losetup -d "${LODEV}"
LODEV=""
trap - EXIT

echo "    Compressing to .img.zst (zstd -9)..."
zstd -T0 -9 --rm "${IMG_RAW}" -o "${IMG_ZST}"

echo ""
echo "==> Build complete:"
echo "    ISO: ${OUT}/pinneos-${VERSION}-x86_64.iso"
echo "    IMG: ${OUT}/pinneos-${VERSION}-x86_64.img.zst"
