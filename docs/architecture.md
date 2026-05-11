# Architecture

> For full decision rationale and alternatives considered, see [CLAUDE.md](../CLAUDE.md).

## Design principles

- **USB is stateless.** Boot medium only. Never written to during normal operation.
- **ZFS is the brain.** All persistent state lives on ZFS datasets.
- **Replace USB, lose nothing.** If the USB dies, insert a new one — the system resumes from ZFS.
- **Move the disks, restore the system.** ZFS pools are hardware-agnostic.

---

## Boot sequence

```
1. GRUB reads grubenv on Persist partition → selects Slot A or B
2. Kernel + initramfs load into RAM from active slot
3. archiso mkinitcpio hook:
     - Finds USB device by label PINNEOS_LIVE
     - Mounts SquashFS read-only
     - Creates overlayfs (lower=SquashFS, upper=tmpfs)
     - Switch-roots into the overlay
4. System runs entirely in RAM — USB not accessed again
5. pinneos-zfs-import.service:
     - Waits for udev to settle
     - Runs: zpool import -a -N (scans all block devices)
     - Finds pools tagged pinneos:managed=yes
     - Mounts datasets (system/, apps/, storage/)
     - Bind-mounts apps/ dataset to /var/lib/docker
6. Docker starts (after ZFS import completes)
7. Containers resume (Dockge, Homepage, user services)
8. Web panel: http://pinneos.local
```

If no ZFS pool found in step 5 → system stays up, Cockpit available on :9090.
User creates or imports a pool from the web UI.

---

## USB partition layout

```
┌──────────────────────────────────────────────────────┐
│ sda1  FAT32   512 MB   EFI + GRUB                    │
│ sda2  ext4    2 GB     Slot A  ← active boot image   │
│ sda3  ext4    2 GB     Slot B  ← standby (updates)   │
│ sda4  F2FS    ~rest    Persist ← grubenv, logs, state│
└──────────────────────────────────────────────────────┘
```

Each slot contains: `airootfs.sfs` (SquashFS), `vmlinuz-linux-lts`, `initramfs-linux-lts.img`

GRUB reads `boot_slot` from `grubenv` on sda4. Updates write to the standby slot, then atomically flip `boot_slot`. A `boot_tries` counter provides automatic rollback if the new slot fails twice.

> **v0.1 note:** The ISO produced by `make image` is a standard hybrid ISO (single partition, Rufus/Etcher compatible). The A/B partition scheme is implemented in the update scripts and GRUB config template, and will be applied by the first-boot wizard to set up the USB properly.

---

## ZFS dataset layout

```
pool/
  system/     → /etc overrides, systemd drop-ins, TLS certs
  apps/       → /var/lib/docker (xattr=sa, acltype=posixacl required)
  storage/
    media/    → user media files
    backups/  → backup destination datasets
    shared/   → general shared storage
```

Pool tagged at creation: `zfs set pinneos:managed=yes <pool>`

This tag is how `zfs-import.sh` identifies which pool to activate.

---

## ZFS technical details

### Why userspace import (not initramfs)

ZFS root boot requires complex initramfs setup prone to udev races and hostid issues. Since the root filesystem is SquashFS in RAM, there is no need for ZFS in initramfs.

`pinneos-zfs-import.service` runs after `systemd-udev-settle.service`, eliminating timing issues entirely.

### Docker on ZFS

```bash
# Dataset creation (first-boot wizard)
zfs create -o mountpoint=/var/lib/docker \
           -o xattr=sa \
           -o acltype=posixacl \
           pool/apps
```

Docker uses the `overlay2` storage driver. The native ZFS storage driver for Docker is deprecated since Docker 25 — do not use it.

### Static hostid

Generated with `zgenhostid` during image build and baked into the SquashFS. Required so ZFS does not refuse to import pools with "last accessed by another system."

---

## Admin panel

```
http://pinneos.local        Homepage    port 80
http://pinneos.local:9090   Cockpit     system admin, ZFS plugin
http://pinneos.local:5001   Dockge      Docker Compose manager
```

All three run as Docker containers defined in `stacks/panel/docker-compose.yml`.

---

## A/B update scheme

```
Current state:
  Slot A: active
  Slot B: standby
  grubenv: boot_slot=A, boot_tries=0

Update triggered (via Cockpit or CLI):
  1. Download new image from GitHub Releases
  2. Verify SHA256
  3. Write new SquashFS + kernel + initramfs to Slot B
  4. grubenv: boot_slot=B, boot_tries=0   ← atomic single write
  5. Reboot

GRUB on next boot:
  - Reads boot_slot=B
  - Increments boot_tries to 1
  - Boots Slot B

On successful boot (initramfs hook):
  - Resets boot_tries=0

On failed boot (boot_tries >= 2):
  - GRUB flips back to Slot A automatically
```

---

## Backup system

Uses `zfs send/receive` natively.

```
Modes:
  system-apps  →  pool/system + pool/apps
  full         →  pool/system + pool/apps + pool/storage

Snapshots:  pinneos-backup-YYYY-MM-DDTHH:MM:SSZ
Retention:  last 7 snapshots (configurable)

Incremental: automatically detects last common snapshot between
             source and destination, sends only the diff.
```

Restore is available in Recovery Mode (no active pool needed), making it usable for hardware migration.

---

## Dual USB redundancy

```
USB Master    → boots first (BIOS boot order priority 1)
USB Backup    → boots second (BIOS boot order priority 2)
              → detected by UUID via udev rule
              → synced 24 hours after master update
                (intentional delay = rollback window)
```

Both USBs are kept as complete bootable clones of the active slot.
