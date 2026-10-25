"""Adversarial build-tool checks; no network, real bundle or ledger."""
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import stage_processor_runtime as stage


class RuntimeStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.system_lib = self.root / 'platform-libraries'
        self.enterContext(patch(stage.is_system_library.__module__ + '.system_library_roots', return_value=(self.system_lib,)))

    def tearDown(self):
        self.temporary.cleanup()

    def tar(self, entries):
        path = self.root / "runtime.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name, data, link in entries:
                member = tarfile.TarInfo(name)
                if link is not None:
                    member.type = tarfile.SYMTYPE
                    member.linkname = link
                    archive.addfile(member)
                else:
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
        return path

    def test_archive_does_not_write_outside_staging(self):
        archive = self.tar([("python/../../escaped", b"bad", None)])
        with self.assertRaises(stage.StagingError):
            stage.extract_runtime(archive, self.root / "runtime")
        self.assertFalse((self.root / "escaped").exists())

    def test_lazy_local_import_must_be_in_locked_runtime(self):
        scripts = self.root / 'scripts'
        scripts.mkdir()
        (scripts / 'entry.py').write_text('def migrate():\n    from scripts.history import replay\n')
        (scripts / 'history.py').write_text('def replay(): pass\n')
        with self.assertRaisesRegex(stage.StagingError, 'locked processor import missing'):
            stage.validate_processor_imports(self.root, ['scripts/entry.py'])
        stage.validate_processor_imports(self.root, ['scripts/entry.py', 'scripts/history.py'])

    def test_committed_processor_import_closure_is_complete(self):
        source = Path(__file__).resolve().parents[1]
        lock = json.loads((source / 'release/runtime-lock.json').read_text())
        stage.validate_processor_imports(source, lock['processor_scripts'])

    def test_archive_rejects_escape_and_duplicate(self):
        for entries in [[("python/bin/python", b"", "../../../escape")], [("python/bin/python", b"a", None), ("python/bin/python", b"b", None)]]:
            with self.subTest(entries=entries):
                archive = self.tar(entries)
                with self.assertRaises(stage.StagingError):
                    stage.extract_runtime(archive, self.root / ("runtime" + str(len(entries))))

    def test_upstream_relative_alias_is_preserved(self):
        archive = self.tar([("python/bin/python3.13", b"runtime", None), ("python/bin/python3", b"", "python3.13")])
        destination = self.root / "runtime"
        stage.extract_runtime(archive, destination)
        self.assertTrue((destination / "bin/python3").is_symlink())
        self.assertEqual((destination / "bin/python3").read_bytes(), b"runtime")

    def test_wheel_rejects_hooks_and_traversal(self):
        for name in ["../escape.py", "package/hook.pth", "payload.data/scripts/tool"]:
            with self.subTest(name=name):
                path = self.root / "payload.whl"
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr(name, b"bad")
                with self.assertRaises(stage.StagingError):
                    stage.install_wheel(path, self.root / "site")

    def test_cache_hash_mismatch_never_downloads_or_installs(self):
        item = {"filename": "payload.whl", "url": "https://files.pythonhosted.org/packages/payload.whl", "sha256": "0" * 64, "size": 4}
        (self.root / item["filename"]).write_bytes(b"evil")
        with patch.object(stage.subprocess, "run") as run:
            with self.assertRaises(stage.StagingError):
                stage.download_locked(item, self.root)
            run.assert_not_called()

    def test_declared_unused_cli_is_verified_and_omitted(self):
        path = self.root / "payload.whl"
        script = "payload.data/scripts/tool.py"
        content = b"print('unused CLI')\n"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(script, content)
            archive.writestr("payload/__init__.py", b"VALUE = 1\n")
        record = {"path": script, "size": len(content), "sha256": hashlib.sha256(content).hexdigest()}
        stage.install_wheel(path, self.root / "site", [record])
        self.assertEqual((self.root / "site/payload/__init__.py").read_bytes(), b"VALUE = 1\n")
        self.assertFalse((self.root / "site/payload.data").exists())

    def test_omission_cannot_hide_changed_missing_or_additional_scripts(self):
        script = "payload.data/scripts/tool.py"
        data = b"expected"
        record = {"path": script, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        for index, entries in enumerate([[(script, b"modified")], [],
                                         [(script, data), ("payload.data/scripts/extra", data)],
                                         [(script, data), (script, data)]]):
            with self.subTest(index=index):
                path = self.root / (str(index) + ".whl")
                with zipfile.ZipFile(path, "w") as archive:
                    for name, content in entries:
                        archive.writestr(name, content)
                with self.assertRaises(stage.StagingError):
                    stage.install_wheel(path, self.root / ("site" + str(index)), [record])

    def macho(self, cpu=0x100000c, deployment=14 << 16, dependency=None, rpath=None):
        commands = [struct.pack("<6I", 0x32, 24, 1, deployment, 0, 0)]
        if dependency:
            raw = dependency.encode() + b"\0"
            raw += b"\0" * ((-len(raw)) % 8)
            commands.append(struct.pack("<6I", 0xc, 24 + len(raw), 24, 0, 0, 0) + raw)
        if rpath:
            raw = rpath.encode() + b'\0'
            raw += b'\0' * ((-(12 + len(raw))) % 8)
            commands.append(struct.pack('<3I', 0x8000001c, 12 + len(raw), 12) + raw)
        payload = b"".join(commands)
        path = self.root / "native"
        path.write_bytes(struct.pack("<8I", 0xfeedfacf, cpu, 0, 2, len(commands), len(payload), 0, 0) + payload)
        return path

    def test_architecture_deployment_and_external_rpath_fail_closed(self):
        for options in [{"cpu": 0x1000007}, {"deployment": 15 << 16},
                        {"dependency": str(self.root / 'foreign/lib.dylib')},
                        {"dependency": str(self.system_lib / '..' / '..' / 'foreign/lib.dylib')}]:
            with self.subTest(options=options):
                with self.assertRaises(stage.StagingError):
                    stage.inspect_macho(self.macho(**options))
        report = stage.inspect_macho(self.macho(dependency=str(self.system_lib / 'system.dylib')))
        self.assertEqual(report["architecture"], "arm64")

    def test_existing_destination_is_never_replaced(self):
        bundle = self.root / "existing.app"
        bundle.mkdir()
        marker = bundle / "user-file"
        marker.write_bytes(b"unchanged")
        with self.assertRaises(stage.StagingError):
            stage.stage(bundle, self.root / "missing-lock", self.root / "cache", self.root, self.root / "helper")
        self.assertEqual(marker.read_bytes(), b"unchanged")

    def test_system_rpath_does_not_satisfy_missing_bundled_dependency(self):
        bundle = self.root / "App"
        python_relative = stage.RUNTIME + "/bin/python3"
        for relative in (python_relative, stage.HELPER):
            file = bundle / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"fixture")
        info = {"architecture": "arm64", "minimum_macos": "14.0.0",
                "dependencies": [str(self.system_lib / 'system.dylib')], "rpaths": [str(self.system_lib / 'swift')]}
        with patch.object(stage, "inspect_macho", return_value=info):
            self.assertEqual(len(stage.validate_native_tree(bundle, python_relative)), 2)
        with patch.object(stage, "inspect_macho", return_value={**info, "dependencies": ["@rpath/missing.dylib"]}):
            with self.assertRaises(stage.StagingError):
                stage.validate_native_tree(bundle, python_relative)

    def test_relocation_requires_exact_source_hash_before_mutation(self):
        path = self.root / "runtime/library.dylib"
        path.parent.mkdir()
        path.write_bytes(b"unapproved")
        lock = {"native_relocations": [{"path": "runtime/library.dylib", "operation": "delete_rpath", "source_sha256": "0" * 64, "old_rpath_sha256": hashlib.sha256(str(self.root / 'upstream/build').encode()).hexdigest()}]}
        with patch.object(stage.subprocess, "run") as run:
            with self.assertRaises(stage.StagingError):
                stage.apply_locked_relocations(self.root, lock)
            run.assert_not_called()

    def test_locked_rpath_digest_binds_exact_unused_binary_value(self):
        upstream = str(self.root / 'upstream-build')
        upstream_digest = hashlib.sha256(upstream.encode()).hexdigest()
        library = self.root / 'runtime/fixture.dylib'; library.parent.mkdir()
        for case in ('exact-unused', 'wrong-path-digest', 'used-by-dependency'):
            with self.subTest(case=case):
                library.write_bytes(self.macho(rpath=upstream,
                    dependency='@rpath/required.dylib' if case == 'used-by-dependency' else None).read_bytes())
                before = library.read_bytes()
                lock = {'native_relocations': [{'path': 'runtime/fixture.dylib', 'operation': 'delete_rpath',
                    'source_sha256': stage.sha256(library),
                    'old_rpath_sha256': '0' * 64 if case == 'wrong-path-digest' else upstream_digest}]}
                def remove(command, **options):
                    self.assertEqual(Path(command[0]).name, 'install_name_tool')
                    self.assertEqual(command[1:3], ['-delete_rpath', upstream])
                    Path(command[3]).write_bytes(self.macho().read_bytes())
                    return subprocess.CompletedProcess(command, 0)
                with patch.object(stage.subprocess, 'run', side_effect=remove) as execute:
                    if case == 'exact-unused':
                        stage.apply_locked_relocations(self.root, lock)
                        self.assertEqual(stage.inspect_macho(library)['rpaths'], [])
                        execute.assert_called_once()
                    else:
                        with self.assertRaises(stage.StagingError):
                            stage.apply_locked_relocations(self.root, lock)
                        execute.assert_not_called()
                        self.assertEqual(library.read_bytes(), before)

    def test_direct_platform_actions_clear_injection_in_a_real_neutral_child(self):
        injected = {key: str(self.root / 'injected' / key) for key in (
            'DYLD_INSERT_LIBRARIES', 'PYTHONPATH', 'BANKING_VIDEO_HELPER',
            'DEVELOPER_DIR', 'HOME', 'PATH', 'TMPDIR')}
        payload = b'locked fixture download'
        item = {'filename': 'fixture.tar.gz', 'url': 'https://files.pythonhosted.org/fixture.tar.gz',
                'size': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()}
        real_run = subprocess.run
        observed = []
        def neutral(command, **options):
            result = real_run([sys.executable, '-c', 'import json,os; print(json.dumps(dict(os.environ)))'],
                             check=True, capture_output=True, timeout=5, env=options['env'])
            observed.append((Path(command[0]).name, json.loads(result.stdout)))
            if Path(command[0]).name == 'curl':
                Path(command[command.index('--output') + 1]).write_bytes(payload)
            else:
                self.assertEqual(Path(command[0]).name, 'install_name_tool')
            return subprocess.CompletedProcess(command, 0)
        library = self.root / 'runtime/library.dylib'; library.parent.mkdir()
        library.write_bytes(b'locked fixture native input')
        lock = {'native_relocations': [{'path': 'runtime/library.dylib', 'operation': 'delete_rpath',
            'source_sha256': stage.sha256(library), 'old_rpath_sha256': hashlib.sha256(str(self.root / 'upstream/build').encode()).hexdigest()}]}
        native = {'dependencies': [], 'minimum_macos': '14.0.0'}
        with patch.dict(os.environ, injected), patch.object(stage.subprocess, 'run', side_effect=neutral):
            target = stage.download_locked(item, self.root / 'cache')
            with patch.object(stage, 'inspect_macho', side_effect=[
                    {**native, 'rpaths': [str(self.root / 'upstream/build')]}, {**native, 'rpaths': []}]):
                stage.apply_locked_relocations(self.root, lock)
            expected = stage.controlled_environment()
        self.assertEqual(target.read_bytes(), payload)
        self.assertEqual([command for command, _ in observed], ['curl', 'install_name_tool'])
        for _, environment in observed:
            self.assertFalse(any(key.startswith(('DYLD', 'PYTHON', 'BANKING')) for key in environment))
            self.assertNotIn('DEVELOPER_DIR', environment)
            self.assertEqual({key: environment[key] for key in expected}, expected)
            self.assertNotEqual(environment['HOME'], injected['HOME'])


if __name__ == "__main__":
    unittest.main()
