#!/usr/bin/env python3
"""Reject release inputs that cannot be identified by the current commit."""
import subprocess
from pathlib import Path


def check(root):
    result = subprocess.run(
        ["git", "-C", str(root), "status", "--porcelain=v1", "-z", "--untracked-files=all"],
        check=True, capture_output=True,
    )
    entries = iter(result.stdout.decode().split("\0"))
    dirty = []
    for entry in entries:
        if not entry:
            continue
        status, path = entry[:2], entry[3:]
        if status != "??" or path.startswith(("Sources/", "Resources/", "App/")):
            dirty.append(path)
        if "R" in status or "C" in status:
            next(entries)  # --porcelain -z puts the old name after a rename/copy.
    if dirty:
        raise SystemExit("Release packaging requires a clean source tree. Commit or stash changes first:\n"
                         + "\n".join(dirty))


if __name__ == "__main__":
    check(Path(__file__).resolve().parent.parent)
