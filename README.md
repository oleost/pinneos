# PinneOS

> **⚠️ Pre-alpha — not ready for use.**
> This project is vibe-coded and under active development. Expect broken builds, missing features, and no guarantees of stability. Do not run this on anything you care about.

---

> *"pinne"* — Norwegian for *stick*. The USB stick is the ignition key. Everything else lives on your disks.

PinneOS is a custom Linux distribution for homelab enthusiasts who want a server that is trivially restorable, safely upgradeable, and hardware-independent.

---

## The core idea

```
┌──────────────────────────────────────────────────────────────────┐
│  USB stick (read-only, loads into RAM at boot)                   │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ EFI/GRUB │  │  Slot A  │  │  Slot B  │  │    Persist     │  │
│  │          │  │ (active) │  │ (standby)│  │  (boot state)  │  │
│  └──────────┘  └──────────┘  └──────────┘  └────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
                         boots into RAM ↓
┌──────────────────────────────────────────────────────────────────┐
│  Internal drives (ZFS pool)                                      │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────────────────┐ │
│  │  system  │  │   apps   │  │            storage             │ │
│  │ (config) │  │ (Docker) │  │  media / backups / shared      │ │
│  └──────────┘  └──────────┘  └────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

**The USB stick is stateless.** It contains a compressed read-only Linux environment (SquashFS) that loads entirely into RAM at boot. The USB is never written to during normal operation.

**ZFS pools on internal drives hold everything that matters** — Docker app data, configuration, user storage. The USB is just the boot medium.

**Swap the USB, keep everything.** If the stick dies, write a new one with Etcher and boot. Your containers, config, and data are all on the drives — unchanged.

**Move the drives, restore the system.** ZFS pools are hardware-agnostic. Plug the drives into a new machine, boot any PinneOS USB, and the system auto-imports and resumes.

---

## What you get out of the box

| Service | Address | What it does |
|---|---|---|
| **Homepage** | `http://pinneos.local` | Dashboard with live container status widgets |
| **Cockpit** | `http://pinneos.local:9090` | System admin: ZFS, network, storage, terminal |
| **Dockge** | `http://pinneos.local:5001` | Docker Compose stack management |

Cockpit includes a custom **PinneOS plugin** for:
- Creating and managing ZFS pools and datasets
- Setting up a backup USB stick
- Running and scheduling ZFS backups

---

## Safe updates with A/B slots

The USB has two slot partitions (Slot A and Slot B). Updates always write to the inactive slot:

```
Running on Slot A
      ↓
Download new version → write to Slot B → flip boot pointer
      ↓
Reboot into Slot B
      ↓
If Slot B fails to boot twice → GRUB automatically reverts to Slot A
```

No update can brick the system. The old version is always one reboot away.

---

## Backup USB redundancy

Connect a second PinneOS USB to the same machine. Register it in the setup wizard or Cockpit. It will:

- Sync automatically whenever plugged in
- Receive updates 24 hours after the primary (built-in rollback window)
- Boot the system identically if the primary fails — just unplug and swap

---

## Requirements

- x86_64 machine (bare metal or VM)
- 8 GB RAM minimum (ZFS ARC + Docker containers)
- One or more internal drives for ZFS storage
- USB stick, 8 GB or larger (two recommended for redundancy)

---

## Quick start

**Prerequisites:** Docker and `make` on your build machine.

```bash
git clone https://github.com/oleost/pinneos
cd pinneos/build

# Build the Docker build environment (once, ~2 min)
make build

# Build the bootable USB image (~20–30 min first run)
make image VERSION=0.1.0

# Output:
#   release/pinneos-0.1.0-x86_64.iso     — boot ISO for QEMU/VirtualBox
#   release/pinneos-0.1.0-x86_64.img.xz — A/B USB image for Etcher
```

**Write to USB:**

- **Windows / macOS:** Open [BalenaEtcher](https://etcher.balena.io), select `pinneos-*.img.xz`, write to USB. Done.
- **Rufus:** Select `pinneos-*.img.xz` → **DD Image mode** → write.
- **Linux:** `make write DEVICE=/dev/sdX VERSION=0.1.0`

**Test in QEMU before writing:**

```bash
make qemu VERSION=0.1.0
```

**First boot:**

1. Boot from USB
2. Run `pinneos-wizard` in the console (or connect via SSH as root)
3. Set hostname, admin password, and optionally register a backup USB
4. Open `http://pinneos.local:9090` → PinneOS plugin → create a ZFS pool
5. Containers start automatically

---

## Architecture

### Boot sequence

```
GRUB reads grubenv → selects Slot A or Slot B
  ↓
Kernel + initramfs load into RAM
  ↓
archiso hook finds SquashFS by partition label (PINNEOS_A / PINNEOS_B)
  ↓
SquashFS mounted read-only, overlayfs on top (writes go to tmpfs)
  ↓
System runs entirely from RAM — USB no longer accessed
  ↓
pinneos-zfs-import.service: scans drives, imports managed ZFS pool
  ↓
/var/lib/docker bind-mounted from pool/apps
  ↓
Docker starts, containers resume
  ↓
http://pinneos.local — Homepage dashboard
```

### ZFS dataset layout

```
pool/
  system/          ← OS config, /etc overrides, TLS certs
  apps/            ← bind-mounted to /var/lib/docker (xattr=sa, acltype=posixacl)
  storage/
    media/
    backups/
    shared/
```

### USB partition layout

```
sda1  FAT32   512 MB   EFI + GRUB (BIOS + UEFI boot)
sda2  ext4      2 GB   Slot A (active boot image)
sda3  ext4      2 GB   Slot B (standby — receives updates)
sda4  F2FS    ~rest    Persist (grubenv: boot_slot, boot_tries)
```

---

## Technology choices

| Component | Choice | Why |
|---|---|---|
| **Linux base** | Arch Linux + archiso | Best live-ISO tooling, native systemd (required for Cockpit), rolling kernel baked at build time |
| **Filesystem** | ZFS (via zfs-dkms) | Snapshots, send/receive, hardware-agnostic pool migration |
| **ZFS build** | DKMS (compiled at build time) | No lag waiting for pre-built modules to match the kernel; module baked into SquashFS |
| **Bootloader** | GRUB 2 (hybrid BIOS + UEFI) | `grubenv` for A/B state machine; `search --label` finds boot device regardless of port |
| **Container runtime** | Docker + overlay2 on ZFS dataset | Broad ecosystem; overlay2 on ZFS is well-tested with `xattr=sa` and `acltype=posixacl` |
| **Admin panel** | Cockpit + Dockge + Homepage | Each best-in-class for its role; no opinionated app store |

---

## Project status

- **v0.1.0** — Initial release
  - Full A/B USB build pipeline (Etcher-ready `.img.xz`)
  - ZFS auto-import at boot (userspace service, no initramfs complexity)
  - Backup USB registration and auto-sync
  - Cockpit plugin: ZFS pool/dataset management, backup/restore UI
  - First-boot wizard: hostname, password, backup USB
  - Homepage + Dockge panel stack
  - OTA update system with GRUB auto-rollback

---

## Documentation

- [Architecture](docs/architecture.md)
- [Installation](docs/installation.md)
- [Development](docs/development.md)

---

## License

MIT
