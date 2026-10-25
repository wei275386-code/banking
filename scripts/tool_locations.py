"""Tool and OS-directory discovery; never a financial data-root fallback."""
from __future__ import annotations

import os
import pwd
import shutil
import subprocess
import tempfile
from functools import lru_cache
from pathlib import Path


def system_search_path():
    path = os.confstr('CS_PATH') if hasattr(os, 'confstr') else None
    return path or os.defpath


def tool_path(name, *, system=False, environment=None):
    if not name or Path(name).name != name or '/' in name or '\\' in name or '\0' in name:
        raise ValueError('invalid tool name')
    environment = os.environ if environment is None else environment
    search = system_search_path() if system else environment.get('PATH', system_search_path())
    # Empty/relative search entries never make cwd into an executable source.
    search = os.pathsep.join(p for p in search.split(os.pathsep) if Path(p).is_absolute())
    selected = shutil.which(name, path=search)
    if selected is None:
        raise ValueError('required tool unavailable: ' + name)
    return selected


def controlled_environment(*, development=False, temporary=None):
    search = system_search_path()
    if development:
        # Only discovered developer launchers add prefixes; arbitrary ambient
        # PATH entries do not become a child execution search path.
        for name in ('node', 'xcodegen', 'xcodebuildmcp'):
            try:
                prefix = str(Path(tool_path(name)).parent)
            except ValueError:
                continue
            if prefix not in search.split(os.pathsep):
                search += os.pathsep + prefix
    search = os.pathsep.join(p for p in search.split(os.pathsep) if Path(p).is_absolute())
    return {'PATH': search,
            'HOME': pwd.getpwuid(os.getuid()).pw_dir,
            'TMPDIR': str(Path(temporary or tempfile.gettempdir()).resolve()),
            'LANG': 'en_US.UTF-8'}


def resolve_command(command):
    """Discover launchers before clearing ambient code overrides for children."""
    command = list(command)
    name = os.fspath(command[0])
    if Path(name).name == name:
        command[0] = tool_path(name, system=name not in {'xcodebuildmcp', 'xcodegen', 'node', 'python3'})
    return command


@lru_cache(maxsize=8)
def macos_directory(kind):
    # Scripts are fixed OS queries, never interpolated user command text.
    scripts = {
        'applications': 'POSIX path of (path to applications folder from local domain)',
        'system_library': 'POSIX path of (path to library folder from system domain)',
        'user_support': 'POSIX path of (path to application support from user domain)',
        'user_library': 'POSIX path of (path to library folder from user domain)',
    }
    if kind == 'user_caches':
        command = [tool_path('osascript', system=True), '-l', 'JavaScript', '-e',
                   'ObjC.import("Foundation"); $.NSFileManager.defaultManager.URLsForDirectoryInDomains($.NSCachesDirectory, $.NSUserDomainMask).firstObject.path.js']
    elif kind in scripts:
        command = [tool_path('osascript', system=True), '-e', scripts[kind]]
    else:
        raise ValueError('unsupported OS directory kind')
    raw = subprocess.run(command,
                         check=True, capture_output=True, text=True, timeout=10,
                         env=controlled_environment()).stdout.strip()
    path = Path(raw)
    if not raw or not path.is_absolute() or '..' in path.parts:
        raise ValueError('invalid OS directory result')
    return path


def application_path():
    return macos_directory('applications') / '家庭财务复盘.app'


def launch_services_tool():
    # CoreServices is located relative to the OS system library directory.
    path = macos_directory('system_library') / 'Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError('LaunchServices registration tool unavailable')
    return str(path)


@lru_cache(maxsize=1)
def system_library_roots():
    # Derive platform library locations from OS discovery and its utility prefix,
    # never from DYLD overrides or an untrusted downloaded Mach-O's strings.
    utility_prefix = Path(tool_path('codesign', system=True)).parent.parent
    return (utility_prefix / 'lib', macos_directory('system_library'))


def is_system_library(path):
    candidate = Path(path)
    return candidate.is_absolute() and '..' not in candidate.parts and any(
        candidate != root and candidate.is_relative_to(root) for root in system_library_roots())
