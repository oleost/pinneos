# PinneOS Upgrade Advisor

You are performing a thorough upgrade analysis for the PinneOS project. Your job is to research the current state of every component, identify what can safely be upgraded, flag risks and breaking changes, and present a detailed report to the user **before touching any files**. Do not modify any files until the user explicitly approves.

---

## Step 1 — Read current state from the codebase

Read the following files to establish the exact baseline. Do **not** guess versions — read them directly from the source.

| What to read | Where to find it |
|---|---|
| Current ZFS version | Comment in `build/profile/packages.x86_64` (top of ZFS block) |
| Current linux-lts, Docker, Cockpit | Most recent row in version history table in `docs/components.md` |
| Current PINNEOS_VERSION | `overlay/etc/homelab/config` → `PINNEOS_VERSION` |
| Dockge image tag | `overlay/etc/homelab/panel/docker-compose.yml` |
| Homepage image tag | `overlay/etc/homelab/panel/docker-compose.yml` |
| archzfs channel URL | `build/profile/pacman.conf` |
| Current bootmodes | `build/profile/profiledef.sh` → `bootmodes=` |

Also read:
- `docs/components.md` — full compatibility constraints and update risk matrix
- `build/profile/profiledef.sh` — `file_permissions` block
- `overlay/usr/lib/homelab/` — list all `.sh` and `.py` files present

After reading, confirm each "current version" before proceeding. No SSH needed — everything is in the codebase.

---

## Step 2 — Internal consistency audit (no network required)

Before going online, check these things from the files you just read:

**A. profiledef.sh file_permissions audit**
Compare every file under `overlay/usr/lib/homelab/` against the `file_permissions` entries in `build/profile/profiledef.sh`. Flag any script that exists on disk but is missing from `file_permissions` (it won't be executable in the built image) and any entry that references a script that no longer exists.

**B. Compose file consistency**
Check both compose files:
- `overlay/etc/homelab/panel/docker-compose.yml` (baked into image)
- `stacks/panel/docker-compose.yml` (if it exists)

Flag any differences between them — both should be kept in sync.

**C. Version history table**
Verify the most recent row in `docs/components.md` matches what is actually in the current codebase files. If it's stale, note what needs updating.

---

## Step 3 — Research each component upstream

For every component below, fetch the upstream source and determine:
1. Latest stable version
2. Changes since the version we currently use (from Step 1)
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
- **Critical rule:** Any OpenZFS upgrade must be verified against the kernel compat matrix.

### B. Linux LTS kernel
- Current LTS versions: https://www.kernel.org/ (look for "longterm" entries)
- Which LTS version will Arch's `linux-lts` package pull at next build?
  Check: https://archlinux.org/packages/core/x86_64/linux-lts/
- Is the version within the ZFS Linux-Maximum for our ZFS version?

### C. archiso
- Latest version: https://archlinux.org/packages/extra/any/archiso/
- **Fetch and read the actual CHANGELOG:** https://gitlab.archlinux.org/archlinux/archiso/-/raw/master/CHANGELOG.rst
- Verify `bootmodes` values from Step 1 are still listed as valid in the CHANGELOG.
  Do not assume they are valid — confirm from the text.

### D. Docker
- Latest stable: https://archlinux.org/packages/extra/x86_64/docker/
- Docker Engine release notes since our current version: https://docs.docker.com/engine/release-notes/
- Key concern: overlay2 on ZFS with `xattr=sa` + `acltype=posixacl`. Check for deprecation.

### E. Cockpit
- Latest: https://archlinux.org/packages/extra/x86_64/cockpit/
- Release notes since our current version: https://github.com/cockpit-project/cockpit/releases
- Our plugin uses: `cockpit.spawn()`, `cockpit.file()`, `cockpit.dbus()` — search the release
  notes for these exact strings to check for deprecation or API changes.

### F. Dockge
- Latest release: https://github.com/louislam/dockge/releases
- We pin to `:1`. Is there a v2? Is it still actively maintained?
- Check for breaking changes in any release since the version in our compose file.

### G. Homepage dashboard
- Latest release: https://github.com/gethomepage/homepage/releases
- We use `:latest`. Check for breaking YAML config format changes since v0.9.x.

### H. GRUB
- Latest: https://archlinux.org/packages/core/x86_64/grub/
- Modules we use: `part_gpt part_msdos fat search search_label` — still present?

### I. Python (wizard.py)
- Latest: https://archlinux.org/packages/core/x86_64/python/
- Our wizard uses stdlib only (`sys`, `subprocess`, `getpass`, `socket`). Check if any were removed.

### J. avahi / nss-mdns
- Latest: https://archlinux.org/packages/extra/x86_64/avahi/
- Still maintained? Any stable 0.9 release yet? Any Linux-native successor?

---

## Step 4 — Assess project health

For each third-party project (OpenZFS, archzfs, Dockge, Homepage), answer:
- Last release date — is it < 6 months ago?
- Any critical unresolved bugs or security advisories?
- Any community discussion about abandonment, fork, or successor?

---

## Step 5 — Produce the upgrade report

Write a structured report with these sections:

### 5a. Internal audit findings
List any issues found in Step 2 (missing file_permissions, compose file mismatches, stale version table). These are actionable regardless of upstream changes.

### 5b. Summary table
| Component | Current | Latest | Action | Risk |
|-----------|---------|--------|--------|------|
| ZFS | x.x.x | x.x.x | Upgrade / Hold / Watch | High/Med/Low |
| linux-lts | ... | ... | ... | ... |
| (etc.) | | | | |

Use exact version numbers from Step 1 for "Current". No ranges or approximations.

### 5c. Critical blockers
List any upgrade that CANNOT proceed due to a hard incompatibility (e.g. ZFS kernel range exceeded). Explain exactly why.

### 5d. Recommended upgrades (safe to proceed)
For each recommended upgrade:
- What changes
- Why it's safe
- What to test after upgrading
- Exact file changes needed

### 5e. Items to watch but not upgrade yet
For each:
- What's new upstream
- Why we're holding
- What condition would unblock the upgrade

### 5f. Deprecation / successor warnings
Any project that is abandoned, has a better fork, or where our approach has changed.

### 5g. Files that need changing
Exact list of files to edit if the user approves the recommended upgrades.

---

## Step 6 — Get approval to make file changes

Ask the user:

> "Shall I proceed with the recommended upgrades listed in section 5d? You can also ask me to include or exclude specific items."

Do **not** modify any files until the user confirms.

---

## Step 7 — Make file changes

When the user approves:

1. Make all file changes
2. Keep both compose files in sync (`overlay/etc/homelab/panel/` and `stacks/panel/` if present)
3. Bump `PINNEOS_VERSION` in `overlay/etc/homelab/config` following semver:
   - Patch (0.2.x): dependency bumps, no API changes
   - Minor (0.x.0): new components or significant changes to existing ones
   - Major (x.0.0): breaking changes requiring user action on existing installs
4. Update the version history table in `docs/components.md` with exact versions

Do **not** commit yet. Show a summary of what was changed.

---

## Step 8 — Live server test (optional but recommended)

Ask the user:

> "Do you have a live PinneOS server available to test these changes on before releasing? If yes, provide the IP address (or confirm it's the usual one) and I'll deploy and verify before tagging the release."

**If the user says yes:**

1. SCP the changed files to the live server (use `sshpass -p pinneos` and the provided IP, user `root`)
2. For systemd unit changes: run `systemctl daemon-reload` on the server
3. For compose file changes: check whether the running containers need to be recreated (`docker compose up -d` in the panel stack directory)
4. Verify the change works — for each file changed, describe what to check and check it:
   - Service file changes → `systemctl status <service>`
   - compose changes → `docker ps`, check container is running with new env vars
   - Script changes → run the script with a safe/dry invocation if possible
5. Report the verification result to the user before proceeding

**If the user says no (or there's no live server):**

Note that the changes are untested on real hardware and proceed to Step 9.

---

## Step 9 — Commit, tag, and release

Only after the user confirms they are happy (with or without live testing):

1. Commit all changes with a clear message summarising what was upgraded
2. Tag with the new version: `git tag vX.Y.Z`
3. Push branch and tag: `git push origin main && git push origin vX.Y.Z`
4. CI will build and publish the release automatically
