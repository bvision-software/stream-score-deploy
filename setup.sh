#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[FATAL] Error occurred at line $LINENO. Setup aborted."' ERR

if [ "$EUID" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

USER_NAME=pi
USER_HOME=/home/pi

TARGET_DOCKER_MAJOR=29
LOG_FILE_PATH="./logs/setup.log"

BASE_PACKAGES=(
  openssh-server
  curl
  ca-certificates
  gnupg
)

mkdir -p "$(dirname "$LOG_FILE_PATH")"
touch "$LOG_FILE_PATH"
chmod 644 "$LOG_FILE_PATH"

log() {
  local level="$1"; shift
  printf "[%s] %s\n" "$level" "$*" | tee -a "$LOG_FILE_PATH"
}

run() {
  {
    echo
    echo "========== $(date '+%F %T') =========="
    echo "CMD : $*"
    "$@"
    echo "EXIT: $?"
    echo "====================================="
  } >>"$LOG_FILE_PATH" 2>&1
}

install_if_missing() {
    local pkg="$1"

    if dpkg -s "$pkg" &>/dev/null; then
        echo "[OK] $pkg is already installed."
    else
        echo "[INSTALL] Installing $pkg..."
        run apt-get install -y "$pkg"
    fi
}

docker_installed() {
    command -v docker >/dev/null 2>&1
}

docker_major_version() {
    systemctl is-active docker >/dev/null 2>&1 || systemctl start docker
    sleep 2
    docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1 || echo ""
}

install_docker_repo() {
    echo "[SETUP] Adding official Docker repository..."

    install -m 0755 -d /etc/apt/keyrings

    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "[OK] Docker GPG key added."
    else
        echo "[SKIP] Docker GPG key already exists."
    fi

    CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
        $CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        echo "[OK] Docker repository added."
    else
        echo "[SKIP] Docker repository already exists."
    fi
}

echo "== RPI Setup Started =="

echo "== Updating System =="
run apt-get update

echo "== Checking Base Packages =="

for pkg in "${BASE_PACKAGES[@]}"; do
    install_if_missing "$pkg"
done


echo "== Checking Docker =="

if docker_installed; then
    CURRENT_MAJOR=$(docker_major_version)

    if [ -n "$CURRENT_MAJOR" ] && [ "$CURRENT_MAJOR" = "$TARGET_DOCKER_MAJOR" ]; then
        echo "[OK] Docker $CURRENT_MAJOR.x is already installed."
    else
        echo "[WARN] Updating Docker from $CURRENT_MAJOR.x to $TARGET_DOCKER_MAJOR.x..."
        install_docker_repo
        run apt-get update
        run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
else
    echo "[INSTALL] Docker is not installed. Installing..."
    install_docker_repo
    run apt-get update
    run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi


echo "[SETUP] Enabling Docker service..."
run systemctl enable --now docker

if id -nG "$USER_NAME" | grep -qw docker; then
    echo "[OK] $USER_NAME is already in the docker group."
else
    echo "[SETUP] Adding $USER_NAME to the docker group..."
    usermod -aG docker "$USER_NAME"
fi

echo "== Disabling Screen Blanking =="
OVERRIDE_DIR="/usr/share/glib-2.0/schemas"
OVERRIDE_FILE="$OVERRIDE_DIR/90-kiosk-power.gschema.override"

cat > "$OVERRIDE_FILE" <<EOF
[org.gnome.desktop.session]
idle-delay=0
EOF

run glib-compile-schemas "$OVERRIDE_DIR"

echo "[OK] Automatic screen blanking has been disabled."

echo "== Creating Xhost autostart =="

AUTOSTART_DIR="$USER_HOME/.config/autostart"
XHOST_SCRIPT="/usr/local/bin/enable_xhost.sh"

mkdir -p "$AUTOSTART_DIR"

cat > "$XHOST_SCRIPT" <<'EOF'
#!/bin/bash
export DISPLAY=:0
xhost +SI:localuser:root >/dev/null 2>&1
EOF

chmod +x "$XHOST_SCRIPT"
chown root:root "$XHOST_SCRIPT"

cat > "$AUTOSTART_DIR/xhost.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Enable Xhost
Exec=$XHOST_SCRIPT
X-GNOME-Autostart-enabled=true
EOF

chown -R $USER_NAME:$USER_NAME "$AUTOSTART_DIR"

echo "[OK] Xhost will now run in the GUI session on every startup."

echo "== Setup Completed =="
echo "Rebooting the device for the changes to take effect..."
reboot

# # --------------------------------------------------
# # 6. KESİN ÇÖZÜM: "System Problem" ve "Update" Pencerelerini Kapatma
# # --------------------------------------------------
# echo "== Sistem Hata Raporları ve Güncelleme Uyarıları Kapatılıyor =="

# # 1. "System program problem detected" hatasını kapat (Apport)
# # Bu servis her açılışta çökme raporu oluşturup ekrana basar, kapatıyoruz.
# if [ -f /etc/default/apport ]; then
#     sed -i 's/enabled=1/enabled=0/' /etc/default/apport
# fi
# systemctl stop apport
# systemctl disable apport

# # 2. "New Ubuntu version is available" uyarısını kapat
# # Sürüm yükseltme kontrolünü devre dışı bırakır.
# if [ -f /etc/update-manager/release-upgrades ]; then
#     sed -i 's/^Prompt=.*$/Prompt=never/' /etc/update-manager/release-upgrades
# fi

# # 3. Güncelleme Bildirimcisini Sistemden Kaldır (En Temiz Yöntem)
# # Arka planda güncelleme kontrolü yapıp popup açan paketi siliyoruz.
# apt-get remove -y update-notifier update-notifier-common


