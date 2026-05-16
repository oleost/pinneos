#!/usr/bin/env bash
# PinneOS archiso profile definition

iso_name="pinneos"
iso_label="PINNEOS_LIVE"
iso_publisher="PinneOS <https://github.com/yourorg/pinneos>"
iso_application="PinneOS Live"
iso_version="${VERSION:-dev}"

# Install directory inside the ISO filesystem (affects boot paths)
install_dir="pinneos"

# Build a standard ISO (not a netboot or bootstrap tarball)
buildmodes=('iso')

# Hybrid BIOS + UEFI boot support.
# bios.syslinux.mbr: BIOS boot from USB (dd/etcher). Covers old hardware.
# bios.syslinux.eltorito: BIOS boot from ISO (VirtualBox optical drive).
# uefi.grub: UEFI boot (hardware from ~2012+).
# Custom syslinux configs in profile/syslinux/ point to vmlinuz-linux-lts.
bootmodes=('bios.syslinux' 'uefi.grub')

arch="x86_64"
pacman_conf="pacman.conf"

# SquashFS with fast zstd compression
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15' '-b' '1M' '-no-progress')

# File permissions for our scripts (must be executable)
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/usr/lib/homelab/pinneos-persist.sh"]="0:0:755"
  ["/usr/lib/homelab/zfs-import.sh"]="0:0:755"
  ["/usr/lib/homelab/zfs-encrypt.sh"]="0:0:755"
  ["/usr/lib/homelab/zfs-scrub.sh"]="0:0:755"
  ["/usr/lib/homelab/update.sh"]="0:0:755"
  ["/usr/lib/homelab/update-check.sh"]="0:0:755"
  ["/usr/lib/homelab/usb-mirror-sync.sh"]="0:0:755"
  ["/usr/lib/homelab/udev-mirror-trigger.sh"]="0:0:755"
  ["/usr/lib/homelab/boot-success.sh"]="0:0:755"
  ["/usr/lib/homelab/backup.sh"]="0:0:755"
  ["/usr/lib/homelab/restore.sh"]="0:0:755"
  ["/usr/lib/homelab/restore-browse.sh"]="0:0:755"
  ["/usr/lib/homelab/list-pools.sh"]="0:0:755"
  ["/usr/lib/homelab/smart-alert.sh"]="0:0:755"
  ["/usr/lib/homelab/generate-motd.sh"]="0:0:755"
  ["/usr/lib/homelab/wizard.py"]="0:0:755"
  ["/root/customize_airootfs.sh"]="0:0:755"
)
