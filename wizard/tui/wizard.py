#!/usr/bin/env python3
"""PinneOS first-boot wizard"""
import os
import sys
import re
import json
import getpass
import subprocess
import signal

HOMELAB_DIR = "/etc/homelab"
BACKUP_UUID_FILE = f"{HOMELAB_DIR}/backup-usb-uuid"


def clear():
    os.system('clear')


def header(step, total, title):
    clear()
    print()
    print("  \033[1;36mPinneOS Setup Wizard\033[0m  ·  "
          f"Step {step} of {total}")
    print("  " + "─" * 50)
    print(f"  \033[1m{title}\033[0m")
    print()


def info(msg):  print(f"  \033[2m{msg}\033[0m")
def ok(msg):    print(f"  \033[32m✓  {msg}\033[0m")
def warn(msg):  print(f"  \033[33m!  {msg}\033[0m")
def fail(msg):  print(f"  \033[31m✗  {msg}\033[0m")


def ask(prompt, default='', secret=False):
    suffix = f" [{default}]" if default else ""
    full_prompt = f"  {prompt}{suffix}: "
    val = getpass.getpass(full_prompt) if secret else input(full_prompt).strip()
    return val or default


def run(*args):
    return subprocess.run(list(args), capture_output=True, text=True)


def wait_enter(msg="  Press Enter to continue…"):
    try:
        input(msg)
    except EOFError:
        pass


def fmt_size(n):
    try:
        n = int(n)
    except Exception:
        return '?'
    if n >= 1 << 30:
        return f"{n / (1 << 30):.1f} GiB"
    if n >= 1 << 20:
        return f"{n / (1 << 20):.1f} MiB"
    return f"{n} B"


# ── Screen 1: Welcome ─────────────────────────────────────────────────────────

def screen_welcome():
    clear()
    print()
    print("  ┌─────────────────────────────────────────────────────┐")
    print("  │                                                     │")
    print("  │   \033[1;36mWelcome to PinneOS\033[0m                               │")
    print("  │                                                     │")
    print("  │   This wizard takes about 2 minutes and sets up:   │")
    print("  │     • Hostname                                      │")
    print("  │     • Admin password                                │")
    print("  │     • Backup USB  (optional)                        │")
    print("  │                                                     │")
    print("  └─────────────────────────────────────────────────────┘")
    print()
    wait_enter("  Press Enter to begin…")


# ── Screen 2: Hostname ────────────────────────────────────────────────────────

def screen_hostname():
    header(1, 3, "Hostname")
    info("How this server identifies itself on the network.")
    info("Reachable at  http://<hostname>.local  after setup.")
    print()

    r = run('/usr/bin/hostnamectl', '--static')
    current = r.stdout.strip() if r.returncode == 0 else 'pinneos'

    while True:
        name = ask("Hostname", default=current or 'pinneos')
        if re.match(r'^[a-zA-Z0-9][a-zA-Z0-9\-]{0,62}$', name):
            break
        fail("Invalid — letters, digits and hyphens only, no leading hyphen.")

    r = run('/usr/bin/hostnamectl', 'set-hostname', name)
    if r.returncode == 0:
        ok(f"Hostname set to  \033[1m{name}\033[0m")
        info(f"Reachable at  http://{name}.local")
    else:
        warn("hostnamectl failed — set it later in Cockpit → Setup.")

    print()
    wait_enter()
    return name


# ── Screen 3: Admin password ──────────────────────────────────────────────────

def screen_password():
    header(2, 3, "Admin password")
    info("Password for the root account (console + Cockpit).")
    info("Without a ZFS pool this resets on every reboot.")
    print()

    while True:
        pw1 = ask("New password", secret=True)
        if len(pw1) < 8:
            fail("Minimum 8 characters.")
            continue
        pw2 = ask("Confirm", secret=True)
        if pw1 != pw2:
            fail("Passwords do not match.")
            continue
        break

    proc = subprocess.run(
        ['/usr/bin/chpasswd'],
        input=f'root:{pw1}\n',
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0:
        ok("Password changed.")
    else:
        warn("chpasswd failed — change it via Cockpit after setup.")

    print()
    wait_enter()


# ── Screen 4: Backup USB ──────────────────────────────────────────────────────

def get_boot_disk():
    """Find the parent disk of the currently booted USB slot."""
    for label in ('PINNEOS_A', 'PINNEOS_B'):
        r = run('/usr/bin/findfs', f'LABEL={label}')
        if r.returncode == 0:
            part = r.stdout.strip()
            p = run('/usr/bin/lsblk', '-no', 'PKNAME', part)
            if p.returncode == 0 and p.stdout.strip():
                return '/dev/' + p.stdout.strip()
    return ''


def find_backup_candidates(boot_disk):
    """Return PinneOS USB sticks that are NOT the current boot device."""
    r = run('/usr/bin/lsblk', '-J', '-b', '-o',
            'NAME,SIZE,MODEL,TYPE,LABEL,UUID')
    if r.returncode != 0:
        return []
    try:
        data = json.loads(r.stdout)
    except Exception:
        return []

    candidates = []
    for dev in data.get('blockdevices', []):
        if dev.get('type') != 'disk':
            continue
        disk = '/dev/' + dev['name']
        if disk == boot_disk:
            continue
        for child in (dev.get('children') or []):
            if child.get('label') == 'PINNEOS_A' and child.get('uuid'):
                candidates.append({
                    'disk':  disk,
                    'part':  '/dev/' + child['name'],
                    'uuid':  child['uuid'],
                    'model': (dev.get('model') or 'Unknown').strip(),
                    'size':  dev.get('size', 0),
                })
    return candidates


def screen_backup_usb():
    header(3, 3, "Backup USB  (optional)")
    info("A second PinneOS USB, also written with Etcher, kept plugged in.")
    info("Auto-synced on plug-in and after updates — instant fallback.")
    print()

    boot_disk = get_boot_disk()
    candidates = find_backup_candidates(boot_disk)

    if not candidates:
        warn("No other PinneOS USB detected.")
        print()
        info("Write the .img.zst to a second USB with Etcher, plug it in,")
        info("then register it in  Cockpit → Setup → Backup USB.")
        print()
        wait_enter()
        return

    print("  Detected PinneOS USB sticks:")
    print()
    for i, c in enumerate(candidates, 1):
        print(f"  [{i}]  {c['disk']}  —  {c['model']}  —  {fmt_size(c['size'])}")
    print("  [s]  Skip — register later in Cockpit")
    print()

    chosen = None
    while chosen is None:
        ans = ask("Select backup USB").lower()
        if ans in ('s', 'skip', ''):
            info("Skipped. Register later in Cockpit → Setup.")
            print()
            wait_enter()
            return
        try:
            idx = int(ans) - 1
            if 0 <= idx < len(candidates):
                chosen = candidates[idx]
        except ValueError:
            pass
        if chosen is None:
            fail("Enter a number or 's' to skip.")

    os.makedirs(HOMELAB_DIR, exist_ok=True)
    with open(BACKUP_UUID_FILE, 'w') as f:
        f.write(chosen['uuid'] + '\n')

    print()
    ok(f"Registered  \033[1m{chosen['disk']}\033[0m  ({chosen['model']})  as backup USB.")
    info(f"Slot A UUID: {chosen['uuid']}")
    print()
    wait_enter()


# ── Screen 5: Done ────────────────────────────────────────────────────────────

def screen_done(hostname):
    clear()

    r = run('/usr/bin/ip', '-4', 'addr', 'show', 'scope', 'global')
    ip = ''
    for line in r.stdout.splitlines():
        if 'inet ' in line and 'docker' not in line:
            m = re.search(r'inet (\d+\.\d+\.\d+\.\d+)', line)
            if m:
                ip = m.group(1)
                break

    host = hostname or 'pinneos'
    base = ip if ip else f"{host}.local"

    print()
    print("  \033[1;32m✓  Setup complete!\033[0m")
    print()
    print("  Open in your browser:")
    print()
    print(f"    Dashboard  →  http://{base}")
    print(f"    Cockpit    →  http://{base}:9090")
    print(f"    Dockge     →  http://{base}:5001")
    print()
    print("  Next: create a ZFS pool in  Cockpit → PinneOS.")
    print()

    os.makedirs(HOMELAB_DIR, exist_ok=True)
    open(f"{HOMELAB_DIR}/.wizard-done", "w").close()

    wait_enter("  Press Enter to return to login prompt…")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    signal.signal(signal.SIGINT,
                  lambda *_: (print('\n\n  Wizard cancelled.\n'), sys.exit(0)))

    if os.geteuid() != 0:
        print("Run as root.")
        sys.exit(1)

    screen_welcome()
    hostname = screen_hostname()
    screen_password()
    screen_backup_usb()
    screen_done(hostname)


if __name__ == '__main__':
    main()
