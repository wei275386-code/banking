from pathlib import Path
import subprocess
import tempfile
import unittest

from release.source_paths import inventory, path_literals


class SourcePathInventoryTests(unittest.TestCase):
    def test_bare_root_and_external_file_fixture_are_detected(self):
        bare = '/' + 'Applications'
        external = '/' + 'etc/passwd'
        text = 'Path("' + bare + '")\ntarget.symlink_to("' + external + '")'
        rows = path_literals(text)
        self.assertEqual([row['line'] for row in rows], [1, 2])
        self.assertTrue(all(row['classification'] == 'system_root_literal' for row in rows))
        self.assertEqual(path_literals('`' + bare + '`')[0]['classification'], 'system_root_literal')
        self.assertEqual(path_literals('"' + bare.lower() + '"')[0]['classification'], 'system_root_literal')

    def test_relative_sdk_members_and_urls_are_classified_without_hiding_absolute_paths(self):
        text = 'developer / "Toolchains/tool/usr/bin/swift"\n"https://example.invalid/usr/bin/tool"'
        self.assertEqual({row['classification'] for row in path_literals(text)}, {'relative_member', 'uri'})
        path = '/' + 'usr/bin/tool'
        self.assertEqual(path_literals('"file://' + path + '"')[0]['classification'], 'system_root_literal')
        self.assertEqual(path_literals('RUNTIME + "' + path + '"')[0]['classification'], 'appended_member_suffix')
        self.assertEqual(path_literals('ROOT / "' + path + '"')[0]['classification'], 'system_root_literal')

    def test_home_root_grammar_does_not_require_a_system_component(self):
        for suffix in ('', '/', '/Documents/household', '/mock-household', '/' + 'Library/household'):
            with self.subTest(suffix=suffix):
                rows = path_literals('Path("' + chr(126) + suffix + '")')
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0]['classification'], 'system_root_literal')

    def test_json_pointer_escape_is_a_logical_token_not_a_home_locator(self):
        token = chr(126)
        text = '.replace("' + token + '0", "' + token + '")'
        self.assertEqual(path_literals(text)[0]['classification'], 'json_pointer_escape')
        self.assertEqual(path_literals('Path("' + token + '")')[0]['classification'], 'system_root_literal')

    def test_all_visible_files_are_accounted_without_extensions_or_symlink_reads(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve(); repo = base / 'repo'; repo.mkdir()
            subprocess.run(['git', 'init', '-q', str(repo)], check=True, capture_output=True, timeout=10)
            files = {'.gitignore': b'ignored.cache\n', 'release/requirements.in': b'synthetic dependency',
                     'src.py': b'print("mock")', 'outputs/private.tsv': b'mock\tuser',
                     'image.png': b'\x89PNG\0\xff', 'ignored.cache': b'ignored'}
            for name, data in files.items():
                path = repo / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
            external = base / 'external.mock'; external.write_bytes(b'never read external')
            (repo / 'external-link.py').symlink_to(external)
            report = inventory(repo)
            by_path = {row['path']: row for row in report['entries']}
            self.assertEqual(set(by_path), set(files) - {'ignored.cache'} | {'external-link.py'})
            self.assertEqual(by_path['.gitignore']['disposition'], 'text_scanned')
            self.assertEqual(by_path['release/requirements.in']['disposition'], 'text_scanned')
            self.assertEqual(by_path['outputs/private.tsv']['disposition'], 'private_input_deferred_P2_P3_P4')
            self.assertEqual(by_path['image.png']['disposition'], 'binary_not_text_scanned')
            self.assertEqual(by_path['external-link.py']['disposition'], 'symlink_not_followed')
            self.assertEqual(report['enumerated'], sum(report['counts'].values()))
            self.assertEqual(report['unresolved'], 0)
