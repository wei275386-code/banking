"""Build-only command/receipt tests; subprocesses and hardware are fixtures."""
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import sys
from pathlib import Path
from unittest.mock import patch

from test_ios_first_install import DeviceFixture, DEVICE, UDID, TEAM
from scripts.build_ios_app import ARTIFACT_SCHEME, QA_SWIFT_CONDITIONS, build_qa, finish_build
from scripts.generate_release_inputs import generate, load_version
from scripts.ios_artifact import DistributionGate, PreflightError
from scripts.ios_artifact import controlled_environment

ROOT = Path(__file__).resolve().parents[1]


class BuildArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.fixture = DeviceFixture(self.root)
        self.code = self.root / 'code'; (self.code / 'config').mkdir(parents=True)
        shutil.copyfile(ROOT / 'config/release-version.json', self.code / 'config/release-version.json')
        version = load_version(self.code)
        self.fixture.info.update(CFBundleShortVersionString=version['app_version'],
                                 CFBundleVersion=str(version['build_number']))
        self.fixture.write_info()
        self.work = self.root / 'work'
        self.generated = []
        self.commands = []

    def tearDown(self):
        self.temp.cleanup()

    def generator(self, root, **arguments):
        self.generated.append(arguments)
        folder = root / 'native/FamilyReviewIOS'; folder.mkdir(parents=True, exist_ok=True)
        spec = folder / 'project.generated.yml'; spec.write_text(
            'name: FamilyReview\ntargets: {}\nschemes:\n  FamilyReview:\n    test:\n      targets: [FamilyReviewUITests]\n')
        generated = folder / 'Generated'; (generated / 'Bootstrap').mkdir(parents=True)
        version = load_version(root)
        for relative in ('release-version.json', 'Bootstrap/release-version.json'):
            (generated / relative).write_text(json.dumps(version))
        (generated / 'Bootstrap/bootstrap.json').write_text(json.dumps({
            'kind': 'empty', 'workspace_created': False}))
        return {'project_spec': str(spec)}

    def runner(self, command):
        if command[:2] == ['xcodegen', 'generate']:
            # Model real XcodeGen's source-root Info.plist output, distinct from
            # the project-root paths read later by the Xcode build.
            root = Path(command[command.index('--project-root') + 1])
            info = dict(self.fixture.info, CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)')
            (root / 'Generated/Info.plist').write_bytes(plistlib.dumps(info))
        return self.fixture.run(command)

    def complete_worker(self, command, **options):
        self.commands.append(command)
        self.assertNotIn('install', command)
        self.assertNotIn('build-and-run', command)
        for relative in ('Generated/Info.plist', 'Generated/release-version.json',
                         'Generated/Bootstrap/bootstrap.json', 'Generated/Bootstrap/release-version.json'):
            self.assertTrue((self.work / 'Project' / relative).is_file(), relative)
        app = self.work / 'DerivedData/Build/Products/Release-iphoneos/FamilyReview.app'
        app.parent.mkdir(parents=True)
        shutil.copytree(self.fixture.app, app)
        request = json.loads(command[command.index('--json') + 1])
        options['stdout'].write(json.dumps({'didError': False, 'data': {
            'summary': {'status': 'SUCCEEDED'}, 'request': request}})); options['stdout'].flush()
        class Worker:
            pid = 1234
            returncode = 0
            def wait(self, timeout):
                return 0
        return Worker()

    def build(self, launcher=None):
        return build_qa(self.code, self.work, DEVICE, TEAM, runner=self.runner,
            launcher=launcher or self.complete_worker, generator=self.generator)

    def test_build_publishes_verified_artifact_without_install_or_launch(self):
        result = self.build()
        self.assertEqual(result['status'], 'artifact-ready')
        self.assertEqual(self.generated, [{'team': TEAM, 'qa': True}])
        self.assertFalse(result['installed']); self.assertFalse(result['launched'])
        self.assertFalse(result['distribution_ready'])
        arguments = json.loads(self.commands[0][self.commands[0].index('--json') + 1])
        self.assertEqual(arguments['configuration'], 'Release')
        self.assertEqual(arguments['scheme'], ARTIFACT_SCHEME)
        self.assertNotIn('deviceId', arguments)
        self.assertNotIn('buildForTesting', arguments)
        isolated_spec = (self.work / 'Project/project.artifact-qa.yml').read_text()
        self.assertNotIn('    test:', isolated_spec)
        self.assertIn(QA_SWIFT_CONDITIONS, arguments['extraArgs'])
        self.assertTrue(arguments['projectPath'].startswith(str(self.work / 'Project')))
        self.assertTrue(arguments['derivedDataPath'].startswith(str(self.work)))
        self.assertTrue(Path(result['app_path']).is_dir())
        self.assertEqual(len(result['generated_inputs']), 4)
        self.assertEqual(finish_build(self.work, runner=self.fixture.run), result)

    def test_pending_build_resumes_without_relaunch(self):
        calls = []
        class Worker:
            pid = 1234
            returncode = None
            def wait(self, timeout):
                raise subprocess.TimeoutExpired('controlled build', timeout)
        def launcher(command, **options):
            calls.append(command)
            return Worker()
        result = self.build(launcher)
        self.assertEqual(result['status'], 'building')
        self.assertEqual(finish_build(self.work, runner=self.fixture.run)['status'], 'building')
        self.assertEqual(len(calls), 1)
        with self.assertRaises(PreflightError):
            self.build(launcher)
        self.assertEqual(len(calls), 1)

    def test_build_worker_runs_with_a_fixed_environment(self):
        observed = []
        def launcher(command, **options):
            neutral = subprocess.run([sys.executable, '-c',
                'import json,os; print(json.dumps(dict(os.environ)))'],
                check=True, capture_output=True, timeout=5, env=options['env'])
            observed.append(json.loads(neutral.stdout))
            return self.complete_worker(command, **options)
        with patch.dict(os.environ, {'DYLD_LIBRARY_PATH': '/synthetic/libraries',
                'PYTHONPATH': '/synthetic/python', 'BANKING_VIDEO_HELPER': '/synthetic/helper',
                'DEVELOPER_DIR': '/synthetic/Xcode', 'HOME': '/synthetic/home',
                'USER': 'untrusted-user', 'LOGNAME': 'untrusted-login'}):
            result = self.build(launcher)
            expected = controlled_environment()
        self.assertEqual(result['status'], 'artifact-ready')
        self.assertEqual(len(observed), 1)
        self.assertFalse(any(key.startswith(('DYLD', 'PYTHON', 'BANKING')) for key in observed[0]))
        self.assertNotIn('DEVELOPER_DIR', observed[0])
        import pwd
        account = pwd.getpwuid(os.getuid())
        self.assertEqual(observed[0]['USER'], account.pw_name)
        self.assertEqual(observed[0]['LOGNAME'], account.pw_name)
        self.assertEqual({key: observed[0][key] for key in expected}, expected)

    def test_distribution_channels_remain_external_gates(self):
        for channel in ('testflight', 'app-store', 'ad-hoc'):
            with self.assertRaises(DistributionGate):
                build_qa(self.code, self.work, DEVICE, TEAM, channel=channel,
                    runner=self.fixture.run, generator=self.generator)
        self.assertEqual(self.fixture.calls, [])
        self.assertFalse(self.work.exists())

    def test_invalid_team_aborts_before_generation_or_build(self):
        with self.assertRaises(PreflightError):
            build_qa(self.code, self.work, DEVICE, '', runner=self.fixture.run,
                     launcher=self.complete_worker, generator=self.generator)
        self.assertEqual(self.generated, []); self.assertEqual(self.commands, [])

    def test_artifact_tamper_after_publication_is_detected(self):
        result = self.build()
        (Path(result['app_path']) / 'Fixture').write_bytes(b'changed')
        with self.assertRaises(PreflightError):
            finish_build(self.work, runner=self.fixture.run)

    def test_failed_build_cannot_publish_artifact(self):
        class Worker:
            pid = 1234
            returncode = 1
            def wait(self, timeout):
                return 1
        with self.assertRaises(PreflightError):
            self.build(lambda *args, **options: Worker())
        self.assertFalse((self.work / 'artifacts').exists())

    def test_public_generated_resource_closure_uses_real_generator(self):
        folder = self.code / 'native/FamilyReviewIOS'; folder.mkdir(parents=True)
        shutil.copyfile(ROOT / 'native/FamilyReviewIOS/project.yml', folder / 'project.yml')
        result = build_qa(self.code, self.work, DEVICE, TEAM, runner=self.runner,
            launcher=self.complete_worker, generator=generate)
        self.assertEqual(result['status'], 'artifact-ready')
        self.assertFalse((self.work / 'Project/Seed').exists())
        for relative in result['generated_inputs']:
            self.assertEqual((self.work / 'Project' / relative).read_bytes(),
                             (folder / relative).read_bytes())
        production = generate(self.code, team=TEAM, qa=False)
        spec = Path(production['project_spec']).read_text()
        self.assertNotIn('FAMILY_REVIEW_QA', spec)
        self.assertNotIn('ReleaseQA', spec)

    def test_build_for_testing_requires_explicit_opt_in_and_fresh_udid(self):
        result = build_qa(self.code, self.work, DEVICE, TEAM, build_for_testing=True,
            runner=self.runner, launcher=self.complete_worker, generator=self.generator)
        arguments = json.loads(self.commands[0][self.commands[0].index('--json') + 1])
        self.assertTrue(arguments['buildForTesting'])
        self.assertEqual(arguments['deviceId'], UDID)
        self.assertEqual(arguments['scheme'], 'FamilyReview')
        self.assertTrue(result['build_for_testing'])

    def test_missing_generated_resource_aborts_before_builder(self):
        def generator(root, **arguments):
            result = self.generator(root, **arguments)
            Path(result['project_spec']).parent.joinpath('Generated/Bootstrap/release-version.json').unlink()
            return result
        with self.assertRaises(FileNotFoundError):
            build_qa(self.code, self.work, DEVICE, TEAM, runner=self.runner,
                launcher=self.complete_worker, generator=generator)
        self.assertEqual(self.commands, [])
