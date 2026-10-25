"""Actual processor transaction admission while native family publication is pending."""
import json
import tempfile
import unittest
from pathlib import Path

from scripts.workspace_initialization import create_workspace
from scripts.workspace_state import WorkspacePaths, StateTransaction, WorkspaceError, MaintenanceGate


class FamilyHostPublicationGateTests(unittest.TestCase):
    def test_pending_creation_or_publication_blocks_processor_until_settled(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve() / 'synthetic-family'
            create_workspace(root)
            paths = WorkspacePaths(root)
            before = paths.read_pointer()
            for name, phase in [('create-family.json', 'creating'),
                                ('host-publication-family.json', 'frozen')]:
                pending = root / 'device' / name
                pending.write_text(json.dumps({'phase': phase}))
                with MaintenanceGate(paths).acquire("synthetic-test") as token:
                    with self.assertRaises(WorkspaceError):
                        StateTransaction.begin(paths, token)
                pending.unlink()
            (root / 'device/create-family.json').write_text(
                json.dumps({'phase': 'complete'}))
            with MaintenanceGate(paths).acquire("synthetic-test") as token:
                transaction = StateTransaction.begin(paths, token)
                transaction.abort()
            self.assertEqual(paths.read_pointer(), before)
