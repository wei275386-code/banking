"""Atomic App bundle update primitives."""
import contextlib
import ctypes
import fcntl
import os
import subprocess
import time
from pathlib import Path
if __package__:
    from .tool_locations import application_path, resolve_command
else:
    from tool_locations import application_path, resolve_command

def default_app_path():
    return application_path()

BUNDLE_ID = 'local.banking.family-review'


@contextlib.contextmanager
def install_lock(app):
    with (app.parent / '.family-review-install.lock').open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError('Another App installation is in progress') from error
        yield


def swap_bundles(first, second):
    """Both directories stay present while their names switch atomically on APFS."""
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(first), os.fsencode(second), 2):  # RENAME_SWAP
        errno = ctypes.get_errno()
        raise OSError(errno, os.strerror(errno))


def running_app_pids(app):
    result = subprocess.run(resolve_command(['pgrep', '-x', 'EvidenceBrowser']), capture_output=True, text=True, timeout=10)
    if result.returncode not in (0, 1):
        raise RuntimeError('Unable to inspect running App processes')
    executable = 'n' + str(app / 'Contents/MacOS/EvidenceBrowser')
    matches = []
    for pid in result.stdout.split():
        files = subprocess.run(resolve_command(['lsof', '-a', '-p', pid, '-d', 'txt', '-Fn']),
                               capture_output=True, text=True, timeout=10)
        if files.returncode not in (0, 1):
            raise RuntimeError('Unable to inspect the executable of a running App')
        if executable in files.stdout.splitlines():
            matches.append(int(pid))
    return matches


def stop_app(app):
    if not running_app_pids(app):
        return
    # A normal application Quit delivers AppKit termination events; never force-kill.
    script = 'on run argv\ntell application (item 1 of argv) to quit\nend run'
    subprocess.run(resolve_command(['osascript', '-e', script, str(app)]), check=True, capture_output=True, timeout=15)
    deadline = time.monotonic() + 10
    while running_app_pids(app):
        if time.monotonic() > deadline:
            raise RuntimeError('App did not finish quitting; installed bundle was not replaced')
        time.sleep(0.1)

