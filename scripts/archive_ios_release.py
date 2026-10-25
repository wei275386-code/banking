"""Preflight, archive and export a local production iOS release; never upload/install."""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from contextlib import contextmanager
from pathlib import Path, PurePosixPath

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.build_ios_app import artifact_project_spec
from scripts.generate_release_inputs import generate
from scripts.install_ios_app import write_receipt
from scripts.ios_artifact import PreflightError, _regular, artifact_digest, json_response, sha256
from scripts.ios_distribution import (DistributionConfig, export_options,
    controlled_environment, inspect_distribution_app, preflight, run,
    source_proof, toolchain_proof, verify_source_snapshot)

SCHEME = 'FamilyReviewDistribution'
FALLBACK = 'XcodeBuildMCP has no export action; canonical selected Xcode -exportArchive performs local manual export only'


def stage_inputs(source, project, version, *, info=False):
    source, project = Path(source), Path(project)
    names = ['release-version.json', 'Bootstrap/bootstrap.json', 'Bootstrap/release-version.json']
    bootstrap = json.loads((source / names[1]).read_text())
    if (bootstrap.get('kind') != 'empty' or bootstrap.get('workspace_created') is not False):
        raise PreflightError('Production generated Bootstrap is not empty')
    if any(json.loads((source / name).read_text()) != version for name in (names[0], names[2])):
        raise PreflightError('Production generated version differs from controlled inputs')
    if info:
        payload = plistlib.loads((source / 'Info.plist').read_bytes())
        if (payload.get('CFBundleIdentifier') not in ('local.familyreview.FamilyReview', '$(PRODUCT_BUNDLE_IDENTIFIER)') or
                payload.get('CFBundleShortVersionString') != version['app_version'] or
                str(payload.get('CFBundleVersion')) != str(version['build_number'])):
            raise PreflightError('Production generated Info.plist differs from controlled inputs')
        names.append('Info.plist')
    hashes = {}
    for name in names:
        digest = sha256(source / name)
        destination = project / 'Generated' / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, destination)
        if sha256(destination) != digest:
            raise PreflightError('Generated input changed during staging')
        hashes['Project/Generated/' + name] = digest
    return hashes


def archive_request(work, config, version):
    return {'projectPath': str(work / 'Project/FamilyReview.xcodeproj'), 'scheme': SCHEME,
            'configuration': 'Release', 'platform': 'iOS', 'preferXcodebuild': True,
            'derivedDataPath': str(work / 'DerivedData'),
            'extraArgs': ['archive', '-archivePath', str(work / 'FamilyReview.xcarchive'),
                'CODE_SIGN_STYLE=Manual', 'DEVELOPMENT_TEAM=' + config.team,
                'CODE_SIGN_IDENTITY=' + config.certificate_sha1,
                'PROVISIONING_PROFILE_SPECIFIER=' + config.profile_uuid,
                'PRODUCT_BUNDLE_IDENTIFIER=' + config.bundle_id,
                'MARKETING_VERSION=' + version['app_version'],
                'CURRENT_PROJECT_VERSION=' + str(version['build_number']),
                'SWIFT_ACTIVE_COMPILATION_CONDITIONS=', 'SKIP_INSTALL=NO']}


def spawn(work, phase, command, *, launcher=subprocess.Popen):
    plan = {'phase': phase, 'command': command}
    path = work / (phase + '-plan.json')
    write_receipt(path, plan)
    digest = sha256(path)
    receipt_path = work / 'distribution-receipt.json'
    receipt = json.loads(receipt_path.read_text())
    receipt['plan_sha256'] = digest
    write_receipt(receipt_path, receipt)
    worker = [sys.executable, '-I', '-B', str(work / 'Source/scripts/archive_ios_release.py'), '--worker', str(path)]
    with (work / (phase + '-worker.log')).open('wb') as log:
        process = launcher(worker, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
                           cwd=work / 'Source', env=controlled_environment())
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        pass
    return process.pid, digest


def worker(path):
    """Detached local operation, with atomic completion instead of exit-code inference."""
    path = Path(path).resolve()
    plan = json.loads(path.read_text())
    phase, command = plan['phase'], plan['command']
    if (phase not in {'archive', 'export'} or not isinstance(command, list) or
            any(not isinstance(arg, str) for arg in command) or
            any('allowProvisioning' in arg or arg == 'upload' or 'authenticationKey' in arg for arg in command)):
        raise PreflightError('Worker refuses remote/account/provisioning operations')
    if phase == 'archive':
        if command[:3] != ['xcodebuildmcp', 'device', 'build']:
            raise PreflightError('Archive worker requires the discovered XcodeBuildMCP build action')
        request = json.loads(command[command.index('--json') + 1])
        receipt = json.loads((path.parent / 'distribution-receipt.json').read_text())
        config = DistributionConfig.decode(receipt['preflight']['config'])
        if request != archive_request(path.parent, config, receipt['preflight']['version']):
            raise PreflightError('Archive plan differs from the bound manual production request')
    else:
        receipt = json.loads((path.parent / 'distribution-receipt.json').read_text())
        if command != export_command(path.parent, receipt):
            raise PreflightError('Export plan differs from the bound local export request')
        config = DistributionConfig.decode(receipt['preflight']['config'])
        options = plistlib.loads((path.parent / 'ExportOptions.plist').read_bytes())
        if options != export_options(config):
            raise PreflightError('Export options differ from manual local export')
        if sha256(path.parent / 'ExportOptions.plist') != receipt['export_options_sha256']:
            raise PreflightError('Export options changed before the worker started')
    if sha256(path) != receipt['plan_sha256']:
        raise PreflightError('Worker plan changed before execution')
    for relative, checksum in receipt['generated_inputs'].items():
        if sha256(path.parent / relative) != checksum:
            raise PreflightError('Generated input changed before the worker started')
    if phase == 'export' and artifact_digest(path.parent / 'FamilyReview.xcarchive') != receipt['archive_sha256']:
        raise PreflightError('Archive changed before export worker started')
    checks = preflight(receipt['root'], config,
        device=(receipt['preflight']['device'] or {}).get('device_id'))
    if any(checks[key] != receipt['preflight'][key] for key in ('version', 'config', 'signing', 'export_tool', 'source', 'toolchain')):
        raise PreflightError('Signing inputs changed before the worker started')
    verify_source_snapshot(path.parent / 'Source', receipt['preflight']['source'])
    digest = sha256(path)
    with (path.parent / (phase + '-stdout.log')).open('wb') as output, (path.parent / (phase + '-stderr.log')).open('wb') as errors:
        process = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
                                 cwd=path.parent / 'Source', env=controlled_environment())
    if process.returncode == 0:
        after = preflight(receipt['root'], config,
            device=(receipt['preflight']['device'] or {}).get('device_id'))
        if any(after[key] != receipt['preflight'][key] for key in ('version', 'config', 'signing', 'export_tool', 'source', 'toolchain')):
            raise PreflightError('Source/signing/toolchain changed during the local operation')
        verify_source_snapshot(path.parent / 'Source', receipt['preflight']['source'])
    write_receipt(path.parent / (phase + '-result.json'), {'phase': phase,
                  'plan_sha256': digest, 'returncode': process.returncode})


def start_archive(root, work, config, *, device=None, runner=run,
                  launcher=subprocess.Popen, generator=generate):
    root, work = Path(root).resolve(), Path(work).resolve()
    checks = preflight(root, config, device=device, runner=runner)
    if work.exists():
        raise PreflightError('Use a new work directory; existing operations resume with verify')
    # Preflight is complete before generation, work creation or signing.
    work.mkdir(parents=True)
    snapshot = work / 'Source'; snapshot.mkdir()
    for name, checksum in checks['source']['source_files'].items():
        destination = snapshot / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, destination)
        if sha256(destination) != checksum:
            raise PreflightError('Committed source changed during snapshot creation')
    if source_proof(root) != checks['source']:
        raise PreflightError('Source commit changed during snapshot creation')
    verify_source_snapshot(snapshot, checks['source'])
    generated = generator(snapshot, team=config.team, qa=False)
    text = Path(generated['project_spec']).read_text()
    if 'FAMILY_REVIEW_QA' in text or '.ReleaseQA' in text or '\n      - path: Seed\n' in text:
        raise PreflightError('Production generated project contains QA flags or development Seed')
    project = work / 'Project'; project.mkdir()
    spec = project / 'project.distribution.yml'
    artifact_project_spec(generated['project_spec'], spec)
    spec.write_text(spec.read_text().replace('FamilyReviewArtifactQA:', SCHEME + ':'))
    source = Path(generated['project_spec']).parent / 'Generated'
    stage_inputs(source, project, checks['version'])
    runner(['xcodegen', 'generate', '--spec', str(spec), '--project', str(project),
            '--project-root', str(snapshot / 'native/FamilyReviewIOS'), '--no-env'])
    inputs = stage_inputs(source, project, checks['version'], info=True)
    inputs['Project/project.distribution.yml'] = sha256(spec)
    inputs['Project/FamilyReview.xcodeproj/project.pbxproj'] = sha256(project / 'FamilyReview.xcodeproj/project.pbxproj')
    request = archive_request(work, config, checks['version'])
    command = ['xcodebuildmcp', 'device', 'build', '--json', json.dumps(request), '--output', 'json']
    receipt = {'kind': 'ios-distribution', 'status': 'archiving',
               'root': str(root), 'preflight': checks, 'generated_inputs': inputs,
               'archive_request': request, 'installed': False, 'uploaded': False,
               'distribution_ready': False, 'export_fallback': FALLBACK}
    write_receipt(work / 'distribution-receipt.json', receipt)
    pid, digest = spawn(work, 'archive', command, launcher=launcher)
    receipt.update(worker_pid=pid, plan_sha256=digest)
    write_receipt(work / 'distribution-receipt.json', receipt)
    return finish(work, runner=runner)


def export_command(work, receipt):
    return [receipt['preflight']['export_tool'], '-exportArchive', '-archivePath',
            str(work / 'FamilyReview.xcarchive'), '-exportPath', str(work / 'Export'),
            '-exportOptionsPlist', str(work / 'ExportOptions.plist')]


@contextmanager
def exclusive_work(work):
    descriptor = os.open(work / 'distribution.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise PreflightError('Another process is verifying or exporting this work receipt') from error
        yield
    finally:
        os.close(descriptor)


def export_archive(work, *, runner=run, launcher=subprocess.Popen):
    work = Path(work).resolve()
    with exclusive_work(work):
        return _export_archive(work, runner=runner, launcher=launcher)


def _export_archive(work, *, runner=run, launcher=subprocess.Popen):
    receipt = _finish(work, runner=runner)
    if receipt['status'] == 'export-ready':
        return receipt
    if receipt['status'] != 'archive-ready':
        raise PreflightError('Export requires a successfully verified archive-ready receipt')
    config = DistributionConfig.decode(receipt['preflight']['config'])
    checks = preflight(receipt['root'], config, device=(receipt['preflight']['device'] or {}).get('device_id'), runner=runner)
    if any(checks[key] != receipt['preflight'][key] for key in ('version', 'config', 'signing', 'export_tool', 'source', 'toolchain')):
        raise PreflightError('Distribution inputs changed since archive preflight')
    if (work / 'Export').exists() or (work / 'ExportOptions.plist').exists():
        raise PreflightError('Export output already exists without a completed export receipt')
    options = work / 'ExportOptions.plist'
    options.write_bytes(plistlib.dumps(export_options(config)))
    receipt.update(status='exporting', export_options_sha256=sha256(options))
    write_receipt(work / 'distribution-receipt.json', receipt)
    pid, digest = spawn(work, 'export', export_command(work, receipt), launcher=launcher)
    receipt.update(worker_pid=pid, plan_sha256=digest)
    write_receipt(work / 'distribution-receipt.json', receipt)
    return _finish(work, runner=runner)


def inspect_ipa(path, config, version, *, runner=run):
    with zipfile.ZipFile(_regular(path)) as archive, tempfile.TemporaryDirectory(prefix='ios-export-inspect-') as temporary:
        temporary = str(Path(temporary).resolve())
        names = set()
        size = 0
        for member in archive.infolist():
            relative = PurePosixPath(member.filename)
            size += member.file_size
            if (member.filename in names or relative.is_absolute() or '..' in relative.parts or
                    '\\' in member.filename or stat.S_ISLNK(member.external_attr >> 16) or size > 2 * 1024**3):
                raise PreflightError('IPA contains unsafe/duplicate/oversized members')
            names.add(member.filename)
        archive.extractall(temporary)
        apps = list((Path(temporary) / 'Payload').glob('*.app'))
        if len(apps) != 1:
            raise PreflightError('Export must contain exactly one production application')
        return inspect_distribution_app(apps[0], config, version, runner=runner)


def finish(work, *, runner=run):
    work = Path(work).resolve()
    with exclusive_work(work):
        return _finish(work, runner=runner)


def _finish(work, *, runner=run):
    path = work / 'distribution-receipt.json'
    receipt = json.loads(path.read_text())
    if receipt.get('kind') != 'ios-distribution' or receipt.get('status') not in {
            'archiving', 'archive-ready', 'exporting', 'export-ready'}:
        raise PreflightError('Resume requires the original distribution receipt')
    if source_proof(receipt['root']) != receipt['preflight']['source']:
        raise PreflightError('Selected clean source commit changed after preflight')
    verify_source_snapshot(work / 'Source', receipt['preflight']['source'])
    if toolchain_proof(work / 'Source', runner=runner) != receipt['preflight']['toolchain']:
        raise PreflightError('Locked toolchain/SDK/runtime changed after preflight')
    for relative, digest in receipt['generated_inputs'].items():
        if sha256(work / relative) != digest:
            raise PreflightError('Bound generated project input changed')
    archive = work / 'FamilyReview.xcarchive'
    if receipt['status'] in {'archive-ready', 'exporting', 'export-ready'}:
        if artifact_digest(archive) != receipt['archive_sha256']:
            raise PreflightError('Bound archive changed after verification')
    if receipt['status'] == 'export-ready':
        if sha256(Path(receipt['ipa_path'])) != receipt['ipa_sha256']:
            raise PreflightError('Exported IPA differs from its receipt')
        return receipt
    if receipt['status'] == 'archive-ready':
        return receipt
    phase = 'archive' if receipt['status'] == 'archiving' else 'export'
    if sha256(work / (phase + '-plan.json')) != receipt['plan_sha256']:
        raise PreflightError('Operation plan differs from its receipt')
    result_path = work / (phase + '-result.json')
    if not result_path.is_file():
        return {**receipt, 'next_step': 'Rerun verify; the original operation continues without reissuing it'}
    result = json.loads(result_path.read_text())
    if result != {'phase': phase, 'plan_sha256': receipt['plan_sha256'], 'returncode': 0}:
        raise PreflightError('Local ' + phase + ' failed; no installation or remote upload was attempted')
    config = DistributionConfig.decode(receipt['preflight']['config'])
    version = receipt['preflight']['version']
    if phase == 'archive':
        response = json_response((work / 'archive-stdout.log').read_bytes())
        if response.get('data', {}).get('summary', {}).get('status') != 'SUCCEEDED':
            raise PreflightError('Archive CLI did not explicitly succeed')
        actual = response.get('data', {}).get('request', {})
        if any(actual.get(key) != receipt['archive_request'][key] for key in
               ('projectPath', 'scheme', 'configuration', 'derivedDataPath')):
            raise PreflightError('Archive CLI result does not match the isolated request')
        info = plistlib.loads((archive / 'Info.plist').read_bytes())
        application = info.get('ApplicationProperties', {}).get('ApplicationPath')
        if not isinstance(application, str) or not application.startswith('Applications/') or '..' in PurePosixPath(application).parts:
            raise PreflightError('XCArchive has no safe application product')
        app = archive / 'Products' / application
        receipt.update(status='archive-ready', archive_sha256=artifact_digest(archive),
            archive_artifact=inspect_distribution_app(app, config, version, runner=runner),
            next_step='Explicit export produces a local IPA; remote publication remains gated')
    else:
        if sha256(work / 'ExportOptions.plist') != receipt['export_options_sha256']:
            raise PreflightError('Export options changed after preflight')
        packages = list((work / 'Export').glob('*.ipa'))
        if len(packages) != 1:
            raise PreflightError('Successful export must produce exactly one IPA')
        artifact = inspect_ipa(packages[0], config, version, runner=runner)
        receipt.update(status='export-ready', ipa_path=str(packages[0]), ipa_sha256=sha256(packages[0]),
            export_artifact=artifact, next_step='External account/channel acceptance and upload require separate authorization')
    write_receipt(path, receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', nargs='?', choices=['preflight', 'archive', 'export', 'verify'], default='preflight')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--config', type=Path)
    parser.add_argument('--work', type=Path)
    parser.add_argument('--device')
    parser.add_argument('--worker', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        try:
            worker(args.worker)
            return 0
        except (ValueError, OSError, subprocess.SubprocessError):
            path = args.worker.resolve()
            plan = json.loads(path.read_text())
            if plan.get('phase') in {'archive', 'export'}:
                write_receipt(path.parent / (plan['phase'] + '-result.json'), {
                    'phase': plan['phase'], 'plan_sha256': sha256(path), 'returncode': 1,
                    'reason': 'worker-preflight-or-execution-failed'})
            print('Local distribution worker failed; no remote publication attempted', file=sys.stderr)
            return 1
    try:
        if args.action in {'export', 'verify'}:
            if not args.work or args.config or args.device:
                parser.error('export/verify consumes only the original --work receipt')
            result = export_archive(args.work) if args.action == 'export' else finish(args.work)
        else:
            if not args.config or (args.action == 'archive' and not args.work):
                parser.error('preflight requires --config; archive also requires a new --work')
            config = DistributionConfig.decode(json.loads(args.config.read_text()))
            result = (preflight(args.root, config, device=args.device) if args.action == 'preflight' else
                      start_archive(args.root, args.work, config, device=args.device))
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(json.dumps({'status': 'blocked', 'error': str(error), 'installed': False,
                          'uploaded': False, 'distribution_ready': False}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
