#!/usr/bin/env bash
set -Eeuo pipefail

# SPICE / Virtio display integration for Omarchy 4 (Hyprland + Lua + Wayland).
# Run inside the VM as a normal desktop user.
trap 'printf "[ERROR] Failed at line %s.\n" "$LINENO" >&2' ERR
info() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die 'Run as a regular user, not root.'
for cmd in pacman sudo systemctl hyprctl jq flock; do
  command -v "$cmd" >/dev/null 2>&1 || {
    if [[ "$cmd" == jq || "$cmd" == flock ]]; then continue; fi
    die "Required command missing: $cmd"
  }
done
[[ ${XDG_SESSION_TYPE:-} == wayland ]] || die 'A Wayland session is required.'
hyprctl monitors -j >/dev/null 2>&1 || die 'Run this from an active Hyprland session.'
[[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/autostart.lua" ]] || die 'Omarchy 4 autostart.lua not found (older Omarchy version?).'

packages=(spice-vdagent jq)
missing=()
for package in "${packages[@]}"; do
  pacman -Q "$package" >/dev/null 2>&1 || missing+=("$package")
done
if ((${#missing[@]})); then
  info 'Installing dependencies...'
  sudo pacman -S --needed "${missing[@]}"
fi

# Guest daemon. X11 spice-vdagent session process is not started in Wayland.
if systemctl list-unit-files spice-vdagentd.socket --no-legend 2>/dev/null | grep -q '^spice-vdagentd.socket'; then
  sudo systemctl enable --now spice-vdagentd.socket
elif systemctl list-unit-files spice-vdagentd.service --no-legend 2>/dev/null | grep -q '^spice-vdagentd.service'; then
  sudo systemctl enable --now spice-vdagentd.service
else
  warn 'No spice-vdagentd systemd unit found.'
fi

# Only install/start QEMU guest agent when the corresponding virtio port exists.
if [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then
  sudo pacman -S --needed qemu-guest-agent
  sudo systemctl enable --now qemu-guest-agent.service
else
  info 'QEMU guest agent channel not present; skipping qemu-guest-agent.'
fi

bin_dir="$HOME/.local/bin"
helper="$bin_dir/omarchy-spice-resize"
mkdir -p "$bin_dir"
cat > "$helper" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail

# Sync Virtio-GPU DRM preferred mode to Hyprland's Lua monitor API.
# Polling is intentionally unprivileged: no sudo/udev monitor permissions needed.
command -v jq >/dev/null || exit 1
command -v hyprctl >/dev/null || exit 1
command -v flock >/dev/null || exit 1

lock_dir="${XDG_RUNTIME_DIR:-/tmp}"
exec 9>"$lock_dir/omarchy-spice-resize-$(id -u).lock"
flock -n 9 || exit 0

declare -A last_mode=()
while :; do
  monitors=$(hyprctl monitors -j 2>/dev/null) || { sleep 2; continue; }
  while IFS= read -r output; do
    [[ $output =~ ^[A-Za-z0-9_-]+$ ]] || continue
    # Usually Virtual-1. Find DRM connector dynamically (card numbers vary).
    drm_path=''
    for candidate in /sys/class/drm/card*-"$output"; do
      if [[ -r "$candidate/modes" ]]; then
        drm_path="$candidate"
        break
      fi
    done
    [[ -n $drm_path ]] || continue
    IFS= read -r mode < "$drm_path/modes" || true
    [[ $mode =~ ^[0-9]+x[0-9]+$ ]] || continue
    [[ ${last_mode[$output]:-} != "$mode" ]] || continue

    # Hyprland 0.55+ Lua config provider, not the legacy 'keyword monitor'.
    if result=$(hyprctl eval "hl.monitor({ output = \"${output}\", mode = \"${mode}@60\", position = \"auto\", scale = 1 })" 2>&1) && [[ "$result" == *ok* ]]; then
      last_mode[$output]="$mode"
      printf '[SPICE] %s -> %s\n' "$output" "$mode"
    else
      printf '[SPICE] Could not set %s to %s: %s\n' "$output" "$mode" "$result" >&2
      # Avoid flooding Hyprland when driver has no applicable mode.
      last_mode[$output]="$mode"
    fi
  done < <(jq -r '.[] | select(.name | startswith("Virtual-")) | .name' <<< "$monitors")
  sleep 1
 done
HELPER
chmod 755 "$helper"

# Insert a distinctly delimited, repeatable Omarchy 4 Lua startup hook.
autostart="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/autostart.lua"
start_marker='-- BEGIN omarchy-spice-resize (managed)'
if ! grep -Fq "$start_marker" "$autostart"; then
  info 'Registering automatic startup in Omarchy 4...'
  cp -a "$autostart" "${autostart}.bak.$(date +%Y%m%d%H%M%S)"
  cat >> "$autostart" <<'LUA'

-- BEGIN omarchy-spice-resize (managed)
o.launch_on_start("$HOME/.local/bin/omarchy-spice-resize")
-- END omarchy-spice-resize (managed)
LUA
else
  info 'Autostart was already configured.'
fi

# Start in the current session as well. Start only one process per user.
info 'Starting the resize watcher for the current Hyprland session...'
nohup "$helper" >"${XDG_RUNTIME_DIR:-/tmp}/omarchy-spice-resize.log" 2>&1 </dev/null &
info 'Installation complete. Resize the virt-manager window to test.'
info "Log: ${XDG_RUNTIME_DIR:-/tmp}/omarchy-spice-resize.log"
info 'Requires a Virtio GPU with a DRM virtual connector that reports window size.'
