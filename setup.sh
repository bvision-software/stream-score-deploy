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
XINITRC_PATH="$USER_HOME/.xinitrc"
BASH_PROFILE_PATH="$USER_HOME/.bash_profile"
AUTOLOGIN_DIR="/etc/systemd/system/getty@tty1.service.d"
AUTOLOGIN_CONF="$AUTOLOGIN_DIR/autologin.conf"
PRINTER_IP="${PRINTER_IP:-192.168.1.240}" 
PRINTER_NAME="${PRINTER_NAME:-HP_Laser_MFP_137fnw_5F_F5_C9}"
BASE_PACKAGES=(curl ca-certificates gnupg jq xserver-xorg-core xserver-xorg-video-fbdev xinit x11-xserver-utils openbox cups cups-client poppler-utils libpango-1.0-0 libpangocairo-1.0-0 libgdk-pixbuf-2.0-0)
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

    if dpkg -s "$pkg" 2>/dev/null | grep -q "^Status: install ok installed"; then
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
    run apt-get update
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
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        log INFO "Docker GPG key added."
    else
        log INFO "Docker GPG key already exists, skipping."
    fi

    # Detect Ubuntu codename
    CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

    # Add repo if missing
    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $CODENAME stable" \
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
    if [[ -z "${GHCR_USER:-}" || -z "${GHCR_DEPLOY_TOKEN:-}" ]]; then
        log FATAL "GHCR_USER or GHCR_DEPLOY_TOKEN not set."
        exit 1
    fi

    log INFO "Logging in to GitHub Container Registry (GHCR) as root..."

    HOME=/root docker login ghcr.io \
        -u "$GHCR_USER" \
        --password-stdin <<<"$GHCR_DEPLOY_TOKEN" \
        || {
            log FATAL "Docker login failed!"
            exit 1
        }

    chmod 600 /root/.docker/config.json
    log INFO "Docker login successful (stored in /root/.docker/config.json)."

    mkdir -p "$USER_HOME/.docker"
    cp /root/.docker/config.json "$USER_HOME/.docker/config.json"
    chown -R "$USER_NAME:$USER_NAME" "$USER_HOME/.docker"
    log INFO "Docker credentials copied to $USER_NAME home."
}

docker_logout_ghcr() {
    log INFO "Logging out from GitHub Container Registry (GHCR)..."
    docker logout ghcr.io \
        && log INFO "Docker logout successful." \
        || log INFO "Docker logout failed or not logged in."

    rm -f "$USER_HOME/.docker/config.json"
    log INFO "Docker credentials removed from $USER_NAME home."
}
# ==========================================================================================

# ===== Xhost SETUP =====
# ==========================================================================================
setup_xhost_autostart() {
    local script_dst="/usr/local/bin/enable_xhost.sh"

    log INFO "Setting up Xhost script..."

    cat > "$script_dst" <<'EOF'
#!/bin/bash
export DISPLAY=:0
xhost +SI:localuser:root >/dev/null 2>&1
EOF

    chown root:root "$script_dst"
    chmod 755 "$script_dst"

    log INFO "Xhost script installed."
}

remove_xhost_autostart() {
    log INFO "Removing Xhost script..."
    rm -f /usr/local/bin/enable_xhost.sh
    log INFO "Xhost script removed."
}
# ==========================================================================================

# ===== DISPLAY SETUP =====
# ==========================================================================================
setup_autologin() {
    log INFO "Setting up autologin for $USER_NAME on tty1..."

    mkdir -p "$AUTOLOGIN_DIR"

    cat > "$AUTOLOGIN_CONF" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %I \$TERM
EOF

    chown root:root "$AUTOLOGIN_CONF"
    chmod 644 "$AUTOLOGIN_CONF"

    run systemctl daemon-reload
    run systemctl restart getty@tty1

    log INFO "Autologin configured."
}

remove_autologin() {
    log INFO "Removing autologin configuration..."
    rm -f "$AUTOLOGIN_CONF"
    run systemctl daemon-reload
    run systemctl restart getty@tty1
    log INFO "Autologin removed."
}
# ==========================================================================================

# ==========================================================================================
setup_xinitrc() {
    log INFO "Setting up .xinitrc for $USER_NAME..."

    cat > "$XINITRC_PATH" <<'EOF'
#!/bin/sh
xset s off
xset -dpms
xset s noblank

/usr/local/bin/enable_xhost.sh

openbox &
wait
EOF

    chown "$USER_NAME:$USER_NAME" "$XINITRC_PATH"
    chmod 755 "$XINITRC_PATH"

    log INFO ".xinitrc created."
}

remove_xinitrc() {
    log INFO "Removing .xinitrc..."
    rm -f "$XINITRC_PATH"
    log INFO ".xinitrc removed."
}
# ==========================================================================================

# ==========================================================================================
setup_bash_profile() {
    log INFO "Setting up .bash_profile for auto startx..."

    cat > "$BASH_PROFILE_PATH" <<EOF
if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
  exec startx -- -nocursor -auth $USER_HOME/.Xauthority 2>/dev/null
fi
EOF

    chown "$USER_NAME:$USER_NAME" "$BASH_PROFILE_PATH"
    chmod 644 "$BASH_PROFILE_PATH"

    log INFO ".bash_profile created."
}

remove_bash_profile() {
    log INFO "Removing .bash_profile..."
    rm -f "$BASH_PROFILE_PATH"
    log INFO ".bash_profile removed."
}
# ==========================================================================================

# ==========================================================================================
setup_gpu_memory() {
    local config_file="/boot/firmware/config.txt"
    local line="gpu_mem=128"

    if grep -q "^gpu_mem=" "$config_file"; then
        sed -i "s/^gpu_mem=.*/$line/" "$config_file"
        log INFO "gpu_mem updated in $config_file."
    else
        echo "$line" >> "$config_file"
        log INFO "gpu_mem added to $config_file."
    fi
}

remove_gpu_memory() {
    local config_file="/boot/firmware/config.txt"
    sed -i '/^gpu_mem=/d' "$config_file"
    log INFO "gpu_mem removed from $config_file."
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
    local state_dir="./state"
    local state_file="$state_dir/state.json"

    if [[ -f "$state_file" ]]; then
        log INFO "Edge agent state already exists, skipping bootstrap. path=$state_file"
        return
    fi

    log INFO "Bootstrapping initial edge agent state... path=$state_file"

    mkdir -p "$state_dir"

    cp setup/state/initial-state.json "$state_file"
    chown root:root "$state_file"
    chmod 644 "$state_file"

    log INFO "Initial edge agent state created. path=$state_file"
}

remove_edge_agent_state() {
    local state_dir="./state"
    local state_file="$state_dir/state.json"

    if [[ -f "$state_file" ]]; then
        log INFO "Removing edge agent state file... path=$state_file"
        rm -f "$state_file"
    else
        log INFO "Edge agent state file not found, skipping. path=$state_file"
    fi

    if [[ -d "$state_dir" && -z "$(ls -A "$state_dir")" ]]; then
        rmdir "$state_dir"
        log INFO "State directory removed (was empty). path=$state_dir"
    fi
}
# ==========================================================================================

# ===== PRINTER SETUP =====
# ==========================================================================================
setup_printer() {
    log INFO "Setting up CUPS printer service..."
    run systemctl enable cups
    run systemctl start cups
    # Wait for CUPS to become active (max 10s)
    local timeout=10
    local waited=0
    until systemctl is-active --quiet cups; do
        sleep 1
        waited=$((waited+1))
        if [ $waited -ge $timeout ]; then
            log FATAL "CUPS service did not start within $timeout seconds. Aborting."
            exit 1
        fi
    done

    log INFO "Adding printer: $PRINTER_NAME -> $PRINTER_IP"
    if CUPS_SERVER=/run/cups/cups.sock lpadmin -p "$PRINTER_NAME" -E -v "ipp://$PRINTER_IP/ipp/print" -m everywhere; then
        log INFO "Printer added successfully: $PRINTER_NAME"
    else
        log INFO "Printer add failed or already exists, continuing."
    fi

    # Install boot-time printer registration service.
    # Reboot / power loss sometimes leaves the printer in printers.conf but
    # unloaded by cupsd (StateTime 0). This oneshot service re-registers the
    # printer on every boot so it self-heals without manual lpadmin.
    log INFO "Installing boot-time printer registration service..."
    cat > /etc/systemd/system/printer-setup.service <<EOF
[Unit]
Description=Register CUPS printer on boot
After=cups.service
Requires=cups.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=CUPS_SERVER=/run/cups/cups.sock
ExecStartPre=/bin/sleep 5
ExecStart=/usr/sbin/lpadmin -p $PRINTER_NAME -E -v "ipp://$PRINTER_IP/ipp/print" -m everywhere

[Install]
WantedBy=multi-user.target
EOF

    chown root:root /etc/systemd/system/printer-setup.service
    chmod 644 /etc/systemd/system/printer-setup.service

    run systemctl daemon-reload
    run systemctl enable printer-setup.service

    log INFO "Boot-time printer registration service installed."
}

remove_printer() {
    log INFO "Removing CUPS printer..."

    # Stop & disable boot-time registration service
    systemctl stop printer-setup.service 2>/dev/null || true
    systemctl disable printer-setup.service 2>/dev/null || true
    rm -f /etc/systemd/system/printer-setup.service
    systemctl daemon-reload 2>/dev/null || true

    if command -v lpadmin >/dev/null 2>&1; then
        CUPS_SERVER=/run/cups/cups.sock lpadmin -x "$PRINTER_NAME" 2>/dev/null \
            && log INFO "Printer removed: $PRINTER_NAME" \
            || log INFO "Printer not found or already removed, skipping."
    else
        log INFO "lpadmin not available, skipping printer removal."
    fi

    systemctl stop cups 2>/dev/null || true
    systemctl disable cups 2>/dev/null || true

    log INFO "CUPS printer removal completed."
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

    # 3. Display
    setup_xhost_autostart
    setup_autologin
    setup_xinitrc
    setup_bash_profile
    setup_gpu_memory
    ensure_display_in_bashrc

    # 4. Printer
    setup_printer

    # 5. Setup updater
    setup_edge_updater

    # 6. Initial state
    bootstrap_edge_agent_state

    log INFO "== Setup Completed =="
    log INFO "Rebooting device..."
    sleep 5
    reboot
}

uninstall_main() {
    log INFO "== Uninstall Started =="

    # 0. Printer (must run before base packages removal)
    remove_printer

    # 1. Base packages
    uninstall_base_packages

    # 2. Docker
    docker_logout_ghcr
    uninstall_docker_setup
    remove_user_from_docker_group

    # 3. Display
    remove_xhost_autostart
    remove_autologin
    remove_xinitrc
    remove_bash_profile
    remove_gpu_memory
    remove_display_from_bashrc

    # 4. Setup updater
    remove_edge_updater

    # 5. Initial state
    remove_edge_agent_state

    log INFO "== Uninstall Completed =="
    log INFO "Rebooting device..."
    sleep 5
    reboot
}

if [ "$ACTION" = "install" ]; then
    main
else
    uninstall_main
fi

