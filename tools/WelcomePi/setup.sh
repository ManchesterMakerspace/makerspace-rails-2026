#!/usr/bin/env bash
# Run on the Pi. See setup-pi0.MD for the wiring and first boot.
set -euo pipefail

usage() {
    echo "Usage: sudo bash setup.sh install | check | watch-door | enable-updates"
    echo "  install     Configure a Pi Zero W, Pi 4 Model B or Pi 5 and install the service files"
    echo "  check       Report HDMI status and check the reader, database reads and broker subscriptions"
    echo "  watch-door  Wait for a fresh door check-in beside the running kiosk"
    echo "  enable-updates  Enroll this installation for automatic updates from master"
}
die() { echo "$*" >&2; exit 1; }
if [[ $# == 1 && $1 == --help ]]; then usage; exit 0; fi
if [[ $# != 1 ]]; then usage >&2; exit 2; fi
case "$1" in install|check|watch-door|enable-updates) ;; *) usage >&2; exit 2 ;; esac
[[ $EUID == 0 ]] || die "Run this command with sudo on the Pi."
umask 022

app=/opt/welcomepi
case "$1" in
    check|watch-door)
        if [[ -L "$app/current" ]]; then app="$app/current"; fi
        [[ -x "$app/.venv/bin/python" && -f /etc/welcomepi.env ]] || die "Run the install step first."
        args=("$1")
        if [[ $1 == check ]] && systemctl is-active --quiet welcomepi.service; then
            args+=(--reader-in-use)
        fi
        # Let systemd parse the credentials just as it does for the kiosk.
        exec systemd-run --quiet --wait --pipe --collect \
            -p User=welcomepi -p Group=welcomepi -p 'SupplementaryGroups=video dialout i2c' \
            -p EnvironmentFile=/etc/welcomepi.env -p WorkingDirectory="$app" -p LimitCORE=0 \
            "$app/.venv/bin/python" -B -u -m pi0.check "${args[@]}"
        ;;
esac

source_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
[[ -r "$source_dir/welcomepi/__main__.py" ]] || die "The WelcomePi source directory is incomplete."
board=$(/usr/bin/python3 -I "$source_dir/pi0/configure_boot.py" --check-platform)

exec 9>/run/lock/welcomepi-setup.lock
flock 9
if getent passwd welcomepi >/dev/null; then
    case "$(getent passwd welcomepi | cut -d: -f7)" in
        */nologin|*/false) ;;
        *) die "welcomepi is an interactive login. Reserve that name for the kiosk service account." ;;
    esac
fi

install_updater() {
    local helper=/usr/local/lib/welcomepi-update
    if ! id -u welcomepi-build >/dev/null 2>&1; then
        useradd --system --user-group --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin welcomepi-build
    fi
    [[ $(id -u welcomepi-build) != 0 && $(id -g welcomepi-build) != 0 ]] || \
        die "The dependency builder needs an unprivileged account."
    case "$(getent passwd welcomepi-build | cut -d: -f7)" in
        */nologin|*/false) ;;
        *) die "Reserve welcomepi-build for the non-interactive dependency builder." ;;
    esac
    install -d -m 0755 "$helper" /etc/systemd/system/welcomepi.service.d
    install -m 0644 "$source_dir"/deploy/{update,release}.py "$helper/"
    /usr/bin/python3 -E -s -B "$helper/update.py" enroll
    install -m 0644 "$source_dir/deploy/current.conf" /etc/systemd/system/welcomepi.service.d/10-current.conf
    install -m 0644 "$source_dir"/deploy/welcomepi-update.{service,timer} /etc/systemd/system/
}

if [[ $1 == enable-updates ]]; then
    [[ -x "$app/.venv/bin/python" && -f /etc/welcomepi.env ]] || die "Run the install step first."
    install_updater
    systemctl daemon-reload
    systemctl enable --now welcomepi-update.timer
    echo "Automatic updates enabled. Check with systemctl list-timers welcomepi-update.timer"
    exit 0
fi

apt-get update
apt-get install -y --no-install-recommends \
    python3-venv python3-kms++ kms++-utils python3-pil python3-pymongo \
    python3-dnspython python3-paho-mqtt python3-qrcode python3-serial python3-usb1 \
    libusb-1.0-0 i2c-tools ca-certificates fonts-dejavu-core tzdata

getent group welcomepi >/dev/null || groupadd --system welcomepi
getent group i2c >/dev/null || groupadd --system i2c
if ! id -u welcomepi >/dev/null 2>&1; then
    useradd --system --gid welcomepi --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin welcomepi
fi
if [[ -L "$app/current" ]]; then
    install_updater
else
    install -d -m 0755 "$app" "$app/welcomepi" "$app/pi0"
    /usr/bin/python3 -m venv --system-site-packages "$app/.venv"
    "$app/.venv/bin/python" -m pip --disable-pip-version-check install -r "$source_dir/requirements.txt"
    "$app/.venv/bin/python" -B -c \
        'from PIL import Image; import pykms, pymongo, paho.mqtt.client, qrcode, nfc; print("Pillow", Image.__version__, "and kiosk dependencies imported")'

    install -m 0644 "$source_dir"/welcomepi/*.py "$app/welcomepi/"
    install -m 0644 "$source_dir/pi0/check.py" "$app/pi0/check.py"
    install -m 0644 "$source_dir/requirements.txt" "$app/requirements.txt"
fi
if [[ ! -e /etc/welcomepi.env ]]; then
    install -m 0600 "$source_dir/welcomepi.env.example" /etc/welcomepi.env
    if [[ $board == pi5 ]]; then
        # The Pi 5's /dev/serial0 uses the debug header, separate from GPIO 14/15.
        sed -i 's|^WELCOMEPI_NFC_PORT=/dev/serial0$|WELCOMEPI_NFC_PORT=/dev/ttyAMA0|' /etc/welcomepi.env
    fi
fi
/usr/bin/python3 -I "$source_dir/pi0/configure_boot.py"
install -m 0644 "$source_dir/welcomepi.service" /etc/systemd/system/welcomepi.service
systemctl daemon-reload
systemctl try-restart welcomepi.service

echo "Installed. Configure credentials with sudoedit /etc/welcomepi.env, then sudo reboot."
echo "After reconnecting: cd ~/WelcomePi && sudo bash setup.sh check"
echo "Start at boot and show the board: sudo systemctl enable --now welcomepi.service"
