# ZFS Encryption — Implementation Plan

This document is a complete implementation guide for adding ZFS native encryption support to PinneOS. It was designed in a conversation session and is written so a future Claude session can implement it without prior context.

---

## Design decisions (already agreed)

- **ZFS native encryption** — not dm-crypt. Per-dataset, integrates with `zfs load-key` / `zfs mount`, works transparently with `zfs send/receive` backup.
- **Key model**: a random 32-byte raw key is generated at pool creation time and never changes. This raw key is what actually encrypts the data in ZFS (`keyformat=raw`).
- **The raw key is always wrapped** — users never interact with it directly during normal operation.
- **Two unlock mechanisms** (both wrap the same raw key):
  1. **Passphrase + encrypted keyfile on USB** — for automatic or manual unlock via password
  2. **Recovery key** — the raw 32-byte key as a downloadable file, for escrow (safe deposit box, password manager). Only used if passphrase is forgotten.
- **Auto-unlock on boot is optional** — user can choose whether to store the encrypted keyfile on the USB persist partition. If not stored, they must type the passphrase in the Cockpit ZFS tab on every reboot.
- **Passphrase change** only re-encrypts the keyfile — the underlying raw key and ZFS pool data are untouched.

---

## Architecture

### Key files on the USB persist partition (`/run/pinneos/persist/`)

```
/run/pinneos/persist/
  encryption/
    <poolname>.key.enc    # Raw key encrypted with user passphrase (via openssl enc -aes-256-gcm)
    <poolname>.key.enc.salt  # Salt used for passphrase → encryption key derivation
```

If the user opts out of auto-unlock, these files are not created (or are deleted after use).

### Raw key during unlock

The raw key is decrypted from `.key.enc` into a **tmpfs file** (`/run/pinneos/keys/<poolname>.key`), passed to `zfs load-key -L file:///run/pinneos/keys/<poolname>.key`, then immediately deleted. It never touches persistent storage in plaintext.

### Recovery key

The raw 32-byte key encoded as hex (64 hex chars) — presented to the user at pool creation as a downloadable `.txt` file. Stored nowhere on the system after creation.

---

## Files to create / modify

### 1. `overlay/usr/lib/homelab/zfs-encrypt.sh` (new)

Helper script called by `zfs-import.sh` and the Cockpit plugin backend. Provides these functions:

```
generate_raw_key <poolname>
  → Generates 32 random bytes, stores as hex in /tmp (tmpfs), returns path

encrypt_key_to_persist <poolname> <passphrase>
  → Reads raw key from tmpfs, derives encryption key from passphrase+salt via PBKDF2
    (openssl enc -aes-256-gcm -pbkdf2 -iter 600000), writes .key.enc + .key.enc.salt
    to /run/pinneos/persist/encryption/

decrypt_key_to_tmpfs <poolname> <passphrase>
  → Reads .key.enc + salt, decrypts, writes raw key to /run/pinneos/keys/<poolname>.key
  → Returns 0 on success, 1 on wrong passphrase

delete_tmpfs_key <poolname>
  → Removes /run/pinneos/keys/<poolname>.key

unlock_pool <poolname> <passphrase>
  → Calls decrypt_key_to_tmpfs → zfs load-key → zfs mount -a → delete_tmpfs_key
  → Returns 0 on success, 1 on failure

create_encrypted_pool <poolname> <vdevs> <passphrase> <save_to_usb: true|false>
  → generate_raw_key
  → zpool create with -O encryption=aes-256-gcm -O keyformat=raw -O keylocation=file://...
  → if save_to_usb: encrypt_key_to_persist
  → print recovery key (hex) to stdout for UI to capture
  → delete_tmpfs_key
```

Tool dependencies: `openssl`, `zfs`, `zpool` (all already in the image).

---

### 2. `overlay/usr/lib/homelab/zfs-import.sh` (modify)

After pool import, check if the pool has encryption enabled:

```bash
ENCRYPTION=$(zfs get -H -o value encryption "$POOL" 2>/dev/null)
if [ "$ENCRYPTION" != "off" ] && [ "$ENCRYPTION" != "-" ]; then
    KEY_ENC="/run/pinneos/persist/encryption/${POOL}.key.enc"
    if [ -f "$KEY_ENC" ]; then
        # Auto-unlock: try to decrypt with stored keyfile
        # This requires the passphrase — see NOTE below
        echo "pinneos-zfs-import: pool $POOL is encrypted, keyfile found on USB"
        echo "unlock-needed-with-keyfile" > /run/pinneos/unlock-needed
    else
        # No keyfile on USB — manual unlock required
        echo "pinneos-zfs-import: pool $POOL is encrypted, no keyfile on USB"
        echo "unlock-needed" > /run/pinneos/unlock-needed
    fi
    # Do NOT mount Docker yet — write status and exit cleanly
    exit 0
fi
```

**NOTE on auto-unlock**: True passwordless auto-unlock (keyfile on USB + no passphrase prompt) requires the encryption key to be stored unencrypted on the USB, which is a deliberate security trade-off. The current design requires a passphrase even for auto-unlock — this means a prompt in the Cockpit UI is always needed for encrypted pools. If the user wants fully automated unlock (e.g. home server), a future enhancement could store the passphrase in a protected location on the persist partition. Do not implement this in v1 — keep it simple.

---

### 3. `overlay/usr/share/cockpit/pinneos/pinneos.js` (modify)

The Cockpit plugin already has a ZFS tab skeleton. Add:

#### 3a. Unlock banner (shown at page load if `/run/pinneos/unlock-needed` exists)

```
┌─────────────────────────────────────────────────────────┐
│  ⚠  Pool "tank" is encrypted and locked.                │
│  Enter passphrase to unlock:  [______________] [Unlock] │
└─────────────────────────────────────────────────────────┘
```

- On "Unlock": calls backend script `zfs-encrypt.sh unlock_pool <pool> <passphrase>`
- On success: removes `/run/pinneos/unlock-needed`, restarts Docker, mounts datasets, refreshes UI
- On failure: shows "Wrong passphrase" inline, clears input
- Also show "Use recovery key instead" link → opens file upload dialog → accepts `.txt` file with 64-char hex → calls `zfs load-key` directly with the raw key

#### 3b. Create pool dialog — add encryption section

New section in the "Create pool" dialog:

```
[ ] Enable encryption
    Passphrase: [______________]
    Confirm:    [______________]
    [ ] Store encrypted keyfile on USB (auto-prompt on boot)
    
    ⚠ A recovery key will be generated. Download and store it safely.
      If you forget your passphrase and lose the recovery key, data is unrecoverable.
```

After pool creation, show a modal:

```
┌──────────────────────────────────────────┐
│  Recovery Key — Download Now             │
│                                          │
│  a3f7c2...8b91d4  (64 hex chars)        │
│                                          │
│  [Download recovery-key-tank.txt]        │
│                                          │
│  Store this file in a safe place outside │
│  this server. You cannot recover it      │
│  later.                                  │
│                                          │
│  [I have saved the recovery key]  ←only  │
│   this button closes the dialog          │
└──────────────────────────────────────────┘
```

#### 3c. Pool settings panel — encryption section

For existing encrypted pools, show under pool details:

- Lock status (locked / unlocked)
- "Change passphrase" button → old passphrase + new passphrase fields → calls `encrypt_key_to_persist` with new passphrase
- "Download recovery key" — NOT available (recovery key is generated once and not stored on the system). Show: "Recovery key was generated at pool creation. If you no longer have it, consider creating a new pool."
- "Remove keyfile from USB" / "Save keyfile to USB" toggle

---

### 4. Backend API calls from Cockpit plugin

Cockpit plugins call host commands via `cockpit.spawn()`. The pattern already used in `pinneos.js`:

```javascript
cockpit.spawn(["zfs-encrypt.sh", "unlock_pool", poolName, passphrase], { superuser: "require" })
    .then(() => { /* success */ })
    .catch((err) => { /* show error */ });
```

Commands needed:
- `zfs-encrypt.sh unlock_pool <pool> <passphrase>` → exit 0/1
- `zfs-encrypt.sh encrypt_key_to_persist <pool> <passphrase>` → exit 0/1
- `zfs-encrypt.sh remove_keyfile <pool>` → deletes .key.enc from persist
- `cat /run/pinneos/unlock-needed` → check if unlock banner should show

---

### 5. Docker restart after unlock

After successful unlock in the Cockpit UI:

```javascript
cockpit.spawn(["systemctl", "restart", "docker"], { superuser: "require" })
```

Docker must be restarted because `/var/lib/docker` (bind-mounted from ZFS apps dataset) was not available when Docker started. After unlock + mount, Docker needs to re-read its storage.

**Edge case**: containers that were already running (on unencrypted datasets or named volumes) will be interrupted. For v1, this is acceptable — document it. Future: check if docker is already using the correct mountpoint before restarting.

---

### 6. `overlay/usr/lib/homelab/wizard.py` (modify)

The first-boot wizard creates the ZFS pool. Add an encryption step:

```
Step N: Encryption
  Enable encryption on your pool? (y/n)
  > y
  Enter passphrase (min 12 chars): ****
  Confirm passphrase:              ****
  Store encrypted keyfile on USB for boot-time prompt? (y/n)
  > y
  
  ⚠  Write down your recovery key:
     a3f7c2...8b91d4
  Press Enter when you have saved it.
```

---

## Implementation order

Do these in order — each step is independently testable:

1. **`zfs-encrypt.sh`** — implement and test all functions in isolation (can test on dev machine with a loopback ZFS pool)
2. **`zfs-import.sh`** — add the encryption detection + `/run/pinneos/unlock-needed` status file
3. **Cockpit unlock banner** — the most important user-facing piece; test with a manually locked pool
4. **Cockpit create pool dialog** — encryption checkbox + recovery key modal
5. **Cockpit pool settings** — change passphrase, keyfile toggle
6. **`wizard.py`** — add encryption step at the end

---

## Testing checklist

- [ ] Create encrypted pool with passphrase, keyfile on USB → reboot → Cockpit shows unlock banner → enter passphrase → Docker restarts → containers come up
- [ ] Create encrypted pool with passphrase, no keyfile on USB → same flow
- [ ] Wrong passphrase → error shown, retry works
- [ ] Recovery key unlock → upload `.txt` file → pool unlocks
- [ ] Change passphrase → old keyfile gone, new keyfile works on next boot
- [ ] Backup (`zfs send`) of encrypted pool → restore to new pool → unlock with same recovery key
- [ ] Dual-USB: backup USB sync copies `.key.enc` files from persist partition too (check `backup-usb-sync.sh`)

---

## Key constraints to remember

- The raw key must **never be written to persistent storage in plaintext**. Always use tmpfs (`/run/`) and delete immediately after `zfs load-key`.
- `openssl enc -aes-256-gcm -pbkdf2 -iter 600000` is the encryption command for the keyfile. Use `-iter 600000` minimum (OWASP 2023 recommendation for PBKDF2-SHA256).
- ZFS pool must be created with `-O encryption=aes-256-gcm -O keyformat=raw -O keylocation=prompt` initially, then key location updated to file after the first `zfs load-key`.
- The `homelab` user (uid=1000) does not have ZFS key management privileges — all `zfs load-key`, `zfs change-key`, `zpool create` calls must run as root via `cockpit.spawn(..., { superuser: "require" })`.
- `zfs-encrypt.sh` must be in `/usr/lib/homelab/` (already on PATH via the overlay).
