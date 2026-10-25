"""ios:first-install: preflight an artifact, explicitly install an absent QA ID.

No build, uninstall, container read, update, launch or production installation.
An asynchronous installation is resumed only with --verify-only.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.ios_artifact import (QA_BUNDLE, DistributionGate, PreflightError,
    artifact_digest, controlled_environment, first_install_preflight, inspect_device, installed_app,
    json_response, run)


def write_receipt(path, value):
    descriptor, temporary = tempfile.mkstemp(prefix='.receipt-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False, sort_keys=True, indent=2)
            stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def installation_gate(device, bundle_id):
    folder = Path(tempfile.gettempdir()).resolve() / ('banking-ios-install-' + str(os.getuid()))
    folder.mkdir(mode=0o700, exist_ok=True)
    if folder.is_symlink() or folder.stat().st_uid != os.getuid():
        raise PreflightError('Installation gate directory is unsafe')
    key = hashlib.sha256(json.dumps([device, bundle_id], separators=(',', ':')).encode()).hexdigest()
    descriptor = os.open(folder / (key + '.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise PreflightError('Another installation is still active for this device/bundle') from error
        yield descriptor
    finally:
        # A pending child inherits the open file description and retains its
        # lock. Explicit LOCK_UN here would incorrectly unlock that child.
        os.close(descriptor)


def verify_installation(evidence, *, runner=run):
    evidence = Path(evidence).resolve()
    receipt_path = evidence / 'first-install-receipt.json'
    receipt = json.loads(receipt_path.read_text())
    if receipt.get('status') not in {'installing', 'installed-unverified-welcome'} or receipt.get('kind') != 'ios-first-install':
        raise PreflightError('Verification requires an original first-install receipt')
    if receipt['artifact']['bundle_id'] != QA_BUNDLE or receipt.get('installation_requested') is not True:
        raise DistributionGate('Receipt is not an explicitly requested QA installation')
    output = evidence / 'install.json'
    if not output.is_file() or not output.stat().st_size:
        return {**receipt, 'status': 'installing', 'next_step': 'Rerun --verify-only; do not reinstall'}
    try:
        raw = json.loads(output.read_text())
    except json.JSONDecodeError:
        return {**receipt, 'status': 'installing', 'next_step': 'Installer JSON is not complete; rerun --verify-only'}
    response = json_response(json.dumps(raw))
    data = response.get('data', {})
    artifact = data.get('artifacts', {})
    if (data.get('summary', {}).get('status') != 'SUCCEEDED' or
            artifact.get('deviceId') != receipt['device']['device_id'] or
            artifact.get('appPath') != receipt['app_path']):
        raise PreflightError('Installer success/request identity cannot be verified')
    current = inspect_device(receipt['device']['device_id'], runner=runner)
    if current['udid'] != receipt['device']['udid']:
        raise PreflightError('Verification device identity differs from installation receipt')
    installed = installed_app(current['device_id'], receipt['artifact']['bundle_id'], runner=runner)
    if installed is None or (str(installed.get('bundleVersion')), installed.get('version')) != (receipt['artifact']['build'], receipt['artifact']['version']):
        raise PreflightError('Installed version/build does not match the original artifact receipt')
    result = {**receipt, 'status': 'installed-unverified-welcome', 'installed_version_verified': True,
        'welcome_verified': False, 'distribution_ready': False,
        'next_step': 'Verify the empty welcome page on the physical device; channel acceptance remains separate'}
    write_receipt(receipt_path, result)
    return result


def first_install(app, device, evidence, *, bundle_id, team, version, build,
                  install_qa=False, runner=run, launcher=subprocess.Popen):
    app, evidence = Path(app).absolute(), Path(evidence).resolve()
    if bundle_id != QA_BUNDLE:
        raise DistributionGate('This engineering entry accepts only the explicit ReleaseQA bundle ID; production requires its selected distribution channel')
    # Same device/bundle is serialized, including a CLI process that outlives
    # the bounded wait. No overwrite flag exists.
    with installation_gate(device, bundle_id) as gate_fd:
        receipt = first_install_preflight(app, device, bundle_id=bundle_id, team=team,
            version=version, build=build, runner=runner)
        evidence.mkdir(parents=True, exist_ok=False)
        receipt.update(kind='ios-first-install', app_path=str(app), evidence=str(evidence),
                       installation_requested=install_qa)
        path = evidence / 'first-install-receipt.json'
        write_receipt(path, receipt)
        if not install_qa:
            return receipt
        # Close the preflight-to-install window without trusting an earlier
        # app inventory or mutable artifact path.
        if installed_app(device, bundle_id, runner=runner) is not None:
            raise PreflightError('App appeared after preflight; first install aborted, use update')
        if artifact_digest(app) != receipt['artifact']['artifact_sha256']:
            raise PreflightError('Artifact bytes changed after preflight')
        receipt['status'] = 'installing'
        write_receipt(path, receipt)
        with (evidence / 'install.json').open('w') as output, (evidence / 'install-stderr.log').open('w') as errors:
            process = launcher(['xcodebuildmcp', 'device', 'install', '--device-id', device,
                '--app-path', str(app), '--output', 'json'], stdin=subprocess.DEVNULL,
                stdout=output, stderr=errors, start_new_session=True, pass_fds=(gate_fd,),
                env=controlled_environment())
        receipt['installer_pid'] = process.pid
        write_receipt(path, receipt)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            return {**receipt, 'next_step': 'Rerun --verify-only; do not reinstall'}
        if process.returncode:
            raise PreflightError('Installation failed; evidence retained, no automatic retry or uninstall')
        return verify_installation(evidence, runner=runner)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--device')
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--bundle-id')
    parser.add_argument('--team')
    parser.add_argument('--version')
    parser.add_argument('--build')
    parser.add_argument('--install-qa', action='store_true', help='Explicitly install the absent ReleaseQA ID after preflight')
    parser.add_argument('--verify-only', action='store_true', help='Resume the existing receipt; never install again')
    args = parser.parse_args()
    try:
        if args.verify_only:
            if args.install_qa or any((args.app, args.device, args.bundle_id, args.team, args.version, args.build)):
                parser.error('--verify-only consumes only --evidence from the original request')
            result = verify_installation(args.evidence)
        else:
            if not all((args.app, args.device, args.bundle_id, args.team, args.version, args.build)):
                parser.error('preflight requires --app/--device/--bundle-id/--team/--version/--build')
            result = first_install(args.app, args.device, args.evidence, bundle_id=args.bundle_id,
                team=args.team, version=args.version, build=args.build, install_qa=args.install_qa)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({'status': 'blocked', 'error': str(error), 'distribution_ready': False}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
