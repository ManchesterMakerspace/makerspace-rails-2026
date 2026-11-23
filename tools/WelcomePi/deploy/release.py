"""WelcomePi's public release format. Shared by the publisher and the Pi."""

import hashlib
import io
import json
import re
from pathlib import PurePosixPath
from zipfile import ZIP_STORED, ZipFile, ZipInfo


ARCHIVE = "welcomepi.zip"
MANIFEST = "manifest.json"
MAX_BYTES = 8 * 1024 * 1024
REQUIRED = {"requirements.txt", "pi0/check.py", "welcomepi/__init__.py", "welcomepi/__main__.py"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def is_hash(value, length):
    return isinstance(value, str) and re.fullmatch(f"[0-9a-f]{{{length}}}", value) is not None


def check_paths(names):
    if not REQUIRED.issubset(names) or len(names) > 512:
        raise ValueError("Incomplete or oversized WelcomePi release")
    for name in names:
        parts = PurePosixPath(name).parts
        if (not parts or "/".join(parts) != name or
                not all(re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", p) for p in parts) or
                "__pycache__" in parts or name.endswith(".pyc") or
                not (name in REQUIRED or (len(parts) > 1 and parts[0] == "welcomepi"))):
            raise ValueError(f"Unexpected release path {name!r}")
        if any("/".join(parts[:i]) in names for i in range(1, len(parts))):
            raise ValueError("Release path is both a file and a directory")


def pack(files):
    """Fixed ZIP metadata makes identical runtime bytes generate the same release ID."""
    check_paths(files)
    stream = io.BytesIO()
    with ZipFile(stream, "w") as archive:
        for name in sorted(files):
            entry = ZipInfo(name)  # Fixed 1980 timestamp and ZIP_STORED.
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, files[name])
    data = stream.getvalue()
    if len(data) > MAX_BYTES:
        raise ValueError("Release exceeds the Pi's staging limit")
    return data


def unpack(data, expected):
    if len(data) > MAX_BYTES or digest(data) != expected:
        raise ValueError("WelcomePi archive checksum or size mismatch")
    with ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        names = set(archive.namelist())
        check_paths(names)
        if (len(entries) != len(names) or sum(e.file_size for e in entries) > MAX_BYTES or
                any(e.compress_type != ZIP_STORED or e.external_attr >> 16 != 0o100644 for e in entries)):
            raise ValueError("Unexpected WelcomePi archive entries")
        return {e.filename: archive.read(e) for e in entries}


def read_manifest(data):
    manifest = json.loads(data)
    if (not isinstance(manifest, dict) or manifest.get("format") != 1 or
            not is_hash(manifest.get("source"), 40) or not is_hash(manifest.get("sha256"), 64)):
        raise ValueError("Invalid WelcomePi release manifest")
    return manifest
