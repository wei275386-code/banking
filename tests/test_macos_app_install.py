import fcntl
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import bundle_evidence_browser as packaging
from scripts import mac_app_install as installer
from scripts import update_macos_app as updater


class MacAppInstallTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        production = Path(temporary.name).resolve() / 'Applications/家庭财务复盘.app'
        self.enterContext(patch.object(packaging, 'default_app_path', return_value=production))
        self.enterContext(patch.object(installer, 'default_app_path', return_value=production))

    def fixture(self, root):
        package = root / 'native/PaymentImageCore'
        (package / 'Sources/App').mkdir(parents=True)
        source = package / 'Sources/App/App.swift'
        source.write_text('// source')
        manifest = package / 'Package.swift'
        manifest.write_text('// package')
        for path in (source, manifest):
            os.utime(path, (1, 1))
        binary = package / '.build/release/EvidenceBrowser'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'new executable')
        output = root / 'data'
        output.mkdir()
        (output / 'ledger.json').write_text('keep this data')
        return output, binary, source

    def old_app(self, app, identity):
        (app / 'Contents/Resources').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identity}))
        (app / 'Contents/Resources/obsolete.txt').write_text('old')

    def fake_icon(self, root, destination):
        destination.write_bytes(b'icon')

    def test_repeat_install_replaces_entire_bundle_and_preserves_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output, binary, _ = self.fixture(root)
            app = root / 'Apps/Test.app'
            with patch.object(packaging, 'write_app_icon', self.fake_icon), patch.object(packaging.subprocess, 'run'):
                packaging.bundle(root, output, app_path=app)
                identity = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
                self.assertTrue(identity.startswith(installer.BUNDLE_ID + '.qa-'))
                (app / 'Contents/Resources/obsolete.txt').write_text('old')
                binary.write_bytes(b'newer executable')
                packaging.bundle(root, output, app_path=app)
            self.assertEqual((app / 'Contents/MacOS/EvidenceBrowser').read_bytes(), b'newer executable')
            self.assertFalse((app / 'Contents/Resources/obsolete.txt').exists())
            self.assertEqual(list(app.parent.glob('*.app')), [app])
            self.assertEqual(list(app.parent.glob('.family-review-install-*')), [])
            self.assertEqual((output / 'ledger.json').read_text(), 'keep this data')
            self.assertEqual(json.loads((app / 'Contents/Resources/evidence-location.json').read_text())['folder'], str(output.resolve()))

    def test_failed_validation_leaves_old_app_and_no_staging_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output, _, _ = self.fixture(root)
            app = root / 'Apps/Test.app'
            self.old_app(app, 'old identity')
            def signing(args, **kwargs):
                if '--verify' in args:
                    raise subprocess.CalledProcessError(1, args)
            with patch.object(packaging, 'write_app_icon', self.fake_icon), patch.object(packaging.subprocess, 'run', signing):
                with self.assertRaises(subprocess.CalledProcessError):
                    packaging.bundle(root, output, app_path=app)
            self.assertTrue((app / 'Contents/Resources/obsolete.txt').exists())
            self.assertEqual(list(app.parent.glob('.family-review-install-*')), [])

    def test_activation_failure_rolls_back_complete_previous_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / 'data'; output.mkdir()
            app = root / 'Installed.app'; candidate = root / 'New.app'
            for path in (app, candidate):
                self.old_app(path, installer.BUNDLE_ID)
            (candidate / 'Contents/Resources/obsolete.txt').write_text('new')
            seen = []
            def activation(path, project):
                seen.append((path / 'Contents/Resources/obsolete.txt').read_text())
                if len(seen) == 1:
                    raise RuntimeError('launch failed')
            with patch.object(installer, 'default_app_path', return_value=app), patch.object(installer, 'stop_app'):
                with self.assertRaisesRegex(RuntimeError, 'launch failed'):
                    installer.install_staged(candidate, app, root, output, activation)
            self.assertEqual(seen, ['new', 'old'])
            self.assertEqual((app / 'Contents/Resources/obsolete.txt').read_text(), 'old')

    def test_active_import_prevents_shutdown_or_replacement(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); output = root / 'data'; output.mkdir()
            app = root / 'Installed.app'; candidate = root / 'New.app'
            for path in (app, candidate):
                self.old_app(path, installer.BUNDLE_ID)
            with (output / '.review-processor.lock').open('a') as guard:
                fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch.object(installer, 'default_app_path', return_value=app), patch.object(installer, 'stop_app') as stop:
                    with self.assertRaisesRegex(RuntimeError, 'import or review'):
                        installer.install_staged(candidate, app, root, output)
                    stop.assert_not_called()

    def test_rollback_keeps_previous_bundle_even_if_new_app_will_not_quit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); output = root / 'data'; output.mkdir()
            app = root / 'Installed.app'; candidate = root / 'New.app'
            for path in (app, candidate):
                self.old_app(path, installer.BUNDLE_ID)
            (candidate / 'Contents/Resources/obsolete.txt').write_text('new')
            def activation(path, project):
                raise RuntimeError('launch failed')
            with patch.object(installer, 'default_app_path', return_value=app), patch.object(installer, 'stop_app', side_effect=[None, RuntimeError('quit failed')]):
                with self.assertRaisesRegex(RuntimeError, 'quit failed'):
                    installer.install_staged(candidate, app, root, output, activation)
            self.assertEqual((app / 'Contents/Resources/obsolete.txt').read_text(), 'old')

    def test_concurrent_install_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'App.app'
            with installer.install_lock(app):
                with self.assertRaisesRegex(RuntimeError, 'installation is in progress'):
                    with installer.install_lock(app):
                        self.fail('second installation acquired the lock')

    def test_stale_binary_and_debug_cannot_replace_production(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); output, binary, source = self.fixture(root)
            os.utime(source, (binary.stat().st_mtime + 1, binary.stat().st_mtime + 1))
            with self.assertRaisesRegex(ValueError, 'stale'):
                packaging.bundle(root, output)
            with self.assertRaisesRegex(ValueError, 'requires Release'):
                packaging.bundle(root, output, 'debug')

    def test_prebuilt_artifact_rejection_does_not_stop_or_replace_existing_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); output, _, _ = self.fixture(root)
            installed = root / 'Installed.app'; candidate = root / 'Candidate.app'
            self.old_app(installed, installer.BUNDLE_ID)
            self.old_app(candidate, installer.BUNDLE_ID)
            preferences = root / 'preferences.plist'
            preferences.write_bytes(plistlib.dumps({'retained': True}))
            evidence = root / 'update-evidence'
            before = (installed / 'Contents/Resources/obsolete.txt').read_bytes()
            with patch.object(updater, 'verify_app', side_effect=ValueError('artifact rejected')), \
                    patch.object(updater, 'stop_app') as stop, patch.object(updater, 'swap_bundles') as swap:
                with self.assertRaisesRegex(ValueError, 'artifact rejected'):
                    updater.update(candidate, output, evidence, preferences=preferences,
                        artifact_receipt=root / 'receipt.json', installed=installed,
                        stopper=stop, swapper=swap)
                stop.assert_not_called(); swap.assert_not_called()
            self.assertFalse(evidence.exists())
            self.assertEqual((installed / 'Contents/Resources/obsolete.txt').read_bytes(), before)
            self.assertEqual((output / 'ledger.json').read_text(), 'keep this data')


if __name__ == '__main__':
    unittest.main()
