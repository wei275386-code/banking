"""Commit-only release inputs and streaming Git blob access.

No working tree content, user HOME, git submodule, symlink, or filesystem glob
can enter a source export. Defaults have an explicit JSON schema allowlist.
"""
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

from release.validation import ContractError, validate
from scripts.release_contracts import validate_contract, ContractError as SharedContractError

CHUNK_SIZE = 1024 * 1024
METADATA_LIMIT = 2 * 1024 * 1024
DENIED_PARTS = {'outputs', 'evidence', 'logs', 'downloads', 'files', 'seed',
                '.git', '.xcodebuildmcp', 'node_modules', '.build',
                'deriveddata', '__pycache__', '.scratch', 'site-packages'}
DENIED_SUFFIXES = {'.sqlite', '.sqlite3', '.db', '.csv', '.xlsx', '.xls',
                   '.pdf', '.mp4', '.mov', '.mobileprovision', '.p12', '.pem'}


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':'), allow_nan=False).encode('utf-8')


def check_path(path, profile='production'):
    if not isinstance(path, str) or not path or len(path) > 1024:
        raise ContractError('unsafe_input_path')
    if '\\' in path or any(ord(c) < 32 or ord(c) == 127 for c in path):
        raise ContractError('unsafe_input_path')
    pure = PurePosixPath(path)
    if pure.is_absolute() or str(pure) != path or any(p in {'', '.', '..'} for p in path.split('/')):
        raise ContractError('unsafe_input_path')
    parts = [p.lower() for p in pure.parts]
    if any(p in DENIED_PARTS or 'qarunner' in p or p.startswith('.env') for p in parts):
        raise ContractError('excluded_input_path')
    if pure.suffix.lower() in DENIED_SUFFIXES:
        raise ContractError('excluded_input_path')
    if parts[0] == 'config' and path != 'config/release-version.json':
        raise ContractError('private_config_excluded')
    dev = path.startswith('tests/') or path.startswith('native/PaymentImageCore/Tests/') or 'FamilyReviewUITests' in pure.parts or path.startswith('schemas/release/fixtures/') or path.startswith('native/PaymentImageCore/Sources/VisionProbe/')
    if profile == 'production' and dev:
        raise ContractError('dev_input_in_production')
    if profile == 'dev-tests' and not dev:
        raise ContractError('invalid_dev_input')
    return path


class GitSource:
    def __init__(self, repo, commit='HEAD'):
        self.repo = Path(repo)
        if not isinstance(commit, str) or not re.fullmatch(r'[A-Za-z0-9_./-]+', commit) or commit.startswith('-'):
            raise ContractError('invalid_commit')
        self.commit = self.git('rev-parse', '--verify', '--end-of-options', commit + '^{commit}').decode().strip()
        self.tree = self.git('rev-parse', self.commit + '^{tree}').decode().strip()
        self.entries = {}
        for record in self.git('ls-tree', '-r', '-z', self.commit).split(b'\0'):
            if not record:
                continue
            header, name = record.split(b'\t', 1)
            mode, kind, oid = header.decode('ascii').split()
            try:
                path = name.decode('utf-8')
            except UnicodeDecodeError:
                # Unselected unrelated private paths cannot be surfaced.
                continue
            self.entries[path] = (mode, kind, oid)

    def git(self, *args):
        try:
            result = subprocess.run(['git', '-C', str(self.repo), *args],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    timeout=20, check=True)
        except (subprocess.SubprocessError, OSError):
            raise ContractError('git_read_failed') from None
        return result.stdout

    def dirty(self):
        return bool(self.git('status', '--porcelain=v1', '-z', '--untracked-files=all'))

    def metadata(self, path):
        check_path(path)
        mode, kind, oid = self.entry(path)
        size = int(self.git('cat-file', '-s', oid))
        if size > METADATA_LIMIT:
            raise ContractError('metadata_too_large')
        try:
            def pairs(items):
                value = {}
                for key, item in items:
                    if key in value:
                        raise ContractError('duplicate_json_metadata')
                    value[key] = item
                return value
            def constant(value):
                raise ContractError('nonfinite_json_metadata')
            return json.loads(self.git('cat-file', 'blob', oid), object_pairs_hook=pairs, parse_constant=constant)
        except (ValueError, UnicodeError):
            raise ContractError('invalid_json_metadata') from None

    def entry(self, path):
        if path not in self.entries:
            raise ContractError('missing_committed_input:' + path)
        entry = self.entries[path]
        if entry[0] not in {'100644', '100755'} or entry[1] != 'blob':
            raise ContractError('non_regular_input:' + path)
        return entry

    @contextmanager
    def blobs(self):
        # One process for every source blob. A request is sent only after the
        # previous blob is consumed, so stdin/stdout pipes cannot deadlock.
        process = subprocess.Popen(['git', '-C', str(self.repo), 'cat-file', '--batch'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
        try:
            yield process
        finally:
            process.stdin.close()
            process.stdout.close()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    def stream(self, process, path, consume):
        mode, kind, oid = self.entry(path)
        process.stdin.write((oid + '\n').encode('ascii'))
        process.stdin.flush()
        header = process.stdout.readline().decode('ascii').strip().split()
        if len(header) != 3 or header[0] != oid or header[1] != 'blob':
            raise ContractError('git_blob_read_failed')
        size = int(header[2])
        digest = hashlib.sha256()

        class Reader:
            remaining = size
            def read(self, length=-1):
                length = min(CHUNK_SIZE if length < 0 else length, self.remaining)
                if not length:
                    return b''
                data = process.stdout.read(length)
                if not data:
                    raise ContractError('git_blob_truncated')
                self.remaining -= len(data)
                digest.update(data)
                return data

        reader = Reader()
        consume(reader, size, mode)
        if reader.remaining or process.stdout.read(1) != b'\n':
            raise ContractError('git_blob_not_consumed')
        return {'path': path, 'git_blob': oid, 'sha256': digest.hexdigest(),
                'size': size, 'mode': mode}


def load_inputs(source, profile='production'):
    if profile not in {'production', 'dev-tests'}:
        raise ContractError('invalid_source_profile')
    allowlist = source.metadata('release/source-allowlist.json')
    validate(allowlist, source.metadata('release/source-allowlist.schema.json'))
    # Independently enforce contract structure even if a schema is weakened.
    if allowlist.get('version_config') != 'config/release-version.json':
        raise ContractError('invalid_source_contract')
    paths = allowlist['profiles'][profile]
    if not isinstance(paths, list) or not paths or len(paths) != len(set(paths)):
        raise ContractError('invalid_source_allowlist')
    for path in paths:
        check_path(path, profile)
        source.entry(path)
    version = source.metadata('config/release-version.json')
    try:
        validate_contract('release-version', version,
                          schema_loader=lambda name: source.metadata('schemas/release/' + name))
    except SharedContractError:
        raise ContractError('invalid_version_config') from None
    if not {'app_version', 'build_number', 'macos_minimum', 'ios_minimum'} <= set(version):
        raise ContractError('invalid_version_config')
    if profile == 'production':
        for default in allowlist['defaults']:
            if default['path'] not in paths or default['schema'] not in paths:
                raise ContractError('default_not_allowlisted')
            if not default['path'].startswith('release/') or not default['schema'].startswith('release/'):
                raise ContractError('invalid_default_resource')
            validate(source.metadata(default['path']), source.metadata(default['schema']))
    return sorted(paths), version, allowlist
