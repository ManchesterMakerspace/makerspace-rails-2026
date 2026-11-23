#!/usr/bin/env bash
# On the Raspberry Pi Zero W. See setup-pi0.MD for the wiring and first boot.
set -euo pipefail

usage() {
    echo "Usage: sudo bash setup.sh install | check | watch-door"
    echo "  install     Configure the Zero W and install the service files"
    echo "  check       Check the reader, database reads and broker subscriptions"
    echo "  watch-door  Wait for a fresh door check-in beside the running kiosk"
}
die() { echo "$*" >&2; exit 1; }
if [[ $# == 1 && $1 == --help ]]; then usage; exit 0; fi
if [[ $# != 1 ]]; then usage >&2; exit 2; fi
case "$1" in install|check|watch-door) ;; *) usage >&2; exit 2 ;; esac
[[ $EUID == 0 ]] || die "Run this command with sudo on the Pi."
umask 022

app=/opt/welcomepi
case "$1" in
    check|watch-door)
        [[ -x "$app/.venv/bin/python" && -f /etc/welcomepi.env ]] || die "Run the install step first."
        args=("$1")
        if [[ $1 == check ]] && systemctl is-active --quiet welcomepi.service; then
            args+=(--reader-in-use)
        fi
        # Let systemd parse the credentials just as it does for the kiosk.
        exec systemd-run --quiet --wait --pipe --collect \
            -p User=welcomepi -p Group=welcomepi -p 'SupplementaryGroups=video dialout' \
            -p EnvironmentFile=/etc/welcomepi.env -p WorkingDirectory="$app" -p LimitCORE=0 \
            "$app/.venv/bin/python" -B -u -m pi0.check "${args[@]}"
        ;;
esac

source_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
[[ -r "$source_dir/welcomepi/__main__.py" ]] || die "The WelcomePi source directory is incomplete."
[[ -r /proc/device-tree/model ]] || die "Run the installer on the Raspberry Pi Zero W."
model=$(tr -d '\0' </proc/device-tree/model)
[[ $model == "Raspberry Pi Zero W"* ]] || die "This 720p boot profile is for a Pi Zero W. Found $model."
# shellcheck source=/dev/null
. /etc/os-release
[[ ${VERSION_CODENAME:-} == bookworm && $(dpkg --print-architecture) == armhf ]] ||
    die "Install Raspberry Pi OS Lite, 32-bit Bookworm, before running setup."

exec 9>/run/lock/welcomepi-setup.lock
flock 9
if getent passwd welcomepi >/dev/null; then
    case "$(getent passwd welcomepi | cut -d: -f7)" in
        */nologin|*/false) ;;
        *) die "welcomepi is an interactive login. Reserve that name for the kiosk service account." ;;
    esac
fi

apt-get update
apt-get install -y --no-install-recommends \
    python3-venv python3-kms++ kms++-utils python3-pil python3-pymongo \
    python3-dnspython python3-paho-mqtt python3-qrcode python3-serial python3-usb1 \
    libusb-1.0-0 ca-certificates fonts-dejavu-core tzdata

getent group welcomepi >/dev/null || groupadd --system welcomepi
if ! id -u welcomepi >/dev/null 2>&1; then
    useradd --system --gid welcomepi --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin welcomepi
fi
install -d -m 0755 "$app" "$app/welcomepi" "$app/pi0"
/usr/bin/python3 -m venv --system-site-packages "$app/.venv"
"$app/.venv/bin/python" -m pip --disable-pip-version-check install -r "$source_dir/requirements.txt"
"$app/.venv/bin/python" -B -c \
    'from PIL import Image; import pykms, pymongo, paho.mqtt.client, qrcode, nfc; print("Pillow", Image.__version__, "and kiosk dependencies imported")'

install -m 0644 "$source_dir"/welcomepi/*.py "$app/welcomepi/"
install -m 0644 "$source_dir/pi0/check.py" "$app/pi0/check.py"
install -m 0644 "$source_dir/requirements.txt" "$app/requirements.txt"
if [[ ! -e /etc/welcomepi.env ]]; then
    install -m 0600 "$source_dir/welcomepi.env.example" /etc/welcomepi.env
fi
/usr/bin/python3 -I "$source_dir/pi0/configure_boot.py"
install -m 0644 "$source_dir/welcomepi.service" /etc/systemd/system/welcomepi.service
systemctl daemon-reload
systemctl try-restart welcomepi.service

echo "Installed. Configure credentials with sudoedit /etc/welcomepi.env, then sudo reboot."
echo "After reconnecting: cd ~/WelcomePi && sudo bash setup.sh check"
echo "Start at boot and show the board: sudo systemctl enable --now welcomepi.service"
