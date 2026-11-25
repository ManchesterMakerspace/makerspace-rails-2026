"""Configure a stock Raspberry Pi OS boot partition for WelcomePi."""
import argparse
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile


def board_profile(model, codename, architecture):
    if codename not in ("bookworm", "trixie"):
        raise ValueError("Setup requires Raspberry Pi OS Lite (Bookworm or Trixie).")
    # Device-tree model strings can include a revision after the model name.
    name = model.rstrip("\0\n").partition(" Rev ")[0]
    if name == "Raspberry Pi Zero W" and architecture == "armhf":
        return "pi0w"
    if name == "Raspberry Pi 4 Model B" and architecture in ("armhf", "arm64"):
        return "pi4"
    if name in ("Raspberry Pi 5", "Raspberry Pi 5 Model B") and architecture == "arm64":
        return "pi5"
    raise ValueError(f"Unsupported {name} ({architecture}). Use a Zero W (32-bit), "
                     "Pi 4 Model B (32- or 64-bit) or Pi 5 (64-bit).")


def firmware_config(original, board="pi0w"):
    lines = original.splitlines(keepends=True)
    filters = {"[all]", f"[{board}]"}
    if board == "pi0w":
        filters.add("[pi0]")
    active = True
    kms = False
    header_uart = False
    settings = {}
    for index, line in enumerate(lines):
        directive = line.partition("#")[0].strip()
        if directive.startswith("["):
            active = directive in filters
        if not active:
            continue
        key, _, value = directive.partition("=")
        key, value = key.strip(), value.strip()
        if key == "dtoverlay":
            overlay = value.split(",")[0]
            full_kms = overlay.replace("vc4-fkms-v3d", "vc4-kms-v3d", 1)
            if full_kms in ("vc4-kms-v3d", f"vc4-kms-v3d-{board}"):
                kms = True
                lines[index] = line.replace(overlay, full_kms, 1)
            if overlay in ("uart0", "uart0-pi5"):
                header_uart = True
        if key in ("enable_uart", "disable_fw_kms_setup"):
            settings[key] = value
    additions = [] if kms else ["dtoverlay=vc4-kms-v3d"]
    if board == "pi5" and not header_uart:
        additions.append("dtoverlay=uart0-pi5")
    required = ("disable_fw_kms_setup",) if board == "pi5" else ("enable_uart", "disable_fw_kms_setup")
    for name in required:
        if settings.get(name) != "1":
            additions.append(f"{name}=1")
    text = "".join(lines)
    if additions:
        section = "[pi5]" if board == "pi5" else "[all]"
        text = text.rstrip("\r\n") + f"\n\n{section}\n" + "\n".join(additions) + "\n"
        if board == "pi5":
            text += "[all]\n"
    return text


def kernel_cmdline(original, board="pi0w"):
    lines = original.strip().splitlines()
    if len(lines) != 1:
        raise ValueError("Expected one kernel command line in cmdline.txt")
    # Preserve root=, non-serial consoles, other outputs and quoted kernel arguments.
    tokens = re.findall(r"""(?:[^\s"']+|"[^"]*"|'[^']*')+""", lines[0])
    # Pi 5 has a separate debug UART; leave its console in place.
    serial = ("console=ttyAMA0",) if board == "pi5" else ("console=serial0", "console=ttyAMA0", "console=ttyS0")
    args = [t for t in tokens if t.split(",", 1)[0] not in serial
            and not t.startswith("consoleblank=")]
    if board == "pi0w":
        args = [t for t in args if not t.startswith("video=HDMI-A-1:")]
        args.append("video=HDMI-A-1:1280x720@60")
    return " ".join([*args, "consoleblank=0"]) + "\n"


def write_atomic(path, content):
    stream = tempfile.NamedTemporaryFile(dir=path.parent, delete=False)
    temp = Path(stream.name)
    try:
        with stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def configure(directory, board="pi0w"):
    files = []
    for name, transform in (("config.txt", firmware_config), ("cmdline.txt", kernel_cmdline)):
        path = directory / name
        original = path.read_bytes()
        files.append((path, original, transform(original.decode(), board).encode()))
    # Validate both files before touching either. Keep first-install backups
    # on the FAT partition so they are also accessible from the workstation.
    for path, original, _ in files:
        backup = path.with_suffix(".txt.welcomepi-backup")
        if not backup.exists():
            write_atomic(backup, original)
    for path, original, updated in files:
        if original != updated:
            write_atomic(path, updated)
    display = "HDMI-A-1 at 1280x720@60" if board == "pi0w" else "per-port KMS display modes"
    print(f"Configured {display} and GPIO UART. Boot backups are beside the originals.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-platform", action="store_true")
    args = parser.parse_args()
    model_file = Path("/proc/device-tree/model")
    if not model_file.is_file():
        parser.exit(1, "Run setup on a Raspberry Pi Zero W, Pi 4 Model B or Pi 5.\n")
    try:
        board = board_profile(model_file.read_text(), platform.freedesktop_os_release().get("VERSION_CODENAME"),
                              subprocess.check_output(["dpkg", "--print-architecture"], text=True).strip())
    except ValueError as error:
        parser.exit(1, f"{error}\n")
    if args.check_platform:
        print(board)
    else:
        configure(Path("/boot/firmware"), board)
