# PinneOS component inventory

This document tracks every version-sensitive component in PinneOS, the compatibility
constraints between them, and where to check for updates.

**Update workflow:** A GitHub Actions job runs every Monday and opens an issue if
anything needs attention. See `.github/workflows/update-check.yml`.

---

## Critical compatibility constraint: ZFS ↔ Linux kernel

This is the only constraint that can break a build entirely if ignored.

| OpenZFS release | Minimum kernel | Maximum kernel |
|-----------------|---------------|----------------|
| 2.3.x | 3.10 | 6.15 |
| 2.4.x | 4.18 | 6.16+ (no upper limit as of Dec 2025) |

**Rule:** Before upgrading either `linux-lts` or `zfs-dkms`, verify the new combination
is within the supported range. Check the `META` file in the OpenZFS release:
`https://github.com/openzfs/zfs/blob/zfs-VERSION/META`

---

## Component table

### Build environment (Dockerfile)

| Component | Current | Pinned | Update risk | Check |
|-----------|---------|--------|-------------|-------|
| Build base image | `archlinux:latest` | No — pulls latest on each `docker build` | Low | — |
| archiso | latest (Arch extra) | No | **Medium** — profile format changes break builds | [Arch pkg](https://archlinux.org/packages/extra/any/archiso/) |
| GRUB (build tools) | latest (Arch extra) | No | Low — only used for `grub-mkimage`/`grub-bios-setup` | [Arch pkg](https://archlinux.org/packages/extra/x86_64/grub/) |

**archiso note:** When archiso releases a new major version, check if the `bootmodes`
values in `profile/profiledef.sh` are still valid. They changed in archiso 75+.

---

### Live image packages (packages.x86_64)

| Component | Current | Pinned | Compatibility constraint | Check |
|-----------|---------|--------|--------------------------|-------|
| `linux-lts` | latest LTS at build time | No | Must be within ZFS supported range | [kernel.org LTS](https://www.kernel.org/) |
| `linux-lts-headers` | matches linux-lts | No | Must match linux-lts exactly | same as above |
| `zfs-dkms` | 2.4.1 (archzfs experimental) | Channel | **Critical:** kernel range 4.18–6.16+ | [OpenZFS releases](https://github.com/openzfs/zfs/releases) |
| `zfs-utils` | matches zfs-dkms | Channel | Must match zfs-dkms | same as above |
| `grub` | latest (Arch extra) | No | Low | [Arch pkg](https://archlinux.org/packages/extra/x86_64/grub/) |
| `cockpit` | latest (Arch extra) | No | Plugin API: our JS uses basic `cockpit.spawn()` — stable across versions | [Arch pkg](https://archlinux.org/packages/extra/x86_64/cockpit/) |
| `docker` | latest (Arch extra) | No | overlay2 on ZFS requires `xattr=sa` + `acltype=posixacl` — stable | [Arch pkg](https://archlinux.org/packages/extra/x86_64/docker/) |
| `docker-compose` | latest (Arch extra) | No | Low | [Arch pkg](https://archlinux.org/packages/extra/x86_64/docker-compose/) |
| `networkmanager` | latest (Arch extra) | No | Low | [Arch pkg](https://archlinux.org/packages/extra/x86_64/networkmanager/) |
| `avahi` | latest (Arch extra) | No | Low | [Arch pkg](https://archlinux.org/packages/extra/x86_64/avahi/) |
| `python` | latest (Arch extra) | No | Wizard uses stdlib only — no version risk | [Arch pkg](https://archlinux.org/packages/extra/x86_64/python/) |

---

### ZFS source (pacman.conf)

| Item | Current value | Notes |
|------|--------------|-------|
| Repo | `archzfs` experimental | GitHub release channel |
| URL | `https://github.com/archzfs/archzfs/releases/download/experimental` | |
| SigLevel | `Optional TrustAll` | Build-time convenience — key imported in build.sh |
| ZFS version | **2.4.1** | OpenZFS December 2025 release |

**When to upgrade ZFS channel:**
- OpenZFS releases a new minor (2.5.x) → check kernel support range, then update pacman.conf URL
- Stay on `experimental` channel — the `stable` channel (archzfs.com) lags behind and was stuck on 2.3.x

---

### Panel stack (overlay/etc/homelab/panel/docker-compose.yml)

These are Docker images pulled at first boot, not baked into the SquashFS.

| Service | Image | Tag | Pinned | Check |
|---------|-------|-----|--------|-------|
| Homepage | `ghcr.io/gethomepage/homepage` | `:latest` | No | [Releases](https://github.com/gethomepage/homepage/releases) |
| Dockge | `louislam/dockge` | `:1` | Major version | [Releases](https://github.com/louislam/dockge/releases) |

**Dockge note:** Pinned to `:1` (major version) intentionally. Breaking changes happen
across major versions. Check release notes before bumping to `:2`.

---

## Update risk matrix

| Component | Upgrade frequency | Risk | Action required |
|-----------|------------------|------|----------------|
| ZFS major (2.4 → 2.5) | Every ~1 year | **High** | Verify kernel compat range, test build |
| ZFS minor (2.4.0 → 2.4.1) | Every few months | Low | Update version ref, rebuild |
| linux-lts major (6.6 → 6.12) | Every ~6 months | Medium | Verify ZFS compat, test boot |
| archiso major | Every ~1 year | Medium | Check profiledef bootmodes, test build |
| cockpit | Monthly | Low | Rebuild and test plugin UI |
| docker | Monthly | Low | Rebuild, verify overlay2 still works |
| grub | Rare | Low | Rebuild, test UEFI + BIOS boot |
| Homepage/Dockge | Continuous (:latest) | Low | Pulled fresh at boot — no rebuild needed |

---

## Update checklist

Before building a new release:

```
[ ] Check OpenZFS latest: https://github.com/openzfs/zfs/releases
    [ ] New version available?
    [ ] Check META file for Linux-Maximum — is our linux-lts within range?
    [ ] Update archzfs channel reference if needed

[ ] Check linux-lts current version: https://www.kernel.org/
    [ ] Is it within ZFS 2.4.x supported range (4.18–)?

[ ] Check archiso: https://archlinux.org/packages/extra/any/archiso/
    [ ] Major version bump? Review bootmodes in profiledef.sh

[ ] Check cockpit: https://archlinux.org/packages/extra/x86_64/cockpit/
    [ ] Test plugin after build (ZFS tab, Backup USB tab)

[ ] Check docker: https://archlinux.org/packages/extra/x86_64/docker/
    [ ] Major version? Review overlay2 on ZFS release notes

[ ] Run: make image VERSION=X.Y.Z
[ ] Boot in QEMU: make qemu VERSION=X.Y.Z
[ ] Flash to USB and test on real hardware
[ ] Tag and release: git tag vX.Y.Z && git push origin vX.Y.Z
```

---

## Version history

| PinneOS version | linux-lts | ZFS | Docker | Cockpit | Date |
|----------------|-----------|-----|--------|---------|------|
| 0.1.0 | 6.12.x (LTS) | 2.4.1 | 28.x | 332+ | 2026-05-12 |
