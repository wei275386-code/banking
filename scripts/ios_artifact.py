"""Read-only signing/device preflight shared by build and first-install tools."""
from __future__ import annotations

import hashlib
import fnmatch
import json
import os
import plistlib
import pwd
import re
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
if __package__:
    from .tool_locations import controlled_environment as _platform_environment, resolve_command
else:
    from tool_locations import controlled_environment as _platform_environment, resolve_command

PRODUCTION_BUNDLE = 'local.familyreview.FamilyReview'
QA_BUNDLE = PRODUCTION_BUNDLE + '.ReleaseQA'


class PreflightError(ValueError):
    pass


class ExistingInstall(PreflightError):
    """First install must never become an unbacked update."""


class DistributionGate(PreflightError):
    pass


def controlled_environment():
    """Platform tools use the existing user's keychain, without ambient code overrides."""
    account = pwd.getpwuid(os.getuid())
    environment = _platform_environment(development=True)
    environment.update(USER=account.pw_name, LOGNAME=account.pw_name)
    return environment


def run(command):
    return subprocess.run(resolve_command(command), check=True, capture_output=True, timeout=20,
                          env=controlled_environment())


def json_response(raw):
    response = json.loads(raw)
    if response.get('didError') or response.get('isError'):
        raise PreflightError(response.get('error') or 'XcodeBuildMCP operation failed')
    if response.get('didError') is not False:
        raise PreflightError('XcodeBuildMCP result lacks explicit successful outcome')
    return response


def _regular(path):
    path = Path(path).absolute()
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise PreflightError('Artifact path contains a symlink')
    if not path.is_file():
        raise PreflightError('Artifact file is missing: ' + path.name)
    return path


def sha256(path):
    digest = hashlib.sha256()
    with _regular(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_digest(app):
    """Exact artifact bytes, including its embedded profile and code signature."""
    hashes = {}
    for folder, directories, files in os.walk(app, followlinks=False):
        for name in directories:
            if (Path(folder) / name).is_symlink():
                raise PreflightError('Artifact contains a directory symlink')
        for name in files:
            path = Path(folder) / name
            hashes[path.relative_to(app).as_posix()] = sha256(path)
    encoded = json.dumps(hashes, sort_keys=True, separators=(',', ':')).encode()
    return hashlib.sha256(encoded).hexdigest()


def _utc(value):
    if not isinstance(value, datetime):
        raise PreflightError('Profile timestamp is missing or malformed')
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def os_version(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', value):
        raise PreflightError('OS version is missing or malformed')
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (3 - len(parts))


def _entitlement_allowed(value, permitted):
    if isinstance(value, list):
        return isinstance(permitted, list) and all(any(_entitlement_allowed(item, allowed)
            for allowed in permitted) for item in value)
    if isinstance(value, str) and isinstance(permitted, str):
        return '*' not in value and fnmatch.fnmatchcase(value, permitted)
    return type(value) is type(permitted) and value == permitted


def inspect_artifact(app, *, bundle_id, team, version, build, runner=run, now=None):
    """Inspect an already-built QA package. Does not build, sign or install it."""
    app = Path(app).absolute()
    now = _utc(now or datetime.now(timezone.utc))
    if app.suffix != '.app' or not app.is_dir() or app.is_symlink():
        raise PreflightError('Use an existing .app artifact')
    if not re.fullmatch(r'[A-Z0-9]{10}', team or ''):
        raise PreflightError('An explicit signing team is required')
    info = plistlib.loads(_regular(app / 'Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier'), info.get('CFBundleShortVersionString'), str(info.get('CFBundleVersion'))) != (bundle_id, version, str(build)):
        raise PreflightError('Artifact bundle ID/version/build differs from controlled inputs')
    if info.get('CFBundlePackageType') != 'APPL' or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise PreflightError('Artifact is not an iPhoneOS application')
    families = info.get('UIDeviceFamily')
    if not isinstance(families, list) or 1 not in families:
        raise PreflightError('Artifact does not support iPhone')
    minimum = info.get('MinimumOSVersion')
    os_version(minimum)
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        raise PreflightError('Artifact executable name is invalid')
    _regular(app / executable)
    # Empty bootstrap is the only candidate bootstrap. Never inspect private Seed.
    if (app / 'Seed').exists():
        raise PreflightError('Artifact contains development Seed resources')
    bootstrap = app / 'Bootstrap/bootstrap.json'
    if not bootstrap.is_file():
        raise PreflightError('Artifact has no empty Bootstrap contract')
    payload = json.loads(_regular(bootstrap).read_text())
    if payload.get('kind') != 'empty' or payload.get('workspace_created') is not False:
        raise PreflightError('Artifact bootstrap is not empty')
    runner(['codesign', '--verify', '--deep', '--strict', str(app)])
    signed = plistlib.loads(runner(['codesign', '-d', '--entitlements', ':-', str(app)]).stdout)
    profile = plistlib.loads(runner(['security', 'cms', '-D', '-i',
                                    str(_regular(app / 'embedded.mobileprovision'))]).stdout)
    identifier = team + '.' + bundle_id
    profile_entitlements = profile.get('Entitlements', {})
    if (signed.get('application-identifier') != identifier or
            signed.get('com.apple.developer.team-identifier') != team or
            team not in profile.get('TeamIdentifier', []) or
            profile_entitlements.get('com.apple.developer.team-identifier') != team):
        raise PreflightError('Signature/profile/bundle signing team differs')
    permitted = profile_entitlements.get('application-identifier')
    if permitted != identifier and permitted != team + '.*':
        raise PreflightError('Profile does not authorize the bundle ID')
    for key, value in signed.items():
        if key not in profile_entitlements or not _entitlement_allowed(value, profile_entitlements[key]):
            raise PreflightError('Signed entitlement is not authorized by the profile: ' + key)
    if signed.get('get-task-allow') is not True or profile_entitlements.get('get-task-allow') is not True:
        raise DistributionGate('Direct QA installation requires a development profile; distribution uses its selected channel')
    expiry, created = _utc(profile.get('ExpirationDate')), _utc(profile.get('CreationDate'))
    if not isinstance(profile.get('UUID'), str) or not profile['UUID']:
        raise PreflightError('Profile identity is missing')
    if not created <= now < expiry:
        raise PreflightError('Profile is expired or not yet valid')
    devices = profile.get('ProvisionedDevices')
    if not isinstance(devices, list) or not devices or not all(isinstance(item, str) and item for item in devices):
        raise PreflightError('QA profile has no registered device scope')
    if profile.get('ProvisionsAllDevices') is True:
        raise PreflightError('Enterprise profiles are not this QA installation channel')
    with tempfile.TemporaryDirectory(prefix='ios-signature-') as temporary:
        prefix = Path(temporary).resolve() / 'certificate'
        # This option's prefix is optional; it must use '=' or codesign treats
        # the separate prefix argument as another input code object.
        runner(['codesign', '-d', '--extract-certificates=' + str(prefix), str(app)])
        certificate = _regular(Path(str(prefix) + '0'))
        certificate_bytes = certificate.read_bytes()
        if certificate_bytes not in profile.get('DeveloperCertificates', []):
            raise PreflightError('Signing certificate is not authorized by the profile')
        raw_expiry = runner(['openssl', 'x509', '-inform', 'DER', '-in', str(certificate),
                             '-noout', '-enddate']).stdout.decode().strip()
        try:
            certificate_expiry = datetime.strptime(raw_expiry, 'notAfter=%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
        except ValueError as error:
            raise PreflightError('Signing certificate expiry cannot be verified') from error
        if now >= certificate_expiry:
            raise PreflightError('Signing certificate is expired')
    architectures = runner(['lipo', '-archs', str(app / executable)]).stdout.decode().split()
    if not architectures or any(value not in {'arm64', 'arm64e'} for value in architectures):
        raise PreflightError('Artifact has unsupported device architecture')
    return {'kind': 'ios-qa-artifact', 'bundle_id': bundle_id,
        'team': team, 'version': version, 'build': str(build), 'minimum_ios': minimum,
        'device_families': families, 'architectures': architectures,
        'profile_uuid': profile.get('UUID'), 'profile_expires': expiry.isoformat(),
        'profile_devices': sorted(devices), 'signing_certificate_sha256': hashlib.sha256(certificate_bytes).hexdigest(),
        'certificate_expires': certificate_expiry.isoformat(), 'artifact_sha256': artifact_digest(app),
        'channel': 'development-qa', 'distribution_ready': False}


def device_result(device, arguments, *, runner=run):
    developer = runner(['xcode-select', '-p']).stdout.decode().strip()
    tool = Path(developer) / 'usr/bin/devicectl'
    with tempfile.TemporaryDirectory(prefix='ios-device-inspect-') as temporary:
        output = Path(temporary).resolve() / 'result.json'
        runner([str(tool), 'device', *arguments, '--device', device,
                '--timeout', '15', '--quiet', '--json-output', str(output)])
        response = json.loads(output.read_text())
    if response.get('info', {}).get('outcome') != 'success':
        raise PreflightError('Device inspection did not return success')
    return response['result']


def inspect_device(device, *, runner=run):
    listed = json_response(runner(['xcodebuildmcp', 'device', 'list', '--output', 'json']).stdout)
    matches = [item for item in listed.get('data', {}).get('devices', []) if item.get('deviceId') == device]
    if len(matches) != 1 or matches[0].get('state') != 'connected' or matches[0].get('isAvailable') is not True or matches[0].get('platform') != 'iOS':
        raise PreflightError('Select a currently discovered, available physical iOS device ID')
    details = device_result(device, ['info', 'details'], runner=runner)
    hardware, properties, connection = [details.get(name, {}) for name in
        ('hardwareProperties', 'deviceProperties', 'connectionProperties')]
    if (details.get('identifier') != device or hardware.get('reality') != 'physical' or
            hardware.get('platform') != 'iOS' or hardware.get('deviceType') != 'iPhone' or
            connection.get('pairingState') != 'paired' or connection.get('tunnelState') != 'connected' or
            properties.get('bootState') != 'booted' or properties.get('developerModeStatus') != 'enabled' or
            properties.get('ddiServicesAvailable') is not True or
            'com.apple.coredevice.feature.installapp' not in {item.get('featureIdentifier')
                for item in details.get('capabilities', [])}):
        raise PreflightError('Device is not paired/connected with Developer Mode and DDI available')
    udid = hardware.get('udid')
    if not isinstance(udid, str) or not udid:
        raise PreflightError('Current hardware UDID is unavailable')
    version = properties.get('osVersionNumber')
    os_version(version)
    return {'device_id': device, 'udid': udid, 'name': properties.get('name'),
            'model': hardware.get('marketingName'), 'product_type': hardware.get('productType'),
            'ios_version': version, 'device_families': hardware.get('supportedDeviceFamilies', []),
            'architectures': [item['name'] for item in hardware.get('supportedCPUTypes', [])]}


def installed_app(device, bundle_id, *, runner=run):
    inventory = device_result(device, ['info', 'apps', '--bundle-id', bundle_id,
                                      '--include-all-apps'], runner=runner)
    if inventory.get('deviceIdentifier') != device or inventory.get('matchingBundleIdentifier') != bundle_id:
        raise PreflightError('Installed-app inventory does not match the selected device/bundle')
    apps = inventory.get('apps')
    if not isinstance(apps, list) or len(apps) > 1 or any(item.get('bundleIdentifier') != bundle_id for item in apps):
        raise PreflightError('Installed-app inventory is ambiguous')
    return apps[0] if apps else None


def validate_device_artifact(artifact, device):
    if device['udid'] not in artifact['profile_devices']:
        raise PreflightError('Current device UDID is not provisioned')
    if os_version(device['ios_version']) < os_version(artifact['minimum_ios']):
        raise PreflightError('Device OS is below artifact minimum')
    if not set(device['architectures']) & set(artifact['architectures']) or not set(device['device_families']) & set(artifact['device_families']):
        raise PreflightError('Artifact does not support current device hardware')


def first_install_preflight(app, device, *, bundle_id, team, version, build, runner=run, now=None):
    current = inspect_device(device, runner=runner)
    if installed_app(device, bundle_id, runner=runner) is not None:
        raise ExistingInstall('Same bundle ID is already installed; use ios:update with its backup flow')
    artifact = inspect_artifact(app, bundle_id=bundle_id, team=team, version=version,
                                build=build, runner=runner, now=now)
    validate_device_artifact(artifact, current)
    return {'status': 'preflight-passed', 'artifact': artifact,
            'device': current, 'existing_install': False, 'welcome_verified': False,
            'distribution_ready': False}
