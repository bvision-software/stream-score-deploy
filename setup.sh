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
BASE_PACKAGES=(curl ca-certificates gnupg)
# ==================

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
    local override_dir="/usr/share/glib-2.0/schemas"
    local override_file="$override_dir/90-kiosk-settings.gschema.override"

    local desired_content="[org.gnome.desktop.session]
idle-delay=0

[org.gnome.desktop.notifications]
show-banners=false"

    if [ -f "$override_file" ] && cmp -s <(echo "$desired_content") "$override_file"; then
        log INFO "GNOME override file already up-to-date, skipping."
        return
    fi

    log INFO "Disabling screen blanking and GNOME notifications..."
    echo "$desired_content" > "$override_file"

    run glib-compile-schemas "$override_dir"
    log INFO "Screen blanking and GNOME notifications disabled."
}

# Create Xhost autostart script
setup_xhost_autostart() {
    local autostart_dir="$USER_HOME/.config/autostart"
    local xhost_script="/usr/local/bin/enable_xhost.sh"
    local desktop_file="$autostart_dir/xhost.desktop"

    local desired_script='#!/bin/bash
export DISPLAY=:0
xhost +SI:localuser:root >/dev/null 2>&1'

    local desired_desktop="[Desktop Entry]
Type=Application
Name=Enable Xhost
Exec=$xhost_script
X-GNOME-Autostart-enabled=true"

    mkdir -p "$autostart_dir"

    # Script content check
    if [ -f "$xhost_script" ] && cmp -s <(echo "$desired_script") "$xhost_script" && \
       [ -f "$desktop_file" ] && cmp -s <(echo "$desired_desktop") "$desktop_file"; then
        log INFO "Xhost autostart already configured, skipping."
        return
    fi

    log INFO "Creating Xhost autostart..."

    echo "$desired_script" > "$xhost_script"
    chmod +x "$xhost_script"
    chown root:root "$xhost_script"

    echo "$desired_desktop" > "$desktop_file"
    chown -R "$USER_NAME:$USER_NAME" "$autostart_dir"

    log INFO "Xhost autostart configured."
}

# Ensure DISPLAY variable in .bashrc
ensure_display_in_bashrc() {
    if ! grep -q "export DISPLAY=:0" "$USER_HOME/.bashrc"; then
        echo 'export DISPLAY=:0' >> "$USER_HOME/.bashrc"
        log INFO "DISPLAY=:0 added to $USER_HOME/.bashrc"
    else
        log INFO "DISPLAY=:0 already exists in $USER_HOME/.bashrc, skipping."
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

    log INFO "== Setup Completed =="
    log INFO "Rebooting the device for changes to take effect..."
    sleep 5
    reboot
}

main