"""Typed, credential-free signing preflight for local iOS distribution artifacts."""
from __future__ import annotations

import hashlib
import json
import os
import plistlib
import pwd
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from scripts.tool_locations import controlled_environment as _platform_environment, resolve_command, tool_path

from scripts.generate_release_inputs import load_version
from scripts.ios_artifact import (PRODUCTION_BUNDLE, DistributionGate, PreflightError,
    _entitlement_allowed, _regular, _utc, artifact_digest, inspect_device,
    os_version, sha256)


def controlled_environment():
    return _platform_environment(development=True)


def run(command):
    return subprocess.run(resolve_command(command), check=True, capture_output=True, timeout=20,
                          env=controlled_environment())


def source_proof(root):
    """Clean commit plus exact production allowlist, including ignored inputs."""
    from release.source_contract import check_path
    root = Path(root).resolve()
    def git(*args, input=None):
        try:
            return subprocess.run([tool_path('git', system=True), '-C', str(root), *args], input=input,
                check=True, capture_output=True, timeout=20, env=controlled_environment()).stdout
        except (OSError, subprocess.SubprocessError):
            raise PreflightError('Formal archive requires a clean committed Git source snapshot') from None
    commit = git('rev-parse', '--verify', 'HEAD^{commit}').decode().strip()
    if git('status', '--porcelain=v1', '-z', '--untracked-files=all'):
        raise PreflightError('Formal archive refuses dirty or uncommitted source')
    entries = {}
    for record in git('ls-tree', '-r', '-z', commit).split(b'\0'):
        if record:
            header, name = record.split(b'\t', 1)
            entries[name.decode()] = header.decode().split()
    allow_bytes = git('cat-file', 'blob', commit + ':release/source-allowlist.json')
    allowlist = json.loads(allow_bytes)
    names = allowlist.get('profiles', {}).get('production')
    if (not isinstance(names, list) or not names or any((not isinstance(name, str) for name in names)) or (len(names) != len(set(names)))):
        raise PreflightError('Formal archive requires the explicit committed production allowlist')
    mandatory = {'release/source-allowlist.json', 'release/native-toolchain.json',
        'release/runtime-lock.json', 'config/release-version.json',
        'native/FamilyReviewIOS/project.yml', 'native/PaymentImageCore/Package.swift',
        'scripts/archive_ios_release.py', 'scripts/ios_distribution.py'}
    if not mandatory <= set(names):
        raise PreflightError('Production source allowlist lacks required version/project/lock inputs')
    for name in names:
        check_path(name)
        if entries.get(name, [])[:2] not in (['100644', 'blob'], ['100755', 'blob']):
            raise PreflightError('Production allowlist has a nonregular or uncommitted source')
    raw = git('cat-file', '--batch', input=''.join(entries[name][2] + '\n' for name in names).encode())
    offset = 0; files = {}
    for name in names:
        end = raw.index(b'\n', offset)
        header = raw[offset:end].decode().split(); length = int(header[2]); offset = end + 1
        if header[:2] != [entries[name][2], 'blob'] or len(raw) < offset + length + 1:
            raise PreflightError('Committed source blob batch is incomplete')
        expected = hashlib.sha256(raw[offset:offset + length]).hexdigest(); offset += length + 1
        if sha256(root / name) != expected:
            raise PreflightError('Working source differs from the committed production input')
        files[name] = expected
    # Directory source groups compiled by the generated project/SwiftPM cannot
    # silently ingest ignored or unallowlisted Swift files.
    for folder in ('native/FamilyReviewIOS/FamilyReviewApp',
                   'native/PaymentImageCore/Sources/PaymentImageCore',
                   'native/PaymentImageCore/Sources/EvidenceBrowser'):
        for path in (root / folder).rglob('*.swift'):
            if path.relative_to(root).as_posix() not in files:
                raise PreflightError('Unallowlisted Swift source could enter the production compiler')
    encoded = json.dumps(files, sort_keys=True, separators=(',', ':')).encode()
    return {'commit': commit, 'dirty': False, 'source_files': files,
            'source_input_sha256': hashlib.sha256(encoded).hexdigest()}


def verify_source_snapshot(root, proof):
    from release.source_contract import check_path
    root = Path(root)
    files = proof['source_files']
    encoded = json.dumps(files, sort_keys=True, separators=(',', ':')).encode()
    if hashlib.sha256(encoded).hexdigest() != proof['source_input_sha256']:
        raise PreflightError('Source proof digest differs')
    for name, expected in files.items():
        check_path(name)
        if sha256(root / name) != expected:
            raise PreflightError('Committed source snapshot changed')
    for folder in ('native/FamilyReviewIOS/FamilyReviewApp',
                   'native/PaymentImageCore/Sources/PaymentImageCore',
                   'native/PaymentImageCore/Sources/EvidenceBrowser'):
        for path in (root / folder).rglob('*.swift'):
            if path.relative_to(root).as_posix() not in files:
                raise PreflightError('Source snapshot has an unallowlisted compiler input')


def toolchain_proof(root, *, runner=run):
    root = Path(root)
    lock = json.loads((root / 'release/native-toolchain.json').read_text())
    runtime = json.loads((root / 'release/runtime-lock.json').read_text())
    developer = Path(runner(['xcode-select', '-p']).stdout.decode().strip()).resolve()
    paths = {'xcodebuild': (developer / 'usr/bin/xcodebuild').resolve(),
        'swift': (developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift').resolve(),
        'xcodegen': Path(tool_path('xcodegen')).resolve()}
    for name, path in paths.items():
        if sha256(path) != lock.get('tools', {}).get(name, {}).get('sha256'):
            raise PreflightError('Selected toolchain differs from the committed lock: ' + name)
    # Exact tool hashes bind versions without executing raw xcodebuild build.
    sdks = {}
    for entry in lock.get('sdks', []):
        platform = entry.get('platform')
        if platform not in {'MacOSX', 'iPhoneOS'}:
            raise PreflightError('Unknown locked SDK')
        settings = developer / ('Platforms/' + platform + '.platform/Developer/SDKs/' + platform + '.sdk/SDKSettings.plist')
        raw = settings.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if digest != entry.get('settings_sha256') or plistlib.loads(raw).get('Version') != entry.get('version'):
            raise PreflightError('Selected SDK differs from the committed lock')
        sdks[platform] = {'version': entry['version'], 'settings_sha256': digest}
    if set(sdks) != {'MacOSX', 'iPhoneOS'} or runtime.get('runtime_version') != 'cpython-3.13.9-pbs-20251014-lock1':
        raise PreflightError('Incomplete SDK/runtime version lock')
    return {'developer': str(developer), 'tools': {key: {'path': str(value),
        'sha256': lock['tools'][key]['sha256'], 'version': lock['tools'][key]['version']} for key, value in paths.items()},
        'xcode_build': lock['xcode_build'], 'sdks': sdks, 'runtime_version': runtime['runtime_version'],
        'native_lock_sha256': sha256(root / 'release/native-toolchain.json'),
        'runtime_lock_sha256': sha256(root / 'release/runtime-lock.json')}


@dataclass(frozen=True)
class DistributionConfig:
    channel: str
    team: str
    certificate_sha1: str
    profile_path: Path
    profile_uuid: str
    bundle_id: str = PRODUCTION_BUNDLE
    device_ids: tuple[str, ...] = ()
    app_store_app_id: str | None = None

    @classmethod
    def decode(cls, value):
        if not isinstance(value, dict) or set(value) - {
                'channel', 'team', 'certificate_sha1', 'profile_path', 'profile_uuid',
                'bundle_id', 'device_ids', 'app_store_app_id'}:
            raise PreflightError('Distribution config has unknown fields; credentials are not accepted')
        required = {'channel', 'team', 'certificate_sha1', 'profile_path', 'profile_uuid'}
        if not required <= value.keys() or any(not isinstance(value[key], str) for key in required):
            raise PreflightError('Distribution config requires explicit channel/team/certificate/profile')
        if value['channel'] not in {'testflight', 'app-store', 'ad-hoc'}:
            raise DistributionGate('Select TestFlight, App Store, or Ad Hoc explicitly')
        if not re.fullmatch(r'[A-Z0-9]{10}', value['team']):
            raise PreflightError('Signing team must have ten uppercase characters')
        if not re.fullmatch(r'[0-9A-F]{40}', value['certificate_sha1']):
            raise PreflightError('Use an exact uppercase certificate SHA1, not an automatic signing selector')
        if not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', value['profile_uuid']):
            raise PreflightError('Use an explicit provisioning profile UUID')
        if value.get('bundle_id', PRODUCTION_BUNDLE) != PRODUCTION_BUNDLE:
            raise PreflightError('Distribution entry accepts only the production bundle ID')
        profile = Path(value['profile_path']).expanduser()
        if not profile.is_absolute():
            raise PreflightError('Profile path must be absolute')
        devices = value.get('device_ids', [])
        if (not isinstance(devices, list) or
                any(not isinstance(item, str) or not re.fullmatch(r'[A-Fa-f0-9-]{16,64}', item) for item in devices) or
                len(devices) != len(set(devices))):
            raise PreflightError('Ad Hoc device IDs must be unique hardware UDIDs')
        app_id = value.get('app_store_app_id')
        if value['channel'] == 'ad-hoc':
            if not devices or app_id is not None:
                raise PreflightError('Ad Hoc requires device IDs and no App Store account metadata')
        elif devices or not isinstance(app_id, str) or not re.fullmatch(r'[0-9]{1,20}', app_id):
            raise DistributionGate('TestFlight/App Store requires its explicit App Store Connect app ID')
        return cls(value['channel'], value['team'], value['certificate_sha1'], profile,
                   value['profile_uuid'], device_ids=tuple(devices), app_store_app_id=app_id)

    def document(self):
        return {'channel': self.channel, 'team': self.team, 'certificate_sha1': self.certificate_sha1,
                'profile_path': str(self.profile_path), 'profile_uuid': self.profile_uuid,
                'bundle_id': self.bundle_id, 'device_ids': list(self.device_ids),
                'app_store_app_id': self.app_store_app_id}


def certificate_dates(certificate, *, runner=run):
    with tempfile.TemporaryDirectory(prefix='ios-distribution-certificate-') as temporary:
        path = Path(temporary).resolve() / 'certificate.der'
        path.write_bytes(certificate)
        raw = runner(['openssl', 'x509', '-inform', 'DER', '-in', str(path),
                      '-noout', '-startdate', '-enddate']).stdout.decode().splitlines()
    try:
        values = dict(line.split('=', 1) for line in raw)
        return tuple(datetime.strptime(values[key], '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
                     for key in ('notBefore', 'notAfter'))
    except (ValueError, KeyError) as error:
        raise PreflightError('Distribution certificate dates cannot be verified') from error


def validate_profile(profile, config, *, runner=run, now=None):
    now = _utc(now or datetime.now(timezone.utc))
    entitlements = profile.get('Entitlements', {})
    if (profile.get('UUID') != config.profile_uuid or profile.get('TeamIdentifier') != [config.team] or
            entitlements.get('com.apple.developer.team-identifier') != config.team or
            entitlements.get('application-identifier') != config.team + '.' + config.bundle_id or
            entitlements.get('get-task-allow') is not False or profile.get('ProvisionsAllDevices') is True):
        raise PreflightError('Profile must exactly authorize production/team with distribution entitlements')
    created, expiry = _utc(profile.get('CreationDate')), _utc(profile.get('ExpirationDate'))
    if not created <= now < expiry:
        raise PreflightError('Distribution profile is expired or not yet valid')
    devices = profile.get('ProvisionedDevices')
    if config.channel == 'ad-hoc':
        if not isinstance(devices, list) or not devices or not set(config.device_ids) <= set(devices):
            raise PreflightError('Ad Hoc profile does not cover the declared hardware UDIDs')
    elif devices is not None:
        raise PreflightError('App Store Connect requires a distribution profile without device scope')
    certificates = profile.get('DeveloperCertificates', [])
    certificates = [cert for cert in certificates if isinstance(cert, bytes) and
                    hashlib.sha1(cert).hexdigest().upper() == config.certificate_sha1]
    if len(certificates) != 1:
        raise PreflightError('Selected distribution certificate is not in the profile')
    start, end = certificate_dates(certificates[0], runner=runner)
    if not start <= now < end:
        raise PreflightError('Distribution certificate is expired or not yet valid')
    return {'profile_uuid': config.profile_uuid, 'profile_expires': expiry.isoformat(),
            'certificate_expires': end.isoformat(), 'certificate_sha1': config.certificate_sha1,
            'profile_devices': sorted(devices or [])}


def preflight(root, config, *, device=None, runner=run, now=None):
    """Read-only checks before any build work directory or signing operation."""
    if not isinstance(config, DistributionConfig):
        raise PreflightError('Preflight requires a typed distribution config')
    config = DistributionConfig.decode(config.document())
    version = load_version(Path(root))
    identities = runner(['security', 'find-identity', '-v', '-p', 'codesigning']).stdout.decode()
    pattern = r'^\s*\d+\)\s+' + config.certificate_sha1 + r'\s+"(?:Apple Distribution|iPhone Distribution):[^"\n]*\(' + config.team + r'\)"\s*$'
    if len(re.findall(pattern, identities, re.MULTILINE)) != 1:
        raise DistributionGate('Selected valid distribution certificate/private-key identity is unavailable')
    source = source_proof(root)
    tools = toolchain_proof(root, runner=runner)
    profile_path = _regular(config.profile_path)
    profile = plistlib.loads(runner(['security', 'cms', '-D', '-i', str(profile_path)]).stdout)
    signing = validate_profile(profile, config, runner=runner, now=now)
    # Manual UUID resolution needs an already-installed profile. Never import it
    # or modify the keychain/account as part of a build or export.
    folders = [Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
               Path.home() / 'Library/MobileDevice/Provisioning Profiles']
    installed = [folder / (config.profile_uuid + '.mobileprovision') for folder in folders]
    checksum = sha256(profile_path)
    if not any(path.is_file() and sha256(path) == checksum for path in installed):
        raise DistributionGate('The exact selected profile must already be installed for manual signing')
    current = inspect_device(device, runner=runner) if device else None
    if config.channel == 'ad-hoc':
        if current is None or current['udid'] not in config.device_ids:
            raise DistributionGate('Ad Hoc preflight requires a fresh selected physical device in the declared scope')
    if current and os_version(current['ios_version']) < os_version(version['ios_minimum']):
        raise PreflightError('Selected physical device is below the controlled iOS minimum')
    export_tool = _regular(Path(tools['tools']['xcodebuild']['path']))
    return {'kind': 'ios-distribution-preflight', 'config': config.document(), 'version': version,
            'signing': {**signing, 'profile_sha256': checksum}, 'device': current,
            'source': source, 'toolchain': tools,
            'export_tool': str(export_tool), 'installed': False, 'uploaded': False,
            'distribution_ready': False, 'external_gate': 'App Store Connect account/app/channel acceptance remains unverified'}


def export_options(config):
    return {'method': 'release-testing' if config.channel == 'ad-hoc' else 'app-store-connect',
            'destination': 'export', 'signingStyle': 'manual', 'teamID': config.team,
            'signingCertificate': config.certificate_sha1,
            'provisioningProfiles': {config.bundle_id: config.profile_uuid},
            'manageAppVersionAndBuildNumber': False, 'stripSwiftSymbols': True}


def inspect_distribution_app(app, config, version, *, runner=run, now=None):
    config = DistributionConfig.decode(config.document())
    app = Path(app)
    info = plistlib.loads(_regular(app / 'Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier'), info.get('CFBundleShortVersionString'), str(info.get('CFBundleVersion'))) != (
            config.bundle_id, version['app_version'], str(version['build_number'])):
        raise PreflightError('Distribution application identity differs from controlled version')
    if (info.get('CFBundlePackageType') != 'APPL' or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS'] or
            1 not in info.get('UIDeviceFamily', []) or info.get('MinimumOSVersion') != version['ios_minimum']):
        raise PreflightError('Distribution application platform/support/minimum differs from controlled inputs')
    if (app / 'Seed').exists() or (app / 'PlugIns').exists():
        raise PreflightError('Distribution entry does not accept Seed or undeclared embedded app targets')
    bootstrap = json.loads(_regular(app / 'Bootstrap/bootstrap.json').read_text())
    if (bootstrap.get('kind') != 'empty' or bootstrap.get('workspace_created') is not False or json.loads(_regular(app / 'Bootstrap/release-version.json').read_text()) != version):
        raise PreflightError('Distribution Bootstrap is not the controlled empty version')
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable, str) or Path(executable).name != executable:
        raise PreflightError('Distribution executable is malformed')
    architectures = runner(['lipo', '-archs', str(_regular(app / executable))]).stdout.decode().split()
    if not architectures or any(arch not in {'arm64', 'arm64e'} for arch in architectures):
        raise PreflightError('Distribution archive must contain physical iOS architecture')
    runner(['codesign', '--verify', '--deep', '--strict', str(app)])
    signed = plistlib.loads(runner(['codesign', '-d', '--entitlements', ':-', str(app)]).stdout)
    profile_path = _regular(app / 'embedded.mobileprovision')
    if sha256(profile_path) != sha256(config.profile_path):
        raise PreflightError('Embedded distribution profile differs from selected profile')
    profile = plistlib.loads(runner(['security', 'cms', '-D', '-i', str(profile_path)]).stdout)
    signing = validate_profile(profile, config, runner=runner, now=now)
    if signed.get('application-identifier') != config.team + '.' + config.bundle_id or signed.get('get-task-allow') is not False:
        raise PreflightError('Distribution signature is not the selected production identity')
    for key, value in signed.items():
        if key not in profile['Entitlements'] or not _entitlement_allowed(value, profile['Entitlements'][key]):
            raise PreflightError('Distribution signed entitlement is not authorized: ' + key)
    with tempfile.TemporaryDirectory(prefix='ios-distribution-signature-') as temporary:
        prefix = Path(temporary).resolve() / 'certificate'
        runner(['codesign', '-d', '--extract-certificates=' + str(prefix), str(app)])
        leaf = _regular(Path(str(prefix) + '0')).read_bytes()
        if hashlib.sha1(leaf).hexdigest().upper() != config.certificate_sha1:
            raise PreflightError('Distribution application used a different signing certificate')
    return {**signing, 'bundle_id': config.bundle_id, 'version': version['app_version'],
            'build': str(version['build_number']), 'architectures': architectures,
            'artifact_sha256': artifact_digest(app)}
