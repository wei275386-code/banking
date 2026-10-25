"""Empty FIRE inputs use explicit nulls; no private reports or defaults."""
import json
import tempfile
import unittest
from pathlib import Path

from scripts.workspace_initialization import create_workspace, fire_template
from scripts.workspace_state import WorkspacePaths
from scripts.workspace_validation import FIRE, ProductValidationError, _decode


class FireInputTests(unittest.TestCase):
    def test_actual_empty_workspace_preserves_unset_numeric_fields(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder).resolve() / 'synthetic-family'
            create_workspace(destination)
            state = WorkspacePaths(destination).resolve_active()
            configuration = json.loads((state.root / 'config/fire-parameters.json').read_text())
            report = json.loads((state.root / 'review/financial-review.json').read_text())
            self.assertEqual(configuration['status'], 'needs_input')
            self.assertIsNone(configuration['currentFireAssets'])
            self.assertIsNone(configuration['birthYear'])
            self.assertIsNone(configuration['branches']['housing']['totalPrice'])
            self.assertEqual(report['fire_parameters'], configuration)

    def test_nullable_numeric_contract_distinguishes_zero_and_rejects_wrong_scalars(self):
        value = fire_template()
        _decode(value, FIRE, 'synthetic-fire')
        value['currentFireAssets'] = 0
        _decode(value, FIRE, 'synthetic-fire')
        for wrong in (True, '0'):
            value['currentFireAssets'] = wrong
            with self.assertRaises(ProductValidationError):
                _decode(value, FIRE, 'synthetic-fire')
