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

### ZFS: DKMS approach (zfs-dkms 2.4.2 from archzfs)

**Chosen over:** `zfs-linux-lts` (pre-built binary packages)

**Why DKMS:**
- The archzfs-linux-lts repo provides pre-built modules for each linux-lts kernel version. There is always a lag (hours to days) between a new kernel release and archzfs catching up. A build that happens during this lag window will fail.
- With `zfs-dkms`, we compile the module against the EXACT kernel installed in the image during build. No version mismatch possible.
- The compiled module is baked into the SquashFS — no compilation at boot time.
- Cost: adds ~5 minutes to build time and requires `gcc`/`make` in the live image.

**Which archzfs package:**
- `zfs-dkms` 2.4.2 from the archzfs experimental GitHub release (`github.com/archzfs/archzfs/releases/download/experimental`).
- The archzfs.com stable repo only has 2.3.3 (caps at Linux-Maximum 6.15 — fails to build against kernel 6.16+).
- OpenZFS 2.4.x (December 2025+) added proper kernel 6.16–7.0 support. No source patches are needed.
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
- Both USB sticks are equal mirrors — no "primary vs backup" designation. GRUB boots from whichever it finds first. `usb-mirror-sync.sh` keeps both slots (A and B) and grubenv identical. The A/B slot mechanism provides the rollback window — a separate backup delay is unnecessary.

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

## Docker app conventions

All Docker containers on PinneOS run as `PUID=1000 PGID=1000` (the `homelab` system user,
baked into the image). `zfs-import.sh` chowns the storage dataset top-level dirs to
`homelab:homelab` after pool import.

**Volume layout** (pool name varies — set by user during setup, default placeholder is `tank`):
- App config/state: `/POOL/apps/<appname>/` — bind-mount into container
- User data: `/POOL/storage/` — owned by homelab user
- Internal databases users never touch: Docker named volumes (auto-created in `/var/lib/docker/volumes/`, lives on apps dataset)

**Image preference:** `lscr.io/linuxserver/<app>` first (native PUID/PGID support).
If no lscr image: `user: "1000:1000"` in compose. `user: root` only as last resort.

**Slash command:** `.claude/commands/add-app.md` — invoke `/add-app <appname>` in Claude Code
to get a correctly configured compose stack following PinneOS conventions.

See `docs/apps.md` for top-12 recommended apps with ready-to-use compose stacks.
See `docs/components.md` for component versions, compatibility matrix, and update checklist.

---

## GRUB installation approach (important)

`grub-install` is NOT used in `build.sh`. It embeds a UUID from the loop device that
doesn't match on real hardware. Instead:

- **UEFI:** `grub-mkimage` with `--config=<early_cfg>` embedding `search --no-floppy --label --set=root PINNEOS_EFI` + `set prefix=($root)/grub`. Modules: `part_gpt part_msdos fat search search_label`.
- **BIOS:** `grub-mkimage` to produce `core.img`, then `grub-bios-setup --skip-fs-probe`.
- The `-p /grub` flag is required by `grub-mkimage` even when `--config` is specified.
- All x86_64-efi and i386-pc modules are copied to the FAT32 EFI partition at build time.

---

## USB mirror — dual-USB behaviour

Both USB sticks have identical partition labels (PINNEOS_A, PINNEOS_B, PINNEOS_PERSIST, PINNEOS_EFI).
`findfs LABEL=PINNEOS_A` is ambiguous when both are connected. This is intentional by design — both
sticks are equal mirrors and GRUB can boot from either.

**Boot disk identification in scripts:** Never use `findfs` for the active slot. Instead, read the
`archisolabel=PINNEOS_X` parameter from `/proc/cmdline` (set by archiso at boot) → `findfs` that
specific label → `lsblk -no PKNAME` to get the parent disk. This is unambiguous regardless of how
many PinneOS USBs are connected.

**udev trigger:** Fires on `PINNEOS_A` partition add (not disk add). At disk-add time the kernel has
not yet enumerated partitions, so lsblk cannot confirm the disk is a PinneOS USB. Matching the
partition event is reliable. `udev-mirror-trigger.sh` resolves the parent disk from the partition
name and starts `pinneos-usb-mirror-sync@DISK.service`.

**Sync scope:** `usb-mirror-sync.sh` syncs both Slot A and Slot B (not just the active slot), plus
grubenv. After sync the mirror is a complete duplicate — it boots to the same slot and rolls back
identically if the new slot fails.

---

## Implementation status

### Done ✓
- Repository structure and build system
- Docker-based archiso build pipeline
- GRUB A/B slot config (grub-mkimage + embedded search_label — no grub-install)
- Repository structure and build system
- Docker-based archiso build pipeline
- GRUB A/B slot config (grub-mkimage + embedded search_label — no grub-install)
- All systemd service units (ZFS import, update check, USB mirror sync, backup timer)
- Runtime scripts: `zfs-import.sh`, `update.sh`, `update-check.sh`, `usb-mirror-sync.sh`, `backup.sh`, `restore.sh`
- Backup and restore system (full and incremental, pool-to-pool and file-based)
- Cockpit PinneOS plugin (full JS implementation in `overlay/usr/share/cockpit/pinneos/`)
- Docker daemon config (overlay2, log rotation)
- mDNS setup (avahi + nss-mdns for pinneos.local)
- udev rules for USB mirror detection (PINNEOS_A partition add → sync)
- `homelab` system user (uid=1000, gid=1000) — Docker app convention
- Component inventory and weekly automated update checks (`docs/components.md`, `.github/workflows/update-check.yml`)
- GitHub Actions CI: builds ISO+IMG.gz on tag push, creates draft release
- **v0.1.0 tested on real hardware (ASUS UEFI PC) — boots correctly**
- **v0.2.0** — ZFS encryption, pool health UI, update.sh IMG.gz support, Cockpit UI fixes
- SMART disk monitoring (`smartd` + `smart-alert.sh` — logs to journal, optional Gotify push)
- ZFS scrub timer (`pinneos-zfs-scrub.timer` — monthly, all managed pools)
- Gotify push notification integration (optional, configure via `/etc/homelab/gotify-{url,token}`)
- **ZFS native encryption** — full implementation:
  - `overlay/usr/lib/homelab/zfs-encrypt.sh` — backend helper (create-pool, unlock, unlock-recovery, change-passphrase, remove/save-keyfile)
  - `zfs-import.sh` — detects encrypted pools at boot, writes `/run/pinneos/unlock-needed`
  - `backup.sh` — uses `zfs send -w` (raw send) for encrypted datasets (ZFS 2.4.1 bug fix)
  - Cockpit ZFS tab: unlock banner on boot, encrypted pool creation with passphrase, recovery key modal, encryption status per pool, passphrase change, keyfile USB management
- **Pool health visualization** — `zpool status` output parsed and rendered in Cockpit ZFS tab: state badge, scrub status (last run, color-coded), vdev tree, run/cancel scrub buttons
- **Release mounts button** — stops Docker and unmounts `/var/lib/docker` from ZFS apps dataset so pools can be cleanly destroyed
- **First-boot wizard** — `/usr/lib/homelab/wizard.py` (hostname, password). Run manually after first login: `pinneos-wizard`
- **update.sh complete** — downloads `.img.gz` (preferred) or `.iso` (fallback), verifies SHA256, mounts via `losetup -P` (IMG) or loop (ISO), copies kernel/initramfs/squashfs to standby slot, flips grubenv atomically
- `cockpit-zfs/` skeleton deleted — real plugin lives in `overlay/usr/share/cockpit/pinneos/`
- **Cockpit Update tab** — GitHub version check, direct download+install, local file upload (.img.gz/.iso), reboot button
- **A/B update flow tested end-to-end on real hardware** — v0.2.0→v0.2.1 via Cockpit Update tab
- **Dynamic login banner** — `/etc/profile.d/pinneos-banner.sh` shows PinneOS version, hostname, IP on login; `pinneos-issue.service` writes `/etc/issue` before getty
- **USB mirror redesign** — replaced "primary/backup with 24h delay" model with always-in-sync mirrors: `usb-mirror-sync.sh` syncs both slots (A+B) and grubenv; triggered on boot-success and USB plug-in; no registration required; GRUB boots from either USB freely
- **Built-in file sharing** — SMB and NFS run as host daemons (samba + nfs-utils packages); Cockpit Shares tab for add/remove/status; no Docker required
- **Cockpit Apps tab** — catalog of 11 Docker Compose apps; Install + Install & Start buttons; installed detection via `/opt/stacks/<id>/`; pool placeholder `{{POOL}}` substituted at install; `docs/apps.json` machine-readable companion to `docs/apps.md`
- **update.sh mount-order fix** — target slot partition resolved BEFORE loop device setup to prevent PINNEOS_* label ambiguity causing read-only mounts (v0.3.1)

### In progress / TODO
- VM support (KVM + QEMU + cockpit-machines) — plan in `docs/vm-support-plan.md`, primary use-case is AMP game server manager

### Known gaps
- Password doesn't persist across reboots without ZFS pool (works with ZFS system/ dataset)
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
make image VERSION=0.2.0
# Output: ../release/pinneos-0.2.0-x86_64.iso

# Test in QEMU (optional)
make qemu VERSION=0.2.0

# Write to USB (destructive — types YES to confirm)
make write DEVICE=/dev/sdX VERSION=0.2.0

# Build + generate SHA256 + manifest for GitHub release
make release VERSION=0.2.0
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
    pacman.conf               Includes archzfs experimental repo (zfs-dkms 2.4.2)
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
    pinneos-usb-mirror-sync.service        USB mirror sync auto-detect (triggered by boot-success)
    pinneos-usb-mirror-sync@.service      USB mirror sync for specific disk (triggered by udev)
    pinneos-boot-success.service          Reset GRUB boot_tries=0, trigger mirror sync after boot
    pinneos-issue.service                 Write /etc/issue with PinneOS version before getty
    docker.service.d/10-pinneos-zfs.conf  Makes Docker wait for ZFS import
  etc/udev/rules.d/90-pinneos-backup-usb.rules  Fires on PINNEOS_A partition add → starts mirror sync
  etc/profile.d/pinneos-banner.sh         Dynamic login banner: version, hostname, IP, links
  usr/lib/homelab/
    zfs-import.sh             Find + import managed ZFS pool, bind-mount /var/lib/docker
    zfs-encrypt.sh            ZFS native encryption backend (create, unlock, passphrase, keyfile)
    update.sh                 A/B slot update: IMG.gz (preferred) or ISO, verify, write, flip grubenv
    update-check.sh           Poll GitHub Releases API, write state file if update available
    usb-mirror-sync.sh        Sync both slots (A+B) and grubenv from boot USB to mirror USB
    udev-mirror-trigger.sh    udev helper: resolves parent disk from partition, starts mirror service
    backup.sh                 ZFS send/receive backup (create / list / prune)
    restore.sh                ZFS receive restore (list / run), works in recovery mode
    wizard.py                 First-boot console wizard (hostname, password)

grub/grub.cfg.template        Reference template for the A/B runtime GRUB config
                              (separate from the live-ISO GRUB config in build/profile/grub/)

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
