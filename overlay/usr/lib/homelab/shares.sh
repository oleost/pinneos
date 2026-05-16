#!/bin/sh
# PinneOS file sharing backend — SMB shares and NFS exports.
# Called by the Cockpit Shares tab. All writes go through validated inputs.

set -e

SMB_CONF="/etc/samba/smb.conf"
EXPORTS="/etc/exports"

_smb_list() {
    python3 - << 'EOF'
import configparser, json
c = configparser.ConfigParser(interpolation=None)
c.read('/etc/samba/smb.conf')
shares = []
for s in c.sections():
    if s.lower() in ('global', 'homes', 'printers'):
        continue
    shares.append({
        'name': s,
        'path': c.get(s, 'path', fallback=''),
        'guest': c.get(s, 'guest ok', fallback='no').strip(),
        'readonly': c.get(s, 'read only', fallback='no').strip(),
    })
print(json.dumps(shares))
EOF
}

_smb_add() {
    local name="$1" path="$2" guest="${3:-yes}" readonly="${4:-no}"
    echo "$name" | grep -qE '^[a-zA-Z0-9_-]{1,32}$' \
        || { echo "Invalid share name (alphanumeric/dash/underscore, max 32 chars)" >&2; exit 1; }
    echo "$path" | grep -qE '^/' \
        || { echo "Path must be absolute" >&2; exit 1; }

    SHARE_NAME="$name" SHARE_PATH="$path" SHARE_GUEST="$guest" SHARE_READONLY="$readonly" \
    python3 - << 'EOF'
import configparser, os, sys
name     = os.environ['SHARE_NAME']
path     = os.environ['SHARE_PATH']
guest    = os.environ['SHARE_GUEST']
readonly = os.environ['SHARE_READONLY']
c = configparser.ConfigParser(interpolation=None)
c.read('/etc/samba/smb.conf')
if name in c.sections():
    print('Share [' + name + '] already exists', file=sys.stderr)
    sys.exit(1)
c.add_section(name)
c.set(name, 'path',           path)
c.set(name, 'browseable',     'yes')
c.set(name, 'read only',      readonly)
c.set(name, 'guest ok',       guest)
c.set(name, 'force user',     'homelab')
c.set(name, 'create mask',    '0664')
c.set(name, 'directory mask', '0775')
with open('/etc/samba/smb.conf', 'w') as f:
    c.write(f)
print('Share [' + name + '] added')
EOF
    systemctl restart smb nmb 2>/dev/null || true
}

_smb_remove() {
    local name="$1"
    echo "$name" | grep -qE '^[a-zA-Z0-9_-]{1,32}$' \
        || { echo "Invalid share name" >&2; exit 1; }

    SHARE_NAME="$name" python3 - << 'EOF'
import configparser, os, sys
name = os.environ['SHARE_NAME']
c = configparser.ConfigParser(interpolation=None)
c.read('/etc/samba/smb.conf')
if name not in c.sections():
    print('Share [' + name + '] not found', file=sys.stderr)
    sys.exit(1)
c.remove_section(name)
with open('/etc/samba/smb.conf', 'w') as f:
    c.write(f)
print('Share [' + name + '] removed')
EOF
    systemctl restart smb nmb 2>/dev/null || true
}

_nfs_list() {
    python3 - << 'EOF'
import json, re
exports = []
try:
    with open('/etc/exports', 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            m = re.match(r'^(\S+)\s+(.*)', line)
            if not m:
                continue
            path = m.group(1)
            rest = m.group(2).strip()
            cm = re.match(r'^(\S+)\(([^)]*)\)', rest)
            if cm:
                clients = cm.group(1)
                options = cm.group(2)
            else:
                clients = rest.split()[0] if rest.split() else '*'
                options = ''
            exports.append({'path': path, 'clients': clients, 'options': options})
except FileNotFoundError:
    pass
print(json.dumps(exports))
EOF
}

_nfs_add() {
    local path="$1" clients="${2:-*}" readonly="${3:-no}"
    echo "$path" | grep -qE '^/' \
        || { echo "Path must be absolute" >&2; exit 1; }
    local opts
    [ "$readonly" = "yes" ] \
        && opts="ro,sync,no_subtree_check,insecure" \
        || opts="rw,sync,no_subtree_check,insecure"

    NFS_PATH="$path" python3 - << 'EOF'
import os, re, sys
path = os.environ['NFS_PATH']
try:
    with open('/etc/exports', 'r') as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []
if any(re.match(r'^\s*' + re.escape(path) + r'[\s(]', l) for l in lines):
    print('Export already exists: ' + path, file=sys.stderr)
    sys.exit(1)
EOF
    printf '%s\t%s(%s)\n' "$path" "$clients" "$opts" >> "$EXPORTS"
    exportfs -ra 2>/dev/null || true
    echo "Export $path added"
}

_nfs_remove() {
    local path="$1"
    echo "$path" | grep -qE '^/' \
        || { echo "Path must be absolute" >&2; exit 1; }

    NFS_PATH="$path" python3 - << 'EOF'
import os, re, sys
path = os.environ['NFS_PATH']
try:
    with open('/etc/exports', 'r') as f:
        lines = f.readlines()
except FileNotFoundError:
    print('No exports file', file=sys.stderr); sys.exit(1)
pattern = re.compile(r'^\s*' + re.escape(path) + r'[\s(]')
new_lines = [l for l in lines if not pattern.match(l)]
if len(new_lines) == len(lines):
    print('Export not found: ' + path, file=sys.stderr); sys.exit(1)
with open('/etc/exports', 'w') as f:
    f.writelines(new_lines)
print('Export ' + path + ' removed')
EOF
    exportfs -ra 2>/dev/null || true
}

cmd="${1:-}"
[ -n "$cmd" ] || { echo "Usage: shares.sh <cmd> [args]" >&2; exit 1; }
shift

case "$cmd" in
    smb-list)   _smb_list ;;
    smb-add)    _smb_add "$@" ;;
    smb-remove) _smb_remove "$1" ;;
    nfs-list)   _nfs_list ;;
    nfs-add)    _nfs_add "$@" ;;
    nfs-remove) _nfs_remove "$1" ;;
    smb-status) systemctl is-active smb 2>/dev/null || true ;;
    nfs-status) systemctl is-active nfs-server 2>/dev/null || true ;;
    *) echo "Unknown command: $cmd" >&2; exit 1 ;;
esac
