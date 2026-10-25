"""Preserving internal iOS update; no uninstall, relaunch or data rollback.

The pre-existing devicectl commands transfer containers because XcodeBuildMCP
has no container-backup tool. --verify-only never starts an installer.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import shutil
import subprocess
import uuid
from pathlib import Path

if __package__ in (None, ''):
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.installation_inventory import (BUNDLE_ID, InstallationError, compare, compatibility,
    excluded, inspect, relative, safe_tree, MAX_FILES, MAX_BYTES, POLICY)
from scripts.release_contracts import canonical_json, digest_bytes, digest_file, parse_json
from scripts.workspace_state import _safe, _files
from scripts.tool_locations import system_search_path


def run_json(command, output):
    result = subprocess.run(command, capture_output=True, text=True, timeout=20)
    output.write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    response = json.loads(result.stdout)
    if response.get('didError') or response.get('isError'):
        raise RuntimeError(response.get('error') or result.stdout)
    return response


class DeviceContainer:
    """Bounded, fail-closed wrapper of existing listing/copy commands."""
    def __init__(self, device, evidence, devicectl):
        self.device, self.evidence, self.devicectl = device, evidence, devicectl
        self.counter = 0
        self.run_id = uuid.uuid4().hex

    def command(self, arguments, name):
        self.counter += 1
        path = self.evidence / (name + '-' + self.run_id + '-' + str(self.counter) + '.json')
        result = subprocess.run([self.devicectl, 'device', *arguments, '--device', self.device,
            '--timeout', '15', '--quiet', '--json-output', str(path)],
            capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError(result.stderr or result.stdout)
        response = json.loads(path.read_text())
        if response.get('info', {}).get('outcome') != 'success':
            raise RuntimeError('Device inspection/backup failed: ' + name)
        return response['result']

    def listing(self):
        queue, members = [''], {}
        while queue:
            directory = queue.pop(0)
            arguments = ['info', 'files', '--domain-type', 'appDataContainer',
                         '--domain-identifier', BUNDLE_ID, '--no-recurse']
            if directory:
                arguments += ['--subdirectory', directory]
            listing = self.command(arguments, 'container-list')
            if not isinstance(listing.get('files'), list):
                raise InstallationError('container enumeration capability unavailable')
            for item in listing['files']:
                name = item.get('name')
                if not isinstance(name, str) or '/' in name or '\\' in name:
                    raise InstallationError('unsafe device container member')
                path = relative(directory + '/' + name if directory else name)
                resources = item.get('resources', {})
                if resources.get('isSymbolicLink') is not False:
                    raise InstallationError('device listing lacks a verified non-symlink member')
                if excluded(path):
                    continue
                if path in members or len(members) >= MAX_FILES:
                    raise InstallationError('duplicate or oversized device inventory')
                if type(resources.get('isDirectory')) is not bool:
                    raise InstallationError('device listing lacks directory type metadata')
                if resources.get('isDirectory') is True:
                    queue.append(path)
                elif resources.get('isRegularFile') is not True:
                    raise InstallationError('device listing lacks regular-file metadata')
                members[path] = resources
        return dict(sorted(members.items()))

    def backup(self, target):
        if target.exists():
            raise InstallationError('container backup destination already exists')
        first = self.listing()
        required = 0
        for resources in first.values():
            if resources['isDirectory']:
                continue
            length = resources.get('fileSize')
            if type(length) is not int or length < 0:
                raise InstallationError('device listing lacks a bounded file size')
            required += length
        if required > MAX_BYTES or shutil.disk_usage(target.parent).free < required + 64 * 1024**2:
            raise InstallationError('insufficient space or oversized container backup')
        target.mkdir(mode=0o700)
        for path, resources in first.items():
            destination = target / relative(path)
            if resources['isDirectory']:
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                self.command(['copy', 'from', '--domain-type', 'appDataContainer',
                    '--domain-identifier', BUNDLE_ID, '--source', path,
                    '--destination', str(destination)], 'container-copy')
                if not destination.is_file() or destination.is_symlink():
                    raise InstallationError('container copy returned no regular file')
                if destination.stat().st_size != resources['fileSize']:
                    raise InstallationError('container copy is incomplete or changed size')
        _, copied_files, copied_directories = safe_tree(target)
        if set(copied_files) != {path for path, resource in first.items() if not resource['isDirectory']} or set(copied_directories) != {path for path, resource in first.items() if resource['isDirectory']}:
            raise InstallationError('copied container does not match enumerated closure')
        if first != self.listing():
            raise InstallationError('container changed during backup; app must remain stopped')
        return first


def verify_install_result(path, *, device=None, app_path=None):
    if not path.is_file() or not path.stat().st_size:
        raise InstallationError('installer has not returned a result; wait and use --verify-only')
    try:
        result = parse_json(path.read_bytes())
    except ValueError as error:
        raise InstallationError('installer result is incomplete; wait and use --verify-only') from error
    def responses(value):
        if isinstance(value, dict):
            yield value
            for child in value.values():
                yield from responses(child)
        elif isinstance(value, list):
            for child in value:
                yield from responses(child)
    nodes = list(responses(result))
    if not isinstance(result, dict) or any(node.get('didError') or node.get('isError') or node.get('success') is False for node in nodes):
        raise InstallationError('installer failed; original backup retained')
    canonical = [node for node in nodes if isinstance(node.get('data'), dict)
                 and isinstance(node['data'].get('summary'), dict)]
    if canonical:
        for node in canonical:
            data = node['data']; artifact = data.get('artifacts', {})
            if (node.get('didError') is not False or data['summary'].get('status') != 'SUCCEEDED'
                    or (device is not None and artifact.get('deviceId') != device)
                    or (app_path is not None and artifact.get('appPath') != str(app_path))):
                raise InstallationError('installer completion/request identity differs')
        return result
    if device is not None or app_path is not None:
        raise InstallationError('installer lacks canonical request-bound completion evidence')
    if not any(node.get('success') is True or
               (node.get('isError') is False and node.get('content')) for node in nodes):
        raise InstallationError('installer response lacks completion evidence')
    return result


def update(device, app, evidence, data_root='Library/Application Support/FamilyReview', verify_only=False,
           *, backend=None):
    data_root = relative(data_root)
    app, evidence = _safe(Path(app)), _safe(Path(evidence))
    info_bytes = (app / 'Info.plist').read_bytes()
    info = plistlib.loads(info_bytes)
    if info.get('CFBundleIdentifier') != BUNDLE_ID:
        raise InstallationError('update must retain the existing production bundle ID')
    candidate_policy = parse_json(POLICY.read_bytes())
    if info.get('CFBundleShortVersionString') != candidate_policy['app_version'] or str(info.get('CFBundleVersion')) != str(candidate_policy['build_number']):
        raise InstallationError('candidate app/build has no matching compatibility contract')
    operation = {'device': device, 'bundle_id': BUNDLE_ID, 'data_root': data_root,
                 'candidate_info_hash': digest_bytes(info_bytes),
                 'candidate_app_path': str(app),
                 'candidate_tree_hash': digest_bytes(canonical_json({name: digest_file(path) for name, path in _files(app)})),
                 'candidate_build': info['CFBundleVersion'], 'candidate_version': info['CFBundleShortVersionString'],
                 'preserves_user_bytes': True}
    if verify_only:
        previous = parse_json((evidence / 'operation.json').read_bytes())
        if previous != operation:
            raise InstallationError('verify-only must retain the original device/candidate/backup operation')
        saved = parse_json((evidence / 'before-inventory.json').read_bytes())
        if inspect(evidence / 'before', data_root=data_root) != saved:
            raise InstallationError('original update backup has changed')
        verify_install_result(evidence / 'install.json', device=device, app_path=app)
    else:
        evidence.mkdir(parents=True, exist_ok=False)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)],
                       check=True, capture_output=True, timeout=20,
                       env={'PATH': system_search_path()})
        (evidence / 'operation.json').write_bytes(canonical_json(operation))
    if backend is None:
        developer = subprocess.run(['xcode-select', '-p'], check=True, capture_output=True,
                                   text=True, timeout=5).stdout.strip()
        backend = DeviceContainer(device, evidence, str(Path(developer) / 'usr/bin/devicectl'))
    if not verify_only:
        processes = backend.command(['info', 'processes'], 'processes-before')
        for process in processes['runningProcesses']:
            if process.get('executable', '').endswith('/FamilyReview.app/FamilyReview'):
                run_json(['xcodebuildmcp', 'device', 'stop', '--device-id', device,
                    '--process-id', str(process['processIdentifier']), '--output', 'json'], evidence / 'stop.json')
        backend.backup(evidence / 'before')
        before = inspect(evidence / 'before', data_root=data_root)
        policy = compatibility()
        for minimum_writer in before['minimum_writer_versions']:
            decision = compatibility(minimum_writer=minimum_writer)
            if not decision['writable']:
                policy = decision
        if not policy['writable']:
            raise InstallationError('candidate cannot write existing schema; backup retained; installation blocked')
        (evidence / 'before-inventory.json').write_bytes(canonical_json(before))
        (evidence / 'compatibility.json').write_bytes(canonical_json(policy))
        with (evidence / 'install.json').open('w') as output, (evidence / 'install-stderr.log').open('w') as errors:
            installer = subprocess.Popen(['xcodebuildmcp', 'device', 'install', '--device-id', device,
                '--app-path', str(app), '--output', 'json'], stdin=subprocess.DEVNULL,
                stdout=output, stderr=errors, start_new_session=True)
        (evidence / 'install.pid').write_text(str(installer.pid))
        try:
            installer.wait(timeout=15)
        except subprocess.TimeoutExpired:
            result = {'status': 'installing', 'evidence': str(evidence),
                      'next_step': 'wait for install.json, then --verify-only; never reinstall'}
            print(json.dumps(result), flush=True)
            return result
        verify_install_result(evidence / 'install.json', device=device, app_path=app)
    attempt = 1
    after = evidence / 'after'
    while after.exists():
        attempt += 1
        after = evidence / ('after-' + str(attempt))
    backend.backup(after)
    result = compare(evidence / 'before', after, data_root=data_root)
    result.update(device=device, candidate_build=info['CFBundleVersion'], app_left_stopped=True,
                  first_run_qualified=False,
                  pending_first_run_gates=['native-schema-and-task-journal-health'])
    (evidence / 'result.json').write_bytes(canonical_json(result))
    print(canonical_json(result).decode(), flush=True)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--data-root', default='Library/Application Support/FamilyReview')
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    update(args.device, args.app, args.evidence, args.data_root, args.verify_only)
