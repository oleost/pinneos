# Installation

## What you need

- x86_64 machine (dedicated)
- 8 GB RAM minimum (16 GB recommended)
- One or more drives for ZFS storage
- One USB stick (8 GB minimum) — two recommended for redundancy
- Another machine to write the USB image from

## Step 1: Write the USB image

Download the latest release from GitHub:

```bash
# Linux/macOS
curl -LO https://github.com/yourorg/pinneos/releases/latest/download/pinneos-x86_64.img
sudo dd if=pinneos-x86_64.img of=/dev/sdX bs=4M status=progress
sync
```

On Windows: use [Rufus](https://rufus.ie) or [Balena Etcher](https://etcher.balena.io) in DD mode.

## Step 2: Boot from USB

Set USB as first boot device in BIOS/UEFI.

## Step 3: First-boot wizard

On first boot you will be greeted by the setup wizard.

**Phase 1 (console — runs automatically):**
- Network configuration (DHCP or static IP)
- Hostname (default: `pinneos`)
- Admin password or SSH public key

**Phase 2 (web — open browser to `http://pinneos.local` or the IP shown):**
- Disk selection and ZFS pool creation (or import of existing pool)
- Dataset layout confirmation
- Optional: register a second USB stick as backup

The wizard completes in roughly 5 minutes on a typical setup.

## Step 4: Access the admin panel

```
http://pinneos.local         Dashboard (Homepage)
http://pinneos.local:9090    System admin (Cockpit)
http://pinneos.local:5001    App management (Dockge)
```

## Backup USB (recommended)

Insert a second USB stick after initial setup.
Open Cockpit → PinneOS → Backup USB, and follow the registration steps.
The system will keep the backup in sync, with a 24-hour delay after each update.

## Restoring on new hardware

1. Move ZFS drives to the new machine
2. Insert USB stick
3. Boot — the system detects and imports the existing ZFS pool automatically
4. All services resume exactly as before
