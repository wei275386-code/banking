"""Read-only upgrade closure over an explicit, stopped-app container copy.

This is preservation evidence, not a schema migrator or a cloud bridge. Unknown
persistent files are retained exactly. Only tmp/ and Library/Caches/ are omitted.
"""
from __future__ import annotations

import argparse
import base64
import os
import plistlib
import re
import stat
import unicodedata
from pathlib import Path

from scripts.release_contracts import (canonical_json,
    digest_bytes, digest_file, parse_json, validate_relative_path)
from scripts.workspace_state import WorkspacePaths, _safe, _regular

BUNDLE_ID = 'local.familyreview.FamilyReview'
POLICY = Path(__file__).resolve().parents[1] / 'release/compatibility.json'
EXCLUDED = ('tmp/', 'Library/Caches/')
MAX_FILES = 100_000
MAX_BYTES = 100 * 1024**3
HASH = re.compile(r'[0-9a-f]{64}\Z')



class InstallationError(ValueError):
    pass


def relative(value):
    try:
        return validate_relative_path(value)
    except (ValueError, TypeError) as error:
        raise InstallationError('unsafe relative path') from error


def hash_value(value):
    if not isinstance(value, str) or not HASH.fullmatch(value):
        raise InstallationError('invalid SHA256 reference')
    return value


def excluded(name):
    return any(name == prefix.rstrip('/') or name.startswith(prefix) for prefix in EXCLUDED)


def safe_tree(root):
    root = _safe(Path(root))
    if not root.is_dir():
        raise InstallationError('container copy is not a directory')
    files, directories, aliases, size = {}, [], set(), 0
    for directory, dirs, names in os.walk(root, followlinks=False):
        for name in [*dirs, *names]:
            path = Path(directory) / name
            rel = relative(path.relative_to(root).as_posix())
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise InstallationError('symlink or special container member: ' + rel)
            alias = unicodedata.normalize('NFC', rel).casefold()
            if alias in aliases:
                raise InstallationError('filesystem alias collision: ' + rel)
            aliases.add(alias)
            if len(aliases) > MAX_FILES:
                raise InstallationError('container member count resource limit')
            if excluded(rel):
                continue
            if stat.S_ISDIR(mode):
                directories.append(rel)
            else:
                length = path.stat().st_size
                size += length
                if len(files) >= MAX_FILES or size > MAX_BYTES:
                    raise InstallationError('container inventory resource limit')
                files[rel] = {'sha256': digest_file(_regular(path)), 'bytes': length}
        dirs[:] = [name for name in dirs if not excluded((Path(directory) / name).relative_to(root).as_posix())]
    return root, dict(sorted(files.items())), sorted(directories)


def _object(path):
    value = parse_json(_regular(path).read_bytes())
    if not isinstance(value, dict):
        raise InstallationError('expected JSON object: ' + path.name)
    return value


def inspect(root, *, data_root='Library/Application Support/FamilyReview', bundle_id=BUNDLE_ID):
    """Inventory persistent bytes and current selected/pending file references."""
    root, files, directories = safe_tree(root)
    data_root = relative(data_root)
    if not (root / data_root).is_dir():
        raise InstallationError('existing install data root is missing')
    identities, pending, revisions, dependencies, minimum_writers = {}, {}, {}, [], set()
    def require(name, expected=None, reason='reference'):
        name = relative(name)
        entry = files.get(name)
        if entry is None or expected is not None and entry['sha256'] != hash_value(expected):
            raise InstallationError('missing or changed current input: ' + name)
        dependencies.append({'path': name, 'reason': reason, 'sha256': entry['sha256']})
        return root / name
    preferences = 'Library/Preferences/' + bundle_id + '.plist'
    try:
        plistlib.loads(require(preferences, reason='preferences/bookmarks').read_bytes())
    except Exception as error:
        raise InstallationError('preferences plist is invalid') from error
    for name in files:
        if not name.startswith(data_root + '/'):
            continue
        path = root / name
        if path.suffix != '.json':
            if path.parent.name == 'objects' and HASH.fullmatch(path.name) and files[name]['sha256'] != path.name:
                raise InstallationError('corrupt content-addressed pending input')
            continue
        value = parse_json(path.read_bytes())
        if path.name in {'workspace.json', 'device-identity.json', 'family-connection.json', 'client-active.json', 'financial-review.json', 'payment-evidence.json'} and not isinstance(value, dict):
            raise InstallationError('invalid current document')
        if isinstance(value, dict) and 'min_writer_version' in value:
            compatibility(minimum_writer=value['min_writer_version'])
            minimum_writers.add(value['min_writer_version'])
        if path.name == 'workspace.json':
            try:
                state = WorkspacePaths(path.parent).resolve_active()
            except ValueError as error:
                raise InstallationError('invalid current workspace') from error
            identities[path.parent.relative_to(root).as_posix()] = {'workspace_id': state.workspace_id}
        elif path.name == 'device-identity.json' and path.parent.name == 'device':
            from scripts.release_contracts import normalized_uuid
            normalized_uuid(value['device_id'])
            identities[name] = {'device_id': value['device_id']}
        elif path.name == 'family-connection.json':
            identities[name] = {key: value[key] for key in ('workspace_id', 'binding_id', 'host_id')}
        elif path.name == 'client-active.json':
            device = path.parent
            view = relative(value['view_path'])
            if not view.startswith('client-views/') or len(view.split('/')) != 2:
                raise InstallationError('invalid selected client view')
            view_root = device / view
            metadata_path = view_root / 'client-view.json'
            metadata = _object(require(metadata_path.relative_to(root).as_posix(), value['view_hash'], 'selected-view'))
            for child, expected in metadata['files'].items():
                require(view_root.relative_to(root).as_posix() + '/' + relative(child), expected, 'selected-view-member')
        elif path.parent.name == 'envelopes' and 'family-requests' in path.parts:
            from scripts.release_contracts import normalized_uuid
            required = {'workspace_id', 'binding_id', 'request_id', 'author_device_id', 'kind', 'created_at', 'payload_hash', 'files'}
            if set(value) != required or value['kind'] not in ('import', 'review') or not isinstance(value['files'], list):
                raise InstallationError('invalid current pending request')
            request = normalized_uuid(value['request_id'])
            if path.stem != request or request in pending:
                raise InstallationError('duplicate or mismatched pending request')
            cache = path.parent.parent / 'objects'
            require((cache / hash_value(value['payload_hash'])).relative_to(root).as_posix(), value['payload_hash'], 'request-payload')
            names = set()
            for item in value['files']:
                display = relative(item['name'])
                if '/' in display or display in names:
                    raise InstallationError('invalid pending original filename')
                names.add(display)
                source = require((cache / hash_value(item['sha256'])).relative_to(root).as_posix(), item['sha256'], 'pending-input:' + request)
                if type(item['bytes']) is not int or source.stat().st_size != item['bytes']:
                    raise InstallationError('pending original size changed')
            pending[request] = files[name]['sha256']
        elif path.name in ('financial-review.json', 'payment-evidence.json'):
            field = 'records' if path.name == 'financial-review.json' else 'candidates'
            if not isinstance(value.get('dataset_id'), str) or not isinstance(value.get(field), list):
                raise InstallationError('invalid current report')
    return {'bundle_id': bundle_id, 'data_root': data_root, 'identities': identities, 'files': files,
            'minimum_writer_versions': sorted(minimum_writers), 'directories': directories,
            'pending_requests': dict(sorted(pending.items())), 'revision_causal_identities': revisions,
            'dependencies': dependencies, 'excluded_rebuildable_roots': list(EXCLUDED),
            'pending_gates': ['native-first-run-health-and-task-recovery']}


def compare(before_root, after_root, *, data_root='Library/Application Support/FamilyReview', bundle_id=BUNDLE_ID):
    before = inspect(before_root, data_root=data_root, bundle_id=bundle_id)
    after = inspect(after_root, data_root=data_root, bundle_id=bundle_id)
    if before['directories'] != after['directories'] or before['files'] != after['files']:
        raise InstallationError('installation changed persistent user data')
    return {'status': 'preservation-verified', 'exact_bytes': True, 'bundle_id': bundle_id,
            'identities': before['identities'], 'pending_requests': list(before['pending_requests']),
            'file_count': len(before['files']), 'pending_gates': before['pending_gates']}


def compatibility(*, minimum_writer=None, runtime_version=None, policy_path=POLICY):
    policy = _object(Path(policy_path))
    reasons = []
    if runtime_version is not None and runtime_version != policy['runtime_version']:
        reasons.append('unknown-runtime-build')
    def version(value):
        if not isinstance(value, str) or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
            raise InstallationError('invalid minimum writer version')
        parts = tuple(map(int, value.split('.')))
        if any(part > 2**64 - 1 for part in parts):
            raise InstallationError('invalid minimum writer version')
        return parts
    if minimum_writer is not None and version(minimum_writer) > version(policy['app_version']):
        reasons.append('minimum-writer-newer-than-app')
    writable = not reasons
    return {'readable': True, 'writable': writable, 'mode': 'read-write' if writable else 'read-only', 'reasons': reasons}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--after', type=Path)
    parser.add_argument('--data-root', default='Library/Application Support/FamilyReview')
    args = parser.parse_args(argv)
    result = (compare(args.root, args.after, data_root=args.data_root)
              if args.after else inspect(args.root, data_root=args.data_root))
    print(canonical_json(result).decode())


if __name__ == '__main__':
    main()
