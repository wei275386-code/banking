"""Synthetic first-run and retained App update faults; production is untouched."""
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from scripts.workspace_initialization import create_workspace
from scripts.workspace_state import MaintenanceGate, _write, _read
from scripts.installation_health import health_check, runtime_health
from scripts.installation_inventory import InstallationError, POLICY
from scripts.release_contracts import canonical_json, digest_file
from scripts.distribute_macos_release import tree_digest
from scripts.update_macos_app import update


class InstallationHealthTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.paths = create_workspace(self.root / 'workspace')
        self.pointer = self.paths.read_pointer()

    def tearDown(self):
        self.temporary.cleanup()

    def doctor(self, paths, **kwargs):
        self.assertEqual(kwargs['expected_pointer'], self.paths.read_pointer())
        return {'source_pointer': self.pointer, 'operation_membership_verified': True,
                'full_backup_eligible': True, 'business_fingerprint': {}}

    def test_first_run_requires_actual_runtime_and_does_not_replay_journals(self):
        journal = next(self.paths.journals.glob('*.json'))
        value = _read(journal); value['target_pointer'] = None; value['phase'] = 'committed'
        value['expected_pointer'] = self.pointer
        _write(journal, value)
        before = journal.read_bytes()
        report = health_check(self.paths, doctor=self.doctor)
        self.assertTrue(report['writable'])
        self.assertFalse(report['runtime_verified'])
        self.assertFalse(report['processor_health_qualified'])
        self.assertFalse(report['cloud_authorization_granted'])
        self.assertEqual(report['task_journals'][journal.name], 'uncommitted-needs-review-no-replay')
        self.assertEqual(journal.read_bytes(), before)

    def test_actual_processor_journal_is_retained_and_qualified_without_public_envelope(self):
        from scripts.processor_result import execute_workspace
        from scripts.installation_health import _journal_health
        original = self.root / 'review.json'; original.write_bytes(b'{}')
        def action(transaction, retained):
            report = _read(transaction.review / 'financial-review.json')
            report['summary']['test_journal_value'] = 17
            transaction.write_json('review/financial-review.json', report)
            return {}
        with MaintenanceGate(self.paths).acquire('actual-journal') as token:
            result, code = execute_workspace(self.paths.workspace, self.pointer,
                'actual-operation', 'actual-request', None, action,
                [{'path': str(original), 'kind': 'review'}], token=token)
        self.assertEqual(code, 0, result)
        with MaintenanceGate(self.paths).acquire('actual-journal-retry') as token:
            repeated, code = execute_workspace(self.paths.workspace, self.pointer,
                'actual-operation', 'actual-request', None,
                lambda *args: self.fail('included request replayed'),
                [{'path': str(original), 'kind': 'review'}], token=token)
        self.assertEqual(code, 0, repeated)
        self.assertEqual(result, repeated)
        self.assertIn('no-op', [_read(p)['phase'] for p in self.paths.journals.glob('*.json')])
        journals = {p.name: p.read_bytes() for p in self.paths.journals.glob('*.json')}
        context = next(_read(p)['operation'] for p in self.paths.journals.glob('*.json')
                       if _read(p)['operation'] is not None)
        self.assertNotIn('version', context)
        pointer = self.paths.read_pointer()
        report = _journal_health(self.paths, pointer, current_operations=('actual-operation',))
        actual = next(p.name for p in self.paths.journals.glob('*.json') if _read(p)['operation'])
        self.assertEqual(report[actual], 'included-current')
        self.assertEqual(journals, {p.name: p.read_bytes() for p in self.paths.journals.glob('*.json')})
        with self.assertRaisesRegex(InstallationError, 'missing or corrupt input'):
            (self.paths.sources / context['inputs'][0]['sha256']).unlink()
            _journal_health(self.paths, pointer, current_operations=('actual-operation',))

    def test_internal_retaining_context_is_not_membership_and_invalid_hash_is_rejected(self):
        from scripts.installation_health import _journal_health
        journal = next(self.paths.journals.glob('*.json'))
        value = _read(journal)
        value.update(phase='failed', expected_pointer=self.pointer, target_pointer=None,
            operation={'operation_id': 'retaining', 'request_id': 'request',
                'algorithm_version': 'review-state', 'input_hash': None, 'inputs': [], 'stage': 'retaining'})
        _write(journal, value)
        before = journal.read_bytes()
        self.assertEqual(_journal_health(self.paths, self.pointer)[journal.name], 'uncommitted-terminal')
        self.assertEqual(journal.read_bytes(), before)
        value['operation'].update(stage='processing', input_hash='f' * 64)
        _write(journal, value)
        with self.assertRaisesRegex(InstallationError, 'input identity hash mismatch'):
            _journal_health(self.paths, self.pointer)

    def test_unknown_workspace_control_fields_are_rejected_before_doctor(self):
        metadata = _read(self.paths.workspace / 'workspace.json'); metadata['unknown_authority'] = True
        _write(self.paths.workspace / 'workspace.json', metadata)
        with self.assertRaises(InstallationError):
            health_check(self.paths, doctor=lambda *a, **k: self.fail('malformed workspace opened'))

    def test_newer_minimum_writer_stays_readable_and_restored_client_has_no_processor_authority(self):
        metadata = _read(self.paths.workspace / 'workspace.json'); metadata['min_writer_version'] = '2.0.0'
        _write(self.paths.workspace / 'workspace.json', metadata)
        metadata['access'] = 'viewing'; _write(self.paths.workspace / 'workspace.json', metadata)
        report = health_check(self.paths, doctor=self.doctor)
        self.assertTrue(report['compatibility']['readable']); self.assertFalse(report['writable'])
        self.assertFalse(report['processor_health_qualified'])

    def test_unknown_writer_alias_is_rejected_and_current_report_requirement_applies(self):
        metadata = _read(self.paths.workspace / 'workspace.json')
        metadata.update(min_writer_version='1.0.0', minimum_writer='2.0.0')
        _write(self.paths.workspace / 'workspace.json', metadata)
        with self.assertRaises(InstallationError): health_check(self.paths, doctor=self.doctor)
        del metadata['minimum_writer']; _write(self.paths.workspace / 'workspace.json', metadata)
        report_path = self.paths.states / self.pointer['state_id'] / 'review/financial-review.json'
        report = _read(report_path); report['min_writer_version'] = '2.0.0'; _write(report_path, report)
        self.assertFalse(health_check(self.paths, doctor=self.doctor)['writable'])

    def test_runtime_rejects_unpinned_self_manifest_before_executing_code(self):
        bundle = self.root / 'Untrusted.app'; bundle.mkdir()
        with patch('scripts.installation_health.subprocess.run') as runner:
            with self.assertRaises(InstallationError): runtime_health(bundle)
            runner.assert_not_called()

    def test_runtime_uses_fixed_env_and_checks_real_doctor_result(self):
        bundle = self.root / 'Runtime.app'; resources = bundle / 'Contents/Resources'; resources.mkdir(parents=True)
        manifest = {'runtime_version': 'cpython-3.13.9-pbs-20251014-lock1',
                    'python': {'path': 'python'}, 'bootstrap': {'path': 'bootstrap'}}
        (resources / 'runtime-manifest.json').write_bytes(canonical_json(manifest))
        (resources / 'build-provenance.json').write_bytes(b'{}')
        authority = {'app_sha256': tree_digest(bundle),
                     'runtime_manifest_sha256': digest_file(resources / 'runtime-manifest.json'),
                     'provenance_sha256': digest_file(resources / 'build-provenance.json')}
        calls = []
        def runner(command, **kwargs):
            calls.append((command, kwargs))
            return SimpleNamespace(stdout=canonical_json({'ok': True,
                'runtime_version': manifest['runtime_version'], 'checks': [{'name': 'actual-import', 'ok': True}]}))
        with patch('scripts.runtime_doctor.load_manifest', return_value=manifest), patch.dict(os.environ, {'DYLD_INSERT_LIBRARIES': str(self.root / 'bad')}):
            report = runtime_health(bundle, artifact_reference=authority, runner=runner)
        self.assertTrue(report['verified'])
        self.assertEqual(len(calls), 2)
        for _, kwargs in calls:
            self.assertEqual(kwargs['env'], {'PATH': os.confstr('CS_PATH') or os.defpath})
        self.assertIn('-I', calls[1][0]); self.assertIn('-S', calls[1][0])

    def apps(self):
        self.installed = self.root / 'Apps/Existing.app'; self.candidate = self.root / 'Candidate.app'
        self.preferences = self.root / 'preferences.plist'; self.preferences.write_bytes(plistlib.dumps({'bookmark': b'opaque'}))
        policy = _read(POLICY)
        for app, version, build, binary in [(self.installed, '0.17', 17, b'old application'),
                                            (self.candidate, policy['app_version'], policy['build_number'], b'new application')]:
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/MacOS/EvidenceBrowser').write_bytes(binary)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.banking.family-review',
                'CFBundleShortVersionString': version, 'CFBundleVersion': str(build)}))
        return self.root / 'evidence'

    def update(self, evidence, runtime=lambda *a, **k: {'verified': True}):
        def runner(command):
            self.assertEqual(Path(command[0]).name, 'ditto')
            shutil.copytree(command[1], command[2])
        with patch('scripts.update_macos_app.verify_app', return_value={'version': {'app_version': _read(POLICY)['app_version']}}), \
             patch('scripts.update_macos_app.artifact_reference', return_value={'independent': 'test-pin'}):
            return update(self.candidate, self.paths, evidence, preferences=self.preferences, artifact_receipt=self.root / 'receipt.json',
                installed=self.installed, runner=runner, stopper=lambda app: None, runtime_validator=runtime,
                qualifier=lambda paths, **kwargs: {'writable': True, 'runtime_verified': True, 'source_pointer': self.pointer})

    def test_retained_update_atomic_swap_keeps_old_bundle_and_requires_first_run(self):
        evidence = self.apps()
        result = self.update(evidence)
        self.assertEqual(result['phase'], 'installed-awaiting-first-run')
        self.assertFalse(result['first_run_qualified'])
        self.assertTrue(result['exact_bytes_preserved'])
        old = Path(result['retained_old_app_path'])
        self.assertEqual((old / 'Contents/MacOS/EvidenceBrowser').read_bytes(), b'old application')
        self.assertFalse((evidence / 'workspace-before').exists())
        self.assertFalse((evidence / 'preferences-before.plist').exists())

    def test_post_swap_runtime_failure_restores_only_app_with_unchanged_data(self):
        evidence = self.apps()
        def failed(*a, **k): raise InstallationError('runtime failed')
        with self.assertRaises(InstallationError): self.update(evidence, failed)
        self.assertEqual((self.installed / 'Contents/MacOS/EvidenceBrowser').read_bytes(), b'old application')
        self.assertEqual(_read(evidence / 'update-receipt.json')['phase'], 'old-app-restored-data-unchanged')
        self.assertEqual(self.paths.read_pointer(), self.pointer)

    def test_new_work_after_swap_prohibits_automatic_rollback(self):
        evidence = self.apps()
        def new_work(*a, **k):
            (self.paths.workspace / 'device/new-user-work.bin').write_bytes(b'new user work')
            raise InstallationError('runtime failed after new work')
        with self.assertRaises(InstallationError): self.update(evidence, new_work)
        self.assertEqual((self.installed / 'Contents/MacOS/EvidenceBrowser').read_bytes(), b'new application')
        self.assertEqual((self.paths.workspace / 'device/new-user-work.bin').read_bytes(), b'new user work')
        self.assertEqual(_read(evidence / 'update-receipt.json')['phase'], 'failed-new-work-retained-no-auto-rollback')


if __name__ == '__main__': unittest.main()
