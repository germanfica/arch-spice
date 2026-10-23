#!/usr/bin/env bash
set -Eeuo pipefail

# Install SPICE guest integration on Omarchy 4.x (Hyprland/Wayland).
# Safe to rerun as a regular user. Does not change display settings.

trap 'printf "\n[ERROR] Command failed at line %s.\n" "$LINENO" >&2' ERR
info() { printf '\n[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die 'Do not run as root.'
for cmd in pacman sudo systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done
[[ -r /dev/tty && -w /dev/tty ]] || die 'Interactive terminal required.'

packages=(spice-vdagent virt-viewer)
missing=()
for pkg in "${packages[@]}"; do
  if pacman -Q "$pkg" >/dev/null 2>&1; then
    info "Already installed: $pkg"
  else
    missing+=("$pkg")
  fi
done
if (( ${#missing[@]} )); then
  info 'Installing missing packages...'
  sudo pacman -S --needed "${missing[@]}" </dev/tty
fi

# Arch ships a socket-activated system daemon. Enable its socket,
# not the static spice-vdagentd.service.
info 'Activating SPICE system socket...'
sudo systemctl enable --now spice-vdagentd.socket

# Arch also ships a systemd user unit pulled in by graphical-session.target.
# Start it for the current session; systemd handles subsequent logins.
if [[ ${XDG_SESSION_TYPE:-} == wayland ]]; then
  if systemctl --user list-unit-files spice-vdagent.service --no-legend 2>/dev/null | grep -q '^spice-vdagent.service'; then
    info 'Starting SPICE session agent...'
    systemctl --user start spice-vdagent.service
  else
    info 'Session unit not found; check package installation.'
  fi
else
  info 'Not in Wayland; skipping manual session-agent start.'
fi

info 'SPICE installation completed. No Hyprland configuration changed.'
info 'Note: Wayland clipboard, file transfer and auto-resize depend on guest/client support.'
