import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import tool_locations as tools


class ToolLocationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        tools.macos_directory.cache_clear()
        tools.system_library_roots.cache_clear()

    def tearDown(self):
        tools.macos_directory.cache_clear()
        tools.system_library_roots.cache_clear()
        self.temporary.cleanup()

    def test_explicit_prefixes_work_without_current_directory_search(self):
        for prefix in ('prefix-one', 'prefix-two'):
            directory = self.root / prefix
            directory.mkdir()
            executable = directory / 'mock-tool'
            executable.write_bytes(b'mock executable')
            executable.chmod(0o700)
            selected = tools.tool_path('mock-tool', environment={'PATH': os.pathsep.join(['.', str(directory)])})
            self.assertEqual(selected, str(executable))
        with self.assertRaises(ValueError):
            tools.tool_path('mock-tool', environment={'PATH': '.'})
        for name in ('../tool', 'a/tool', 'a\\tool', ''):
            with self.assertRaises(ValueError):
                tools.tool_path(name)

    def test_production_environment_uses_os_path_not_untrusted_overrides(self):
        with patch.dict(os.environ, {'PATH': str(self.root), 'PYTHONPATH': 'mock-injection',
                                     'DYLD_LIBRARY_PATH': 'mock-injection'}, clear=True):
            environment = tools.controlled_environment(temporary=self.root)
            self.assertEqual(environment['PATH'], tools.system_search_path())
            self.assertNotIn('PYTHONPATH', environment)
            self.assertNotIn('DYLD_LIBRARY_PATH', environment)
            self.assertEqual(environment['TMPDIR'], str(self.root))
            self.assertEqual(set(environment), {'PATH', 'HOME', 'TMPDIR', 'LANG'})

    def test_os_directory_query_is_fixed_and_config_free(self):
        completed = type('Completed', (), {'stdout': str(self.root) + '\n'})()
        with patch.object(tools.subprocess, 'run', return_value=completed) as run:
            self.assertEqual(tools.macos_directory('applications'), self.root)
            self.assertIn('path to applications folder', run.call_args.args[0][-1])
            self.assertNotIn(str(self.root), run.call_args.args[0][-1])
            self.assertEqual(tools.application_path(), self.root / '家庭财务复盘.app')
        with self.assertRaises(ValueError):
            tools.macos_directory('unsupported-kind')

    def test_developer_environment_adds_only_discovered_absolute_tool_prefixes(self):
        for name in ('user-one', 'user-two'):
            prefix = self.root / name / 'tools'
            prefix.mkdir(parents=True)
            node = prefix / 'node'
            node.write_bytes(b'synthetic launcher'); node.chmod(0o700)
            ignored = self.root / name / 'unused'
            with patch.dict(os.environ, {'PATH': os.pathsep.join(['.', str(ignored), str(prefix)]),
                                         'DYLD_LIBRARY_PATH': str(ignored), 'PYTHONHOME': str(ignored)}, clear=True):
                environment = tools.controlled_environment(development=True)
                paths = environment['PATH'].split(os.pathsep)
                self.assertIn(str(prefix), paths)
                self.assertNotIn(str(ignored), paths); self.assertNotIn('.', paths)
                self.assertNotIn('DYLD_LIBRARY_PATH', environment); self.assertNotIn('PYTHONHOME', environment)
                self.assertEqual(tools.resolve_command(['node', '--version']), [str(node), '--version'])

    def test_system_resolution_ignores_a_spoofed_developer_tool(self):
        prefix = self.root / 'foreign'
        prefix.mkdir()
        spoof = prefix / 'codesign'; spoof.write_bytes(b'synthetic spoof'); spoof.chmod(0o700)
        with patch.dict(os.environ, {'PATH': str(prefix)}, clear=True):
            resolved = tools.resolve_command(['codesign', '--verify'])
        self.assertNotEqual(resolved[0], str(spoof))
        self.assertIn(str(Path(resolved[0]).parent), tools.system_search_path().split(os.pathsep))

    def test_system_library_classification_is_bounded_and_rejects_traversal(self):
        library = self.root / 'os-libraries'
        foreign = self.root / 'foreign'
        with patch.object(tools, 'system_library_roots', return_value=(library,)):
            self.assertTrue(tools.is_system_library(str(library / 'mock.dylib')))
            self.assertFalse(tools.is_system_library(str(foreign / 'mock.dylib')))
            self.assertFalse(tools.is_system_library(str(library / '..' / 'foreign' / 'mock.dylib')))
            self.assertFalse(tools.is_system_library('relative/mock.dylib'))


if __name__ == '__main__':
    unittest.main()
