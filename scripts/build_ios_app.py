"""Build an isolated QA iPhone artifact without installing or launching it.

Uses controlled version/empty Bootstrap generation and XcodeBuildMCP build-only.
Distribution archive/export/upload remain gated on the selected account/channel.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.generate_release_inputs import generate, load_version
from scripts.install_ios_app import write_receipt
from scripts.ios_artifact import (QA_BUNDLE, DistributionGate, PreflightError,
    artifact_digest, controlled_environment, inspect_artifact, inspect_device, json_response, run,
    sha256, validate_device_artifact)

QA_SWIFT_CONDITIONS = 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) FAMILY_REVIEW_QA'
ARTIFACT_SCHEME = 'FamilyReviewArtifactQA'


def artifact_project_spec(source, destination):
    """Give artifact-only builds a main-App scheme with no test action."""
    text = Path(source).read_text()
    project, separator, schemes = text.partition('\nschemes:\n')
    if not separator or not re.search(r'^  FamilyReview:\s*$', schemes, re.MULTILINE):
        raise PreflightError('Generated project has no expected FamilyReview scheme')
    Path(destination).write_text(project + '\nschemes:\n  ' + ARTIFACT_SCHEME +
        ':\n    build:\n      targets:\n        FamilyReview: all\n    run:\n      config: Release\n')
    return str(destination)


def stage_generated_inputs(source, project, version, *, include_info=False):
    """Close only the public Generated resources referenced by this project.

    XcodeGen's --project output resolves Generated paths against the new project
    directory, while --project-root generates Info.plist in the source directory.
    Stage Bootstrap before generation, then copy the generated Info.plist after.
    Never glob/copy the source Seed or arbitrary stale Generated files.
    """
    source, project = Path(source), Path(project)
    names = ['release-version.json', 'Bootstrap/bootstrap.json', 'Bootstrap/release-version.json']
    bootstrap = json.loads((source / 'Bootstrap/bootstrap.json').read_text())
    if (bootstrap.get('kind') != 'empty' or bootstrap.get('workspace_created') is not False):
        raise PreflightError('Generated Bootstrap is not the controlled empty contract')
    for name in ('release-version.json', 'Bootstrap/release-version.json'):
        if json.loads((source / name).read_text()) != version:
            raise PreflightError('Generated version differs from controlled build inputs')
    if include_info:
        import plistlib
        info = plistlib.loads((source / 'Info.plist').read_bytes())
        if (info.get('CFBundleIdentifier') not in (QA_BUNDLE, '$(PRODUCT_BUNDLE_IDENTIFIER)') or
                (info.get('CFBundleShortVersionString'), str(info.get('CFBundleVersion'))) != (
                version['app_version'], str(version['build_number']))):
            raise PreflightError('Generated Info.plist differs from the QA build identity')
        names.append('Info.plist')
    hashes = {}
    for name in names:
        original = source / name
        checksum = sha256(original)  # Includes regular-file and ancestor checks.
        destination = project / 'Generated' / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, destination)
        if sha256(destination) != checksum:
            raise PreflightError('Generated input changed while staging: ' + name)
        hashes['Generated/' + name] = checksum
    return hashes


def finish_build(work, *, runner=run):
    work = Path(work).resolve()
    receipt_path = work / 'build-receipt.json'
    receipt = json.loads(receipt_path.read_text())
    if receipt.get('kind') != 'ios-qa-build' or receipt.get('channel') != 'development-qa':
        raise PreflightError('Verification requires the original QA build receipt')
    if receipt['status'] == 'artifact-ready':
        if artifact_digest(Path(receipt['app_path'])) != receipt['artifact']['artifact_sha256']:
            raise PreflightError('Published artifact differs from its build receipt')
        return receipt
    if receipt['status'] != 'building':
        raise PreflightError('Build receipt cannot be resumed')
    for relative, checksum in receipt['generated_inputs'].items():
        if sha256(work / 'Project' / relative) != checksum:
            raise PreflightError('Generated project input changed during build: ' + relative)
    output = work / 'build.json'
    if not output.is_file() or not output.stat().st_size:
        return {**receipt, 'next_step': 'Rerun --verify-only; do not start another build'}
    try:
        response = json.loads(output.read_text())
    except json.JSONDecodeError:
        return {**receipt, 'next_step': 'Build JSON is not complete; rerun --verify-only'}
    response = json_response(json.dumps(response))
    data = response.get('data', {})
    request = data.get('request', {})
    expected = json.loads(receipt['build_command'][receipt['build_command'].index('--json') + 1])
    required = ['projectPath', 'derivedDataPath', 'scheme', 'configuration']
    if receipt['build_for_testing']:
        required += ['deviceId', 'buildForTesting']
    if data.get('summary', {}).get('status') != 'SUCCEEDED' or any(
            request.get(key) != expected[key] for key in
            required):
        raise PreflightError('Build success/request identity cannot be verified')
    if not receipt['build_for_testing'] and (request.get('deviceId') or request.get('buildForTesting')):
        raise PreflightError('Artifact-only build unexpectedly included device testing')
    app = work / 'DerivedData/Build/Products/Release-iphoneos/FamilyReview.app'
    version = receipt['version']
    artifact = inspect_artifact(app, bundle_id=QA_BUNDLE, team=receipt['team'],
        version=version['app_version'], build=version['build_number'], runner=runner)
    current = inspect_device(receipt['device']['device_id'], runner=runner)
    if current['udid'] != receipt['device']['udid']:
        raise PreflightError('Build verification device identity changed')
    validate_device_artifact(artifact, current)
    name = 'FamilyReview-' + version['app_version'] + '-' + str(version['build_number']) + '-arm64.ReleaseQA.app'
    destination = work / 'artifacts' / name
    destination.parent.mkdir(exist_ok=True)
    shutil.copytree(app, destination)
    if artifact_digest(destination) != artifact['artifact_sha256'] or artifact_digest(app) != artifact['artifact_sha256']:
        raise PreflightError('Artifact changed while publishing the isolated build output')
    result = {**receipt, 'status': 'artifact-ready', 'app_path': str(destination), 'artifact': artifact,
        'installed': False, 'launched': False, 'distribution_ready': False,
        'next_step': 'Use install_ios_app.py preflight separately; distribution channel remains gated'}
    write_receipt(receipt_path, result)
    return result


def build_qa(root, work, device, team, *, channel='development-qa', build_for_testing=False, runner=run,
             launcher=subprocess.Popen, generator=generate):
    if channel != 'development-qa':
        raise DistributionGate('Archive/export/upload require a configured signing account and selected TestFlight/App Store/Ad Hoc channel')
    root, work = Path(root).resolve(), Path(work).resolve()
    if work.exists():
        raise PreflightError('Use a new isolated build directory; resume the original with --verify-only')
    if not re.fullmatch(r'[A-Z0-9]{10}', team or ''):
        raise PreflightError('Build requires an explicit signing team')
    current = inspect_device(device, runner=runner)
    version = load_version(root)
    # Generation validates the explicit team and supplies an empty Bootstrap.
    # A separate project directory leaves the tracked production project intact.
    generated = generator(root, team=team, qa=True)
    work.mkdir(parents=True, exist_ok=False)
    project_folder = work / 'Project'; project_folder.mkdir()
    generated_folder = Path(generated['project_spec']).parent / 'Generated'
    stage_generated_inputs(generated_folder, project_folder, version)
    spec = (generated['project_spec'] if build_for_testing else artifact_project_spec(
            generated['project_spec'], project_folder / 'project.artifact-qa.yml'))
    runner(['xcodegen', 'generate', '--spec', spec, '--project',
            str(project_folder), '--project-root', str(root / 'native/FamilyReviewIOS'), '--no-env'])
    generated_inputs = stage_generated_inputs(generated_folder, project_folder, version, include_info=True)
    arguments = {'projectPath': str(project_folder / 'FamilyReview.xcodeproj'),
        'scheme': 'FamilyReview' if build_for_testing else ARTIFACT_SCHEME,
        'configuration': 'Release', 'platform': 'iOS',
        'derivedDataPath': str(work / 'DerivedData'),
        'extraArgs': ['DEVELOPMENT_TEAM=' + team, 'PRODUCT_BUNDLE_IDENTIFIER=' + QA_BUNDLE,
            'MARKETING_VERSION=' + version['app_version'], 'CURRENT_PROJECT_VERSION=' + str(version['build_number']),
            QA_SWIFT_CONDITIONS]}
    if build_for_testing:
        # CoreDevice inventory IDs are used by devicectl inspection; Xcode's
        # test destination requires the current hardware UDID from details.
        arguments.update(buildForTesting=True, deviceId=current['udid'])
    command = ['xcodebuildmcp', 'device', 'build', '--json', json.dumps(arguments), '--output', 'json']
    receipt = {'kind': 'ios-qa-build', 'status': 'building',
        'channel': channel, 'version': version, 'team': team, 'device': current,
        'generated_inputs': generated_inputs,
        'build_for_testing': build_for_testing,
        'bundle_id': QA_BUNDLE, 'build_command': command, 'installed': False,
        'launched': False, 'distribution_ready': False}
    path = work / 'build-receipt.json'
    write_receipt(path, receipt)
    with (work / 'build.json').open('w') as output, (work / 'build-stderr.log').open('w') as errors:
        process = launcher(command, stdin=subprocess.DEVNULL, stdout=output, stderr=errors, start_new_session=True,
                           env=controlled_environment())
    receipt['builder_pid'] = process.pid
    write_receipt(path, receipt)
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        return {**receipt, 'next_step': 'Rerun --verify-only; the original build continues'}
    if process.returncode:
        raise PreflightError('Build failed; logs retained and no device installation was attempted')
    return finish_build(work, runner=runner)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--work', type=Path, required=True, help='New isolated build directory')
    parser.add_argument('--device')
    parser.add_argument('--team')
    parser.add_argument('--channel', default='development-qa', choices=['development-qa', 'testflight', 'app-store', 'ad-hoc'])
    parser.add_argument('--verify-only', action='store_true', help='Resume the original build receipt, without rebuilding')
    parser.add_argument('--build-for-testing', action='store_true', help='Explicitly compile test products; requires the separate test-runner provisioning profile')
    args = parser.parse_args()
    try:
        if args.verify_only:
            if args.device or args.team or args.build_for_testing:
                parser.error('--verify-only consumes the original --work receipt')
            result = finish_build(args.work)
        else:
            if not args.device or not args.team:
                parser.error('build requires a freshly discovered --device and explicit --team')
            result = build_qa(args.root, args.work, args.device, args.team, channel=args.channel,
                             build_for_testing=args.build_for_testing)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({'status': 'blocked', 'error': str(error), 'distribution_ready': False}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
