#!/usr/bin/env python
"""What gets published to the Space, and a digest that identifies it.

Two scripts read this: deploy_space.py, which uploads the manifest and records
the digest, and check_deployment.py, which recomputes the digest and compares it
against what the Space reports. They must agree on the file set exactly, which
is why the set is defined once, here.

Run directly to print the digest of the current build context:

    python dairy-api/payload.py
"""

from __future__ import annotations

import hashlib
import sys
from fnmatch import fnmatch
from pathlib import Path
from typing import Iterable

CONTEXT = Path(__file__).resolve().parent

# Developer tooling and repo-relative scripts that mean nothing inside a Space.
IGNORE = [
    "tests/*",
    "skill_harness/*",
    "__pycache__/*",
    "*/__pycache__/*",
    "*.pyc",
    ".pytest_cache/*",
    "build.sh",
    "verify_build_context.sh",
    "deploy_space.py",
    "check_deployment.py",
    "payload.py",
    "requirements-deploy.txt",
    "railway.toml",
]

# Written by deploy_space.py from the digest of everything else, so it cannot be
# part of what it identifies. It is still uploaded -- the Space serves it from
# /health, and that is what makes drift detectable at all.
BUILD_INFO_NAME = "build_info.json"

# Line endings are normalised before hashing. `.gitattributes` sets `text=auto`,
# so a Windows checkout holds CRLF where a Linux one holds LF, and hashing raw
# bytes would report drift between two checkouts of the same commit. A file that
# differs only in line endings is not a Space running something older.
#
# Text is decided by content rather than by suffix, and the difference is not
# academic: `Dockerfile` and `.dockerignore` are both in the payload, both have
# an empty `Path.suffix`, and `text=auto` converts them like anything else. A
# suffix list left the two most load-bearing files in the build context hashing
# differently on two checkouts of one commit -- found by Codex review on PR #59,
# and reproduced on this working tree, where both carried CRLF.
#
# The rule below is git's own: a file is binary if it holds a NUL byte near the
# start. That is what `text=auto` itself applies, so the digest and the working
# tree cannot disagree about which files were converted -- and it does not go
# stale when someone adds a Makefile or a LICENSE.
_BINARY_SNIFF_BYTES = 8000


def is_text(content: bytes) -> bool:
    return b"\0" not in content[:_BINARY_SNIFF_BYTES]


def manifest(context: Path = CONTEXT) -> list[tuple[Path, str]]:
    """Every file upload_folder will publish, as (path, posix relative path)."""
    found = sorted(
        (path, path.relative_to(context).as_posix())
        for path in context.rglob("*")
        if path.is_file()
    )
    return [
        (path, rel)
        for path, rel in found
        if not any(fnmatch(rel, pattern) for pattern in IGNORE)
    ]


def digest(context: Path = CONTEXT) -> str:
    """A sha256 over the published file set: every relative path and its content.

    Identifies what the Space is running. Two checkouts of the same commit give
    the same digest; one file changed anywhere in the payload gives a different
    one.
    """
    running = hashlib.sha256()
    for path, rel in manifest(context):
        if rel == BUILD_INFO_NAME:
            continue
        content = path.read_bytes()
        if is_text(content):
            content = content.replace(b"\r\n", b"\n")
        running.update(rel.encode("utf-8"))
        running.update(b"\0")
        running.update(hashlib.sha256(content).digest())
    return running.hexdigest()


def stale_remote_files(deployed: Iterable[str], context: Path = CONTEXT) -> list[str]:
    """Files the deployment carries that this build context does not.

    The digest identifies the *content* of the local manifest, and identical
    content is not the same thing as an identical deployment. `upload_folder`
    adds and overwrites; a file that disappears locally stays on the Space
    unless deletion is asked for. So the Space can carry a module, a route file
    or an R input the repository dropped, while the digest still matches.

    Measured, not hypothesised: the Space carried `fastapi_app.py` and
    `model.joblib` from an earlier incarnation through three deploys of this
    work, and the check reported it current every time.

    `.gitattributes` is excluded because the Hub owns it -- it writes the file
    and `upload_folder` refuses to delete it.
    """
    local = {rel for _, rel in manifest(context)}
    return sorted(set(deployed) - local - {".gitattributes"})


def main() -> int:
    files = manifest()
    if not files:
        print("No build context. Run `bash dairy-api/build.sh` first.")
        return 1
    print(f"{len(files)} files")
    print(digest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
