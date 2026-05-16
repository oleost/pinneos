#!/bin/sh
# Dynamic login banner — shown after successful login

. /etc/homelab/config 2>/dev/null || PINNEOS_VERSION="unknown"

_hn=$(hostname 2>/dev/null || echo "pinneos")
_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$_ip" ] && _ip="(no IP)"

cat <<EOF

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
