"""Bounded regular-file copying for current local installation operations."""
from __future__ import annotations
import os
import stat
from scripts.workspace_state import _regular, _safe


def copy_file(source, target, check=None):
    check = check or (lambda point: None)
    source = _regular(source)
    target = _safe(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    with os.fdopen(os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as src:
        if not stat.S_ISREG(os.fstat(src.fileno()).st_mode):
            raise ValueError("copy source is not a regular file")
        with os.fdopen(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb") as dst:
            while True:
                check("copy-chunk")
                chunk = src.read(1024 * 1024)
                if not chunk:
                    break
                dst.write(chunk)
            dst.flush()
            os.fsync(dst.fileno())
