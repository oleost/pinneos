# PinneOS Upgrade Advisor

You are performing a thorough upgrade analysis for the PinneOS project. Your job is to research the current state of every component, identify what can safely be upgraded, flag risks and breaking changes, and present a detailed report to the user **before touching any files**. Do not modify any files until the user explicitly approves.

---

## Step 1 — Read current state

Read these files to establish the baseline:
- `docs/components.md` — current component versions, compatibility constraints, update risk matrix
- `overlay/etc/homelab/config` — current PINNEOS_VERSION
- `build/profile/packages.x86_64` — exact packages installed in the live image
- `build/pacman.conf` — archzfs channel URL and ZFS version reference

---

## Step 2 — Research each component

For every component below, fetch the upstream source and determine:
1. Latest stable version
2. Changes since the version we use
3. Breaking changes or migration notes
4. Whether the project is still actively maintained (last release < 12 months ago)
5. Whether a better fork or successor exists

Fetch the following sources (use WebFetch or WebSearch as needed):

### A. OpenZFS / zfs-dkms
- Latest release: https://github.com/openzfs/zfs/releases (look for latest stable tag, not RC)
- For the latest version, fetch its META file to get Linux-Minimum and Linux-Maximum:
  `https://raw.githubusercontent.com/openzfs/zfs/zfs-VERSION/META`
- Check if the archzfs experimental channel has a newer package than what we use:
  `https://github.com/archzfs/archzfs/releases/tag/experimental`
- Check archzfs project health: last commit, open issues, maintained?
- **Critical rule:** Any OpenZFS upgrade must be verified against the kernel compat matrix.

### B. Linux LTS kernel
- Current LTS versions: https://www.kernel.org/ (look for "longterm" entries)
- Which LTS version will Arch's `linux-lts` package pull at next build?
  Check: https://archlinux.org/packages/extra/x86_64/linux-lts/
- Is the current linux-lts version within the ZFS Linux-Maximum for our ZFS version?

### C. archiso
- Latest version: https://archlinux.org/packages/extra/any/archiso/
- Changelog / release notes: https://gitlab.archlinux.org/archlinux/archiso/-/blob/master/CHANGELOG.rst
- Check if `bootmodes` values used in `build/profile/profiledef.sh` are still valid.
  Our current bootmodes: `('bios.syslinux' 'uefi.grub')`

### D. Docker
- Latest stable: https://archlinux.org/packages/extra/x86_64/docker/
- Docker Engine release notes for any version since our current: https://docs.docker.com/engine/release-notes/
- Key concern: overlay2 storage driver behavior on ZFS. Check for any deprecation of overlay2 or changes to xattr/acl requirements.
- Check if Docker has deprecated or changed anything related to our setup (overlay2 on ZFS dataset with xattr=sa + acltype=posixacl).

### E. Cockpit
- Latest: https://archlinux.org/packages/extra/x86_64/cockpit/
- Release notes: https://github.com/cockpit-project/cockpit/releases
- Our plugin uses: `cockpit.spawn()`, `cockpit.file()`, `cockpit.dbus()` — check if any of these APIs changed or were deprecated.

### F. Dockge
- Latest release: https://github.com/louislam/dockge/releases
- We pin to `:1` (major version tag). Is there a major version 2?
- Is Dockge still actively maintained? Last release date?
- Any known successor or "better alternative" the community has moved to?

### G. Homepage dashboard
- Latest release: https://github.com/gethomepage/homepage/releases
- We use `:latest` tag — pulled at boot, so no rebuild needed. But check for:
  - Breaking config format changes (our config is YAML in the ZFS system dataset)
  - Any migration required for existing installs

### H. GRUB
- Latest: https://archlinux.org/packages/extra/x86_64/grub/
- We use `grub-mkimage` with specific modules. Check if any modules we use were renamed or removed.
- Modules we use (from `build/build.sh`): `part_gpt part_msdos fat search search_label`

### I. Python (wizard.py)
- Latest: https://archlinux.org/packages/extra/x86_64/python/
- Our wizard uses stdlib only. Check if any stdlib module we use was removed in new versions.

### J. avahi / nss-mdns
- Latest: https://archlinux.org/packages/extra/x86_64/avahi/
- Low risk, but verify still maintained (avahi has had maintenance concerns historically).
- Any known successor for mDNS on Linux?

---

## Step 3 — Assess project health

For each third-party project (OpenZFS, archzfs, Dockge, Homepage), answer:
- Last release date — is it < 6 months ago?
- Stars/forks trending up or down?
- Open issues count — any critical unresolved bugs?
- Any community discussion about abandonment, fork, or successor?
- Any security advisories?

---

## Step 4 — Produce the upgrade report

Write a structured report with these sections:

### 4a. Summary table
| Component | Current | Latest | Action | Risk |
|-----------|---------|--------|--------|------|
| ZFS | x.x.x | x.x.x | Upgrade / Hold / Watch | High/Med/Low |
| linux-lts | ... | ... | ... | ... |
| (etc.) | | | | |

### 4b. Critical blockers
List any upgrade that CANNOT proceed due to a hard incompatibility (e.g. ZFS kernel range exceeded). Explain exactly why.

### 4c. Recommended upgrades (safe to proceed)
For each recommended upgrade:
- What changes
- Why it's safe
- What to test after upgrading
- Exact file changes needed (e.g. "change line X in pacman.conf from Y to Z")

### 4d. Items to watch but not upgrade yet
For each:
- What's new upstream
- Why we're holding
- What condition would unblock the upgrade

### 4e. Deprecation / successor warnings
Any project that is abandoned, has a better fork, or where our approach (e.g. archzfs experimental channel) has changed.

### 4f. Files that need changing
Exact list of files to edit if the user approves the recommended upgrades.

---

## Step 5 — Wait for approval

After presenting the report, ask the user:

> "Shall I proceed with the recommended upgrades listed in section 4c? You can also ask me to include or exclude specific items."

Do **not** modify any files until the user confirms. When approved, make the changes and bump the PinneOS version number in `overlay/etc/homelab/config` following semver:
- Patch (0.2.x): dependency version bumps, no API changes
- Minor (0.x.0): new components or significant changes to existing ones
- Major (x.0.0): breaking changes requiring user action on existing installs

After making changes, remind the user to run `make release VERSION=X.Y.Z` to build the new image.
