# VM Support — Design Notes

This document captures the design discussion around adding virtual machine support to PinneOS. No implementation has started. Use this as context if/when the feature is prioritized.

---

## Requirements

- CPU with Intel VT-x or AMD-V (must be enabled in BIOS) — a real blocker on some older homelab hardware
- Hypervisor: **KVM + QEMU** (standard on Arch Linux, well-maintained)
- UI: **cockpit-machines** (Red Hat maintained, integrates directly into Cockpit — supports create, start/stop, console, snapshots)
- VM disk storage: ZFS dataset, e.g. `pool/vms/` (`.qcow2` files)
- libvirt as the management layer between cockpit-machines and QEMU

---

## The RAM problem

PinneOS loads the entire OS into RAM at boot. A typical homelab machine has 8–32 GB RAM. VMs are hungry:

- PinneOS in RAM: ~2–4 GB
- Each VM (Ubuntu Server minimum): ~2 GB
- Three VMs: 6 GB VM RAM + 4 GB PinneOS = 10 GB minimum

This is not a blocker but it is a real constraint that distinguishes PinneOS from Proxmox (which runs directly from disk). Users with less than 16 GB RAM will feel it.

---

## Where ZFS adds value

VM disks on ZFS (`pool/vms/`) gives:
- `zfs snapshot pool/vms@before-upgrade` before touching a VM — instant rollback
- Incremental backup via `zfs send` covers VMs automatically if using the `full` backup mode
- Better than what Proxmox offers without extra configuration

---

## Proposed approach: optional component, not a core feature

VM support should not be a core PinneOS feature — it conflicts with the Docker-focused identity and adds significant complexity. The right model is **opt-in**:

1. Add `qemu-full` and `libvirt` to `packages.x86_64`
2. Enable `libvirtd.service` in `customize_airootfs.sh` (but socket-activated, so ~0 RAM idle)
3. `cockpit-machines` is already packaged in Arch — add to packages list
4. Create `pool/vms` dataset in `zfs-import.sh` alongside existing datasets (conditional on libvirt being present)
5. Document in `docs/installation.md` that VM support requires VT-x/AMD-V in BIOS

No new scripts needed. No new UI needed beyond cockpit-machines itself.

---

## What is NOT needed

- A custom VM management UI (cockpit-machines covers this well)
- Proxmox-style clustering or migration (single-server homelab)
- ARM/nested virtualization support (out of scope)

---

## Open question

The use-case is not yet defined. VM support makes most sense for:
- Running something that has no Docker image (legacy software, full OS testing)
- Network appliances (pfSense, OPNsense) that need direct hardware access
- Windows VMs

If the primary use-case is just running Linux services, Docker covers it better. Clarify the use-case before starting implementation.

---

## Implementation effort estimate

Small — mostly package additions and service enablement. The hard parts (QEMU, libvirt, cockpit-machines) are all mature upstream packages. Estimated work: half a session.
