"""Synthetic CLI/data separation checks; no existing household is opened."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch



class ExplicitDataRootTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()

    def test_diagnostic_processors_require_both_data_roots_before_writing(self):
        source = Path(__file__).resolve().parents[1]
        launch = ('import runpy,sys; sys.path.insert(0,sys.argv[1]); '
                  'module=sys.argv[2]; sys.argv=[module]+sys.argv[3:]; '
                  'runpy.run_module(module,run_name="__main__")')
        for module in ('scripts.financial_review', 'scripts.probe_payment_evidence'):
            with self.subTest(module=module):
                data = self.root / module.replace('.', '-')
                data.mkdir()
                completed = subprocess.run([sys.executable, '-E', '-B', '-c', launch, str(source), module,
                    '--root', str(data)], cwd=self.root, capture_output=True, text=True, timeout=15,
                    env={'PATH': os.confstr('CS_PATH') or os.defpath})
                self.assertEqual(completed.returncode, 2, completed.stderr)
                self.assertIn('--output', completed.stderr)
                self.assertEqual(list(data.iterdir()), [])


    def test_staging_import_and_matching_require_explicit_database_and_inputs(self):
        source = Path(__file__).resolve().parents[1]
        for module, arguments in (
                ('scripts.import_wechat_alipay', []),
                ('scripts.import_wechat_alipay', ['mock.csv']),
                ('scripts.import_wechat_alipay', ['--db', str(self.root / 'unused.sqlite3')]),
                ('scripts.match_bill_details', [])):
            with self.subTest(module=module, arguments=arguments):
                completed = subprocess.run([sys.executable, '-B', '-m', module, *arguments],
                    cwd=source, capture_output=True, text=True, timeout=15)
                self.assertEqual(completed.returncode, 2, completed.stderr)
                self.assertIn('required', completed.stderr)
                self.assertEqual(list(self.root.iterdir()), [])



if __name__ == '__main__':
    unittest.main()
