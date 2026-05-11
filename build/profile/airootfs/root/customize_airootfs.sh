#!/usr/bin/env bash
# Runs inside the archiso chroot after all packages are installed
# and the airootfs overlay has been applied.
# NOTE: Do NOT call mkinitcpio here — archiso runs it automatically after this script.

set -euo pipefail

echo "==> PinneOS: customize_airootfs.sh starting..."

# ── Locale & timezone ─────────────────────────────────────────────────────────
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# ── Hostname ──────────────────────────────────────────────────────────────────
echo "pinneos" > /etc/hostname
cat > /etc/hosts << 'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   pinneos.local pinneos
EOF

# ── mDNS (.local resolution) ─────────────────────────────────────────────────
sed -i 's/^hosts:.*/hosts: mymachines mdns4_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' \
    /etc/nsswitch.conf

# ── Static ZFS hostid ────────────────────────────────────────────────────────
# Without this, zpool import fails with "pool was last accessed by another system".
zgenhostid

# ── Build ZFS kernel module via DKMS ─────────────────────────────────────────
# Compiles zfs.ko against the linux-lts kernel baked into this rootfs.
# archiso runs mkinitcpio AFTER this script.
# zfs-dkms 2.4.1 (OpenZFS Dec 2025) has native kernel 6.16+ support — no patches needed.
echo "==> Building ZFS kernel module (this takes ~5 min)..."
KVER=$(ls /usr/lib/modules | grep -- '-lts$' | sort -V | tail -1)
if [ -z "$KVER" ]; then
    echo "ERROR: Could not find linux-lts kernel in /usr/lib/modules"
    exit 1
fi
echo "    Kernel: $KVER"
ZFS_SRC=$(find /usr/src -maxdepth 1 -name "zfs-*" -type d | head -1)
echo "    ZFS source: ${ZFS_SRC:-NOT FOUND}"

echo "    Building all registered DKMS modules for $KVER..."
if ! dkms autoinstall -k "${KVER}"; then
    echo "==> DKMS build FAILED. Dumping logs..."
    find /var/lib/dkms -name "make.log" | while read -r f; do
        echo "--- ${f} ---"; cat "${f}"
    done
    echo "==> config.log (last 60 lines):"
    find /var/lib/dkms -name "config.log" -exec tail -60 {} \;
    exit 1
fi
echo "==> ZFS module built and installed."

# ── Docker daemon config ──────────────────────────────────────────────────────
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

# ── sudo for wheel group ──────────────────────────────────────────────────────
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ── Enable systemd services ───────────────────────────────────────────────────
systemctl enable NetworkManager.service
systemctl enable avahi-daemon.service
systemctl enable sshd.service
systemctl enable docker.service
systemctl enable cockpit.socket
systemctl enable pinneos-persist.service
systemctl enable pinneos-zfs-import.service
systemctl enable pinneos-update-check.timer
systemctl enable pinneos-panel.service

# ── Panel directories ─────────────────────────────────────────────────────────
mkdir -p /opt/stacks

# ── Root shell + password ─────────────────────────────────────────────────────
# Releng sets root's shell to /usr/bin/zsh, but we don't install zsh.
# pam_shells.so rejects login if the shell isn't in /etc/shells — fix it.
usermod -s /bin/bash root
# Force SHA-512 (more compatible than yescrypt in live PAM stack).
sed -i 's/^ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' /etc/login.defs
echo "root:pinneos" | chpasswd
echo "  Root shell: $(grep "^root:" /etc/passwd | cut -d: -f7)"
echo "  Shadow entry (should start with \$6\$):"
grep "^root:" /etc/shadow | cut -d: -f1-3

# ── PinneOS config directory ─────────────────────────────────────────────────
mkdir -p /etc/homelab
chmod 755 /etc/homelab

# Stamp version from build env into the live image
VERSION_FILE="/etc/pinneos-version"
if [ -f "$VERSION_FILE" ]; then
    cp "$VERSION_FILE" /etc/homelab/version
else
    echo "dev" > /etc/homelab/version
fi

# ── Ensure scripts are executable ────────────────────────────────────────────
chmod +x /usr/lib/homelab/*.sh /usr/lib/homelab/wizard.py 2>/dev/null || true
ln -sf /usr/lib/homelab/wizard.py /usr/local/bin/pinneos-wizard

echo "==> PinneOS: customize_airootfs.sh done."
