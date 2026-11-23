"""Bookworm updater installed by setup.sh. Runs independently of the kiosk venv."""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from zipfile import BadZipFile

if __package__:
    from . import release
else:
    import release


REPO = "ManchesterMakerspace/makerspace-rails-2026"
CHANNEL = "refs/heads/welcomepi-deploy"
UNIT = "welcomepi.service"
APP = Path("/opt/welcomepi")
RAM = Path("/run/welcomepi-update")


def sync_dir(directory):
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_file(path, data):
    with path.open("wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def save(path, record):
    tmp = path.with_suffix(".tmp")
    write_file(tmp, json.dumps(record, sort_keys=True).encode())
    os.replace(tmp, path)
    sync_dir(path.parent)


def load(path):
    try:
        return json.loads(path.read_bytes())
    except FileNotFoundError:
        return {}


def point(link, target):
    temporary = link.with_suffix(".new")
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target, target_is_directory=True)
    os.replace(temporary, link)
    sync_dir(link.parent)


class Channel:
    def get(self, url, limit, etag=None):
        headers = {"User-Agent": "ManchesterMakerspace-WelcomePi"}
        if etag:
            headers["If-None-Match"] = etag
        try:
            with urlopen(Request(url, headers=headers), timeout=30) as response:
                data = response.read(limit + 1)
                if len(data) > limit:
                    raise ValueError("Release download exceeds the staging limit")
                return data, response.headers.get("ETag")
        except HTTPError as exc:
            if exc.code == 304 and etag:
                return None, etag
            raise

    def head(self, etag):
        data, tag = self.get(f"https://api.github.com/repos/{REPO}/git/ref/heads/welcomepi-deploy",
                             32 * 1024, etag)
        if data is None:
            return None, tag
        ref = json.loads(data)
        obj = ref.get("object", {})
        if ref.get("ref") != CHANNEL or obj.get("type") != "commit" or not release.is_hash(obj.get("sha"), 40):
            raise ValueError("GitHub returned an unexpected deployment reference")
        return obj["sha"], tag

    def file(self, revision, name, limit):
        data, _ = self.get(f"https://raw.githubusercontent.com/{REPO}/{revision}/{name}", limit)
        return data


class Host:
    def active(self):
        return subprocess.run(["systemctl", "is-active", "--quiet", UNIT]).returncode == 0

    def restart(self, restoring=False):
        if restoring:
            subprocess.run(["systemctl", "reset-failed", UNIT], check=True)
        subprocess.run(["systemctl", "restart", UNIT], check=True)
        args = ["systemctl", "show", UNIT, "-p", "ActiveState", "-p", "SubState", "-p", "InvocationID"]
        initial = subprocess.check_output(args).splitlines()
        time.sleep(12)  # More than two RestartSec intervals for this service.
        final = subprocess.check_output(args).splitlines()
        if (initial != final or b"ActiveState=active" not in final or b"SubState=running" not in final or
                not any(line.startswith(b"InvocationID=") and len(line) > 13 for line in final)):
            raise RuntimeError("WelcomePi did not stay running after restart")

    def as_builder(self, args, cwd, ram, writable=None):
        import pwd
        account = pwd.getpwnam("welcomepi-build")
        if writable:
            os.chown(writable, account.pw_uid, account.pw_gid)
        with tempfile.TemporaryDirectory(dir=ram) as temp:
            os.chown(temp, account.pw_uid, account.pw_gid)
            env = {"PATH": "/usr/bin:/bin", "HOME": temp, "TMPDIR": temp, "LC_ALL": "C.UTF-8",
                   "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"}
            subprocess.run(args, cwd=cwd, env=env, user=account.pw_uid, group=account.pw_gid,
                           extra_groups=[], umask=0o022, check=True)

    def build_venv(self, dest, requirements, ram):
        self.as_builder(["/usr/bin/python3", "-m", "venv", "--system-site-packages", dest],
                        Path("/"), ram, writable=dest)
        self.as_builder([dest / "bin/python", "-B", "-m", "pip", "--disable-pip-version-check",
                         "--no-input", "install", "--no-cache-dir", "--no-compile", "-r", requirements],
                        Path("/"), ram)

    def check_imports(self, candidate, ram):
        self.as_builder([candidate / ".venv/bin/python", "-B", "-s", "-c",
                         "from PIL import Image; import pykms, pymongo, paho.mqtt.client, qrcode, nfc; "
                         "import welcomepi.__main__, pi0.check"], candidate, ram)


class DependencyBuildError(RuntimeError):
    pass


class Installation:
    def __init__(self, root=APP, ram=RAM, host=None, channel=None):
        self.root = root
        self.ram = ram
        self.releases = root / "releases"
        self.venvs = root / "venvs"
        self.current = root / "current"
        self.previous = root / "previous"
        self.pending = root / "update-pending.json"
        self.rejected = root / "update-rejected.json"
        self.cache = ram / "channel.json"
        self.retry = ram / "dependency-retry.json"
        self.host = host or Host()
        self.channel = channel or Channel()

    def active_release(self, link):
        target = link.readlink()
        if target.parent != Path("releases") or not release.is_hash(target.name, 64):
            raise ValueError(f"Unexpected release link {link}")
        return self.root / target

    def select(self, link, checksum):
        if not release.is_hash(checksum, 64) or not (self.releases / checksum).is_dir():
            raise ValueError("Missing local release")
        point(link, Path("releases") / checksum)

    def write_release(self, files, target, base):
        target.mkdir()
        for name, content in files.items():
            dest = target / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            old = base / name
            if old.is_file() and old.read_bytes() == content:
                os.link(old, dest)
            else:
                write_file(dest, content)
        for directory, _, _ in os.walk(target, topdown=False):
            sync_dir(directory)

    def enroll(self):
        if self.current.is_symlink():
            if not (self.active_release(self.current) / ".venv/bin/python").is_file():
                raise ValueError("The active release is missing its Python interpreter")
            return
        if not (self.root / ".venv/bin/python").is_file():
            raise ValueError("Install WelcomePi and check the working kiosk before enabling updates")
        paths = list((self.root / "welcomepi").glob("*.py"))
        paths.extend((self.root / "pi0/check.py", self.root / "requirements.txt"))
        files = {p.relative_to(self.root).as_posix(): p.read_bytes() for p in paths}
        checksum = release.digest(release.pack(files))
        self.releases.mkdir(exist_ok=True)
        self.venvs.mkdir(exist_ok=True)
        initial = self.releases / checksum
        if initial.exists():  # A previous enrollment stopped before selecting the baseline.
            shutil.rmtree(initial)
        self.write_release(files, initial, self.root)
        point(initial / ".venv", self.root / ".venv")
        sync_dir(self.releases)
        self.select(self.current, checksum)
        print(f"Enrolled the installed kiosk as {checksum}.")

    def prune(self):
        keep = {self.active_release(link) for link in (self.current, self.previous) if link.is_symlink()}
        environments = {(path / ".venv").resolve() for path in keep}
        for parent, retained in ((self.releases, keep), (self.venvs, environments)):
            for path in parent.iterdir():
                if release.is_hash(path.name, 64) and path not in retained:
                    shutil.rmtree(path)

    def prepare(self, files, checksum, active):
        candidate = self.releases / checksum
        if candidate.exists():  # Previously deployed rollback release, already complete.
            return candidate
        self.write_release(files, candidate, active)
        requirements = files["requirements.txt"]
        for link in (self.current, self.previous):
            if link.is_symlink() and (link / "requirements.txt").read_bytes() == requirements:
                env = (link / ".venv").resolve()
                break
        else:
            env = self.venvs / release.digest(requirements)
            env.mkdir()
            try:
                self.host.build_venv(env, candidate / "requirements.txt", self.ram)
            except (subprocess.CalledProcessError, OSError) as exc:
                raise DependencyBuildError("Dependency installation failed") from exc
        point(candidate / ".venv", env)
        sync_dir(self.releases)
        return candidate

    def recover(self):
        pending = load(self.pending)
        if pending:
            self.select(self.current, pending["previous"])
            self.host.restart(restoring=True)
            if pending["rollback"]:
                self.select(self.previous, pending["rollback"])
            else:
                self.previous.unlink(missing_ok=True)
            self.pending.unlink()
            sync_dir(self.root)
            self.prune()
            print("Restored the last working WelcomePi release.")

    def activate(self, files, checksum, revision, active):
        self.prune()  # Discard incomplete staging left by an interrupted preparation.
        try:
            candidate = self.prepare(files, checksum, active)
            try:
                self.host.check_imports(candidate, self.ram)
            except (OSError, subprocess.CalledProcessError) as exc:
                save(self.rejected, {"revision": revision})
                raise RuntimeError("Candidate imports failed; this revision is held") from exc
            if not self.host.active():  # A dependency build can outlast the start of maintenance.
                return False

            rollback = self.active_release(self.previous).name if self.previous.is_symlink() else None
            save(self.pending, {"previous": active.name, "rollback": rollback})
            self.select(self.current, checksum)
            try:
                self.host.restart()
            except (OSError, subprocess.CalledProcessError, RuntimeError):
                try:
                    save(self.rejected, {"revision": revision})
                finally:
                    self.recover()
                raise
            self.select(self.previous, active.name)
            self.pending.unlink()
            sync_dir(self.root)
            print(f"Activated WelcomePi {checksum}.")
            return True
        finally:
            if not self.pending.exists():
                self.prune()

    def poll(self):
        self.recover()  # Also works offline after a power loss in the activation window.
        active = self.active_release(self.current)
        rejected = load(self.rejected).get("revision")
        cached = load(self.cache)
        if cached.get("active") != active.name or cached.get("rejected") != rejected:
            cached = {}
        revision, etag = self.channel.head(cached.get("etag"))
        if revision is None or revision == cached.get("revision"):
            return
        if revision != rejected:
            retry = load(self.retry)
            if retry.get("revision") == revision and time.monotonic() < retry["after"]:
                return
            manifest = release.read_manifest(self.channel.file(revision, release.MANIFEST, 4096))
            checksum = manifest["sha256"]
            if checksum != active.name:
                if not self.host.active():  # Leave deliberately stopped kiosks in maintenance.
                    return
                data = self.channel.file(revision, release.ARCHIVE, release.MAX_BYTES)
                files = release.unpack(data, checksum)
                try:
                    if not self.activate(files, checksum, revision, active):
                        return
                except DependencyBuildError:
                    save(self.retry, {"revision": revision, "after": time.monotonic() + 3600})
                    raise
                active = self.active_release(self.current)
        # Remember only a handled revision. A failed fetch or build is retried, even with ETags.
        save(self.cache, {"active": active.name, "rejected": rejected, "revision": revision, "etag": etag})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("enroll", "poll"))
    args = parser.parse_args()
    try:
        installation = Installation()
        if args.command == "enroll":
            installation.enroll()
        else:
            installation.poll()
    except (OSError, RuntimeError, ValueError, BadZipFile, subprocess.CalledProcessError) as error:
        sys.exit(f"WelcomePi update: {error}")
