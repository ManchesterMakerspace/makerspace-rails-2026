import io
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError
from zipfile import ZipFile, ZipInfo

from deploy import release, update


BASE = {"welcomepi/__init__.py": b"", "welcomepi/__main__.py": b"# original\n",
        "pi0/check.py": b"# check\n", "requirements.txt": b"nfcpy==1.0.4\n"}
PUBLISHER = Path(__file__).resolve().parents[1] / "deploy/publish.py"


def write_tree(root, entries):
    for name, data in entries.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


class Publication(unittest.TestCase):
    """Use real Git pushes against a disposable local origin, including the first orphan commit."""

    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.work = root / "work"
        self.origin = root / "origin.git"
        self.work.mkdir()
        self.git("init", "--bare", str(self.origin))
        self.git("init", "-b", "master")
        self.git("config", "user.name", "Kiosk Test")
        self.git("config", "user.email", "kiosk@example.invalid")
        self.git("config", "core.autocrlf", "false")
        self.git("remote", "add", "origin", self.origin.as_uri())
        self.tool = self.work / "tools/WelcomePi"
        write_tree(self.tool, BASE)
        self.commit()

    def git(self, *args):
        result = subprocess.run(["git", *args], cwd=self.work, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result.stdout

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-m", "fixture")
        self.git("push", "origin", "HEAD:refs/heads/master")
        return self.git("rev-parse", "HEAD").decode().strip()

    def publisher(self, *args):
        result = subprocess.run([sys.executable, "-B", str(PUBLISHER), *args], cwd=self.work,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def inspect(self):
        return dict(line.split("=", 1) for line in self.publisher("check").splitlines())

    def remote(self, *args):
        return self.git("--git-dir", str(self.origin), *args)

    def test_subdirectory_filter_and_atomic_reproducible_publication(self):
        original = self.inspect()
        self.assertEqual(original["changed"], "true")
        self.publisher("publish", original["sha256"])
        channel = "welcomepi-deploy"
        initial = self.remote("rev-parse", channel)
        self.assertEqual(self.remote("ls-tree", "--name-only", channel).splitlines(),
                         [b"manifest.json", b"welcomepi.zip"])
        self.assertEqual(self.remote("rev-list", "--count", channel).strip(), b"1")
        manifest = release.read_manifest(self.remote("show", channel + ":manifest.json"))
        self.assertEqual(manifest["source"], original["source"])
        self.assertEqual(release.unpack(self.remote("show", channel + ":welcomepi.zip"), manifest["sha256"]), BASE)
        for folder, name in ((self.work, "rails.rb"), (self.tool, "setup-pi0.MD"), (self.tool, "tests/test.py")):
            write_tree(folder, {name: b"# change outside the runtime"})
            self.commit()
            self.assertEqual(self.inspect()["changed"], "false")
        self.publisher("publish", original["sha256"])
        self.assertEqual(self.remote("rev-parse", channel), initial)

        write_tree(self.tool, {"welcomepi/first.py": b"new code"})
        intermediate = self.commit()
        outdated = self.inspect()
        write_tree(self.tool, {"requirements.txt": b"new requirement"})
        latest = self.commit()
        self.git("checkout", "--detach", intermediate)
        self.publisher("publish", outdated["sha256"])
        self.assertEqual(self.remote("rev-parse", channel), initial)
        self.git("checkout", "--detach", latest)
        tested = self.inspect()["sha256"]
        write_tree(self.work, {"unrelated.rb": b"# a later unrelated master push"})
        self.commit()
        self.git("checkout", "--detach", latest)
        self.publisher("publish", tested)
        self.assertEqual(self.remote("rev-parse", channel + "^"), initial)
        self.assertEqual(release.read_manifest(self.remote("show", channel + ":manifest.json"))["source"], latest)


class ReleaseFormat(unittest.TestCase):
    def test_deterministic_archive_and_deletion(self):
        archive = release.pack(BASE)
        self.assertEqual(archive, release.pack(dict(reversed(list(BASE.items())))))
        self.assertNotEqual(archive, release.pack({**BASE, "welcomepi/extra.py": b""}))
        with self.assertRaises(ValueError):
            release.unpack(archive, "a" * 64)

    def test_only_bounded_regular_runtime_files_are_accepted(self):
        for name in ("README.md", ".venv/config", "welcomepi/../config", "welcomepi/.env"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                release.pack({**BASE, name: b"x"})
        stream = io.BytesIO(release.pack(BASE))
        with ZipFile(stream, "a") as archive:
            entry = ZipInfo("welcomepi/link")
            entry.external_attr = 0o120777 << 16
            archive.writestr(entry, "some-file")
        with self.assertRaises(ValueError):
            release.unpack(stream.getvalue(), release.digest(stream.getvalue()))

    def test_anonymous_conditional_get_and_immutable_file_urls(self):
        http = update.Channel()
        def unchanged(request, timeout):
            self.assertEqual(request.get_header("If-none-match"), '"head"')
            self.assertIsNone(request.get_header("Authorization"))
            raise HTTPError(request.full_url, 304, "unchanged", {}, None)
        with patch.object(update, "urlopen", side_effect=unchanged):
            self.assertEqual(http.head('"head"'), (None, '"head"'))
        revision = "a" * 40
        with patch.object(http, "get", return_value=(b"contents", None)) as get:
            self.assertEqual(http.file(revision, release.ARCHIVE, 4096), b"contents")
            self.assertIn("/" + revision + "/welcomepi.zip", get.call_args.args[0])


class Feed:
    def __init__(self):
        self.reads = []
        self.tags = []
        self.put(BASE)

    def put(self, files):
        self.archive = release.pack(files)
        self.checksum = release.digest(self.archive)
        self.revision = self.checksum[:40]
        self.etag = '"' + self.revision + '"'
        self.manifest = json.dumps({"format": 1, "source": "0" * 40, "sha256": self.checksum}).encode()

    def head(self, tag):
        self.tags.append(tag)
        return (None if tag == self.etag else self.revision), self.etag

    def file(self, revision, name, limit):
        if revision != self.revision:
            raise AssertionError("Archive and manifest must use the observed commit")
        self.reads.append(name)
        return self.manifest if name == release.MANIFEST else self.archive


class StartupCheck(unittest.TestCase):
    def test_flapping_or_inactive_service_fails_the_health_check(self):
        running = b"ActiveState=active\nSubState=running\nInvocationID=first\n"
        for after in (running, running.replace(b"first", b"second"), b"ActiveState=failed\n"):
            with self.subTest(after=after), patch.object(update.subprocess, "run") as run, \
                    patch.object(update.subprocess, "check_output", side_effect=[running, after]), \
                    patch.object(update.time, "sleep"):
                if after == running:
                    update.Host().restart()
                else:
                    with self.assertRaises(RuntimeError):
                        update.Host().restart()
                run.assert_called_once_with(["systemctl", "restart", "welcomepi.service"], check=True)


class PiUpdates(unittest.TestCase):
    def setUp(self):
        if sys.platform == "win32":
            # Windows kiosk developers can exercise POSIX directory links without administrator privileges.
            from pyfakefs.fake_filesystem import OSType
            from pyfakefs.fake_filesystem_unittest import Patcher
            patcher = Patcher()
            patcher.setUp()
            self.addCleanup(patcher.tearDown)
            patcher.fs.os = OSType.LINUX
            # Windows shutil probes NTFS reparse attributes even on the simulated Linux filesystem.
            self.enterContext(patch.object(update.shutil, "rmtree", patcher.fs.remove_object))
            root = Path("/kiosk-tests")
        else:
            temp = TemporaryDirectory()
            self.addCleanup(temp.cleanup)
            root = Path(temp.name)
        self.app = root / "app"
        ram = root / "run"
        ram.mkdir(parents=True)
        self.feed = Feed()
        self.host = Mock(spec=update.Host)
        self.host.active.return_value = True
        self.pi = update.Installation(self.app, ram, self.host, self.feed)
        write_tree(self.app, {**BASE, ".venv/bin/python": b"installed interpreter"})
        self.pi.enroll()
        self.baseline = self.pi.active_release(self.pi.current)

    def test_enroll_twice_and_unchanged_polls_only_read_the_ref(self):
        self.pi.enroll()
        self.pi.poll()
        self.pi.poll()
        self.assertEqual(self.feed.tags, [None, self.feed.etag])
        self.assertEqual(self.feed.reads, [release.MANIFEST])
        self.assertEqual(list(self.pi.releases.iterdir()), [self.baseline])
        self.assertEqual(self.host.mock_calls, [])
        with patch.object(update, "write_file") as write:
            self.pi.poll()
            write.assert_not_called()

    def test_app_only_restarts_once_reuses_venv_and_removes_old_modules(self):
        first = {**BASE, "welcomepi/temporary.py": b"# extra"}
        self.feed.put(first)
        self.pi.poll()
        intermediate = self.pi.active_release(self.pi.current)
        self.assertEqual((intermediate / ".venv").resolve(), self.app / ".venv")
        self.assertTrue(os.path.samefile(intermediate / "pi0/check.py", self.baseline / "pi0/check.py"))
        self.pi.poll()
        self.host.restart.assert_called_once_with()
        self.feed.put({**BASE, "welcomepi/__main__.py": b"# new"})
        self.pi.poll()
        self.host.build_venv.assert_not_called()
        self.assertEqual(self.pi.active_release(self.pi.previous), intermediate)
        self.assertFalse((self.pi.current / "welcomepi/temporary.py").exists())
        self.assertFalse(self.baseline.exists())
        self.assertEqual(len(list(self.pi.releases.iterdir())), 2)

    def test_requirements_build_once_and_reuse_matching_venv(self):
        def build(dest, requirements, ram):
            self.assertEqual(dest.parent, self.pi.venvs)
            self.assertEqual(requirements.read_bytes(), b"changed")
            write_tree(dest, {"bin/python": b"new interpreter"})
        self.host.build_venv.side_effect = build
        files = {**BASE, "requirements.txt": b"changed"}
        self.feed.put(files)
        self.pi.poll()
        new_env = (self.pi.current / ".venv").resolve()
        self.assertEqual(new_env.parent, self.pi.venvs)
        self.feed.put({**files, "welcomepi/__main__.py": b"# next"})
        self.pi.poll()
        self.assertEqual((self.pi.current / ".venv").resolve(), new_env)
        self.host.build_venv.assert_called_once()

    def test_unreachable_corrupt_or_stopped_kiosk_preserves_active_installation(self):
        self.feed.put({**BASE, "welcomepi/change.py": b"x"})
        with patch.object(self.feed, "head", side_effect=URLError("offline")), self.assertRaises(URLError):
            self.pi.poll()
        archive = self.feed.archive
        self.feed.archive = archive[:-1]
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.pi.poll()
        self.host.active.return_value = False
        self.feed.archive = archive
        self.pi.poll()
        self.assertEqual(self.pi.active_release(self.pi.current), self.baseline)
        self.assertEqual(list(self.pi.releases.iterdir()), [self.baseline])
        self.host.restart.assert_not_called()
        self.host.active.return_value = True
        self.pi.poll()
        self.host.restart.assert_called_once_with()

    def test_bad_imports_and_failed_startup_hold_the_revision(self):
        self.feed.put({**BASE, "welcomepi/change.py": b"bad import"})
        self.host.check_imports.side_effect = subprocess.CalledProcessError(1, "python")
        with self.assertRaisesRegex(RuntimeError, "imports"):
            self.pi.poll()
        self.pi.poll()
        self.host.restart.assert_not_called()
        self.feed.put({**BASE, "welcomepi/change.py": b"bad startup"})
        self.host.check_imports.side_effect = None
        self.host.restart.side_effect = [RuntimeError("crash loop"), None]
        with self.assertRaisesRegex(RuntimeError, "crash loop"):
            self.pi.poll()
        self.assertEqual(self.pi.active_release(self.pi.current), self.baseline)
        self.assertEqual(self.host.restart.call_count, 2)
        self.host.restart.assert_called_with(restoring=True)
        self.assertFalse(self.pi.pending.exists())
        self.pi.poll()
        self.pi.poll()
        self.assertEqual(self.host.restart.call_count, 2)
        self.assertEqual(list(self.pi.releases.iterdir()), [self.baseline])
        self.pi.rejected.unlink()  # Operator has repaired the cause and requests a retry.
        self.host.restart.side_effect = None
        self.pi.poll()
        self.assertEqual(self.pi.active_release(self.pi.current).name, self.feed.checksum)

    def test_interrupted_activation_recovers_before_contacting_github(self):
        self.feed.put({**BASE, "welcomepi/fresh.py": b""})
        self.host.restart.side_effect = KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            self.pi.poll()
        self.assertNotEqual(self.pi.active_release(self.pi.current), self.baseline)
        self.host.restart.side_effect = None
        with patch.object(self.feed, "head", side_effect=URLError("offline")), self.assertRaises(URLError):
            self.pi.poll()
        self.assertEqual(self.pi.active_release(self.pi.current), self.baseline)
        self.assertFalse(self.pi.pending.exists())
        self.host.restart.assert_called_with(restoring=True)

    def test_stop_during_preparation_defers_publication_until_service_resumes(self):
        self.feed.put({**BASE, "welcomepi/change.py": b"updated"})
        self.host.active.side_effect = [True, False]
        self.pi.poll()
        self.host.restart.assert_not_called()
        self.assertEqual(self.pi.active_release(self.pi.current), self.baseline)
        self.host.active.side_effect = None
        self.pi.poll()
        self.host.restart.assert_called_once_with()

    def test_dependency_fetch_failure_backs_off_in_ram_and_retries(self):
        self.feed.put({**BASE, "requirements.txt": b"new"})
        self.host.build_venv.side_effect = subprocess.CalledProcessError(1, "pip")
        with patch.object(update.time, "monotonic", return_value=100):
            with self.assertRaises(update.DependencyBuildError):
                self.pi.poll()
            self.pi.poll()
        self.host.build_venv.assert_called_once()
        self.assertEqual(list(self.pi.venvs.iterdir()), [])
        self.host.build_venv.side_effect = None
        with patch.object(update.time, "monotonic", return_value=3701):
            self.pi.poll()
        self.assertEqual(self.host.build_venv.call_count, 2)
        self.host.restart.assert_called_once_with()
