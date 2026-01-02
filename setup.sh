#!/usr/bin/env bash
set -e

USER_NAME=pi
USER_HOME=/home/pi

echo "== RPI Setup Başlıyor =="

# --------------------------------------------------
# 1. Temel Paketler
# --------------------------------------------------
apt update
apt install -y openssh-server curl ca-certificates gnupg

# --------------------------------------------------
# 2. Docker Kurulumu (Official Repo)
# --------------------------------------------------
echo "== Docker Kuruluyor =="
# Eski paketleri temizle
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do apt-get remove -y $pkg || true; done

# Keyring ve Repo ekle
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
usermod -aG docker "$USER_NAME"

# --------------------------------------------------
# 3. KESİN ÇÖZÜM: Ekran Kapanmasını Önleme (Schema Override)
# Kullanıcı ayarı yerine sistem varsayılanını değiştiriyoruz.
# --------------------------------------------------
echo "== Güç ve Ekran Koruyucu Ayarları Sabitleniyor =="

# GNOME ayarlarını override eden bir dosya oluşturuyoruz
cat > /usr/share/glib-2.0/schemas/90-kiosk-mode.gschema.override <<EOF
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

# Şemaları derle (Bu işlem ayarları kalıcı ve sistem geneli yapar)
glib-compile-schemas /usr/share/glib-2.0/schemas/

# --------------------------------------------------
# 4. KESİN ÇÖZÜM: Xhost ve Display Ayarı
# --------------------------------------------------
echo "== Xhost ve Display Ayarları Yapılandırılıyor =="

AUTOSTART_DIR="$USER_HOME/.config/autostart"
mkdir -p "$AUTOSTART_DIR"

# 1. ADIM: DISPLAY değişkenini kalıcı yap (.bashrc'ye ekle)
# Bu sayede terminal açtığınızda manuel export yapmanıza gerek kalmaz.
if ! grep -q "export DISPLAY=:0" "$USER_HOME/.bashrc"; then
    echo 'export DISPLAY=:0' >> "$USER_HOME/.bashrc"
    echo "DISPLAY=:0 .bashrc'ye eklendi."
fi

# 2. ADIM: Başlatma Scripti Oluştur (X Server'ı bekleyen script)
# xhost komutunu hemen değil, ekran hazır olduğunda çalıştırır.
cat > "$USER_HOME/enable_xhost.sh" <<EOF
#!/bin/bash
export DISPLAY=:0
# X server (grafik arayüz) yanıt verene kadar bekle (max 30 sn)
count=0
while ! xset q &>/dev/null; do
    sleep 1
    count=\$((count+1))
    if [ \$count -ge 30 ]; then break; fi
done

# İzni herkese ver (xhost +)
xhost +
EOF

# Scripti çalıştırılabilir yap ve sahibini ayarla
chmod +x "$USER_HOME/enable_xhost.sh"
chown "$USER_NAME:$USER_NAME" "$USER_HOME/enable_xhost.sh"

# 3. ADIM: Autostart Dosyasını Oluştur
# Masaüstü başladığında yukarıdaki scripti tetikler.
cat > "$AUTOSTART_DIR/xhost-setup.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Enable Xhost
Comment=Sets xhost + for scoreboard
Exec=$USER_HOME/enable_xhost.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

# Autostart dosyasının sahipliğini ayarla
chown "$USER_NAME:$USER_NAME" "$AUTOSTART_DIR"
chown "$USER_NAME:$USER_NAME" "$AUTOSTART_DIR/xhost-setup.desktop"
chmod +x "$AUTOSTART_DIR/xhost-setup.desktop"

# --------------------------------------------------
# 5. Wayland'i Devre Dışı Bırak (Ubuntu 22.04+ için Kritik)
# xhost Wayland'de çalışmaz, X11'e zorlamalıyız.
# --------------------------------------------------
sed -i 's/#WaylandEnable=false/WaylandEnable=false/' /etc/gdm3/custom.conf || true

# --------------------------------------------------
# 6. KESİN ÇÖZÜM: "System Problem" ve "Update" Pencerelerini Kapatma
# --------------------------------------------------
echo "== Sistem Hata Raporları ve Güncelleme Uyarıları Kapatılıyor =="

# 1. "System program problem detected" hatasını kapat (Apport)
# Bu servis her açılışta çökme raporu oluşturup ekrana basar, kapatıyoruz.
if [ -f /etc/default/apport ]; then
    sed -i 's/enabled=1/enabled=0/' /etc/default/apport
fi
systemctl stop apport
systemctl disable apport

# 2. "New Ubuntu version is available" uyarısını kapat
# Sürüm yükseltme kontrolünü devre dışı bırakır.
if [ -f /etc/update-manager/release-upgrades ]; then
    sed -i 's/^Prompt=.*$/Prompt=never/' /etc/update-manager/release-upgrades
fi

# 3. Güncelleme Bildirimcisini Sistemden Kaldır (En Temiz Yöntem)
# Arka planda güncelleme kontrolü yapıp popup açan paketi siliyoruz.
apt-get remove -y update-notifier update-notifier-common

# --------------------------------------------------
# Bitiş
# --------------------------------------------------
echo "== Kurulum Tamamlandı =="
echo "Ayarların geçerli olması için cihaz yeniden başlatılıyor..."
reboot
