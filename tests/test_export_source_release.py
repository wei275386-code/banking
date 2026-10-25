import hashlib
import json
from pathlib import Path
import tarfile
import unittest

from release.source_contract import GitSource, canonical_json
from release.validation import ContractError
from scripts.export_source_release import export_source
from test_release_preflight import ReleaseRepository


class ExportSourceReleaseTests(unittest.TestCase):
    def setUp(self):
        self.fixture = ReleaseRepository()
        self.addCleanup(self.fixture.close)
        self.output = Path(self.fixture.temporary.name) / 'source.tar.gz'

    def export(self, **kwargs):
        return export_source(self.fixture.root, 'HEAD', self.output, **kwargs)

    def test_only_commit_allowlist_inputs_and_verified_provenance(self):
        result = self.export()
        self.assertEqual(result['release_status'], 'candidate')
        with tarfile.open(self.output) as archive:
            names = archive.getnames()
            self.assertNotIn('source/config/fire-parameters.json', names)
            self.assertFalse(any('/Seed/' in name or '/outputs/' in name or '.xcodebuildmcp' in name for name in names))
            provenance = json.load(archive.extractfile('release-provenance.json'))
            for entry in provenance['files']:
                data = archive.extractfile('source/' + entry['path']).read()
                self.assertEqual(hashlib.sha256(data).hexdigest(), entry['sha256'])
                self.assertEqual(len(data), entry['size'])
            self.assertEqual(hashlib.sha256(canonical_json(provenance['files'])).hexdigest(), provenance['input_manifest_sha256'])
            self.assertEqual(len(names), len(provenance['files']) + 1)
        self.assertEqual(hashlib.sha256(self.output.read_bytes()).hexdigest(), result['archive_sha256'])

    def test_same_commit_archive_is_deterministic(self):
        first = self.export()
        second = Path(self.fixture.temporary.name) / 'second.tar.gz'
        result = export_source(self.fixture.root, 'HEAD', second)
        self.assertEqual(first['archive_sha256'], result['archive_sha256'])
        self.assertEqual(self.output.read_bytes(), second.read_bytes())

    def test_dirty_exception_exports_commit_content_not_working_copy(self):
        self.fixture.write('scripts/entry.py', "print('credential-secret-123')", raw=True)
        with self.assertRaisesRegex(ContractError, 'dirty_checkout'):
            self.export()
        self.assertFalse(self.output.exists())
        result = self.export(allow_dirty=True)
        self.assertTrue(result['dirty'])
        with tarfile.open(self.output) as archive:
            data = archive.extractfile('source/scripts/entry.py').read()
            self.assertIn(b'synthetic source', data)
            self.assertNotIn(b'credential-secret', data)

    def test_dev_fixture_is_separate_profile(self):
        self.export(profile='dev-tests')
        with tarfile.open(self.output) as archive:
            self.assertEqual(set(archive.getnames()), {'source/tests/synthetic.json', 'release-provenance.json'})
            self.assertEqual(json.load(archive.extractfile('release-provenance.json'))['profile'], 'dev-tests')

    def test_path_traversal_private_paths_and_qa_runner_fail_closed(self):
        original = list(self.fixture.paths)
        for path in ('../private.json', str(Path(__file__).resolve().parent / 'private.json'), 'scripts//bad.py',
                     'config/fire-parameters.json', 'outputs/private.json',
                     'native/FamilyReviewIOS/Seed/private.json', '.xcodebuildmcp/config.yaml',
                     'native/QARunner/main.swift', 'tests/synthetic.json', 'release/source.csv'):
            with self.subTest(path=path):
                self.fixture.paths = original + [path]
                self.fixture.write_allowlist()
                self.fixture.commit()
                with self.assertRaises(ContractError):
                    self.export()
                self.assertFalse(self.output.exists())

    def test_git_symlink_cannot_export_external_content(self):
        target = self.fixture.root / 'scripts/link.py'
        external = self.fixture.root.parent / 'external-sentinel.txt'
        external.write_bytes(b'synthetic external bytes must never enter source export')
        target.symlink_to(external)
        self.fixture.paths.append('scripts/link.py')
        self.fixture.write_allowlist()
        self.fixture.commit()
        with self.assertRaisesRegex(ContractError, 'non_regular_input'):
            self.export()
        self.assertFalse(self.output.exists())
        self.assertEqual(external.read_bytes(), b'synthetic external bytes must never enter source export')

    def test_existing_output_is_preserved(self):
        self.output.write_bytes(b'previous artifact')
        with self.assertRaisesRegex(ContractError, 'output_already_exists'):
            self.export()
        self.assertEqual(self.output.read_bytes(), b'previous artifact')

    def test_input_manifest_missing_provenance_schema_leaves_no_partial_output(self):
        (self.fixture.root / 'release/source-provenance.schema.json').unlink()
        self.fixture.paths.remove('release/source-provenance.schema.json')
        self.fixture.write_allowlist()
        self.fixture.commit()
        with self.assertRaisesRegex(ContractError, 'missing_committed_input'):
            self.export()
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.output.parent.glob('.source-candidate-*')))
