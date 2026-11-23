"""Apply the Zero W profile to a stock Bookworm boot partition."""
import os
from pathlib import Path
import re
import tempfile


def firmware_config(original):
    lines = original.splitlines(keepends=True)
    active = True
    kms = False
    settings = {}
    for index, line in enumerate(lines):
        directive = line.partition("#")[0].strip()
        if directive.startswith("["):
            active = directive in ("[all]", "[pi0]", "[pi0w]")
        if not active:
            continue
        key, _, value = directive.partition("=")
        key, value = key.strip(), value.strip()
        if key == "dtoverlay" and value.split(",")[0] in ("vc4-fkms-v3d", "vc4-kms-v3d"):
            kms = True
            lines[index] = line.replace("vc4-fkms-v3d", "vc4-kms-v3d", 1)
        if key in ("enable_uart", "disable_fw_kms_setup"):
            settings[key] = value
    additions = [] if kms else ["dtoverlay=vc4-kms-v3d"]
    for name in ("enable_uart", "disable_fw_kms_setup"):
        if settings.get(name) != "1":
            additions.append(f"{name}=1")
    text = "".join(lines)
    if additions:
        text = text.rstrip("\r\n") + "\n\n[all]\n" + "\n".join(additions) + "\n"
    return text


def kernel_cmdline(original):
    lines = original.strip().splitlines()
    if len(lines) != 1:
        raise ValueError("Expected one kernel command line in cmdline.txt")
    # Preserve root=, non-serial consoles, other outputs and quoted kernel arguments.
    tokens = re.findall(r"""(?:[^\s"']+|"[^"]*"|'[^']*')+""", lines[0])
    serial = ("console=serial0", "console=ttyAMA0", "console=ttyS0")
    args = [t for t in tokens if t.split(",", 1)[0] not in serial
            and not t.startswith(("consoleblank=", "video=HDMI-A-1:"))]
    return " ".join([*args, "video=HDMI-A-1:1280x720@60", "consoleblank=0"]) + "\n"


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


def configure(directory):
    files = []
    for name, transform in (("config.txt", firmware_config), ("cmdline.txt", kernel_cmdline)):
        path = directory / name
        original = path.read_bytes()
        files.append((path, original, transform(original.decode()).encode()))
    # Validate both files before touching either. Keep first-install backups
    # on the FAT partition so they are also accessible from the workstation.
    for path, original, _ in files:
        backup = path.with_suffix(".txt.welcomepi-backup")
        if not backup.exists():
            write_atomic(backup, original)
    for path, original, updated in files:
        if original != updated:
            write_atomic(path, updated)
    print("Configured HDMI-A-1 at 1280x720@60 and GPIO UART. Boot backups are beside the originals.")


if __name__ == "__main__":
    configure(Path("/boot/firmware"))
