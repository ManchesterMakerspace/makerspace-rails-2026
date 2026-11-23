"""Run from the repository root on a GitHub-hosted runner."""

import argparse
import json
import subprocess

if __package__:
    from . import release
else:
    import release


PREFIX = "tools/WelcomePi/"
CHANNEL = "refs/heads/welcomepi-deploy"


def git(*args, data=None):
    return subprocess.run(["git", *args], input=data, stdout=subprocess.PIPE, check=True).stdout


def sha(*args):
    return git(*args).decode("ascii").strip()


def runtime(revision):
    files = {}
    paths = [PREFIX + p for p in ("welcomepi", "pi0/check.py", "requirements.txt")]
    for entry in git("ls-tree", "-rz", revision, "--", *paths).split(b"\0"):
        if not entry:
            continue
        meta, path = entry.split(b"\t", 1)
        mode, kind, oid = meta.split()
        if kind != b"blob" or mode not in (b"100644", b"100755"):
            raise ValueError("Runtime files must be regular Git blobs")
        files[path.decode().removeprefix(PREFIX)] = git("cat-file", "blob", oid.decode())
    return release.pack(files)


def published():
    if not git("ls-remote", "--heads", "origin", CHANNEL).strip():
        return None, None
    git("fetch", "--no-tags", "--depth=1", "origin", CHANNEL)
    parent = sha("rev-parse", "FETCH_HEAD")
    return parent, release.read_manifest(git("show", f"{parent}:{release.MANIFEST}"))["sha256"]


def publish(mode, expected=None):
    source = sha("rev-parse", "HEAD")
    archive = runtime(source)
    checksum = release.digest(archive)
    parent, previous = published()
    if mode == "check":
        print(f"source={source}\nsha256={checksum}\nchanged={str(previous != checksum).lower()}")
        return
    if checksum != expected:
        raise ValueError("The publish checkout differs from the tested release")
    if previous == checksum:
        print("WelcomePi already published.")
        return

    manifest = json.dumps({"format": 1, "sha256": checksum, "source": source}, sort_keys=True) + "\n"
    entries = []
    for name, data in ((release.MANIFEST, manifest.encode()), (release.ARCHIVE, archive)):
        oid = git("hash-object", "-w", "--stdin", data=data).strip()
        entries.append(b"100644 blob " + oid + b"\t" + name.encode() + b"\n")
    tree = git("mktree", data=b"".join(entries)).decode().strip()
    parents = ["-p", parent] if parent else []
    commit = sha("-c", "user.name=github-actions[bot]", "-c",
                 "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                 "commit-tree", tree, *parents, "-m", f"Publish WelcomePi from {source}")

    git("fetch", "--no-tags", "--depth=1", "origin", "refs/heads/master")
    if release.digest(runtime("FETCH_HEAD")) != checksum:
        print("A newer WelcomePi runtime reached master during testing. Its workflow will publish it.")
        return
    # A concurrent update to the channel is rejected by Git's fast-forward check.
    git("push", "origin", f"{commit}:{CHANNEL}")
    print(f"Published WelcomePi {checksum} from {source}.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("check", "publish"))
    parser.add_argument("expected", nargs="?")
    args = parser.parse_args()
    publish(args.mode, args.expected)
