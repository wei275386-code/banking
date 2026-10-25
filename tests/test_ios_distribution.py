"""Formal local archive/export gates and async receipts; no signing or upload."""
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from scripts.archive_ios_release import (SCHEME, archive_request, export_archive,
    exclusive_work, finish, inspect_ipa, start_archive, worker)
from scripts.tool_locations import tool_path
from scripts.generate_release_inputs import load_version
from scripts.ios_artifact import DistributionGate, PreflightError, sha256
from scripts.ios_distribution import (DistributionConfig, export_options,
    controlled_environment, inspect_distribution_app, preflight, run,
    source_proof, validate_profile)

ROOT = Path(__file__).resolve().parents[1]
TEAM = 'ABCDEFGHIJ'
UUID = '11111111-2222-3333-4444-555555555555'
UDID = '00000000-0000000000000000'
CERT = b'fixture-distribution-certificate'
SHA1 = hashlib.sha1(CERT).hexdigest().upper()
NOW = datetime(2026, 10, 14, tzinfo=timezone.utc)


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.code = self.base / 'code'; (self.code / 'config').mkdir(parents=True)
        shutil.copyfile(ROOT / 'config/release-version.json', self.code / 'config/release-version.json')
        self.version = load_version(self.code)
        self.home = self.base / 'home'
        folder = self.home / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
        folder.mkdir(parents=True)
        self.profile_path = folder / (UUID + '.mobileprovision')
        self.profile_path.write_bytes(b'fixture signed profile bytes')
        self.config = DistributionConfig.decode({'channel': 'testflight', 'team': TEAM,
            'certificate_sha1': SHA1, 'profile_path': str(self.profile_path),
            'profile_uuid': UUID, 'app_store_app_id': '123456789'})
        self.profile = {'UUID': UUID, 'TeamIdentifier': [TEAM],
            'CreationDate': NOW - timedelta(days=1), 'ExpirationDate': NOW + timedelta(days=90),
            'DeveloperCertificates': [CERT], 'Entitlements': {
                'application-identifier': TEAM + '.' + self.config.bundle_id,
                'com.apple.developer.team-identifier': TEAM, 'get-task-allow': False}}
        self.developer = self.base / 'Xcode/Contents/Developer'
        tool = self.developer / 'usr/bin/xcodebuild'; tool.parent.mkdir(parents=True); tool.write_text('fixture')
        swift = self.developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'
        swift.parent.mkdir(parents=True); swift.write_text('fixture swift')
        self.xcodegen = self.base / 'xcodegen'; self.xcodegen.write_text('fixture xcodegen')
        sdk_records = []
        for platform in ('MacOSX', 'iPhoneOS'):
            settings = self.developer / ('Platforms/' + platform + '.platform/Developer/SDKs/' + platform + '.sdk/SDKSettings.plist')
            settings.parent.mkdir(parents=True); settings.write_bytes(plistlib.dumps({'Version': '26.2'}))
            sdk_records.append({'platform': platform, 'version': '26.2', 'settings_sha256': sha256(settings)})
        release = self.code / 'release'; release.mkdir()
        (release / 'native-toolchain.json').write_text(json.dumps({'xcode_build': '17C529',
            'tools': {name: {'version': 'fixture-version', 'sha256': sha256(path)} for name, path in
                [('xcodebuild', tool), ('swift', swift), ('xcodegen', self.xcodegen)]}, 'sdks': sdk_records}))
        (release / 'runtime-lock.json').write_text(json.dumps({'runtime_version': 'cpython-3.13.9-pbs-20251014-lock1'}))
        native = self.code / 'native'; (native / 'FamilyReviewIOS/FamilyReviewApp').mkdir(parents=True)
        (native / 'FamilyReviewIOS/FamilyReviewApp/App.swift').write_text('import Foundation\n')
        (native / 'FamilyReviewIOS/project.yml').write_text('fixture project template\n')
        (native / 'PaymentImageCore').mkdir(); (native / 'PaymentImageCore/Package.swift').write_text('// fixture package\n')
        (self.code / 'scripts').mkdir()
        for name in ('archive_ios_release.py', 'ios_distribution.py'):
            shutil.copyfile(ROOT / 'scripts' / name, self.code / 'scripts' / name)
        names = [path.relative_to(self.code).as_posix() for path in self.code.rglob('*') if path.is_file()]
        (release / 'source-allowlist.json').write_text(json.dumps({'profiles': {'production': sorted(names + ['release/source-allowlist.json'])}}))
        self.git('init', '-q'); self.git('add', '.'); self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture source')
        self.which_patch = patch('scripts.ios_distribution.tool_path', side_effect=lambda name, **options:
            str(self.xcodegen) if name == 'xcodegen' else tool_path(name, **options))
        self.which_patch.start()
        self.work = self.base / 'work'
        self.calls = []; self.launches = []; self.generated = []
        self.identities = f' 1) {SHA1} "Apple Distribution: Example ({TEAM})"\n 1 valid identities found\n'
        self.home_patch = patch('scripts.ios_distribution.Path.home', return_value=self.home)
        self.home_patch.start()

    def tearDown(self):
        self.which_patch.stop(); self.home_patch.stop(); self.temp.cleanup()

    def git(self, *args):
        return subprocess.run([tool_path('git', system=True), '-C', str(self.code), *args], check=True,
            capture_output=True, timeout=20, env=controlled_environment())

    def runner(self, command):
        self.calls.append(command)
        output = b''
        if command[:2] == ['security', 'find-identity']:
            output = self.identities.encode()
        elif command[:2] == ['security', 'cms']:
            output = plistlib.dumps(self.profile)
        elif command[:2] == ['openssl', 'x509']:
            output = b'notBefore=Oct  1 00:00:00 2026 GMT\nnotAfter=Oct  1 00:00:00 2027 GMT\n'
        elif command[:2] == ['xcode-select', '-p']:
            output = str(self.developer).encode()
        elif command[:2] == ['xcodegen', 'generate']:
            source = Path(command[command.index('--project-root') + 1])
            (source / 'Generated/Info.plist').write_bytes(plistlib.dumps(self.info()))
            project = Path(command[command.index('--project') + 1]) / 'FamilyReview.xcodeproj'
            project.mkdir(); (project / 'project.pbxproj').write_text('fixture project')
        elif command[:2] == ['lipo', '-archs']:
            output = b'arm64\n'
        elif command[:3] == ['codesign', '-d', '--entitlements']:
            output = plistlib.dumps(self.profile['Entitlements'])
        elif command[:2] == ['codesign', '-d'] and command[2].startswith('--extract-certificates='):
            Path(command[2].split('=', 1)[1] + '0').write_bytes(CERT)
        elif command[:2] != ['codesign', '--verify']:
            self.fail('Unexpected external command: ' + repr(command))
        return subprocess.CompletedProcess(command, 0, output, b'')

    def info(self):
        return {'CFBundleIdentifier': self.config.bundle_id,
            'CFBundleShortVersionString': self.version['app_version'],
            'CFBundleVersion': str(self.version['build_number']), 'CFBundlePackageType': 'APPL',
            'CFBundleSupportedPlatforms': ['iPhoneOS'], 'UIDeviceFamily': [1],
            'MinimumOSVersion': self.version['ios_minimum'], 'CFBundleExecutable': 'FamilyReview'}

    def generator(self, root, **arguments):
        self.generated.append(arguments)
        folder = root / 'native/FamilyReviewIOS'; (folder / 'Generated/Bootstrap').mkdir(parents=True)
        spec = folder / 'project.generated.yml'
        spec.write_text('name: FamilyReview\ntargets: {}\nschemes:\n  FamilyReview:\n    run:\n      config: Release\n')
        for name in ('release-version.json', 'Bootstrap/release-version.json'):
            (folder / 'Generated' / name).write_text(json.dumps(self.version))
        (folder / 'Generated/Bootstrap/bootstrap.json').write_text(json.dumps({
            'kind': 'empty', 'workspace_created': False}))
        return {'project_spec': str(spec)}

    def launcher(self, command, **options):
        self.launches.append(command)
        self.assertEqual(options['env'], controlled_environment())
        self.assertEqual(options['cwd'], self.work / 'Source')
        self.assertIn('-I', command)
        class Pending:
            pid = 1234
            def wait(self, timeout):
                raise subprocess.TimeoutExpired('fixture', timeout)
        return Pending()

    def begin(self):
        return start_archive(self.code, self.work, self.config, runner=self.runner,
                             launcher=self.launcher, generator=self.generator)

    def app(self, destination):
        destination.mkdir(parents=True)
        (destination / 'Info.plist').write_bytes(plistlib.dumps(self.info()))
        (destination / 'FamilyReview').write_bytes(b'fixture executable')
        shutil.copyfile(self.profile_path, destination / 'embedded.mobileprovision')
        (destination / 'Bootstrap').mkdir()
        (destination / 'Bootstrap/bootstrap.json').write_text(json.dumps({
            'kind': 'empty', 'workspace_created': False}))
        (destination / 'Bootstrap/release-version.json').write_text(json.dumps(self.version))
        return destination

    def complete_archive(self, *, code=0, archive=True):
        receipt = json.loads((self.work / 'distribution-receipt.json').read_text())
        (self.work / 'archive-result.json').write_text(json.dumps({
            'phase': 'archive', 'plan_sha256': receipt['plan_sha256'], 'returncode': code}))
        (self.work / 'archive-stdout.log').write_text(json.dumps({'didError': False,
            'data': {'summary': {'status': 'SUCCEEDED'}, 'request': receipt['archive_request']}}))
        if archive:
            destination = self.work / 'FamilyReview.xcarchive'
            self.app(destination / 'Products/Applications/FamilyReview.app')
            (destination / 'Info.plist').write_bytes(plistlib.dumps({
                'ApplicationProperties': {'ApplicationPath': 'Applications/FamilyReview.app'}}))

    def complete_export(self, *, code=0):
        receipt = json.loads((self.work / 'distribution-receipt.json').read_text())
        (self.work / 'export-result.json').write_text(json.dumps({
            'phase': 'export', 'plan_sha256': receipt['plan_sha256'], 'returncode': code}))
        output = self.work / 'Export'; output.mkdir()
        source = self.app(self.base / 'ipa-source/Payload/FamilyReview.app')
        with zipfile.ZipFile(output / 'FamilyReview.ipa', 'w') as archive:
            for path in source.rglob('*'):
                if path.is_file():
                    archive.write(path, path.relative_to(self.base / 'ipa-source').as_posix())

    def test_typed_config_rejects_credentials_selectors_and_missing_account(self):
        value = self.config.document()
        for change in ({'api_key': 'SECRET'}, {'certificate_sha1': 'Apple Distribution'},
                       {'app_store_app_id': None}, {'bundle_id': self.config.bundle_id + '.ReleaseQA'},
                       {'device_ids': [{}]}, {'channel': 'enterprise'}):
            with self.subTest(change=change), self.assertRaises(PreflightError):
                DistributionConfig.decode({**value, **change})

    def test_readonly_preflight_does_not_create_work_or_start_tools(self):
        result = preflight(self.code, self.config, runner=self.runner)
        self.assertFalse(result['uploaded']); self.assertFalse(result['distribution_ready'])
        self.assertFalse(self.work.exists()); self.assertEqual(self.launches, [])
        self.assertNotIn('xcodegen', [cmd[0] for cmd in self.calls])

    def test_missing_distribution_private_key_fails_before_generation_or_work(self):
        self.identities = '0 valid identities found\n'
        with self.assertRaises(DistributionGate):
            self.begin()
        self.assertFalse(self.work.exists()); self.assertEqual(self.generated, []); self.assertEqual(self.launches, [])

    def test_wrong_team_or_development_identity_is_not_distribution(self):
        for name in ('Apple Development', 'Apple Distribution'):
            self.identities = f' 1) {SHA1} "{name}: Example (WRONGTEAM1)"\n'
            with self.assertRaises(DistributionGate):
                self.begin()

    def test_profile_scope_dates_and_certificate_fail_closed(self):
        for change in ({'ExpirationDate': NOW - timedelta(days=1)},
                       {'CreationDate': NOW + timedelta(days=1)}, {'DeveloperCertificates': [b'wrong']},
                       {'ProvisionedDevices': [UDID]}, {'ProvisionsAllDevices': True}, {'TeamIdentifier': ['WRONGTEAM1']}):
            with self.subTest(change=change), self.assertRaises(PreflightError):
                validate_profile({**self.profile, **change}, self.config, runner=self.runner, now=NOW)
        self.profile['Entitlements']['get-task-allow'] = True
        with self.assertRaises(PreflightError):
            self.begin()
        self.assertFalse(self.work.exists())

    def test_uninstalled_profile_is_not_imported_automatically(self):
        external = self.base / 'external.mobileprovision'; shutil.copyfile(self.profile_path, external)
        self.profile_path.unlink()
        config = DistributionConfig.decode({**self.config.document(), 'profile_path': str(external)})
        with self.assertRaises(DistributionGate):
            preflight(self.code, config, runner=self.runner)
        self.assertFalse(self.work.exists())

    def test_ad_hoc_requires_fresh_physical_udid_in_profile_and_config(self):
        config = DistributionConfig.decode({**self.config.document(), 'channel': 'ad-hoc',
            'device_ids': [UDID], 'app_store_app_id': None})
        self.profile['ProvisionedDevices'] = [UDID]
        with self.assertRaises(DistributionGate):
            preflight(self.code, config, runner=self.runner)
        current = {'udid': UDID, 'ios_version': '26.7', 'device_id': 'physical-device'}
        with patch('scripts.ios_distribution.inspect_device', return_value=current) as inspect:
            self.assertEqual(preflight(self.code, config, device='physical-device', runner=self.runner)['device'], current)
            inspect.assert_called_once()
        self.profile['ProvisionedDevices'] = ['WRONG']
        with self.assertRaises(PreflightError):
            validate_profile(self.profile, config, runner=self.runner, now=NOW)

    def test_archive_uses_cli_production_manual_signing_and_complete_resource_closure(self):
        result = self.begin()
        self.assertEqual(result['status'], 'archiving')
        self.assertEqual(self.generated, [{'team': TEAM, 'qa': False}])
        request = result['archive_request']
        self.assertEqual(request['scheme'], SCHEME)
        self.assertNotIn('deviceId', request); self.assertNotIn('buildForTesting', request)
        self.assertIn('archive', request['extraArgs'])
        self.assertIn('CODE_SIGN_STYLE=Manual', request['extraArgs'])
        self.assertIn('SWIFT_ACTIVE_COMPILATION_CONDITIONS=', request['extraArgs'])
        self.assertNotIn('FAMILY_REVIEW_QA', json.dumps(request))
        self.assertNotIn('allowProvisioningUpdates', json.dumps(request))
        self.assertEqual(len(result['generated_inputs']), 6)
        self.assertNotIn('test:', (self.work / 'Project/project.distribution.yml').read_text())
        self.assertEqual(finish(self.work, runner=self.runner)['status'], 'archiving')
        self.assertEqual(len(self.launches), 1)
        with self.assertRaises(PreflightError):
            self.begin()
        self.assertEqual(len(self.launches), 1)

    def test_cli_success_without_real_archive_never_claims_archive_ready(self):
        self.begin(); self.complete_archive(archive=False)
        with self.assertRaises(OSError):
            finish(self.work, runner=self.runner)

    def test_nonzero_archive_worker_aborts_even_with_success_json(self):
        self.begin(); self.complete_archive(code=65)
        with self.assertRaises(PreflightError):
            finish(self.work, runner=self.runner)
        self.assertEqual(json.loads((self.work / 'distribution-receipt.json').read_text())['status'], 'archiving')

    def test_generated_resource_tamper_prevents_success(self):
        self.begin(); self.complete_archive()
        (self.work / 'Project/Generated/Bootstrap/bootstrap.json').write_text('{}')
        with self.assertRaises(PreflightError):
            finish(self.work, runner=self.runner)

    def test_archive_verifies_production_and_repeated_verification_does_not_rebuild(self):
        self.begin(); self.complete_archive()
        result = finish(self.work, runner=self.runner)
        self.assertEqual(result['status'], 'archive-ready')
        self.assertEqual(result['archive_artifact']['certificate_sha1'], SHA1)
        self.assertEqual(finish(self.work, runner=self.runner), result)
        self.assertEqual(len(self.launches), 1)
        (self.work / 'FamilyReview.xcarchive/Info.plist').write_bytes(b'tamper')
        with self.assertRaises(PreflightError):
            finish(self.work, runner=self.runner)

    def test_export_manual_local_options_and_receipt_idempotence(self):
        self.begin(); self.complete_archive(); finish(self.work, runner=self.runner)
        result = export_archive(self.work, runner=self.runner, launcher=self.launcher)
        self.assertEqual(result['status'], 'exporting')
        options = plistlib.loads((self.work / 'ExportOptions.plist').read_bytes())
        self.assertEqual(options, export_options(self.config))
        self.assertEqual(options['destination'], 'export')
        self.assertEqual(options['method'], 'app-store-connect')
        plan = json.loads((self.work / 'export-plan.json').read_text())
        self.assertEqual(plan['command'][0], str(self.developer / 'usr/bin/xcodebuild'))
        self.assertIn('-exportArchive', plan['command']); self.assertNotIn('upload', plan['command'])
        with self.assertRaises(PreflightError):
            export_archive(self.work, runner=self.runner, launcher=self.launcher)
        self.complete_export()
        ready = finish(self.work, runner=self.runner)
        self.assertEqual(ready['status'], 'export-ready')
        self.assertFalse(ready['uploaded']); self.assertFalse(ready['installed']); self.assertFalse(ready['distribution_ready'])
        self.assertEqual(export_archive(self.work, runner=self.runner, launcher=self.launcher), ready)
        self.assertEqual(len(self.launches), 2)
        Path(ready['ipa_path']).write_bytes(b'tampered')
        with self.assertRaises(PreflightError):
            finish(self.work, runner=self.runner)

    def test_export_rechecks_signing_before_writing_options_or_launch(self):
        self.begin(); self.complete_archive(); finish(self.work, runner=self.runner)
        self.identities = '0 valid identities found'
        with self.assertRaises(DistributionGate):
            export_archive(self.work, runner=self.runner, launcher=self.launcher)
        self.assertFalse((self.work / 'ExportOptions.plist').exists()); self.assertEqual(len(self.launches), 1)

    def test_failed_export_never_claims_ready(self):
        self.begin(); self.complete_archive(); finish(self.work, runner=self.runner)
        export_archive(self.work, runner=self.runner, launcher=self.launcher); self.complete_export(code=70)
        with self.assertRaises(PreflightError):
            finish(self.work, runner=self.runner)

    def test_ipa_traversal_and_symlink_are_rejected(self):
        for symlink in (False, True):
            package = self.base / ('bad-' + str(symlink) + '.ipa')
            with zipfile.ZipFile(package, 'w') as archive:
                member = zipfile.ZipInfo('Payload/FamilyReview.app/file' if symlink else '../escape')
                if symlink:
                    member.external_attr = 0o120777 << 16
                archive.writestr(member, 'fixture')
            with self.assertRaises(PreflightError):
                inspect_ipa(package, self.config, self.version, runner=self.runner)

    def test_artifact_seed_wrong_version_or_debug_entitlements_are_rejected(self):
        app = self.app(self.base / 'artifact.app')
        (app / 'Seed').mkdir()
        with self.assertRaises(PreflightError):
            inspect_distribution_app(app, self.config, self.version, runner=self.runner)
        (app / 'Seed').rmdir()
        info = self.info(); info['CFBundleVersion'] = '999'
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        with self.assertRaises(PreflightError):
            inspect_distribution_app(app, self.config, self.version, runner=self.runner)

    def test_worker_refuses_upload_or_automatic_provisioning(self):
        plan = self.base / 'plan.json'
        for arg in ('upload', '-allowProvisioningUpdates', '-authenticationKeyPath'):
            plan.write_text(json.dumps({'phase': 'export', 'command': ['xcodebuild', arg]}))
            with patch('scripts.archive_ios_release.subprocess.run') as execute, self.assertRaises(PreflightError):
                worker(plan)
            execute.assert_not_called()

    def test_certificate_expiration_is_a_preflight_gate(self):
        def expired(command):
            if command[:2] == ['openssl', 'x509']:
                return subprocess.CompletedProcess(command, 0,
                    b'notBefore=Oct  1 00:00:00 2025 GMT\nnotAfter=Oct  1 00:00:00 2026 GMT\n', b'')
            return self.runner(command)
        with self.assertRaises(PreflightError):
            preflight(self.code, self.config, runner=expired)
        self.assertFalse(self.work.exists())

    def test_success_result_for_different_project_is_not_accepted(self):
        self.begin(); self.complete_archive()
        path = self.work / 'archive-stdout.log'; data = json.loads(path.read_text())
        data['data']['request']['projectPath'] = '/wrong/project.xcodeproj'
        path.write_text(json.dumps(data))
        with self.assertRaises(PreflightError):
            finish(self.work, runner=self.runner)

    def test_worker_rechecks_signing_before_any_local_tool_action(self):
        self.begin(); self.identities = '0 valid identities found'
        original = preflight
        with patch('scripts.archive_ios_release.preflight', side_effect=lambda root, config, **kwargs:
                   original(root, config, runner=self.runner)), patch('scripts.archive_ios_release.subprocess.run') as execute:
            with self.assertRaises(DistributionGate):
                worker(self.work / 'archive-plan.json')
        execute.assert_not_called()

    def test_bound_archive_and_export_workers_execute_only_original_local_commands(self):
        self.begin()
        original = preflight
        real_process = subprocess.run
        def check(root, config, **kwargs):
            return original(root, config, runner=self.runner)
        def archive_tool(command, **kwargs):
            if Path(command[0]).name == 'git':
                return real_process(command, **kwargs)
            self.assertEqual(command[:3], ['xcodebuildmcp', 'device', 'build'])
            self.complete_archive()
            return subprocess.CompletedProcess(command, 0)
        with patch('scripts.archive_ios_release.preflight', side_effect=check), patch(
                'scripts.archive_ios_release.subprocess.run', side_effect=archive_tool) as execute:
            worker(self.work / 'archive-plan.json')
            self.assertEqual(sum(call.args[0][0] == 'xcodebuildmcp' for call in execute.call_args_list), 1)
        finish(self.work, runner=self.runner)
        export_archive(self.work, runner=self.runner, launcher=self.launcher)
        def export_tool(command, **kwargs):
            if Path(command[0]).name == 'git':
                return real_process(command, **kwargs)
            self.assertEqual(command[0], str(self.developer / 'usr/bin/xcodebuild'))
            self.assertEqual(command[1], '-exportArchive')
            self.complete_export()
            return subprocess.CompletedProcess(command, 0)
        with patch('scripts.archive_ios_release.preflight', side_effect=check), patch(
                'scripts.archive_ios_release.subprocess.run', side_effect=export_tool) as execute:
            worker(self.work / 'export-plan.json')
            self.assertEqual(sum(call.args[0][0] == str(self.developer / 'usr/bin/xcodebuild') for call in execute.call_args_list), 1)
        self.assertEqual(finish(self.work, runner=self.runner)['status'], 'export-ready')

    def test_export_work_lock_prevents_second_initiation(self):
        self.begin(); self.complete_archive(); finish(self.work, runner=self.runner)
        with exclusive_work(self.work), self.assertRaises(PreflightError):
            export_archive(self.work, runner=self.runner, launcher=self.launcher)
        self.assertFalse((self.work / 'ExportOptions.plist').exists())
        self.assertEqual(len(self.launches), 1)

    def test_dirty_source_blocks_before_work_and_generator(self):
        path = self.code / 'native/FamilyReviewIOS/FamilyReviewApp/App.swift'
        path.write_text('uncommitted source edit\n')
        with self.assertRaises(PreflightError):
            self.begin()
        self.assertFalse(self.work.exists()); self.assertEqual(self.generated, []); self.assertEqual(self.launches, [])

    def test_ignored_unallowlisted_swift_cannot_enter_compiler(self):
        self.git('config', 'core.excludesFile', str(self.base / 'ignore'))
        (self.base / 'ignore').write_text('Unselected.swift\n')
        (self.code / 'native/FamilyReviewIOS/FamilyReviewApp/Unselected.swift').write_text('ignored swift\n')
        with self.assertRaises(PreflightError):
            self.begin()
        self.assertFalse(self.work.exists()); self.assertEqual(self.launches, [])

    def test_commit_or_snapshot_source_change_blocks_result_and_export_without_reissue(self):
        self.begin(); self.complete_archive()
        snapshot = self.work / 'Source/native/FamilyReviewIOS/FamilyReviewApp/App.swift'
        original = snapshot.read_bytes(); snapshot.write_text('changed isolated snapshot\n')
        with self.assertRaises(PreflightError):
            finish(self.work, runner=self.runner)
        snapshot.write_bytes(original); finish(self.work, runner=self.runner)
        source = self.code / 'native/FamilyReviewIOS/FamilyReviewApp/App.swift'
        source.write_text('changed selected commit source\n')
        with self.assertRaises(PreflightError):
            export_archive(self.work, runner=self.runner, launcher=self.launcher)
        self.assertEqual(len(self.launches), 1); self.assertFalse((self.work / 'ExportOptions.plist').exists())

    def test_locked_tool_or_sdk_change_blocks_before_archive(self):
        self.xcodegen.write_text('different executable')
        with self.assertRaises(PreflightError):
            self.begin()
        self.assertFalse(self.work.exists())

    def test_controlled_platform_environment_removes_code_injection(self):
        with patch.dict('os.environ', {'DYLD_INSERT_LIBRARIES': '/untrusted.dylib',
                'PYTHONPATH': '/untrusted-python', 'BANKING_VIDEO_HELPER': '/untrusted-helper',
                'DEVELOPER_DIR': '/untrusted-xcode', 'GIT_CONFIG_COUNT': '1'}), patch(
                'scripts.ios_distribution.subprocess.run', return_value=subprocess.CompletedProcess([], 0, b'', b'')) as execute:
            run(['security', 'find-identity', '-v', '-p', 'codesigning'])
        environment = execute.call_args.kwargs['env']
        self.assertEqual(environment, controlled_environment())
        self.assertFalse(any(key.startswith(('DYLD', 'PYTHON', 'BANKING', 'GIT_')) for key in environment))


if __name__ == '__main__':
    unittest.main()
