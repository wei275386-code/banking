"""Synthetic upgrade preservation and mocked-device fault checks only."""
import base64
import json
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.release_contracts import canonical_json, digest_bytes
from scripts.installation_inventory import (BUNDLE_ID, InstallationError, inspect, compare, compatibility)
from scripts.update_ios_app import DeviceContainer, update, verify_install_result

DATA = 'Library/Application Support/FamilyReview'
BINDING = '22222222-2222-4222-8222-222222222222'
REQUEST = '44444444-4444-4444-8444-444444444444'
REQUEST_ROOT = DATA + '/device/family-requests/' + BINDING


def write(root, name, value):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(value if isinstance(value, bytes) else canonical_json(value))
    return path


def fixture(root):
    root.mkdir()
    write(root, 'Library/Preferences/' + BUNDLE_ID + '.plist', plistlib.dumps({'bookmark': b'opaque bookmark bytes', 'chosenAccount': 'all'}))
    selection = {'workspace_id': '11111111-1111-4111-8111-111111111111', 'binding_id': BINDING,
                 'host_id': '33333333-3333-4333-8333-333333333333'}
    write(root, DATA + '/device/device-identity.json', {'device_id': selection['host_id']})
    write(root, DATA + '/device/family-connection.json', selection)
    material = b'synthetic pending recording bytes'; digest = digest_bytes(material)
    files = [{'name': 'video.mov', 'sha256': digest, 'bytes': len(material), 'kind': 'video'}]
    payload = canonical_json(files); payload_hash = digest_bytes(payload)
    write(root, REQUEST_ROOT + '/objects/' + digest, material)
    write(root, REQUEST_ROOT + '/objects/' + payload_hash, payload)
    write(root, REQUEST_ROOT + '/envelopes/' + REQUEST + '.json', {**{k: x for k, x in selection.items() if k != 'host_id'}, 'request_id': REQUEST,
        'author_device_id': selection['host_id'], 'kind': 'import', 'created_at': '2026-10-25T00:00:00Z',
        'payload_hash': payload_hash, 'files': files})
    write(root, DATA + '/device/processing/current-result.json', {'outcome': 'success'})
    write(root, DATA + '/device/conflicts.json', {'field': ['one', 'two']})
    write(root, DATA + '/device/edit-context.json', {'unknown_metadata': {'evidence_note': 'preserve'}})
    view = 'client-views/55555555-5555-4555-8555-555555555555'
    reports = {'financial-review.json': {'dataset_id': 'synthetic', 'records': []},
               'payment-evidence.json': {'dataset_id': 'synthetic', 'candidates': []}}
    hashes = {}
    for name, report in reports.items():
        raw = canonical_json(report); hashes[name] = digest_bytes(raw)
        write(root, DATA + '/device/' + view + '/' + name, raw)
    metadata = canonical_json({'purpose': 'native-family-projection', 'files': hashes})
    write(root, DATA + '/device/' + view + '/client-view.json', metadata)
    write(root, DATA + '/device/client-active.json', {**selection, 'view_path': view, 'view_hash': digest_bytes(metadata)})
    write(root, 'Library/Application Support/custom-state.bin', b'unknown persistent state')
    return digest


class InstallationInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.before = self.root / 'before'
        self.material_hash = fixture(self.before)

    def tearDown(self):
        self.temp.cleanup()

    def clone(self):
        after = self.root / 'after'
        shutil.copytree(self.before, after)
        return after

    def test_full_persistent_closure_and_exact_comparison(self):
        inventory = inspect(self.before)
        self.assertIn(REQUEST, inventory['pending_requests'])
        for name in ['device/processing/current-result.json', 'device/conflicts.json', 'device/edit-context.json']:
            self.assertIn(DATA + '/' + name, inventory['files'])
        self.assertIn('Library/Application Support/custom-state.bin', inventory['files'])
        self.assertTrue(compare(self.before, self.clone())['exact_bytes'])

    def test_pending_missing_or_corrupt_input_blocks(self):
        material = self.before / REQUEST_ROOT / 'objects' / self.material_hash
        material.write_bytes(b'changed')
        with self.assertRaises(InstallationError):
            inspect(self.before)
        material.unlink()
        with self.assertRaises(InstallationError):
            inspect(self.before)

    def test_escape_and_symlink_block(self):
        request = self.before / REQUEST_ROOT / 'envelopes' / (REQUEST + '.json')
        value = json.loads(request.read_text()); value['files'][0]['name'] = '../video.mov'
        request.write_text(json.dumps(value))
        with self.assertRaises(InstallationError):
            inspect(self.before)
        value['files'][0]['name'] = 'video.mov'; request.write_text(json.dumps(value))
        (self.before / DATA / 'escape').symlink_to(self.root)
        with self.assertRaises(ValueError):
            inspect(self.before)

    def test_pointed_snapshot_missing_or_bad_hash_blocks(self):
        pointer = json.loads((self.before / DATA / 'device/client-active.json').read_text())
        report = self.before / DATA / 'device' / pointer['view_path'] / 'financial-review.json'
        report.write_text('{}')
        with self.assertRaises(InstallationError):
            inspect(self.before)
        report.unlink()
        with self.assertRaises(InstallationError):
            inspect(self.before)

    def test_unknown_field_change_and_lost_history_reject(self):
        after = self.clone()
        write(after, DATA + '/device/edit-context.json', {'unknown_metadata': {'evidence_note': 'changed'}})
        with self.assertRaises(InstallationError):
            compare(self.before, after)
        (after / DATA / 'device/processing/current-result.json').unlink()
        with self.assertRaises(InstallationError):
            compare(self.before, after)

    def test_runtime_and_minimum_app_version_gate_updates(self):
        self.assertTrue(compatibility()['writable'])
        self.assertFalse(compatibility(runtime_version='unrecognized')['writable'])
        self.assertFalse(compatibility(minimum_writer='9.0.0')['writable'])
        with self.assertRaises(InstallationError): compatibility(minimum_writer='latest')

    def test_remote_listing_requires_safety_metadata(self):
        backend = DeviceContainer('mock', self.root, '/mock/devicectl')
        with patch.object(backend, 'command', return_value={'files': [{'name': 'Documents', 'resources': {'isDirectory': True}}]}):
            with self.assertRaises(InstallationError):
                backend.listing()

    def test_nested_install_error_is_not_success(self):
        path = write(self.root, 'install.json', {'result': {'isError': True, 'content': ['failed']}})
        with self.assertRaises(InstallationError):
            verify_install_result(path)
        write(self.root, 'install.json', {'isError': False, 'content': []})
        with self.assertRaises(InstallationError):
            verify_install_result(path)

    def test_canonical_install_completion_is_request_bound(self):
        path = write(self.root, 'canonical-install.json', {'didError': False, 'data': {
            'summary': {'status': 'SUCCEEDED'}, 'artifacts': {'deviceId': 'device-a', 'appPath': '/Candidate.app'}}})
        verify_install_result(path, device='device-a', app_path='/Candidate.app')
        with self.assertRaises(InstallationError): verify_install_result(path, device='device-b', app_path='/Candidate.app')
        with self.assertRaises(InstallationError): verify_install_result(path, device='device-a', app_path='/Other.app')

    def test_malformed_current_report_blocks_writer_inventory(self):
        write(self.before, DATA + '/financial-review.json', {'records': []})
        with self.assertRaises(InstallationError):
            inspect(self.before)

    def test_truncated_device_transfer_is_not_a_backup(self):
        backend = DeviceContainer('mock', self.root, '/mock/devicectl')
        listing = {'file.bin': {'isDirectory': False, 'isRegularFile': True, 'isSymbolicLink': False, 'fileSize': 5}}
        def copy(arguments, name):
            Path(arguments[-1]).write_bytes(b'x')
        with patch.object(backend, 'listing', return_value=listing), patch.object(backend, 'command', side_effect=copy):
            with self.assertRaises(InstallationError):
                backend.backup(self.root / 'truncated')

    def test_async_verify_only_never_reinstalls_and_pins_device(self):
        app = self.root / 'Candidate.app'; app.mkdir()
        from scripts.update_ios_app import POLICY
        policy = json.loads(POLICY.read_text())
        write(app, 'Info.plist', plistlib.dumps({'CFBundleIdentifier': BUNDLE_ID,
            'CFBundleVersion': str(policy['build_number']), 'CFBundleShortVersionString': policy['app_version']}))
        evidence = self.root / 'evidence'
        source = self.before
        class Backend:
            def command(self, arguments, name):
                return {'runningProcesses': []}
            def backup(self, target):
                shutil.copytree(source, target)
        class Installer:
            pid = 123
            def wait(self, timeout):
                raise subprocess.TimeoutExpired('mock-install', timeout)
        with patch('scripts.update_ios_app.subprocess.run'), patch('scripts.update_ios_app.subprocess.Popen', return_value=Installer()) as start:
            result = update('mock-device', app, evidence, backend=Backend())
            self.assertEqual(result['status'], 'installing')
            start.assert_called_once()
        write(evidence, 'install.json', {'didError': False, 'data': {'summary': {'status': 'SUCCEEDED'},
            'artifacts': {'deviceId': 'mock-device', 'appPath': str(app)}}})
        with patch('scripts.update_ios_app.subprocess.Popen', side_effect=AssertionError('must not reinstall')):
            result = update('mock-device', app, evidence, verify_only=True, backend=Backend())
            self.assertEqual(result['status'], 'preservation-verified')
            with self.assertRaises(InstallationError):
                update('another-device', app, evidence, verify_only=True, backend=Backend())
            write(app, 'FamilyReview', b'changed candidate payload with same Info.plist')
            with self.assertRaises(InstallationError):
                update('mock-device', app, evidence, verify_only=True, backend=Backend())


if __name__ == '__main__':
    unittest.main()
