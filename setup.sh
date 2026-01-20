#!/usr/bin/env bash
set -Eeuo pipefail

# ===== ROOT CHECK =====
if [ "$EUID" -ne 0 ]; then
  echo "[INFO] Script not run as root. Re-executing with sudo..."
  exec sudo -E bash "$0" "$@"
fi

# ===== CONFIG =====
USER_NAME=pi
USER_HOME=/home/pi
TARGET_DOCKER_MAJOR=29
LOG_FILE_PATH="./logs/setup.log"
BASE_PACKAGES=(curl ca-certificates gnupg jq)
# ==================

install_file() {
  local src="$1"
  local dst="$2"
  local owner="$3"
  local group="$4"
  local mode="$5"

  mkdir -p "$(dirname "$dst")"

  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    return 1
  fi

  cp "$src" "$dst"
  chown "$owner:$group" "$dst"
  chmod "$mode" "$dst"

  return 0
}

# ===== LOG DIRECTORY SETUP =====
mkdir -p "$(dirname "$LOG_FILE_PATH")"
# ==================

# ===== LOG & RUN FUNCTIONS =====
# log <LEVEL> <MESSAGE>
log() {
    local level="$1"; shift
    local timestamp
    timestamp="$(date '+%F %T')"
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$*" | tee -a "$LOG_FILE_PATH"
}
# run <COMMAND ...>
# Executes the command, logs both stdout and stderr
run() {
    log INFO "Running command: $*"
    {
        "$@"
        local exit_code=$?
        echo "Command exited with code: $exit_code"
    } >>"$LOG_FILE_PATH" 2>&1
}
# ==================

# ===== ERROR TRAP =====
trap 'log FATAL "Error occurred at line $LINENO. Setup aborted."' ERR
# ==================

# ===== PACKAGE INSTALLATION =====
# install_if_missing <PACKAGE_NAME>
# Checks if a package is installed, installs it if missing
install_if_missing() {
    local pkg="$1"

    if dpkg -s "$pkg" &>/dev/null; then
        log INFO "Package '$pkg' is already installed."
    else
        log INFO "Package '$pkg' not found. Installing..."
        run apt-get install -y "$pkg"
    fi
}

# Install base packages
install_base_packages() {
    log INFO "Installing base packages..."
    for pkg in "${BASE_PACKAGES[@]}"; do
        install_if_missing "$pkg"
    done
    log INFO "Base packages installation completed."
}
# ==================


# ===== DOCKER FUNCTIONS =====

# Check if docker command exists
docker_installed() {
    command -v docker >/dev/null 2>&1
}

# Get Docker server major version
docker_major_version() {
    # Wait for Docker service to become active (max 10s)
    local timeout=10
    local waited=0
    until systemctl is-active --quiet docker; do
        sleep 1
        waited=$((waited+1))
        if [ $waited -ge $timeout ]; then
            log FATAL "Docker service did not start within $timeout seconds. Aborting."
            exit 1
        fi
    done

    docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1 || echo ""
}


# Add Docker official repository
install_docker_repo() {
    log INFO "Adding official Docker repository..."

    install -d -m 0755 /etc/apt/keyrings

    # Add GPG key if missing
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        log INFO "Docker GPG key added."
    else
        log INFO "Docker GPG key already exists, skipping."
    fi

    # Detect Ubuntu codename
    CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

    # Add repo if missing
    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" \
            | tee /etc/apt/sources.list.d/docker.list > /dev/null
        log INFO "Docker repository added."
    else
        log INFO "Docker repository already exists, skipping."
    fi
}

# Install Docker packages
install_docker_packages() {
    install_docker_repo
    run apt-get update
    run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# Install or update Docker
setup_docker() {
    log INFO "Checking Docker installation..."

    if ! docker_installed; then
        log INFO "Docker not installed. Installing..."
        install_docker_packages
        return
    fi

    CURRENT_MAJOR=$(docker_major_version)

    if [ -z "$CURRENT_MAJOR" ] || [ "$CURRENT_MAJOR" != "$TARGET_DOCKER_MAJOR" ]; then
        log FATAL "Docker major version $CURRENT_MAJOR.x does not match target $TARGET_DOCKER_MAJOR.x. Aborting setup."
        exit 1
    fi

    log INFO "Docker $CURRENT_MAJOR.x is already installed."
}

# Enables and starts Docker service
enable_docker_service() {
    log INFO "Enabling Docker service..."
    run systemctl enable --now docker
}

# Adds user to docker group if not already a member
add_user_to_docker_group() {
    if id -nG "$USER_NAME" | grep -qw docker; then
        log INFO "$USER_NAME is already in the docker group, skipping."
    else
        log INFO "Adding $USER_NAME to the docker group..."
        run usermod -aG docker "$USER_NAME"
    fi
}
# ==================

# ===== GNOME / Xhost SETUP =====

# Disable screen blanking and GNOME notifications
disable_gnome_idle_and_notifications() {
    local schema_dir="/usr/share/glib-2.0/schemas"
    local target="$schema_dir/90-kiosk-settings.gschema.override"
    local source="setup/gnome/90-kiosk-settings.gschema.override"

    log INFO "Checking GNOME kiosk settings..."

    if install_file "$source" "$target" root root 644; then
        log INFO "GNOME kiosk settings updated."
        log INFO "Compiling GNOME schemas..."
        run glib-compile-schemas "$schema_dir"
        log INFO "GNOME schemas compiled successfully."
    else
        log INFO "GNOME kiosk settings already applied. No changes needed."
    fi
}

# Create Xhost autostart script
setup_xhost_autostart() {
    local autostart_dir="$USER_HOME/.config/autostart"

    local script_src="setup/xhost/enable_xhost.sh"
    local script_dst="/usr/local/bin/enable_xhost.sh"

    local desktop_src="setup/xhost/xhost.desktop"
    local desktop_dst="$autostart_dir/xhost.desktop"

    log INFO "Checking Xhost autostart configuration..."

    mkdir -p "$autostart_dir"

    local changed=false

    if install_file "$script_src" "$script_dst" root root 755; then
        log INFO "Xhost script installed/updated."
        changed=true
    fi

    if install_file "$desktop_src" "$desktop_dst" "$USER_NAME" "$USER_NAME" 644; then
        log INFO "Xhost autostart desktop entry installed/updated."
        changed=true
    fi

    if [ "$changed" = false ]; then
        log INFO "Xhost autostart already configured. No changes needed."
    fi
}


# Ensure DISPLAY variable in .bashrc
ensure_display_in_bashrc() {
    local line="export DISPLAY=:0"
    local bashrc="$USER_HOME/.bashrc"

    if grep -Fxq "$line" "$bashrc"; then
        log INFO "DISPLAY already set in $bashrc, skipping."
    else
        echo "$line" >> "$bashrc"
        chown "$USER_NAME:$USER_NAME" "$bashrc"
        log INFO "DISPLAY added to $bashrc"
    fi
}

# ==================

# ===== SYSTEM NOTIFICATIONS & UPDATE SETTINGS =====

# Disable apport crash reporting
disable_apport() {
    local apport_file="/etc/default/apport"

    if [ -f "$apport_file" ]; then
        # Check if already disabled
        if grep -q '^enabled=0' "$apport_file"; then
            log INFO "Apport crash reporting already disabled, skipping."
        else
            sed -i 's/enabled=1/enabled=0/' "$apport_file"
            log INFO "Apport crash reporting disabled in config file."
        fi
    fi

    run systemctl stop apport || true
    run systemctl disable apport || true
}

# Disable release upgrade prompts
disable_release_upgrade_prompt() {
    local update_file="/etc/update-manager/release-upgrades"

    if [ -f "$update_file" ]; then
        # Check if already set
        if grep -q '^Prompt=never' "$update_file"; then
            log INFO "Release upgrade prompt already disabled, skipping."
        else
            sed -i 's/^Prompt=.*$/Prompt=never/' "$update_file"
            log INFO "Release upgrade prompt disabled."
        fi
    fi
}

# Disable Software Updater popup (update-notifier) — idempotent
disable_update_notifier_popup() {
    local desktop_file="/etc/xdg/autostart/update-notifier.desktop"

    if [ ! -f "$desktop_file" ]; then
        log INFO "update-notifier autostart file not found, skipping."
        return
    fi

    if [ ! -x "$desktop_file" ]; then
        log INFO "Update-notifier autostart already disabled, skipping."
        return
    fi

    chmod -x "$desktop_file"
    log INFO "Update-notifier autostart disabled."
}

# ==================

# ===== UPDATER SERVICE =====
setup_edge_updater() {
    log INFO "Setting up Edge OTA Updater service..."

    local UPDATER_DIR="updater"
    local UPDATER_SCRIPT="$UPDATER_DIR/update.sh"
    local SERVICE_SRC="$UPDATER_DIR/edge-updater.service"
    local TIMER_SRC="$UPDATER_DIR/edge-updater.timer"
    local SERVICE_DST="/etc/systemd/system/edge-updater.service"
    local TIMER_DST="/etc/systemd/system/edge-updater.timer"

    chmod +x "$UPDATER_SCRIPT"

    log INFO "Installing systemd service and timer..."

    if install_file "$SERVICE_SRC" "$SERVICE_DST" root root 644; then
        log INFO "Edge updater service file installed/updated."
    else
        log INFO "Edge updater service file already exists, skipping."
    fi

    if install_file "$TIMER_SRC" "$TIMER_DST" root root 644; then
        log INFO "Edge updater timer file installed/updated."
    else
        log INFO "Edge updater timer file already exists, skipping."
    fi

    log INFO "Reloading systemd daemon..."
    run systemctl daemon-reload || log INFO "systemctl daemon-reload failed but continuing."

    log INFO "Enabling and starting updater timer..."
    run systemctl enable --now edge-updater.timer || log INFO "Enabling timer failed but continuing."

    sleep 2
    local status
    status=$(systemctl is-active edge-updater.timer || true)
    if [[ "$status" == "active" ]]; then
        log INFO "Edge updater timer is active."
    else
        log FATAL "Edge updater timer is not active! Current status: $status"
        return 1
    fi
}
# ==================

# ===== INITIAL STATE =====

# Initialize edge-agent state file with default versions if missing
bootstrap_edge_agent_state() {
    local state_dir="/var/lib/edge-agent"
    local state_file="$state_dir/state.json"

    if [ -f "$state_file" ]; then
        log INFO "Edge agent state already exists, skipping bootstrap."
        return
    fi

    log INFO "Bootstrapping initial edge agent state..."

    mkdir -p "$state_dir"
    cp setup/state/initial-state.json "$state_file"
    chown root:root "$state_file"
    chmod 644 "$state_file"

    log INFO "Initial edge agent state created."
}
# ==================


main() {
    log INFO "== RPI Setup Started =="

    # 1. Base packages
    install_base_packages

    # 2. Docker
    setup_docker
    enable_docker_service
    add_user_to_docker_group

    # 3. GNOME / Display
    disable_gnome_idle_and_notifications
    setup_xhost_autostart
    ensure_display_in_bashrc

    # 4. System notifications / updates
    disable_apport
    disable_release_upgrade_prompt
    disable_update_notifier_popup

    # 5. Setup updater
    setup_edge_updater

    # 6. Initial state
    bootstrap_edge_agent_state

    log INFO "== Setup Completed =="
    log INFO "Rebooting the device for changes to take effect..."
    sleep 5
    reboot
}

main