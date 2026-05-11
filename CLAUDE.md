# PinneOS — AI Context Document

This file is the authoritative source of context for Claude (and any other AI assistant) reading this repository. It explains what PinneOS is, every architectural decision made and why, what alternatives were considered, and the current state of implementation.

---

## What is PinneOS?

PinneOS is a custom Linux live distribution for homelab enthusiasts. The core concept:

- **The USB stick is stateless.** It contains only a compressed read-only Linux root (SquashFS) that loads entirely into RAM at boot. The USB is never written to during normal operation.
- **ZFS pools on internal drives hold everything.** Configuration, Docker app data, and user storage all live on ZFS datasets. The USB is just a boot medium.
- **Replace the USB, lose nothing.** If the USB dies, you insert a new one and the system comes back exactly as it was — because everything meaningful lives on the disks.
- **Move the disks, restore the system.** ZFS pools are hardware-agnostic. Plug the disks into a new machine, boot any PinneOS USB, and the system auto-imports and resumes.

### Target audience
Homelab enthusiasts who:
- Know how to set boot order in BIOS
- Understand what Docker is
- Want a server that is trivially restorable and upgradeable

### Non-goals
- Not a NAS OS (no proprietary storage stack)
- Not a desktop OS
- Not dependent on cloud/internet services to function
- No multi-user support (single admin)

---

## Architecture

### Boot sequence

```
1. GRUB reads grubenv → selects Slot A or B
2. Kernel + initramfs load into RAM
3. archiso mkinitcpio hook finds the boot device (by label PINNEOS_LIVE)
4. SquashFS mounted read-only
5. overlayfs created (lower=SquashFS, upper=tmpfs)
6. System runs entirely from RAM — USB not accessed after this point
7. pinneos-zfs-import.service runs: scans for ZFS pools, imports managed pool
8. /var/lib/docker bind-mounted from ZFS apps dataset
9. Docker starts, containers resume
10. Web panel available at http://pinneos.local
```

If no ZFS pool is found in step 7: system stays up with Cockpit on port 9090. User can create or import a pool from the web UI.

### ZFS dataset layout

```
pool/
  system/     → OS config, /etc overrides, TLS certs, per-installation state
  apps/       → bind-mounted to /var/lib/docker (xattr=sa, acltype=posixacl)
  storage/    → user data accessible to services
    media/
    backups/
    shared/
```

### USB partition layout (A/B update scheme)

```
sda1  FAT32   512 MB   EFI + GRUB bootloader
sda2  ext4    2 GB     Slot A (active boot image)
sda3  ext4    2 GB     Slot B (standby — receives updates)
sda4  F2FS    ~rest    Persist (grubenv, logs, backup USB UUID)
```

GRUB reads `boot_slot` from grubenv to decide which slot to boot. Updates write to the standby slot and flip the variable atomically. If the new slot fails to boot twice, GRUB automatically reverts.

F2FS on the Persist partition: better wear leveling than ext4 for flash storage.

### Admin panel layers

```
http://pinneos.local        Homepage dashboard  (port 80)
http://pinneos.local:9090   Cockpit             (system, ZFS, network)
http://pinneos.local:5001   Dockge              (Docker Compose stacks)
```

All three run as Docker containers on the apps ZFS dataset.

---

## Technology decisions and rationale

### Linux base: Arch Linux (via archiso)

**Chosen over:** Alpine Linux, Ubuntu minimal, NixOS, Void Linux

**Why Arch:**
- `archiso` is the most mature and well-documented custom live ISO builder available. Alpine's `mkimage.sh` is less documented and has rougher ZFS integration.
- Arch uses **systemd** natively. Cockpit (the web admin panel) requires systemd — it will not work on Alpine (which uses OpenRC by default).
- Rolling-release risk (the main Arch drawback) does NOT apply here. The kernel is baked into the image at build time and never auto-updates. We control when to release a new image.
- Large community and comprehensive documentation.

**Why not Alpine:**
- Uses OpenRC, not systemd → Cockpit incompatible
- Less polished live-ISO tooling
- ZFS packaging is in `community` and less tested

**Why not Ubuntu:**
- Heavier base, larger images
- Live-ISO tooling (`live-build`) is more complex and produces larger results

**Why not NixOS:**
- Steeper learning curve (Nix language)
- Complex for contributors unfamiliar with Nix
- Would be the best choice IF the project were single-maintainer and Nix-fluent

### ZFS: DKMS approach (zfs-dkms 2.4.1 from archzfs)

**Chosen over:** `zfs-linux-lts` (pre-built binary packages)

**Why DKMS:**
- The archzfs-linux-lts repo provides pre-built modules for each linux-lts kernel version. There is always a lag (hours to days) between a new kernel release and archzfs catching up. A build that happens during this lag window will fail.
- With `zfs-dkms`, we compile the module against the EXACT kernel installed in the image during build. No version mismatch possible.
- The compiled module is baked into the SquashFS — no compilation at boot time.
- Cost: adds ~5 minutes to build time and requires `gcc`/`make` in the live image.

**Which archzfs package:**
- `zfs-dkms` 2.4.1 from the archzfs experimental GitHub release (`github.com/archzfs/archzfs/releases/download/experimental`).
- The archzfs.com stable repo only has 2.3.3 (caps at Linux-Maximum 6.15 — fails to build against kernel 6.16+).
- OpenZFS 2.4.0 (December 2025) added proper kernel 6.16+ support. No source patches are needed.
- `SigLevel = Optional TrustAll` in pacman.conf avoids the key-import step during build.

**Why userspace pool import (not initramfs):**
- ZFS root boot (importing the pool in initramfs) is complex and error-prone (udev races, hostid issues, DKMS timing).
- We don't need ZFS in initramfs because the root filesystem is SquashFS in RAM — ZFS is for data only.
- `pinneos-zfs-import.service` runs in userspace after the system is fully up, after `systemd-udev-settle.service`. This eliminates the entire class of initramfs/udev race conditions.
- The service is `Type=oneshot` with `RemainAfterExit=yes`, so Docker waits for it even if it takes a moment to scan for pools.

**Static hostid:**
- Generated with `zgenhostid` during image build and baked in.
- Required so ZFS doesn't complain "pool was last accessed by another system" when the same USB is used on different hardware.

**Pool auto-detection:**
- Uses `zfs-import-scan` (scans all block devices), not `zfs-import-cache` (which relies on a cache file that goes stale).
- More robust for hardware migration use cases.
- PinneOS-managed pools are tagged with `zfs set pinneos:managed=yes <pool>` during first-boot wizard.

### Bootloader: GRUB 2 (hybrid BIOS + UEFI)

**Chosen over:** systemd-boot, syslinux

**Why GRUB:**
- systemd-boot is UEFI-only. Many homelab machines (repurposed servers, old NUCs, older motherboards) are BIOS-only or have broken UEFI implementations.
- GRUB supports both BIOS MBR and UEFI in a single hybrid image.
- GRUB's `grubenv` mechanism (a key-value environment block file) is used for the A/B slot state machine — no equivalent in systemd-boot.
- GRUB's `search --label` command finds the boot device by filesystem label regardless of which USB port it's in — critical for the dual-USB redundancy feature.

**A/B slot scheme:**
- Inspired by ChromeOS, Android OTA updates, and TrueNAS.
- Updates write to the inactive slot, then flip the boot_slot variable atomically.
- Boot counter (boot_tries) in grubenv: if a slot fails to boot twice, GRUB reverts automatically.
- The backup USB receives updates 24 hours after the master — intentional delay provides a rollback window.

### Container runtime: Docker + overlay2 on ZFS dataset

**Chosen over:** Podman, Docker with native ZFS storage driver

**Why Docker:**
- Broader documentation and community support.
- docker-compose is the dominant homelab tool for service management.
- The native ZFS storage driver for Docker is deprecated since Docker 25 — don't use it.

**Pattern: overlay2 on a ZFS dataset**
```bash
zfs create -o mountpoint=/var/lib/docker \
           -o xattr=sa \
           -o acltype=posixacl \
           pool/apps
```
- Docker uses overlay2 (well-tested, performant).
- ZFS provides snapshotting at the dataset level — `zfs snapshot pool/apps@before-upgrade` before risky changes.
- `xattr=sa` and `acltype=posixacl` are required for overlay2 on ZFS to work.

**Why not rootless Podman:**
- Single-user homelab — no meaningful security benefit from rootless.
- Docker's compose tooling is simpler and more documented.
- The docker-compose focus is reinforced by using Dockge as the UI.

### Web panel: Cockpit + Dockge + Homepage

**Why not a single all-in-one panel:**

Evaluated: CasaOS, Umbrel, YunoHost.
- **CasaOS**: No ZFS support. App store is curated/locked. Not suitable as a base.
- **Umbrel**: Source-available but restrictive license for forks. No ZFS support.
- **YunoHost**: Designed for multi-user web apps (domains, SSL, LDAP). Wrong abstraction for a Docker/ZFS homelab.

**Cockpit** (port 9090):
- System administration: disks, network, services, journal, terminal.
- Socket-activated: ~0 MB RAM idle.
- Extensible with custom pages (vanilla JS, no build step required).
- We write a custom `cockpit-zfs` plugin rather than using the community `cockpit-zfs-manager`, which has uncertain maintenance.

**Dockge** (port 5001):
- Docker Compose stack management. Purpose-built for docker-compose workflows.
- File-backed: stacks are real `docker-compose.yml` files on disk, not a database. Portable and version-controllable.
- ~30 MB RAM idle. Simpler than Portainer for single-server use.
- Created by Louis Lam (creator of Uptime Kuma) — proven track record.

**Why not Portainer:** Portainer CE is designed for multi-server, multi-user enterprise use. For a single homelab server, it's more complex than needed.

**Homepage** (port 80):
- Dashboard/landing page with Docker-aware status widgets.
- YAML configuration (version-controllable, pre-populatable at install time).
- Active maintenance, large widget library (Plex, Sonarr, Jellyfin, etc.).
- No database dependency.

### Backup system: ZFS send/receive

ZFS send/receive is the native mechanism for pool-level backup and replication.

**Two modes:**
- `system-apps`: backs up `pool/system` and `pool/apps` — sufficient to restore a working system
- `full`: adds `pool/storage` — complete backup including user data

**Incremental backups:**
- After the first full send, subsequent backups detect the last common snapshot between source and destination and send only the diff. Can be seconds/minutes for daily changes on a typical homelab.

**Snapshot naming:** `pinneos-backup-YYYY-MM-DDTHH:MM:SSZ`

**Retention:** configurable (default: keep last 7 snapshots).

**Restore:** available in Recovery Mode (no active pool required) so it can be used for hardware migration. After restore, user marks the pool as managed and reboots.

**Scheduled backups:** `pinneos-backup.timer` (systemd) triggers daily. Destination configured in `/etc/homelab/backup-schedule`.

---

## Implementation status

### Done ✓
- Repository structure and build system
- Docker-based archiso build pipeline
- GRUB A/B slot config template
- All systemd service units (ZFS import, update check, backup USB sync, backup timer)
- Runtime scripts: `zfs-import.sh`, `update.sh`, `update-check.sh`, `backup-usb-sync.sh`, `backup.sh`, `restore.sh`
- Backup and restore system (full and incremental, pool-to-pool and file-based)
- Cockpit ZFS plugin (skeleton + full UI plan documented in comments)
- Docker daemon config (overlay2, log rotation)
- mDNS setup (avahi + nss-mdns for pinneos.local)
- udev rules for backup USB detection

### In progress / TODO
- ISO hardware/VM testing — boot `pinneos-0.1.0-x86_64.iso` in VirtualBox or on bare metal
- `wizard/tui/wizard.py` — first-boot wizard (Phase 1: network, hostname, password)
- `cockpit-zfs/index.html` — implement the ZFS plugin UI (sections 1-5 planned in comments)
- Cockpit backup/restore UI (section 5 documented in cockpit-zfs/index.html)
- Homepage + Dockge container definitions (docker-compose.yml for the panel stack)
- First-boot web wizard Phase 2 (ZFS pool creation UI in Cockpit)
- GitHub Actions CI workflow for automated ISO builds on tag push

### Known gaps
- The `update.sh` script has a TODO: extracting squashfs/kernel/initramfs from the downloaded IMG file
- `wizard/tui/wizard.py` is a skeleton (placeholder screens documented as comments)
- ARM/Raspberry Pi support: parked as v2 scope

### Bootmode history
- `bios.grub.mbr` was attempted but is not a valid archiso boot mode (removed in newer archiso versions)
- `uefi-x64.grub.esp` is deprecated — replaced with `uefi.grub`
- Current v0.1: `bootmodes=('bios.syslinux' 'uefi.grub')` — hybrid BIOS+UEFI
- Custom syslinux configs in `profile/syslinux/` point to `vmlinuz-linux-lts` (releng defaults use `vmlinuz-linux`)

---

## Build instructions

**Prerequisites:** Docker, make

```bash
cd build

# Build the Docker build container (once, ~2 min)
make build

# Build the ISO (first run ~20-30 min, downloads ~1 GB packages)
make image VERSION=0.1.0
# Output: ../release/pinneos-0.1.0-x86_64.iso

# Test in QEMU (optional)
make qemu VERSION=0.1.0

# Write to USB (destructive — types YES to confirm)
make write DEVICE=/dev/sdX VERSION=0.1.0

# Build + generate SHA256 + manifest for GitHub release
make release VERSION=0.1.0
```

**Write to USB on Windows/macOS:**
- Rufus: select ISO → select **DD Image mode** → write
- BalenaEtcher: drag in ISO → write

---

## Key files

```
build/
  Dockerfile                  Docker build environment (archlinux + archiso)
  build.sh                    Build entrypoint: merges profiles, runs mkarchiso
  Makefile                    build / image / write / release / qemu targets
  profile/
    profiledef.sh             archiso profile: name, bootmodes, install_dir
    packages.x86_64           Complete package list for the live image
    pacman.conf               Includes archzfs experimental repo (zfs-dkms 2.4.1)
    grub/grub.cfg             GRUB menu with A/B slot support
    airootfs/
      etc/mkinitcpio.conf     Hooks: base udev archiso block filesystems keyboard
      root/customize_airootfs.sh  Post-install: DKMS build, services, config

overlay/                      Baked into the live SquashFS via build.sh
  etc/homelab/config          Runtime variables (pool names, dataset paths, ports)
  etc/systemd/system/
    pinneos-zfs-import.service      Import ZFS pools at boot (userspace, not initramfs)
    pinneos-update-check.{service,timer}  Daily update check via GitHub API
    pinneos-backup.{service,timer}        Scheduled backup
    pinneos-backup-usb-sync@.service      Backup USB sync (triggered by udev)
    docker.service.d/10-pinneos-zfs.conf  Makes Docker wait for ZFS import
  etc/udev/rules.d/90-pinneos-backup-usb.rules  Detects backup USB by UUID
  usr/lib/homelab/
    zfs-import.sh             Find + import managed ZFS pool, bind-mount /var/lib/docker
    update.sh                 A/B slot update: download, verify, write slot, flip grubenv
    update-check.sh           Poll GitHub Releases API, write state file if update available
    backup-usb-sync.sh        Rsync active slot to backup USB
    match-backup-usb.sh       udev helper: returns 0 if device matches registered backup UUID
    backup.sh                 ZFS send/receive backup (create / list / prune)
    restore.sh                ZFS receive restore (list / run), works in recovery mode

grub/grub.cfg.template        Reference template for the A/B runtime GRUB config
                              (separate from the live-ISO GRUB config in build/profile/grub/)

cockpit-zfs/
  manifest.json               Cockpit plugin registration
  index.html                  Plugin UI skeleton + full implementation plan in comments

wizard/
  tui/wizard.py               First-boot console wizard skeleton (TODO: implement)

docs/
  architecture.md             Technical architecture reference
  installation.md             End-user installation guide
  development.md              Developer guide (build, test, contribute)
```

---

## Naming

**PinneOS** — "pinne" is Norwegian for "stick" (as in USB stick). The name reflects the core concept: the system lives on the disks, and the USB stick ("pinnen") is just the ignition key.

No known naming conflicts as of the project's creation (May 2026).

---

## Session history note

This project was designed collaboratively across several conversation sessions. The design started from a concept (USB-boot + ZFS homelab OS), went through Q&A to define requirements, research on technology choices, and then implementation. All decisions documented in this file reflect those sessions. If you are Claude reading this from GitHub: this file plus the source code is everything you need to understand the project — no local memory or prior conversation context is required.
