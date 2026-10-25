import json
import tempfile
import unittest
from pathlib import Path

from scripts.generate_release_inputs import generate


class ReleaseInputGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "config").mkdir()
        (self.root / "native/FamilyReviewIOS").mkdir(parents=True)
        repository = Path(__file__).resolve().parents[1]
        self.source = self.root / "native/FamilyReviewIOS/project.yml"
        self.source.write_bytes((repository / "native/FamilyReviewIOS/project.yml").read_bytes())
        self.version = json.loads((repository / "config/release-version.json").read_text())
        self.config = self.root / "config/release-version.json"
        self.config.write_text(json.dumps(self.version))

    def test_native_versions_are_derived_without_changing_template_or_requiring_user_data(self):
        before = self.source.read_bytes()
        result = generate(self.root)
        spec = Path(result["project_spec"]).read_text()
        self.assertEqual(self.source.read_bytes(), before)
        self.assertIn(f"MARKETING_VERSION: '{self.version['app_version']}'", spec)
        self.assertIn(f"CURRENT_PROJECT_VERSION: '{self.version['build_number']}'", spec)
        self.assertIn("DEVELOPMENT_TEAM: ''", spec)
        self.assertIn("path: Generated/Info.plist", spec)
        self.assertIn("excludes: [Info.plist]", spec)
        self.assertIn("path: ../PaymentImageCore/Sources/EvidenceBrowser/WorkspaceEditing.swift", spec)
        self.assertIn("path: Generated/Bootstrap", spec)
        self.assertNotIn("- path: Seed", spec)
        self.assertNotIn("FamilyReviewUITests", spec)
        self.assertEqual(json.loads(Path(result["bootstrap"]).read_text())["kind"], "empty")
        bundled_version = Path(result["bootstrap"]).parent / "release-version.json"
        self.assertEqual(json.loads(bundled_version.read_text()), self.version)
        self.assertEqual(result["mac_info_properties"]["CFBundleVersion"], str(self.version["build_number"]))
        self.assertFalse((self.root / "banking.sqlite3").exists())
        self.assertFalse((self.root / "outputs").exists())

    def test_qa_build_cannot_use_production_bundle_identifier(self):
        result = generate(self.root, team="ABCDEFGHIJ", qa=True)
        spec = Path(result["project_spec"]).read_text()
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: local.familyreview.FamilyReview.ReleaseQA", spec)
        self.assertNotIn("PRODUCT_BUNDLE_IDENTIFIER: local.familyreview.FamilyReview\n", spec)
        self.assertIn("FamilyReviewUITests", spec)

    def test_invalid_version_or_team_does_not_create_generated_inputs(self):
        valid_build = self.version["build_number"]
        self.version["build_number"] = True
        self.config.write_text(json.dumps(self.version))
        with self.assertRaises(ValueError):
            generate(self.root)
        self.assertFalse((self.source.parent / "project.generated.yml").exists())
        self.version["build_number"] = valid_build
        self.config.write_text(json.dumps(self.version))
        with self.assertRaises(ValueError):
            generate(self.root, team="bad:team")


if __name__ == "__main__":
    unittest.main()
