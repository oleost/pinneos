#!/bin/bash
# ZFS native encryption helper for PinneOS.
# Passphrase and key material are always passed via stdin — never as CLI args.
#
# Commands:
#   create-pool <poolname> [topology] <disk>...
#     stdin: line1=passphrase (min 12 chars), line2=save_to_usb (true|false)
#     stdout: "RECOVERY_KEY:<64 hex chars>"
#
#   unlock <poolname>
#     stdin: passphrase
#
#   unlock-recovery <poolname>
#     stdin: 64-char hex recovery key
#
#   change-passphrase <poolname>
#     stdin: line1=old_passphrase, line2=new_passphrase
#
#   remove-keyfile <poolname>
#
#   save-keyfile <poolname>
#     stdin: line1=passphrase, line2=64-char hex recovery key

set -euo pipefail

PERSIST_DIR="/run/pinneos/persist/encryption"
KEYS_DIR="/run/pinneos/keys"
PBKDF2_ITER=600000

die() { echo "ERROR: $*" >&2; exit 1; }

_gen_key() {
    local key_path="$1"
    mkdir -p "$KEYS_DIR"
    # 32 random bytes → 64 lowercase hex chars, no newline
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' > "$key_path"
    chmod 600 "$key_path"
}

_encrypt_to_persist() {
    local poolname="$1" passphrase="$2"
    local key_path="$KEYS_DIR/${poolname}.key"
    local enc_path="$PERSIST_DIR/${poolname}.key.enc"

    [ -f "$key_path" ] || die "Key file not found: $key_path"
    mkdir -p "$PERSIST_DIR" || die "Cannot create $PERSIST_DIR — is the USB persist partition mounted?"

    # AES-256-CBC + PBKDF2 (openssl enc does not support GCM mode)
    printf '%s\n' "$passphrase" | \
        openssl enc -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" \
            -in "$key_path" -out "$enc_path" -pass stdin
    chmod 600 "$enc_path"
}

_decrypt_from_persist() {
    local poolname="$1" passphrase="$2"
    local enc_path="$PERSIST_DIR/${poolname}.key.enc"
    local key_path="$KEYS_DIR/${poolname}.key"

    [ -f "$enc_path" ] || die "No keyfile on USB for pool '$poolname'"
    mkdir -p "$KEYS_DIR"

    if ! printf '%s\n' "$passphrase" | \
        openssl enc -d -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" \
            -in "$enc_path" -out "$key_path" -pass stdin 2>/dev/null; then
        rm -f "$key_path"
        die "Wrong passphrase"
    fi
    chmod 600 "$key_path"
}

# ── create-pool ───────────────────────────────────────────────────────────────

cmd_create_pool() {
    local poolname="$1"; shift
    local passphrase save_to_usb
    IFS= read -r passphrase
    IFS= read -r save_to_usb

    [ ${#passphrase} -ge 12 ] || die "Passphrase must be at least 12 characters"

    local key_path="$KEYS_DIR/${poolname}.key"
    _gen_key "$key_path"
    local recovery_hex
    recovery_hex=$(cat "$key_path")

    # Create pool with ZFS native encryption, key loaded from tmpfs
    zpool create -f "$poolname" \
        -O encryption=aes-256-gcm \
        -O keyformat=hex \
        -O "keylocation=file://${key_path}" \
        "$@"

    zfs set pinneos:managed=yes "$poolname"

    [ "$save_to_usb" = "true" ] && _encrypt_to_persist "$poolname" "$passphrase"

    echo "RECOVERY_KEY:${recovery_hex}"
    rm -f "$key_path"
}

# ── unlock ────────────────────────────────────────────────────────────────────

cmd_unlock() {
    local poolname="$1"
    local passphrase
    IFS= read -r passphrase

    local key_path="$KEYS_DIR/${poolname}.key"
    _decrypt_from_persist "$poolname" "$passphrase"

    if ! zfs load-key -L "file://${key_path}" "$poolname"; then
        rm -f "$key_path"
        die "zfs load-key failed"
    fi
    zfs mount -a 2>/dev/null || true
    rm -f "$key_path"
    rm -f /run/pinneos/unlock-needed
    echo "Pool '$poolname' unlocked."
}

# ── unlock-recovery ───────────────────────────────────────────────────────────

cmd_unlock_recovery() {
    local poolname="$1"
    local recovery_hex
    IFS= read -r recovery_hex

    echo "$recovery_hex" | grep -qE '^[0-9a-f]{64}$' || \
        die "Invalid recovery key — expected 64 lowercase hex characters"

    mkdir -p "$KEYS_DIR"
    local key_path="$KEYS_DIR/${poolname}.key"
    printf '%s' "$recovery_hex" > "$key_path"
    chmod 600 "$key_path"

    if ! zfs load-key -L "file://${key_path}" "$poolname"; then
        rm -f "$key_path"
        die "Recovery key rejected by ZFS"
    fi
    zfs mount -a 2>/dev/null || true
    rm -f "$key_path"
    rm -f /run/pinneos/unlock-needed
    echo "Pool '$poolname' unlocked with recovery key."
}

# ── change-passphrase ─────────────────────────────────────────────────────────

cmd_change_passphrase() {
    local poolname="$1"
    local old_passphrase new_passphrase
    IFS= read -r old_passphrase
    IFS= read -r new_passphrase

    [ ${#new_passphrase} -ge 12 ] || die "New passphrase must be at least 12 characters"

    local key_path="$KEYS_DIR/${poolname}.key"
    _decrypt_from_persist "$poolname" "$old_passphrase"
    _encrypt_to_persist   "$poolname" "$new_passphrase"
    rm -f "$key_path"
    echo "Passphrase changed."
}

# ── remove-keyfile ────────────────────────────────────────────────────────────

cmd_remove_keyfile() {
    local poolname="$1"
    rm -f "$PERSIST_DIR/${poolname}.key.enc"
    echo "Keyfile removed from USB."
}

# ── save-keyfile ──────────────────────────────────────────────────────────────

cmd_save_keyfile() {
    local poolname="$1"
    local passphrase recovery_hex
    IFS= read -r passphrase
    IFS= read -r recovery_hex

    [ ${#passphrase} -ge 12 ] || die "Passphrase must be at least 12 characters"
    echo "$recovery_hex" | grep -qE '^[0-9a-f]{64}$' || die "Invalid recovery key format"

    mkdir -p "$KEYS_DIR"
    local key_path="$KEYS_DIR/${poolname}.key"
    printf '%s' "$recovery_hex" > "$key_path"
    chmod 600 "$key_path"

    _encrypt_to_persist "$poolname" "$passphrase"
    rm -f "$key_path"
    echo "Keyfile saved to USB."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

CMD="${1:-}"
[ -n "$CMD" ] || { echo "Usage: zfs-encrypt.sh <command> [args]" >&2; exit 1; }
shift

case "$CMD" in
    create-pool)       cmd_create_pool "$@" ;;
    unlock)            cmd_unlock "$@" ;;
    unlock-recovery)   cmd_unlock_recovery "$@" ;;
    change-passphrase) cmd_change_passphrase "$@" ;;
    remove-keyfile)    cmd_remove_keyfile "$@" ;;
    save-keyfile)      cmd_save_keyfile "$@" ;;
    *) die "Unknown command: $CMD" ;;
esac
