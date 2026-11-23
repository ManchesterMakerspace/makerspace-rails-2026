#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: bash workstation/setup.sh USER@PI-HOST"; }
if [[ $# == 1 && $1 == --help ]]; then usage; exit 0; fi
if [[ $# != 1 || -z $1 || $1 == -* ]]; then usage >&2; exit 2; fi

target=$1
cd -- "$(dirname -- "$0")/.."
# Send only the deployment files. A checkout can also contain a real .env,
# private test data, caches, and a workstation virtual environment.
tar -cf - setup.sh workstation/setup.sh setup-pi0.MD README.md requirements.txt welcomepi.service \
    welcomepi.env.example pi0/configure_boot.py pi0/check.py welcomepi/*.py |
    ssh -T -- "$target" 'set -eu; umask 077; mkdir -p "$HOME/WelcomePi"; tar -xf - -C "$HOME/WelcomePi"'

printf 'Copied WelcomePi. Connect with ssh %s and run:\n' "$target"
echo '  cd ~/WelcomePi && sudo bash setup.sh install'
