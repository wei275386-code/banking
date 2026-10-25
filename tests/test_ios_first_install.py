"""Synthetic artifacts/device responses; never install or read an app container."""
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from scripts.ios_artifact import (QA_BUNDLE, PRODUCTION_BUNDLE, DistributionGate,
    ExistingInstall, PreflightError, first_install_preflight, inspect_artifact)
from scripts.ios_artifact import controlled_environment, run as platform_run
from scripts.install_ios_app import first_install, installation_gate, verify_installation

TEAM = 'ABCDEFGHIJ'
DEVICE = 'fixture-current-device'
UDID = 'fixture-actual-udid'
NOW = datetime.now(timezone.utc)


class DeviceFixture:
    def __init__(self, root):
        self.app = root / 'Fixture.app'; self.app.mkdir()
        self.calls = []
        self.installed = None
        self.connected = True
        self.signing_error = None
        self.architectures = b'arm64\n'
        self.info = {'CFBundleIdentifier': QA_BUNDLE, 'CFBundleShortVersionString': '1.1.0',
            'CFBundleVersion': '18', 'CFBundleExecutable': 'Fixture', 'CFBundlePackageType': 'APPL',
            'CFBundleSupportedPlatforms': ['iPhoneOS'], 'UIDeviceFamily': [1], 'MinimumOSVersion': '17.0'}
        self.write_info()
        (self.app / 'Fixture').write_bytes(b'controlled-executable')
        (self.app / 'embedded.mobileprovision').write_bytes(b'controlled-profile')
        (self.app / 'Bootstrap').mkdir()
        (self.app / 'Bootstrap/bootstrap.json').write_text(json.dumps({'kind': 'empty', 'workspace_created': False}))
        self.signed = {'application-identifier': TEAM + '.' + QA_BUNDLE,
            'com.apple.developer.team-identifier': TEAM, 'get-task-allow': True}
        self.profile = {'UUID': 'fixture-profile', 'TeamIdentifier': [TEAM], 'Entitlements': dict(self.signed),
            'CreationDate': (NOW - timedelta(days=1)).replace(tzinfo=None),
            'ExpirationDate': (NOW + timedelta(days=30)).replace(tzinfo=None),
            'ProvisionedDevices': [UDID], 'DeveloperCertificates': [b'controlled-certificate']}
        self.certificate_expiry = b'notAfter=Oct 14 16:35:16 2030 GMT\n'
        self.details = {'identifier': DEVICE,
            'capabilities': [{'featureIdentifier': 'com.apple.coredevice.feature.installapp'}],
            'connectionProperties': {'pairingState': 'paired', 'tunnelState': 'connected'},
            'deviceProperties': {'bootState': 'booted', 'developerModeStatus': 'enabled', 'ddiServicesAvailable': True,
                                 'osVersionNumber': '26.7', 'name': 'Fixture iPhone'},
            'hardwareProperties': {'reality': 'physical', 'platform': 'iOS', 'deviceType': 'iPhone',
                'udid': UDID, 'marketingName': 'iPhone 13 mini', 'productType': 'iPhone14,4',
                'supportedDeviceFamilies': [1], 'supportedCPUTypes': [{'name': 'arm64'}]}}

    def write_info(self):
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info))

    def run(self, command):
        self.calls.append(command)
        output = b''
        if command[:3] == ['xcodebuildmcp', 'device', 'list']:
            output = json.dumps({'didError': False, 'data': {'devices': [{'deviceId': DEVICE,
                'platform': 'iOS', 'state': 'connected' if self.connected else 'disconnected',
                'isAvailable': self.connected}]}}).encode()
        elif command == ['xcode-select', '-p']:
            output = b'/fixture/Xcode/Contents/Developer\n'
        elif command[0].endswith('/devicectl'):
            if 'details' in command:
                result = self.details
            elif 'apps' in command:
                bundle = command[command.index('--bundle-id') + 1]
                result = {'deviceIdentifier': DEVICE, 'matchingBundleIdentifier': bundle,
                          'apps': [self.installed] if self.installed else []}
            else:
                raise AssertionError('Unexpected device action: ' + repr(command))
            Path(command[command.index('--json-output') + 1]).write_text(json.dumps({'info': {'outcome': 'success'}, 'result': result}))
        elif command[:2] == ['codesign', '--verify']:
            if self.signing_error:
                raise subprocess.CalledProcessError(1, command, stderr=b'invalid signature')
        elif command[:3] == ['codesign', '-d', '--entitlements']:
            output = plistlib.dumps(self.signed)
        elif command[:2] == ['codesign', '-d'] and command[2].startswith('--extract-certificates='):
            Path(command[2].split('=', 1)[1] + '0').write_bytes(b'controlled-certificate')
        elif command[:3] == ['security', 'cms', '-D']:
            output = plistlib.dumps(self.profile)
        elif command[:2] == ['openssl', 'x509']:
            output = self.certificate_expiry
        elif command[:2] == ['lipo', '-archs']:
            output = self.architectures
        elif command[:2] == ['xcodegen', 'generate']:
            pass
        else:
            raise AssertionError('Unexpected tool command: ' + repr(command))
        return subprocess.CompletedProcess(command, 0, stdout=output, stderr=b'')

    def inspect(self):
        return inspect_artifact(self.app, bundle_id=QA_BUNDLE, team=TEAM, version='1.1.0',
                                build='18', runner=self.run, now=NOW)

    def preflight(self):
        return first_install_preflight(self.app, DEVICE, bundle_id=QA_BUNDLE, team=TEAM,
                                      version='1.1.0', build='18', runner=self.run, now=NOW)


class FirstInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.fixture = DeviceFixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_absent_container_is_not_required_for_preflight(self):
        result = self.fixture.preflight()
        self.assertEqual(result['status'], 'preflight-passed')
        self.assertFalse(result['welcome_verified'])
        self.assertFalse(any('appDataContainer' in command or 'copy' in command for command in self.fixture.calls))

    def test_existing_production_or_qa_install_exits_without_overwrite(self):
        for bundle in (QA_BUNDLE, PRODUCTION_BUNDLE):
            self.fixture.installed = {'bundleIdentifier': bundle, 'version': '1.0', 'bundleVersion': '17'}
            with self.assertRaises(ExistingInstall):
                first_install_preflight(self.fixture.app, DEVICE, bundle_id=bundle, team=TEAM,
                    version='1.1.0', build='18', runner=self.fixture.run)
        self.assertFalse(any('install' in command or 'uninstall' in command for command in self.fixture.calls))

    def test_profile_expired_and_future_profile_are_blocked(self):
        for field, value in [('ExpirationDate', NOW - timedelta(seconds=1)), ('CreationDate', NOW + timedelta(days=1))]:
            original = self.fixture.profile[field]
            self.fixture.profile[field] = value.replace(tzinfo=None)
            with self.assertRaises(PreflightError):
                self.fixture.inspect()
            self.fixture.profile[field] = original

    def test_team_and_application_entitlement_mismatch_blocked(self):
        for key in ('application-identifier', 'com.apple.developer.team-identifier'):
            original = self.fixture.signed[key]
            self.fixture.signed[key] = 'wrong'
            with self.assertRaises(PreflightError):
                self.fixture.inspect()
            self.fixture.signed[key] = original

    def test_unprovisioned_signed_entitlement_is_blocked(self):
        self.fixture.signed['aps-environment'] = 'production'
        with self.assertRaises(PreflightError):
            self.fixture.inspect()

    def test_signing_certificate_must_match_profile_and_not_expire(self):
        self.fixture.profile['DeveloperCertificates'] = [b'other-certificate']
        with self.assertRaises(PreflightError):
            self.fixture.inspect()
        self.fixture.profile['DeveloperCertificates'] = [b'controlled-certificate']
        self.fixture.certificate_expiry = b'notAfter=Oct 14 16:35:16 2020 GMT\n'
        with self.assertRaises(PreflightError):
            self.fixture.inspect()

    def test_device_udid_and_minimum_os_are_verified(self):
        self.fixture.profile['ProvisionedDevices'] = ['other-udid']
        with self.assertRaises(PreflightError):
            self.fixture.preflight()
        self.fixture.profile['ProvisionedDevices'] = [UDID]
        self.fixture.info['MinimumOSVersion'] = '27.0'; self.fixture.write_info()
        with self.assertRaises(PreflightError):
            self.fixture.preflight()

    def test_actual_physical_device_and_developer_services_are_required(self):
        for key, value in [('reality', 'simulator'), ('platform', 'macOS')]:
            original = self.fixture.details['hardwareProperties'][key]
            self.fixture.details['hardwareProperties'][key] = value
            with self.assertRaises(PreflightError):
                self.fixture.preflight()
            self.fixture.details['hardwareProperties'][key] = original
        self.fixture.details['deviceProperties']['ddiServicesAvailable'] = False
        with self.assertRaises(PreflightError):
            self.fixture.preflight()

    def test_stale_disconnected_device_is_not_accepted(self):
        self.fixture.connected = False
        with self.assertRaises(PreflightError):
            self.fixture.preflight()

    def test_wrong_bundle_version_or_platform_is_blocked(self):
        for key, value in [('CFBundleIdentifier', PRODUCTION_BUNDLE), ('CFBundleVersion', '17'),
                           ('CFBundleSupportedPlatforms', ['iPhoneSimulator'])]:
            original = self.fixture.info[key]
            self.fixture.info[key] = value; self.fixture.write_info()
            with self.assertRaises(PreflightError):
                self.fixture.inspect()
            self.fixture.info[key] = original; self.fixture.write_info()

    def test_seed_resources_bad_architecture_or_unsigned_app_are_blocked(self):
        (self.fixture.app / 'Seed').mkdir()
        with self.assertRaises(PreflightError):
            self.fixture.inspect()
        (self.fixture.app / 'Seed').rmdir()
        self.fixture.architectures = b'x86_64\n'
        with self.assertRaises(PreflightError):
            self.fixture.inspect()
        self.fixture.architectures = b'arm64\n'; self.fixture.signing_error = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.fixture.inspect()

    def test_default_is_preflight_with_no_installer(self):
        def forbidden(*args, **kwargs):
            raise AssertionError('default preflight launched an installer')
        result = first_install(self.fixture.app, DEVICE, self.root / 'evidence', bundle_id=QA_BUNDLE,
            team=TEAM, version='1.1.0', build='18', runner=self.fixture.run, launcher=forbidden)
        self.assertEqual(result['status'], 'preflight-passed')
        self.assertFalse(result['installation_requested'])

    def test_production_install_entry_is_a_distribution_gate(self):
        with self.assertRaises(DistributionGate):
            first_install(self.fixture.app, DEVICE, self.root / 'evidence', bundle_id=PRODUCTION_BUNDLE,
                team=TEAM, version='1.1.0', build='18', install_qa=True, runner=self.fixture.run)
        self.assertEqual(self.fixture.calls, [])

    def test_app_collision_after_preflight_aborts_before_install(self):
        inspections = 0
        def runner(command):
            nonlocal inspections
            if 'apps' in command:
                inspections += 1
                if inspections == 2:
                    self.fixture.installed = {'bundleIdentifier': QA_BUNDLE, 'version': '1.0', 'bundleVersion': '17'}
            return self.fixture.run(command)
        def forbidden(*args, **kwargs):
            raise AssertionError('collision overwrote an existing install')
        with self.assertRaises(PreflightError):
            first_install(self.fixture.app, DEVICE, self.root / 'evidence', bundle_id=QA_BUNDLE,
                team=TEAM, version='1.1.0', build='18', install_qa=True,
                runner=runner, launcher=forbidden)

    def test_artifact_change_after_preflight_aborts_before_install(self):
        inspections = 0
        def runner(command):
            nonlocal inspections
            if 'apps' in command:
                inspections += 1
                if inspections == 2:
                    (self.fixture.app / 'Fixture').write_bytes(b'changed-after-preflight')
            return self.fixture.run(command)
        def forbidden(*args, **kwargs):
            raise AssertionError('changed artifact was installed')
        with self.assertRaises(PreflightError):
            first_install(self.fixture.app, DEVICE, self.root / 'evidence', bundle_id=QA_BUNDLE,
                team=TEAM, version='1.1.0', build='18', install_qa=True,
                runner=runner, launcher=forbidden)

    def test_async_worker_retains_installation_gate_after_parent_close(self):
        with installation_gate(DEVICE, QA_BUNDLE) as descriptor:
            child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(0.5)'],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                pass_fds=(descriptor,))
        try:
            with self.assertRaises(PreflightError):
                with installation_gate(DEVICE, QA_BUNDLE):
                    pass
        finally:
            child.wait(timeout=5)
        with installation_gate(DEVICE, QA_BUNDLE):
            pass

    def test_symlink_artifact_is_rejected(self):
        alias = self.root / 'Alias.app'; alias.symlink_to(self.fixture.app, target_is_directory=True)
        with self.assertRaises(PreflightError):
            inspect_artifact(alias, bundle_id=QA_BUNDLE, team=TEAM, version='1.1.0',
                            build='18', runner=self.fixture.run)

    def test_async_install_and_verify_only_never_reinstall_or_claim_welcome(self):
        calls = []
        class Worker:
            pid = 1234
            returncode = None
            def wait(self, timeout):
                raise subprocess.TimeoutExpired('controlled installer', timeout)
        def launcher(command, **options):
            calls.append(command)
            self.assertTrue(options['pass_fds'])
            return Worker()
        evidence = self.root / 'evidence'
        result = first_install(self.fixture.app, DEVICE, evidence, bundle_id=QA_BUNDLE,
            team=TEAM, version='1.1.0', build='18', install_qa=True,
            runner=self.fixture.run, launcher=launcher)
        self.assertEqual(result['status'], 'installing')
        self.assertEqual(verify_installation(evidence, runner=self.fixture.run)['status'], 'installing')
        (evidence / 'install.json').write_text(json.dumps({'didError': False, 'data': {
            'summary': {'status': 'SUCCEEDED'}, 'artifacts': {'deviceId': DEVICE, 'appPath': str(self.fixture.app)}}}))
        self.fixture.installed = {'bundleIdentifier': QA_BUNDLE, 'version': '1.1.0', 'bundleVersion': '18'}
        result = verify_installation(evidence, runner=self.fixture.run)
        self.assertEqual(result['status'], 'installed-unverified-welcome')
        self.assertFalse(result['welcome_verified'])
        self.assertFalse(result['distribution_ready'])
        self.assertEqual(len(calls), 1)
        self.assertEqual(verify_installation(evidence, runner=self.fixture.run)['status'], result['status'])

    def test_platform_runner_and_install_worker_remove_real_environment_injection(self):
        prefix = self.root / 'synthetic-environment'
        injected = {'DYLD_INSERT_LIBRARIES': str(prefix / 'injection.dylib'),
            'PYTHONPATH': str(prefix / 'python'), 'BANKING_PROCESSOR_PYTHON': str(prefix / 'python3'),
            'DEVELOPER_DIR': str(prefix / 'Xcode'), 'GIT_CONFIG_COUNT': '1',
            'HOME': str(prefix / 'home'), 'PATH': str(prefix / 'bin'), 'TMPDIR': str(prefix / 'tmp')}
        code = 'import json,os; print(json.dumps(dict(os.environ)))'
        observed = []
        class Worker:
            pid = 1234
            def wait(self, timeout):
                raise subprocess.TimeoutExpired('fixture install', timeout)
        def launcher(command, **options):
            # Probe the actual child environment with a neutral Python process;
            # the device install command itself is never executed.
            observed.append(json.loads(subprocess.run([sys.executable, '-c', code],
                check=True, capture_output=True, timeout=5, env=options['env']).stdout))
            return Worker()
        with patch.dict(os.environ, injected):
            direct = json.loads(platform_run([sys.executable, '-c', code]).stdout)
            first_install(self.fixture.app, DEVICE, self.root / 'evidence', bundle_id=QA_BUNDLE,
                team=TEAM, version='1.1.0', build='18', install_qa=True,
                runner=self.fixture.run, launcher=launcher)
            expected = controlled_environment()
        for environment in [direct, *observed]:
            self.assertFalse(any(key.startswith(('DYLD', 'PYTHON', 'BANKING', 'GIT_')) for key in environment))
            self.assertNotIn('DEVELOPER_DIR', environment)
            self.assertEqual({key: environment[key] for key in expected}, expected)
            self.assertNotEqual(environment['HOME'], injected['HOME'])
        self.assertEqual(len(observed), 1)

    def test_verify_only_rejects_wrong_installed_version_and_installer_failure(self):
        class Worker:
            pid = 1234
            returncode = None
            def wait(self, timeout):
                raise subprocess.TimeoutExpired('installer', timeout)
        evidence = self.root / 'evidence'
        first_install(self.fixture.app, DEVICE, evidence, bundle_id=QA_BUNDLE,
            team=TEAM, version='1.1.0', build='18', install_qa=True,
            runner=self.fixture.run, launcher=lambda *args, **kwargs: Worker())
        (evidence / 'install.json').write_text(json.dumps({'didError': True, 'error': 'rejected'}))
        with self.assertRaises(PreflightError):
            verify_installation(evidence, runner=self.fixture.run)
        (evidence / 'install.json').write_text(json.dumps({'didError': False, 'data': {
            'summary': {'status': 'SUCCEEDED'}, 'artifacts': {'deviceId': DEVICE, 'appPath': str(self.fixture.app)}}}))
        self.fixture.installed = {'bundleIdentifier': QA_BUNDLE, 'version': '1.0', 'bundleVersion': '17'}
        with self.assertRaises(PreflightError):
            verify_installation(evidence, runner=self.fixture.run)
