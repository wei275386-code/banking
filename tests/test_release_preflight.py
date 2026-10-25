import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from scripts.release_preflight import preflight
from release.source_contract import GitSource, load_inputs
from release.validation import ContractError, validate


class ReleaseRepository:
    """Small committed synthetic repository; no real workspace inputs."""
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / 'repo'
        self.root.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'synthetic@example.invalid')
        self.git('config', 'user.name', 'Synthetic Fixture')
        source = Path(__file__).resolve().parents[1] / 'release'
        (self.root / 'release').mkdir()
        for name in ('source-allowlist.schema.json', 'dependencies.schema.json',
                     'default-config.schema.json',
                     'source-provenance.schema.json', 'default-config.json'):
            shutil.copyfile(source / name, self.root / 'release' / name)
        project = Path(__file__).resolve().parents[1]
        self.version = json.loads((project / 'config/release-version.json').read_text())
        (self.root / 'schemas/release').mkdir(parents=True)
        for name in ('release-version.schema.json', 'common.schema.json'):
            shutil.copyfile(project / 'schemas/release' / name, self.root / 'schemas/release' / name)
        self.write('config/release-version.json', self.version)
        self.write('release/dependencies.json', {
            'status': 'pending',
            'native': {'status': 'pending', 'lock': None},
            'python': {'status': 'pending', 'lock': None},
            'node': {'status': 'pending', 'lock': None},
            'pipeline': [{'id': 'empty-bootstrap', 'status': 'pending'}]})
        self.write('scripts/entry.py', "print('synthetic source')\n", raw=True)
        self.write('tests/synthetic.json', {'synthetic': True})
        self.paths = sorted(['scripts/entry.py', 'config/release-version.json'] +
                            ['release/' + p.name for p in (self.root / 'release').iterdir()] +
                            ['release/source-allowlist.json', 'schemas/release/release-version.schema.json', 'schemas/release/common.schema.json'])
        self.write_allowlist()
        self.write('config/fire-parameters.json', {'private': 'credential-secret-123'})
        self.write('outputs/private.json', {'private': 'credential-secret-123'})
        self.write('.xcodebuildmcp/config.yaml', 'private-fixed-device', raw=True)
        self.write('native/FamilyReviewIOS/Seed/private.json', {'private': True})
        self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args],
                                       stderr=subprocess.DEVNULL, timeout=20)

    def write(self, name, value, raw=False):
        target = self.root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value if raw else json.dumps(value), encoding='utf-8')

    def write_allowlist(self):
        self.write('release/source-allowlist.json', {
            'version_config': 'config/release-version.json',
            'defaults': [{'path': 'release/default-config.json', 'schema': 'release/default-config.schema.json'}],
            'profiles': {'production': self.paths, 'dev-tests': ['tests/synthetic.json']}})

    def commit(self):
        self.git('add', '--all')
        self.git('commit', '-qm', 'synthetic fixture')
        return self.git('rev-parse', 'HEAD').decode().strip()

    def close(self):
        self.temporary.cleanup()


class ReleasePreflightTests(unittest.TestCase):
    def setUp(self):
        self.fixture = ReleaseRepository()
        self.addCleanup(self.fixture.close)

    def inspect(self):
        return preflight(self.fixture.root, tools={}, signing={'developer_id_application': False, 'apple_distribution': False})

    def test_pending_dependencies_and_distribution_never_pass(self):
        report = self.inspect()
        self.assertEqual(report['release_status'], 'candidate')
        self.assertEqual(report['source_inputs_status'], 'valid')
        self.assertEqual(report['preflight_status'], 'blocked')
        self.assertIn('native_lock_pending', report['failures'])
        self.assertIn('python_lock_pending', report['failures'])
        self.assertIn('required_signing_identity_unavailable', report['failures'])
        self.assertNotIn('credential-secret-123', json.dumps(report))

    def test_preflight_is_read_only_and_detects_dirty(self):
        self.fixture.write('scripts/entry.py', '# changed', raw=True)
        before = {p.relative_to(self.fixture.root): p.read_bytes() for p in self.fixture.root.rglob('*') if p.is_file() and '.git' not in p.parts}
        report = self.inspect()
        after = {p.relative_to(self.fixture.root): p.read_bytes() for p in self.fixture.root.rglob('*') if p.is_file() and '.git' not in p.parts}
        self.assertEqual(before, after)
        self.assertIn('dirty_checkout', report['failures'])

    def test_missing_committed_input_fails_even_when_untracked_file_exists(self):
        self.fixture.paths.append('scripts/missing.py')
        self.fixture.write_allowlist()
        self.fixture.commit()
        self.fixture.write('scripts/missing.py', '# untracked substitute', raw=True)
        report = self.inspect()
        self.assertIn('missing_committed_input:scripts/missing.py', report['failures'])

    def test_invalid_version_does_not_escape_schema(self):
        self.fixture.version['build_number'] = True
        self.fixture.write('config/release-version.json', self.fixture.version)
        self.fixture.commit()
        self.assertIn('invalid_version_config', self.inspect()['failures'])

    def test_private_defaults_cannot_enter_through_unknown_fields(self):
        self.fixture.write('release/default-config.json', {'personal_data': False, 'assets': [123]})
        self.fixture.commit()
        self.assertTrue(any(f.startswith('schema_') for f in self.inspect()['failures']))

    def test_local_import_closure_reports_missing_source(self):
        self.fixture.write('scripts/entry.py', 'import helper\n', raw=True)
        self.fixture.write('scripts/helper.py', '# dependency', raw=True)
        self.fixture.commit()
        self.assertIn('python_input_missing:scripts/helper.py', self.inspect()['failures'])

    def test_unknown_channel_and_invalid_commit_rejected(self):
        self.assertEqual(preflight(self.fixture.root, channel='secret')['failures'], ['invalid_channel'])
        with self.assertRaisesRegex(ContractError, 'invalid_commit'):
            GitSource(self.fixture.root, '--help')

    def test_validator_rejects_unknown_schema_constraints(self):
        with self.assertRaisesRegex(ContractError, 'schema_unsupported'):
            validate({}, {'not': {}})


class LockedReleasePreflightTests(unittest.TestCase):
    def setUp(self):
        self.fixture = ReleaseRepository()
        self.addCleanup(self.fixture.close)
        self.tools = {
            'xcodebuild': {'available': True, 'version': '26.3', 'sha256': '1' * 64, 'build': '17C529'},
            'swift': {'available': True, 'version': '6.2.4', 'sha256': '2' * 64},
            'xcodegen': {'available': True, 'version': '2.46.0', 'sha256': '3' * 64},
            'sdks': {name: {'available': True, 'version': '26.2', 'settings_sha256': digit * 64}
                     for name, digit in [('MacOSX', '4'), ('iPhoneOS', '5')]}}
        self.native = {
            'status': 'locked_inventory', 'xcode_build': '17C529',
            'tools': {name: {'version': self.tools[name]['version'], 'sha256': self.tools[name]['sha256']}
                      for name in ('xcodebuild', 'swift', 'xcodegen')},
            'sdks': [{'platform': name, 'version': value['version'],
                      'settings_sha256': value['settings_sha256'], 'hash_kind': 'SDKSettings.plist_bytes'}
                     for name, value in self.tools['sdks'].items()]}
        artifact = {'version': '1.2.3', 'url': 'https://artifacts.example.invalid/a.whl',
                    'sha256': 'a' * 64, 'size': 100}
        self.python = {'python': dict(artifact), 'wheels': [dict(artifact, name='pillow')],
                       'processor_scripts': ['scripts/entry.py']}
        self.declaration = {'status': 'locked',
                            'native': {'status': 'locked', 'lock': 'release/native-toolchain.json'},
                            'python': {'status': 'locked', 'lock': 'release/runtime-lock.json', 'direct_dependencies': ['pillow']},
                            'node': {'status': 'locked', 'lock': 'package-lock.json', 'scope': 'development-only'},
                            'pipeline': [{'id': 'final-acceptance', 'status': 'pending'}]}
        self.fixture.paths += ['release/native-toolchain.json', 'release/runtime-lock.json']
        self.fixture.write_allowlist()
        self.persist()

    def persist(self):
        self.fixture.write('release/native-toolchain.json', self.native)
        self.fixture.write('release/runtime-lock.json', self.python)
        self.fixture.write('release/dependencies.json', self.declaration)
        self.fixture.commit()

    def inspect(self):
        return preflight(self.fixture.root, tools=self.tools,
                         signing={'developer_id_application': True, 'apple_distribution': False})

    def test_inventory_matches_but_acceptance_remains_candidate(self):
        import hashlib
        report = self.inspect()
        self.assertEqual(report['preflight_status'], 'blocked')
        self.assertEqual(report['failures'], ['pipeline_pending:final-acceptance'])
        self.assertEqual(report['release_status'], 'candidate')
        self.assertEqual(report['lock_document_sha256']['native'],
                         hashlib.sha256((self.fixture.root / 'release/native-toolchain.json').read_bytes()).hexdigest())

    def test_raw_lock_hash_changes_when_only_json_whitespace_changes(self):
        first = self.inspect()['lock_document_sha256']['python']
        self.fixture.write('release/runtime-lock.json', json.dumps(self.python, indent=3) + '\n', raw=True)
        self.fixture.commit()
        second = self.inspect()['lock_document_sha256']['python']
        self.assertNotEqual(first, second)

    def test_version_binary_build_and_sdk_mismatches_are_distinct(self):
        self.tools['swift']['version'] = '6.2.5'
        self.tools['xcodegen']['sha256'] = 'f' * 64
        self.tools['xcodebuild']['build'] = '17C530'
        self.tools['sdks']['MacOSX']['settings_sha256'] = 'e' * 64
        self.tools['sdks']['iPhoneOS']['version'] = '26.3'
        failures = self.inspect()['failures']
        for code in ('toolchain_version_mismatch_swift', 'toolchain_sha256_mismatch_xcodegen',
                     'toolchain_xcode_build_mismatch', 'toolchain_sdk_sha256_mismatch_MacOSX',
                     'toolchain_sdk_version_mismatch_iPhoneOS'):
            self.assertIn(code, failures)

    def test_runtime_artifact_size_sha_and_url_validation(self):
        for field, value in [('size', True), ('size', 0), ('sha256', 'unverified'),
                             ('url', 'https://secret:credential@example.invalid/a')]:
            with self.subTest(field=field, value=value):
                previous = self.python['python'][field]
                self.python['python'][field] = value
                self.persist()
                self.assertIn('python_lock_artifact_incomplete', self.inspect()['failures'])
                self.python['python'][field] = previous

    def test_pep503_dependency_names_match_and_alias_duplicates_are_rejected(self):
        self.python['wheels'][0]['name'] = 'Pillow'
        self.persist()
        self.assertNotIn('python_lock_dependency_closure_missing', self.inspect()['failures'])
        self.python['wheels'].append(dict(self.python['wheels'][0], name='pillow'))
        self.persist()
        self.assertIn('python_lock_dependency_closure_missing', self.inspect()['failures'])

    def test_missing_app_processor_input_cannot_hide_in_source_package(self):
        self.python['processor_scripts'].append('scripts/build-tool-not-selected.py')
        self.persist()
        self.assertIn('python_lock_processor_input_not_allowlisted', self.inspect()['failures'])

    def test_discovery_reports_real_executable_and_sdk_byte_hash_without_paths(self):
        import hashlib
        import plistlib
        from unittest.mock import patch
        from scripts.release_preflight import discover_tools
        developer = self.fixture.root / 'SyntheticXcode/Contents/Developer'
        files = {'xcodebuild': developer / 'usr/bin/xcodebuild',
                 'swift': developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift',
                 'xcodegen': self.fixture.root / 'tools/xcodegen'}
        for name, path in files.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('synthetic binary ' + name).encode())
        for platform in ('MacOSX', 'iPhoneOS'):
            path = developer / ('Platforms/' + platform + '.platform/Developer/SDKs/' + platform + '.sdk/SDKSettings.plist')
            path.parent.mkdir(parents=True)
            path.write_bytes(plistlib.dumps({'Version': '26.2'}))
        outputs = {'xcodebuild': 'Xcode 26.3\nBuild version 17C529\n',
                   'swift': 'Apple Swift version 6.2.4 (swiftlang-synthetic)\nTarget: arm64-apple-macosx14.0\n',
                   'xcodegen': 'Version: 2.46.0\n'}
        def command(argv, **kwargs):
            if argv == ['xcode-select', '-p']:
                return subprocess.CompletedProcess(argv, 0, str(developer) + '\n')
            return subprocess.CompletedProcess(argv, 0, outputs[Path(argv[0]).name])
        with patch('scripts.release_preflight.subprocess.run', side_effect=command), \
                patch('scripts.release_preflight.shutil.which', return_value=str(files['xcodegen'])):
            report = discover_tools()
        self.assertEqual(report['swift']['version'], '6.2.4')
        self.assertEqual(report['xcodebuild']['build'], '17C529')
        self.assertEqual(report['swift']['sha256'], hashlib.sha256(files['swift'].read_bytes()).hexdigest())
        self.assertEqual(report['sdks']['MacOSX']['version'], '26.2')
        self.assertNotIn(str(self.fixture.root), json.dumps(report))
