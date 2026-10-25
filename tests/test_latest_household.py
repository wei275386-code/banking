import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from scripts.payment_evidence import save_evidence


class LatestHouseholdTests(unittest.TestCase):

    def test_future_evidence_writes_keep_only_current_report(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / 'evidence.sqlite3'
            save_evidence(file, [], {'dataset_id': 'old'})
            save_evidence(file, [], {'dataset_id': 'new'})
            with sqlite3.connect(file) as db:
                self.assertEqual(db.execute('SELECT dataset_id FROM evidence_runs').fetchall(), [('new',)])
