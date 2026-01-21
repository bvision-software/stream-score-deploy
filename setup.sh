#!/usr/bin/env bash
set -Eeuo pipefail

# ===== ROOT CHECK =====
if [ "$EUID" -ne 0 ]; then
  echo "[INFO] Script not run as root. Re-executing with sudo..."
  exec sudo -E bash "$0" "$@"
fi

ACTION="${1:-install}"

case "$ACTION" in
  install|uninstall)
    ;;
  *)
    echo "Usage: $0 {install|uninstall}"
    exit 1
    ;;
esac

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
# ==========================================================================================
install_if_missing() {
    local pkg="$1"

    if dpkg -s "$pkg" &>/dev/null; then
        log INFO "Package '$pkg' is already installed."
    else
        log INFO "Package '$pkg' not found. Installing..."
        run apt-get install -y "$pkg"
    fi
}
uninstall_if_installed() {
    local pkg="$1"

    if dpkg -s "$pkg" &>/dev/null; then
        log INFO "Package '$pkg' is installed. Removing..."
        run apt-get remove -y "$pkg"
    else
        log INFO "Package '$pkg' is not installed, skipping."
    fi
}
# ==========================================================================================

# ==========================================================================================
install_base_packages() {
    log INFO "Installing base packages..."
    for pkg in "${BASE_PACKAGES[@]}"; do
        install_if_missing "$pkg"
    done
    log INFO "Base packages installation completed."
}

uninstall_base_packages() {
    log INFO "Uninstalling base packages..."

    for pkg in "${BASE_PACKAGES[@]}"; do
        uninstall_if_installed "$pkg"
    done

    log INFO "Base packages removal completed."
}
# ==========================================================================================


# ===== DOCKER =====

docker_installed() {
    command -v docker >/dev/null 2>&1
}

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

# ==========================================================================================
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

uninstall_docker_repo() {
    log INFO "Removing Docker repository..."

    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.asc

    run apt-get update
}
# ==========================================================================================

# ==========================================================================================
install_docker_packages() {
    install_docker_repo
    run apt-get update
    run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

uninstall_docker_packages() {
    uninstall_docker_repo
    log INFO "Uninstalling Docker packages..."

    run apt-get remove -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin || true

    log INFO "Docker packages removal completed."
}
# ==========================================================================================

# ==========================================================================================
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

uninstall_docker_setup() {
    log INFO "Checking Docker uninstall requirements..."

    if ! docker_installed; then
        log INFO "Docker is not installed. Nothing to uninstall."
        return
    fi

    log INFO "Docker is installed. Proceeding with uninstall..."
    uninstall_docker_packages

}
# ==========================================================================================

enable_docker_service() {
    log INFO "Enabling Docker service..."
    run systemctl enable --now docker
}

# ==========================================================================================
add_user_to_docker_group() {
    if id -nG "$USER_NAME" | grep -qw docker; then
        log INFO "$USER_NAME is already in the docker group, skipping."
    else
        log INFO "Adding $USER_NAME to the docker group..."
        run usermod -aG docker "$USER_NAME"
    fi
}

remove_user_from_docker_group() {
    if id -nG "$USER_NAME" | grep -qw docker; then
        log INFO "Removing $USER_NAME from docker group..."
        gpasswd -d "$USER_NAME" docker || true
    else
        log INFO "$USER_NAME is not in docker group, skipping."
    fi
}

# ==========================================================================================
docker_login_ghcr() {
    if [ -z "${GHCR_USER:-}" ] || [ -z "${GHCR_DEPLOY_TOKEN:-}" ]; then
        log INFO "GHCR_USER or GHCR_DEPLOY_TOKEN not set. Skipping Docker login."
        return
    fi

    log INFO "Logging in to GitHub Container Registry (GHCR)..."
    echo "$GHCR_DEPLOY_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin \
        && log INFO "Docker login successful." \
        || log FATAL "Docker login failed!"
}

docker_logout_ghcr() {
    if ! docker_installed; then
        log INFO "Docker not installed. Skipping GHCR logout."
        return
    fi

    log INFO "Logging out from GitHub Container Registry (GHCR)..."
    docker logout ghcr.io \
        && log INFO "Docker logout successful." \
        || log INFO "Docker logout failed or not logged in."
}
# ==========================================================================================


# ==========================================================================================

# ===== GNOME / Xhost SETUP =====
# ==========================================================================================
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

restore_gnome_idle_and_notifications() {
    local schema_dir="/usr/share/glib-2.0/schemas"
    local target="$schema_dir/90-kiosk-settings.gschema.override"

    if [ -f "$target" ]; then
        log INFO "Removing GNOME kiosk settings override..."
        rm -f "$target"

        log INFO "Recompiling GNOME schemas..."
        run glib-compile-schemas "$schema_dir"
        log INFO "GNOME schemas restored."
    else
        log INFO "GNOME kiosk override not found, skipping."
    fi
}
# ==========================================================================================

# ==========================================================================================
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

remove_xhost_autostart() {
    log INFO "Removing Xhost autostart configuration..."

    rm -f /usr/local/bin/enable_xhost.sh
    rm -f "$USER_HOME/.config/autostart/xhost.desktop"

    log INFO "Xhost autostart removed."
}
# ==========================================================================================

# ==========================================================================================
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

remove_display_from_bashrc() {
    local bashrc="$USER_HOME/.bashrc"

    if grep -Fxq "export DISPLAY=:0" "$bashrc"; then
        sed -i '/^export DISPLAY=:0$/d' "$bashrc"
        chown "$USER_NAME:$USER_NAME" "$bashrc"
        log INFO "DISPLAY removed from $bashrc"
    else
        log INFO "DISPLAY not found in $bashrc, skipping."
    fi
}
# ==========================================================================================


# ===== SYSTEM NOTIFICATIONS & UPDATE SETTINGS =====
# ==========================================================================================
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

restore_apport() {
    local apport_file="/etc/default/apport"

    if [ -f "$apport_file" ]; then
        if grep -q '^enabled=1' "$apport_file"; then
            log INFO "Apport already enabled, skipping."
        else
            sed -i 's/enabled=0/enabled=1/' "$apport_file"
            log INFO "Apport crash reporting re-enabled."
        fi
    fi

    systemctl enable apport || true
    systemctl start apport || true
}
# ==========================================================================================

# ==========================================================================================
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

restore_release_upgrade_prompt() {
    local update_file="/etc/update-manager/release-upgrades"

    if [ -f "$update_file" ]; then
        if grep -q '^Prompt=never' "$update_file"; then
            sed -i 's/^Prompt=never/Prompt=lts/' "$update_file"
            log INFO "Release upgrade prompt restored to default (lts)."
        else
            log INFO "Release upgrade prompt already enabled, skipping."
        fi
    fi
}
# ==========================================================================================

# ==========================================================================================
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

restore_update_notifier_popup() {
    local desktop_file="/etc/xdg/autostart/update-notifier.desktop"

    if [ ! -f "$desktop_file" ]; then
        log INFO "update-notifier autostart file not found, skipping."
        return
    fi

    if [ -x "$desktop_file" ]; then
        log INFO "Update-notifier autostart already enabled, skipping."
        return
    fi

    chmod +x "$desktop_file"
    log INFO "Update-notifier autostart enabled."
}
# ==========================================================================================


# ===== UPDATER SERVICE =====
# ==========================================================================================
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

remove_edge_updater() {
    log INFO "Removing Edge OTA Updater service..."

    # Stop & disable timer
    systemctl stop edge-updater.timer 2>/dev/null || true
    systemctl disable edge-updater.timer 2>/dev/null || true

    # Stop service if running
    systemctl stop edge-updater.service 2>/dev/null || true

    # Remove systemd unit files
    rm -f /etc/systemd/system/edge-updater.service
    rm -f /etc/systemd/system/edge-updater.timer

    log INFO "Reloading systemd daemon..."
    systemctl daemon-reload

    log INFO "Edge OTA Updater service removed."
}
# ==========================================================================================


# ===== INITIAL STATE =====
# ==========================================================================================
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

remove_edge_agent_state() {
    local state_dir="/var/lib/edge-agent"

    if [ -d "$state_dir" ]; then
        log INFO "Removing edge agent state directory..."
        rm -rf "$state_dir"
        log INFO "Edge agent state removed."
    else
        log INFO "Edge agent state directory not found, skipping."
    fi
}
# ==========================================================================================


main() {
    log INFO "== Install Started =="

    # 1. Base packages
    install_base_packages

    # 2. Docker
    setup_docker
    enable_docker_service
    add_user_to_docker_group
    docker_login_ghcr

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
}

uninstall_main() {
    log INFO "== Uninstall Started =="

    # 1. Base packages
    uninstall_base_packages

    # 2. Docker
    docker_logout_ghcr
    uninstall_docker_setup
    remove_user_from_docker_group

    # 3. GNOME / Display
    restore_gnome_idle_and_notifications
    remove_xhost_autostart
    remove_display_from_bashrc

    # 4. System notifications / updates
    restore_apport
    restore_release_upgrade_prompt
    restore_update_notifier_popup

    # 5. Setup updater
    remove_edge_updater

    # 6. Initial state
    remove_edge_agent_state

    log INFO "== Uninstall Completed =="
}

if [ "$ACTION" = "install" ]; then
    main
else
    uninstall_main
fi

log INFO "Rebooting device..."
sleep 5
reboot
