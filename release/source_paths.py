"""Bounded source-path inventory over Git's exact visible file set.

Inspect source paths against the explicit system-location grammar.
Every Git-enumerated file receives a disposition, including extensionless files.
"""
from __future__ import annotations

import re
import stat
import subprocess
from pathlib import Path


# Component names describe the grammar being detected, never runtime locations.
SYSTEM_COMPONENTS = ('Users', 'Volumes', 'Applications', 'System', 'Library',
                     'opt', 'usr', 'bin', 'sbin', 'tmp', 'private', 'var', 'home',
                     'etc', 'dev', 'proc', 'root', 'run', 'mnt', 'media')
_ROOT = re.compile(r'\x7e(?=$|[/\s\x27"`])(?:/[^\s\x27"`<>()[\]{},:;!?\\]*)?|/(?:' + '|'.join(SYSTEM_COMPONENTS) + r')(?=$|[/\s\x27"`<>()[\]{},:;.!?\\])', re.IGNORECASE)
_URI = re.compile(r'\b([A-Za-z][A-Za-z0-9+.-]*)://[^\s\x27"<>`]+')


def path_literals(text: str) -> list[dict]:
    matches = []
    for number, line in enumerate(text.splitlines(), 1):
        uris = list(_URI.finditer(line))
        for match in _ROOT.finditer(line):
            uri = next((uri for uri in uris if uri.start() <= match.start() < uri.end()), None)
            previous = line[match.start() - 1] if match.start() else ''
            appended_suffix = re.search(r'\b[A-Za-z_]\w*\s*\+\s*[\x27"]$', line[:match.start()])
            pointer_escape = match.group() == chr(126) and re.search(r'\.replace\([\x27"]\x7e0[\x27"],\s*[\x27"]$', line[:match.start()])
            if pointer_escape:
                classification = 'json_pointer_escape'
            elif uri and uri.group(1).lower() != 'file':
                classification = 'uri'
            elif previous and (previous.isalnum() or previous in '._-/') and not uri:
                classification = 'relative_member'
            elif appended_suffix:
                classification = 'appended_member_suffix'
            else:
                classification = 'system_root_literal'
            matches.append({'line': number, 'column': match.start() + 1,
                            'token': match.group(), 'classification': classification})
    return matches


def inventory(repo: Path) -> dict:
    repo = Path(repo).resolve()
    raw = subprocess.run(['git', '-C', str(repo), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
                         check=True, capture_output=True, timeout=20).stdout
    names = sorted(set(name.decode('utf-8') for name in raw.split(b'\0') if name))
    entries = []
    for name in names:
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('unsafe Git source path')
        path = repo / relative
        entry = {'path': name}
        # Do not traverse a changed directory symlink, including an ancestor.
        ancestors = [repo.joinpath(*relative.parts[:i]) for i in range(1, len(relative.parts) + 1)]
        if any(parent.is_symlink() for parent in ancestors):
            entry['disposition'] = 'symlink_not_followed'
        elif not path.exists():
            entry['disposition'] = 'missing_worktree_entry'
        elif not stat.S_ISREG(path.stat().st_mode):
            entry['disposition'] = 'special_not_read'
        elif (name.startswith(('config/', 'outputs/', 'native/PaymentImageCore/Tests/FinancialStoreTests/Fixtures/'))
              and name != 'config/release-version.json'):
            entry['disposition'] = 'private_input_deferred_P2_P3_P4'
        else:
            data = path.read_bytes()
            try:
                text = data.decode('utf-8')
            except UnicodeDecodeError:
                entry['disposition'] = 'binary_not_text_scanned'
            else:
                if '\0' in text:
                    entry['disposition'] = 'binary_not_text_scanned'
                else:
                    entry['disposition'] = 'text_scanned'
                    entry['matches'] = path_literals(text)
        entries.append(entry)
    counts = {kind: sum(row['disposition'] == kind for row in entries)
              for kind in sorted({row['disposition'] for row in entries})}
    return {'scope': 'Git tracked plus visible untracked files, no filesystem recursion; system-root literals only',
            'enumerated': len(names), 'counts': counts, 'entries': entries,
            'unresolved': sum(match['classification'] == 'system_root_literal'
                              for entry in entries for match in entry.get('matches', []))}
