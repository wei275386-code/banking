"""Read-only manifest gates and bootstrap exec/lease contract."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import runtime_doctor as doctor
import processor_bootstrap as bootstrap


class RuntimeDoctorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.bundle = self.root / "Candidate.app"
        self.scripts = "Contents/Resources/processor/scripts"
        files = ["Contents/Resources/ProcessorRuntime/bin/python3.13", self.scripts + "/processor_bootstrap.py", self.scripts + "/runtime_doctor.py", self.scripts + "/app_review.py", "Contents/Helpers/VideoRecords", "Contents/Resources/defaults/default-config.json"]
        records = []
        for index, relative in enumerate(files):
            path = self.bundle / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            raw = ("synthetic-" + str(index)).encode()
            path.write_bytes(raw)
            records.append({"path": relative, "kind": "file", "size": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})
        license_path = "Contents/Resources/runtime-licenses.json"
        license_inventory = {"runtime_lock_sha256": "0" * 64, "distribution_ready": False, "artifacts": [{"status": "needs_review", "license_files": [records[-1]]}]}
        raw = json.dumps(license_inventory).encode()
        (self.bundle / license_path).write_bytes(raw)
        records.append({"path": license_path, "kind": "file", "size": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})
        self.manifest = {"runtime_version": "synthetic-runtime", "architecture": "arm64", "minimum_macos": "14.0", "lock_sha256": "0" * 64, "licenses": {"path": license_path, "status": "needs_review"}, "python": {"path": files[0], "version": "3.13.9"}, "scripts": {"path": self.scripts}, "bootstrap": {"path": files[1]}, "doctor": {"path": files[2]}, "helper": {"path": files[4]}, "defaults": {"path": "Contents/Resources/defaults"}, "entry_scripts": ["app_review.py", "runtime_doctor.py"], "files": records, "dependencies": [{"name": name, "version": "synthetic-version"} for name in ("pypdf", "openpyxl", "pdfplumber", "pypdfium2")]}
        self.save()

    def save(self):
        (self.bundle / doctor.MANIFEST).write_text(json.dumps(self.manifest))

    def tearDown(self):
        self.temporary.cleanup()

    def test_manifest_validation_is_read_only(self):
        before = {p.relative_to(self.bundle): p.read_bytes() for p in self.bundle.rglob("*") if p.is_file()}
        self.assertEqual(doctor.load_manifest(self.bundle)["architecture"], "arm64")
        after = {p.relative_to(self.bundle): p.read_bytes() for p in self.bundle.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_hash_mismatch_prevents_all_functional_probes(self):
        (self.bundle / self.manifest["python"]["path"]).write_bytes(b"changed")
        with patch.object(doctor.importlib, "import_module") as imports, patch.object(doctor.sqlite3, "connect") as sql, patch.object(doctor.subprocess, "run") as helper:
            report = doctor.inspect_runtime(self.bundle)
            self.assertFalse(report["ok"])
            self.assertEqual(report["checks"][0]["code"], "RUNTIME_HASH_MISMATCH")
            imports.assert_not_called()
            sql.assert_not_called()
            helper.assert_not_called()
            self.assertNotIn(str(self.bundle), json.dumps(report))

    def test_paths_escape_untracked_module_and_duplicate_are_rejected(self):
        with self.assertRaises(doctor.RuntimeErrorCode):
            doctor.bundle_path(self.bundle, "Contents/../../escape")
        injected = self.bundle / self.scripts / "injected.py"
        injected.write_text("raise RuntimeError('injected')")
        with self.assertRaises(doctor.RuntimeErrorCode) as caught:
            doctor.load_manifest(self.bundle)
        self.assertEqual(caught.exception.code, "RUNTIME_UNTRACKED_FILE")
        injected.unlink()
        self.manifest["files"].append(self.manifest["files"][0])
        self.save()
        with self.assertRaises(doctor.RuntimeErrorCode):
            doctor.load_manifest(self.bundle)

    def test_environment_cannot_select_external_code(self):
        environment = {key: str(self.root / 'external' / key) for key in (
            'PYTHONHOME', 'PYTHONPATH', 'DYLD_LIBRARY_PATH', 'BANKING_PROCESSOR_PROJECT',
            'BANKING_MERCHANT_DB', 'TMPDIR', 'HOME')}
        cleaned = bootstrap.clean_environment(environment, self.bundle, self.bundle / "Contents/Helpers/VideoRecords")
        for key in ("PYTHONHOME", "PYTHONPATH", "DYLD_LIBRARY_PATH", "BANKING_PROCESSOR_PROJECT", "BANKING_MERCHANT_DB"):
            self.assertNotIn(key, cleaned)
        self.assertEqual(cleaned["PATH"], os.confstr('CS_PATH') or os.defpath)
        self.assertEqual(cleaned["TMPDIR"], environment['TMPDIR'])

    def test_external_helper_requires_independent_pin_and_clean_verifier_environment(self):
        helper = self.bundle / "Contents/Helpers/FinancialProjection"
        helper.write_bytes(b"synthetic native helper")
        record = {"path": "Contents/Helpers/FinancialProjection", "kind": "macho",
                  "size": helper.stat().st_size, "sha256": doctor.digest_file(helper)}
        self.manifest["files"].append(record)
        self.manifest["native_code"] = {record["path"]: {"architecture": "arm64"}}
        self.save()
        pin = {"sha256": record["sha256"], "runtime_manifest_sha256": doctor.digest_file(self.bundle / doctor.MANIFEST)}
        with patch.object(doctor.subprocess, "run") as codesign:
            with self.assertRaises(doctor.RuntimeErrorCode) as caught:
                doctor.validate_packaged_helper(helper)
            self.assertEqual(caught.exception.code, "RUNTIME_HELPER_UNTRUSTED")
            codesign.assert_not_called()
            with patch.dict(os.environ, {"DYLD_INSERT_LIBRARIES": str(self.root / 'injected'), "PYTHONPATH": str(self.root / 'injected')}):
                self.assertEqual(doctor.validate_packaged_helper(helper, trusted_pin=pin)["sha256"], record["sha256"])
            self.assertEqual(codesign.call_count, 2)
            for call in codesign.call_args_list:
                self.assertEqual(call.kwargs["env"]["PATH"], os.confstr('CS_PATH') or os.defpath)
                self.assertNotIn("DYLD_INSERT_LIBRARIES", call.kwargs["env"])
                self.assertNotIn("PYTHONPATH", call.kwargs["env"])
        with self.assertRaises(doctor.RuntimeErrorCode):
            doctor.validate_packaged_helper(helper, trusted_pin={**pin, "sha256": "0" * 64})

    def test_uninventoried_processor_metadata_is_rejected(self):
        injected = self.bundle / "Contents/Resources/release/untracked-runtime-data.json"
        injected.parent.mkdir(parents=True)
        injected.write_text("{}")
        with self.assertRaises(doctor.RuntimeErrorCode) as caught:
            doctor.load_manifest(self.bundle)
        self.assertEqual(caught.exception.code, "RUNTIME_UNTRACKED_FILE")

    def test_bootstrap_preserves_fd_zero_and_executes_isolated_stage(self):
        entry = self.bundle / self.scripts / "app_review.py"
        helper = self.bundle / "Contents/Helpers/VideoRecords"
        output = str(self.root / 'synthetic-workspace')
        with patch.object(bootstrap, "prepare", return_value=(self.bundle, entry, helper)), patch.object(bootstrap.os, "set_inheritable") as inheritable, patch.object(bootstrap.os, "execve", side_effect=SystemExit(0)) as execute:
            with self.assertRaises(SystemExit):
                bootstrap.main(["--bundle-root", str(self.bundle), "--entry", "app_review.py", "--", "--output", output])
            inheritable.assert_called_once_with(0, True)
            executable, arguments, environment = execute.call_args.args
            self.assertEqual(executable, sys.executable)
            self.assertEqual(arguments[1:5], ["-I", "-B", "-S", "-c"])
            self.assertEqual(arguments[-2:], ["--output", output])
            self.assertEqual(environment["BANKING_RUNTIME_BUNDLE"], str(self.bundle))


if __name__ == "__main__":
    unittest.main()
