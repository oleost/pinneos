# Development

## Prerequisites

- Docker (for reproducible builds)
- `make`
- A USB stick (8 GB+) or QEMU for testing

## Build the ISO

```bash
cd build

# 1. Build the Docker build container (one-time, ~2 min)
make build

# 2. Build the ISO (~20-30 min first time, ~10-15 min after Docker layer cache)
make image VERSION=0.1.0
# Output: ../release/pinneos-0.1.0-x86_64.iso

# 3. Test in QEMU (no hardware needed)
make qemu VERSION=0.1.0
# Cockpit: http://localhost:9090
# Dockge:  http://localhost:5001

# 4. Write to USB (Linux/macOS)
make write DEVICE=/dev/sdX VERSION=0.1.0
```

**Windows/macOS:** Use Rufus (**DD Image mode**) or BalenaEtcher.

## Project structure

```
build/
  Dockerfile              Build environment (archlinux + archiso)
  build.sh                Entrypoint: merge profiles + run mkarchiso
  Makefile                Targets: build / image / write / release / qemu
  profile/
    profiledef.sh         ISO name, bootmodes, install_dir="pinneos"
    packages.x86_64       Package list (archiso + linux-lts + zfs-dkms 2.4.1 + docker + cockpit)
    pacman.conf           Standard Arch + archzfs experimental repo (github releases)
    grub/grub.cfg         Live-ISO GRUB menu (A/B for the live ISO is a later feature)
    airootfs/
      etc/mkinitcpio.conf HOOKS with archiso live-boot hook
      root/customize_airootfs.sh  Post-install: DKMS build, services, locale, hostname

overlay/                  Baked into the live SquashFS
  etc/homelab/config      Runtime config (pool/dataset names, ports, etc.)
  etc/systemd/system/     All PinneOS systemd units and drop-ins
  etc/udev/rules.d/       Backup USB detection
  usr/lib/homelab/        Runtime scripts

grub/grub.cfg.template    Reference template for the A/B persistent-USB GRUB config
                          (written to USB by the first-boot wizard)

cockpit-zfs/              Custom Cockpit ZFS plugin (skeleton + full plan in comments)
stacks/panel/             Docker Compose stack for Homepage + Dockge
wizard/tui/wizard.py      First-boot console wizard (TODO: implement)

docs/                     Documentation
.github/workflows/        GitHub Actions: automatic ISO build on version tag
```

## How the build works

`build.sh` (inside the Docker container):

1. Imports archzfs signing key into the container's pacman keyring
2. Copies archiso's own `releng` profile to a temp directory (provides working GRUB/EFI configs)
3. Merges `build/profile/` on top (overrides packages, pacman.conf, profiledef, customize script)
4. Merges `overlay/` into `airootfs/` (bakes our systemd units, scripts, config into the image)
5. Runs `mkarchiso` which:
   - Installs packages into a chroot (including linux-lts, zfs-dkms, docker, cockpit)
   - Applies airootfs overlay to the chroot
   - Runs `customize_airootfs.sh` (locale, DKMS ZFS build, service enables)
   - Runs `mkinitcpio` to build the initramfs with the archiso live-boot hook
   - Compresses rootfs to SquashFS (zstd-15)
   - Assembles hybrid ISO (BIOS MBR + UEFI)

## Making a release

```bash
cd build && make release VERSION=1.0.0
```

Produces:
```
release/pinneos-1.0.0-x86_64.iso
release/pinneos-1.0.0-x86_64.iso.sha256
release/pinneos-1.0.0-manifest.json
```

Upload these as assets to a GitHub Release. The in-system updater (`update.sh`) polls the GitHub Releases API to discover new versions.

Alternatively, push a version tag to trigger GitHub Actions:
```bash
git tag v1.0.0 && git push origin v1.0.0
```

## Key packages and why

| Package | Why |
|---------|-----|
| `archiso` | Provides the mkinitcpio `archiso` hook — **required** for live boot |
| `linux-lts` | Stable kernel, changes infrequently |
| `linux-lts-headers` | Required for DKMS compilation |
| `zfs-dkms` | ZFS kernel module, compiled at image build time against the exact kernel |
| `zfs-utils` | zpool/zfs userspace tools |
| `dkms`, `gcc`, `make` | Toolchain for DKMS compilation during `customize_airootfs.sh` |
| `docker` | Container runtime |
| `cockpit` | Web admin panel (systemd-native, socket-activated) |
| `networkmanager` | Network management with nmcli/nmtui |
| `avahi` + `nss-mdns` | mDNS — enables `pinneos.local` discovery |

## Coding conventions

- Shell scripts: `#!/bin/bash` with `set -euo pipefail`
- Cockpit plugin: vanilla JS, PatternFly CSS, no build step
- Python (wizard): 3.11+, textual for TUI
- Commit messages: imperative present tense ("Add ZFS import service")
