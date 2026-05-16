#!/bin/sh
# PinneOS app installer backend — used by the Cockpit Apps tab.
#
# Usage:
#   apps.sh list                         Print apps.json with installed=true/false per app
#   apps.sh install <id> [<pool>]        Write compose file to /opt/stacks/<id>/
#   apps.sh setup   <id> [<pool>]        Run the app's setup commands (mkdir/chown)
#
# Installed detection: /opt/stacks/<id>/docker-compose.yml exists
# Stack directory: Dockge reads stacks from /opt/stacks/

set -e

APPS_JSON="/usr/share/pinneos/apps.json"
STACKS_DIR="/opt/stacks"

die() { echo "ERROR: $*" >&2; exit 1; }

# Resolve the managed ZFS pool name (first pool with pinneos:managed=yes)
_managed_pool() {
    zfs list -H -o name,pinneos:managed 2>/dev/null \
        | awk '$2=="yes"{print $1; exit}' \
        | cut -d/ -f1
}

cmd="$1"
shift || true

case "$cmd" in

list)
    # Output apps.json enriched with an "installed" boolean per app.
    # We use Python (available in the image) for clean JSON manipulation.
    python3 - "$STACKS_DIR" "$APPS_JSON" <<'PYEOF'
import json, sys, os

stacks_dir = sys.argv[1]
apps_file  = sys.argv[2]

with open(apps_file) as f:
    apps = json.load(f)

for app in apps:
    compose_path = os.path.join(stacks_dir, app['id'], 'docker-compose.yml')
    app['installed'] = os.path.isfile(compose_path)

print(json.dumps(apps))
PYEOF
    ;;

install)
    app_id="$1"
    pool="${2:-}"
    [ -n "$app_id" ] || die "install requires <id>"

    # Resolve pool: argument > managed pool > error
    if [ -z "$pool" ]; then
        pool=$(_managed_pool)
    fi
    [ -n "$pool" ] || die "No ZFS pool specified and no managed pool found"

    # Extract compose from apps.json for this id
    compose=$(python3 - "$APPS_JSON" "$app_id" "$pool" <<'PYEOF'
import json, sys

apps_file = sys.argv[1]
app_id    = sys.argv[2]
pool      = sys.argv[3]

with open(apps_file) as f:
    apps = json.load(f)

app = next((a for a in apps if a['id'] == app_id), None)
if not app:
    print("", end="")
    sys.exit(1)

compose = app.get('compose', '')
compose = compose.replace('{{POOL}}', pool)
print(compose, end="")
PYEOF
    )

    [ -n "$compose" ] || die "App '$app_id' not found in apps.json"

    # Write the compose file
    target_dir="${STACKS_DIR}/${app_id}"
    mkdir -p "$target_dir"
    printf '%s' "$compose" > "${target_dir}/docker-compose.yml"
    echo "Installed: ${target_dir}/docker-compose.yml"
    ;;

setup)
    app_id="$1"
    pool="${2:-}"
    [ -n "$app_id" ] || die "setup requires <id>"

    if [ -z "$pool" ]; then
        pool=$(_managed_pool)
    fi
    [ -n "$pool" ] || die "No ZFS pool specified and no managed pool found"

    setup_cmd=$(python3 - "$APPS_JSON" "$app_id" "$pool" <<'PYEOF'
import json, sys

apps_file = sys.argv[1]
app_id    = sys.argv[2]
pool      = sys.argv[3]

with open(apps_file) as f:
    apps = json.load(f)

app = next((a for a in apps if a['id'] == app_id), None)
if not app:
    sys.exit(0)

cmd = app.get('setup', '')
cmd = cmd.replace('{{POOL}}', pool)
print(cmd, end="")
PYEOF
    )

    if [ -n "$setup_cmd" ]; then
        echo "Running setup for $app_id..."
        sh -c "$setup_cmd"
        echo "Setup complete."
    else
        echo "No setup required for $app_id."
    fi
    ;;

*)
    die "Unknown command: $cmd (list | install | setup)"
    ;;
esac
