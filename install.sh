
#!/usr/bin/env bash
set -Eeuo pipefail

# Install SPICE integration on Arch Linux with i3.
# Safe to run multiple times as a regular user.

trap 'printf "\n[ERROR] Command failed at line %s.\n" "$LINENO" >&2' ERR

info() { printf '\n[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -ne 0 ]] || die 'Do not run this script as root.'
command -v pacman >/dev/null 2>&1 || die 'pacman was not found.'
command -v sudo >/dev/null 2>&1 || die 'sudo was not found.'
command -v systemctl >/dev/null 2>&1 || die 'systemctl was not found.'
[[ -r /dev/tty && -w /dev/tty ]] || die 'An interactive terminal is required.'

packages=(
  spice-vdagent
  virt-viewer
)

# Install only missing packages.
missing=()

for package in "${packages[@]}"; do
  if pacman -Q "$package" >/dev/null 2>&1; then
    info "Already installed: $package"
  else
    missing+=("$package")
  fi
done

if (( ${#missing[@]} > 0 )); then
  info 'Installing missing packages...'
  sudo pacman -S --needed "${missing[@]}" </dev/tty
else
  info 'All packages are already installed.'
fi

# Enable service only when necessary.
service='spice-vdagentd.service'

if ! systemctl is-enabled --quiet "$service"; then
  info "Enabling $service..."
  sudo systemctl enable "$service"
else
  info "Already enabled: $service"
fi

if ! systemctl is-active --quiet "$service"; then
  info "Starting $service..."
  sudo systemctl start "$service"
else
  info "Already running: $service"
fi

# Configure i3 autostart without duplicating entries.
i3_config="${XDG_CONFIG_HOME:-$HOME/.config}/i3/config"

if [[ ! -f "$i3_config" && -f "$HOME/.i3/config" ]]; then
  i3_config="$HOME/.i3/config"
fi

if [[ -f "$i3_config" ]]; then
  if grep -Eq '^[[:space:]]*exec(_always)?[[:space:]].*spice-vdagent([[:space:]]|$)' "$i3_config"; then
    info 'SPICE autostart is already configured in i3.'
  else
    info 'Adding SPICE autostart to i3...'
    printf '\n# SPICE guest agent\nexec --no-startup-id spice-vdagent\n' >> "$i3_config"
  fi
else
  info 'i3 configuration not found. Skipping autostart configuration.'
  info 'Initialize i3 first, then rerun this installer.'
fi

# Start the session agent if X11 is available.
if [[ -n "${DISPLAY:-}" && "${XDG_SESSION_TYPE:-x11}" == 'x11' ]]; then
  if pgrep -u "$(id -u)" -x spice-vdagent >/dev/null 2>&1; then
    info 'SPICE session agent is already running.'
  else
    info 'Starting SPICE session agent...'
    spice-vdagent
  fi
fi

info 'SPICE installation and configuration completed.'
