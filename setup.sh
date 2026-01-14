#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[FATAL] Satır $LINENO hata verdi. Kurulum durdu."' ERR

if [ "$EUID" -ne 0 ]; then
  echo "[FATAL] Bu script root olarak çalıştırılmalı: sudo -E ./setup.sh"
  exit 1
fi

USER_NAME=pi
USER_HOME=/home/pi

TARGET_DOCKER_MAJOR=29

install_if_missing() {
    local pkg="$1"

    if dpkg -s "$pkg" &>/dev/null; then
        echo "[OK] $pkg zaten kurulu."
    else
        echo "[INSTALL] $pkg kuruluyor..."
        apt-get install -y "$pkg"
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
    echo "[SETUP] Docker resmi repo ekleniyor..."

    install -m 0755 -d /etc/apt/keyrings

    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "[OK] Docker GPG key eklendi."
    else
        echo "[SKIP] Docker GPG key zaten mevcut."
    fi

    CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
        $CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        echo "[OK] Docker repo eklendi."
    else
        echo "[SKIP] Docker repo zaten mevcut."
    fi
}

echo "== RPI Setup Başlıyor =="
echo "== Temel Paketler Kontrol Ediliyor =="

apt-get update

BASE_PACKAGES=(
  git
  openssh-server
  curl
  ca-certificates
  gnupg
)

for pkg in "${BASE_PACKAGES[@]}"; do
    install_if_missing "$pkg"
done


echo "== Docker Kontrol Ediliyor =="

if docker_installed; then
    CURRENT_MAJOR=$(docker_major_version)

    if [ -n "$CURRENT_MAJOR" ] && [ "$CURRENT_MAJOR" = "$TARGET_DOCKER_MAJOR" ]; then
        echo "[OK] Docker $CURRENT_MAJOR.x zaten kurulu."
    else
        echo "[WARN] Docker $CURRENT_MAJOR.x → $TARGET_DOCKER_MAJOR.x güncelleniyor..."
        install_docker_repo
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
else
    echo "[INSTALL] Docker kurulu değil, kuruluyor..."
    install_docker_repo
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi


echo "[SETUP] Docker servisi etkinleştiriliyor..."
systemctl enable --now docker

if id -nG "$USER_NAME" | grep -qw docker; then
    echo "[OK] $USER_NAME zaten docker grubunda."
else
    echo "[SETUP] $USER_NAME docker grubuna ekleniyor..."
    usermod -aG docker "$USER_NAME"
    echo "[INFO] Değişikliğin aktif olması için reboot gerekli."
fi

exit

echo "== Güç, Ekran ve Bildirim Ayarları Yapılıyor =="

OVERRIDE_DIR="/usr/share/glib-2.0/schemas"
OVERRIDE_FILE="$OVERRIDE_DIR/90-kiosk-power.gschema.override"

cat > "$OVERRIDE_FILE" <<EOF
[org.gnome.desktop.session]
idle-delay=0

[org.gnome.settings-daemon.plugins.power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'

[org.gnome.desktop.screensaver]
lock-enabled=false
idle-activation-enabled=false

[org.gnome.desktop.notifications]
show-banners=false
EOF

# Şemaları derle
glib-compile-schemas "$OVERRIDE_DIR"

echo "[OK] Suspend, screensaver ve bildirimler devre dışı bırakıldı."

# # --------------------------------------------------
# # 4. KESİN ÇÖZÜM: Xhost ve Display Ayarı
# # --------------------------------------------------
# echo "== Xhost ve Display Ayarları Yapılandırılıyor =="

# AUTOSTART_DIR="$USER_HOME/.config/autostart"
# mkdir -p "$AUTOSTART_DIR"

# # 1. ADIM: DISPLAY değişkenini kalıcı yap (.bashrc'ye ekle)
# # Bu sayede terminal açtığınızda manuel export yapmanıza gerek kalmaz.
# if ! grep -q "export DISPLAY=:0" "$USER_HOME/.bashrc"; then
#     echo 'export DISPLAY=:0' >> "$USER_HOME/.bashrc"
#     echo "DISPLAY=:0 .bashrc'ye eklendi."
# fi

# # 2. ADIM: Başlatma Scripti Oluştur (X Server'ı bekleyen script)
# # xhost komutunu hemen değil, ekran hazır olduğunda çalıştırır.
# cat > "$USER_HOME/enable_xhost.sh" <<EOF
# #!/bin/bash
# export DISPLAY=:0
# # X server (grafik arayüz) yanıt verene kadar bekle (max 30 sn)
# count=0
# while ! xset q &>/dev/null; do
#     sleep 1
#     count=\$((count+1))
#     if [ \$count -ge 30 ]; then break; fi
# done

# # İzni herkese ver (xhost +)
# xhost +
# EOF

# # Scripti çalıştırılabilir yap ve sahibini ayarla
# chmod +x "$USER_HOME/enable_xhost.sh"
# chown "$USER_NAME:$USER_NAME" "$USER_HOME/enable_xhost.sh"

# # 3. ADIM: Autostart Dosyasını Oluştur
# # Masaüstü başladığında yukarıdaki scripti tetikler.
# cat > "$AUTOSTART_DIR/xhost-setup.desktop" <<EOF
# [Desktop Entry]
# Type=Application
# Name=Enable Xhost
# Comment=Sets xhost + for scoreboard
# Exec=$USER_HOME/enable_xhost.sh
# Hidden=false
# NoDisplay=false
# X-GNOME-Autostart-enabled=true
# EOF

# # Autostart dosyasının sahipliğini ayarla
# chown "$USER_NAME:$USER_NAME" "$AUTOSTART_DIR"
# chown "$USER_NAME:$USER_NAME" "$AUTOSTART_DIR/xhost-setup.desktop"
# chmod +x "$AUTOSTART_DIR/xhost-setup.desktop"

# # --------------------------------------------------
# # 5. Wayland'i Devre Dışı Bırak (Ubuntu 22.04+ için Kritik)
# # xhost Wayland'de çalışmaz, X11'e zorlamalıyız.
# # --------------------------------------------------
# sed -i 's/#WaylandEnable=false/WaylandEnable=false/' /etc/gdm3/custom.conf || true

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

# # --------------------------------------------------
# # Bitiş
# # --------------------------------------------------
# echo "== Kurulum Tamamlandı =="
# echo "Ayarların geçerli olması için cihaz yeniden başlatılıyor..."
# reboot
