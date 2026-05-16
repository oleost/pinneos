#!/bin/sh
# Generate /etc/issue (pre-login) and /etc/motd (post-login) at boot.
# Both files are on the tmpfs overlay so writes are safe and ephemeral.
# Runs via pinneos-issue.service before getty starts.

. /etc/homelab/config 2>/dev/null || PINNEOS_VERSION="unknown"

_hn=$(hostname 2>/dev/null || echo "pinneos")
_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$_ip" ] && _ip="(no IP)"

# /etc/issue — shown on the physical console before login prompt.
# \l is replaced by getty with the tty name.
printf 'PinneOS v%s  \\l\n\n' "$PINNEOS_VERSION" > /etc/issue

# /etc/motd — shown after login (SSH, console, Cockpit terminal).
cat > /etc/motd <<EOF

  ____  _                       ___  ____
 |  _ \(_)_ __  _ __   ___  ___/ _ \/ ___|
 | |_) | | '_ \| '_ \ / _ \/ _ \ | | \___ \
 |  __/| | | | | | | |  __/ (_) | |_| |___) |
 |_|   |_|_| |_|_| |_|\___|\___/ \___/|____/

  PinneOS v${PINNEOS_VERSION}   host: ${_hn}   IP: ${_ip}

  Web admin   http://${_hn}:9090   (Cockpit)
  Docker UI   http://${_hn}:5001   (Dockge)
  Dashboard   http://${_hn}        (Homepage)

  First time? Run: pinneos-wizard

EOF
