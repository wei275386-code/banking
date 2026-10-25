import json
import tempfile
import unittest
from pathlib import Path

from scripts.financial_review_inputs import FinancialReviewInputs
from scripts.probe_payment_evidence import registry_dependencies, sha
from scripts.workspace_initialization import create_workspace


class DependencyRegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.paths = create_workspace(self.root / 'workspace')
        self.state = self.paths.resolve_active()

    def tearDown(self):
        self.temp.cleanup()

    def test_empty_source_registry_and_real_projection_inputs(self):
        sources = registry_dependencies(self.state.root)
        self.assertEqual(sources['files'], [{'path': 'config/review-import-sources.json', 'dependencies': []}])
        projection = FinancialReviewInputs.dependency_registry(self.state.root, self.state.review)
        dependencies = projection['files'][0]['dependencies']
        self.assertIn('banking.sqlite3', dependencies)
        self.assertIn('config/fire-parameters.json', dependencies)
        self.assertIn('review/payment-evidence.json', dependencies)
        self.assertIn('review/category-catalog.json', dependencies)
        self.assertIn('config/category-seed.json', dependencies)
        self.assertIn('review/material-associations.json', projection['absent_optional'])
        self.assertTrue(all(not name.startswith('/') for name in dependencies))

    def test_source_edges_are_auto_derived_and_verified(self):
        # This fixture creates a separate registry tree; committed workspace is
        # never edited for a dependency-discovery test.
        fixture = self.root / 'registry-fixture'; (fixture / 'config').mkdir(parents=True)
        source = fixture / 'retained.csv'; source.write_bytes(b'fixture-original')
        (fixture / 'config/review-import-sources.json').write_text(json.dumps({'sources': [{'path': 'retained.csv', 'sha256': sha(source), 'platform': 'alipay'}]}))
        registry = registry_dependencies(fixture)
        self.assertEqual(registry['files'][0]['dependencies'], ['retained.csv'])
        self.assertEqual(registry['sources'][0]['sha256'], sha(source))
        source.write_bytes(b'changed-original')
        with self.assertRaises(ValueError):
            registry_dependencies(fixture)

    def test_missing_required_parameter_blocks_projection_dependency_closure(self):
        fixture = self.root / 'incomplete'; (fixture / 'review').mkdir(parents=True)
        with self.assertRaises(ValueError):
            FinancialReviewInputs.dependency_registry(fixture, fixture / 'review')
