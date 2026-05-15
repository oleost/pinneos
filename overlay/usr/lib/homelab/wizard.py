#!/usr/bin/env python3
"""PinneOS first-boot wizard — Phase 1 (network, hostname, password)."""

import os
import subprocess
import sys
import termios
import tty

# ── Terminal helpers ──────────────────────────────────────────────────────────

BOLD  = "\033[1m"
BLUE  = "\033[1;34m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
RED   = "\033[1;31m"
RESET = "\033[0m"
CLEAR = "\033c"


def out(text=""):
    print(text)


def clear():
    print(CLEAR, end="", flush=True)


def header(step, total, title):
    print(BLUE + "=" * 60 + RESET)
    print(BLUE + f"  PinneOS Setup  [{step}/{total}]  {title}" + RESET)
    print(BLUE + "=" * 60 + RESET)
    out()


def prompt(msg, default=""):
    hint = f" [{default}]" if default else ""
    try:
        val = input(f"  {msg}{hint}: ").strip()
    except EOFError:
        return default
    return val or default


def read_password(msg):
    print(f"  {msg}: ", end="", flush=True)
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    chars = []
    try:
        tty.setraw(fd)
        while True:
            ch = os.read(fd, 1).decode("utf-8", errors="replace")
            if ch in ("\n", "\r"):
                break
            elif ch in ("\x7f", "\x08"):
                if chars:
                    chars.pop()
                    sys.stdout.write("\b \b")
                    sys.stdout.flush()
            elif ch == "\x03":
                raise KeyboardInterrupt
            else:
                chars.append(ch)
                sys.stdout.write("*")
                sys.stdout.flush()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    print()
    return "".join(chars)


def pause(msg="  Press Enter to continue..."):
    try:
        input(msg)
    except EOFError:
        pass


# ── System actions ────────────────────────────────────────────────────────────

def get_ip():
    try:
        r = subprocess.run(
            ["ip", "-4", "addr", "show", "scope", "global"],
            capture_output=True, text=True, timeout=3,
        )
        for line in r.stdout.splitlines():
            if "inet " in line:
                return line.strip().split()[1].split("/")[0]
    except Exception:
        pass
    return None


def set_hostname(hostname):
    subprocess.run(["hostnamectl", "set-hostname", hostname], check=True)
    with open("/etc/hostname", "w") as f:
        f.write(hostname + "\n")


def set_password(password):
    proc = subprocess.run(
        ["chpasswd"],
        input=f"root:{password}",
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0


# ── Wizard screens ────────────────────────────────────────────────────────────

def screen_welcome():
    clear()
    header(1, 4, "Welcome")
    out(f"  Welcome to {BOLD}PinneOS{RESET}!")
    out()
    out("  This wizard sets up the basics before you open the")
    out("  web admin panel (Cockpit) to create your ZFS pool.")
    out()
    out("  What we'll configure:")
    out("    • Hostname  (how the server appears on the network)")
    out("    • Password  (for the root account)")
    out()
    out("  This takes about 2 minutes.")
    out()
    pause()


def screen_hostname():
    clear()
    header(2, 4, "Hostname")
    out("  Choose a name for this server.")
    out("  It will be reachable as  http://<hostname>.local")
    out()

    while True:
        hostname = prompt("Hostname", "pinneos")
        # basic validation: lowercase, letters/digits/hyphens, no leading hyphen
        if not hostname:
            out(f"  {YELLOW}! Hostname cannot be empty.{RESET}")
            continue
        if not all(c.isalnum() or c == "-" for c in hostname):
            out(f"  {YELLOW}! Use only letters, digits, and hyphens.{RESET}")
            continue
        if hostname.startswith("-"):
            out(f"  {YELLOW}! Hostname cannot start with a hyphen.{RESET}")
            continue
        break

    try:
        set_hostname(hostname)
        out(f"\n  {GREEN}✓ Hostname set to: {hostname}{RESET}")
    except Exception as e:
        out(f"\n  {YELLOW}! Could not set hostname: {e}{RESET}")

    pause()
    return hostname


def screen_password():
    clear()
    header(3, 4, "Admin password")
    out("  Set the password for the root account.")
    out(f"  {YELLOW}(minimum 8 characters){RESET}")
    out()

    while True:
        pw1 = read_password("New password")
        if len(pw1) < 8:
            out(f"  {YELLOW}! Password must be at least 8 characters.{RESET}\n")
            continue
        pw2 = read_password("Confirm password")
        if pw1 != pw2:
            out(f"  {YELLOW}! Passwords do not match.{RESET}\n")
            continue
        break

    if set_password(pw1):
        out(f"\n  {GREEN}✓ Password updated.{RESET}")
    else:
        out(f"\n  {YELLOW}! Failed to set password — use 'passwd' to set it manually.{RESET}")

    pause()


def screen_done(hostname):
    clear()
    header(4, 4, "Done")
    ip = get_ip()

    out(f"  {GREEN}Setup complete!{RESET}")
    out()

    if ip:
        out("  Open these in your browser:")
        out()
        out(f"  {BOLD}Dashboard{RESET}")
        out(f"    http://{ip}            (by IP)")
        out(f"    http://{hostname}.local      (by hostname)")
        out()
        out(f"  {BOLD}Admin panel (Cockpit){RESET}")
        out(f"    http://{ip}:9090")
        out(f"    http://{hostname}.local:9090")
        out()
        out(f"  {BOLD}Docker stacks (Dockge){RESET}")
        out(f"    http://{ip}:5001")
    else:
        out(f"  {YELLOW}No network detected — check your cable.{RESET}")
        out()
        out("  Once connected, open:")
        out(f"    http://{hostname}.local        (Dashboard)")
        out(f"    http://{hostname}.local:9090   (Cockpit)")
        out(f"    http://{hostname}.local:5001   (Dockge)")

    out()
    out("  Cockpit login:  root / <your new password>")
    out()
    out("  Next step: open Cockpit → PinneOS → ZFS tab")
    out("  and create a pool on your storage drives.")
    out()
    out("  " + "─" * 56)
    out(f"  Run {BOLD}pinneos-wizard{RESET} again at any time to re-run setup.")
    out("  " + "─" * 56)
    out()

    # Mark wizard as done so it doesn't auto-run on next login
    try:
        os.makedirs("/etc/homelab", exist_ok=True)
        open("/etc/homelab/.wizard-done", "w").close()
    except OSError:
        pass

    pause("  Press Enter to return to the login prompt...")


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    try:
        screen_welcome()
        hostname = screen_hostname()
        screen_password()
        screen_done(hostname)
    except KeyboardInterrupt:
        out(f"\n\n  {YELLOW}Wizard cancelled.{RESET} Run 'pinneos-wizard' to restart.")
        sys.exit(0)


if __name__ == "__main__":
    main()
