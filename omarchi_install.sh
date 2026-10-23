#!/usr/bin/env bash
set -Eeuo pipefail

# Omarchy / Hyprland / Wayland SPICE clipboard integration.
# Installs paprika-vdagent from its tagged upstream source, via makepkg.
# Does NOT configure display resizing or alter Hyprland configuration.

trap 'printf "\n[ERROR] Failed on line %s.\n" "$LINENO" >&2' ERR
info() { printf '\n[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die 'Run as a regular user, not root.'
[[ ${XDG_SESSION_TYPE:-} == wayland ]] || die 'Run from your Omarchy Wayland session.'
[[ -n ${WAYLAND_DISPLAY:-} ]] || die 'WAYLAND_DISPLAY is not set.'
[[ -r /dev/tty && -w /dev/tty ]] || die 'An interactive terminal is required.'
for cmd in pacman sudo systemctl git makepkg; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done

port=/dev/virtio-ports/com.redhat.spice.0
[[ -e "$port" ]] || die "Missing $port. In virt-manager, add a SPICE agent channel (spicevmc)."

# SPICE bridge needs Wayland data-control protocol support.
# Hyprland normally provides this; runtime availability is validated by the agent.
packages=(git base-devel rust pkgconf wayland acl wl-clipboard)
missing=()
for pkg in "${packages[@]}"; do
  pacman -Q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if (( ${#missing[@]} > 0 )); then
  info 'Installing build and clipboard dependencies...'
  sudo pacman -S --needed "${missing[@]}" </dev/tty
fi

if ! pacman -Q paprika-vdagent >/dev/null 2>&1; then
  info 'Building paprika-vdagent v0.1.1 from its upstream release tag...'
  build_dir=$(mktemp -d)
  trap 'rm -rf "${build_dir:-}"' EXIT
  git clone --quiet --depth 1 --branch v0.1.1 https://github.com/thelicato/paprika-vdagent.git "$build_dir/paprika-vdagent"
  (
    cd "$build_dir/paprika-vdagent/packaging/pacman"
    makepkg --syncdeps --install --noconfirm
  )
else
  info 'paprika-vdagent is already installed.'
fi

info 'Stopping traditional SPICE agents to prevent virtio channel conflicts...'
systemctl --user stop spice-vdagent.service 2>/dev/null || true
sudo systemctl disable --now spice-vdagentd.socket 2>/dev/null || true
sudo systemctl stop spice-vdagentd.service 2>/dev/null || true
# Stop only this user's traditional session agent, if still running.
pkill -u "$(id -u)" -x spice-vdagent 2>/dev/null || true

# Allow the active local seat access to the SPICE port on future logins.
# This intentionally grants local active-session access only, not world write permissions.
rule=/etc/udev/rules.d/70-omarchy-paprika-spice.rules
rule_text='SUBSYSTEM=="virtio-ports", KERNEL=="vport*", ATTR{name}=="com.redhat.spice.0", TAG+="uaccess"'
info 'Configuring active-seat access to the SPICE virtio port...'
printf '%s\n' "$rule_text" | sudo tee "$rule" >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=virtio-ports --action=change
sudo udevadm settle

# Some guest configurations do not apply uaccess retroactively until next login.
if [[ ! -r "$port" || ! -w "$port" ]]; then
  info 'Granting current user temporary access (until device recreation/reboot)...'
  sudo setfacl -m "u:$(id -un):rw" "$port"
fi
[[ -r "$port" && -w "$port" ]] || die "Cannot access $port even after ACL setup."

info 'Importing Wayland environment and starting paprika-vdagent...'
systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR HYPRLAND_INSTANCE_SIGNATURE
systemctl --user daemon-reload
systemctl --user enable --now paprika-vdagent.service

info 'Service status:'
systemctl --user --no-pager --full status paprika-vdagent.service || true
printf '\n[INFO] Test copying plain text in both directions between host and VM.\n'
printf '[INFO] Diagnose: journalctl --user -u paprika-vdagent.service -n 80 --no-pager\n'
printf '[INFO] No screen resizing or Hyprland settings were changed.\n'
