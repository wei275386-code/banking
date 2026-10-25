"""Local distribution contracts and failure injection; no Apple account required."""
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import distribute_macos_release as distribution
from scripts import package_macos_release as packaging


IDENTITY = "Developer ID Application: Synthetic Team (ABCDEFGHIJ)"
SUBMISSION = "e4cdef57-2fdd-4caa-abff-151fb8f49aa9"
TOOLS = {"identity": IDENTITY, "profile": "synthetic-notary",
         "notarytool": str(Path(tempfile.gettempdir()) / 'synthetic/notarytool'),
         "stapler": str(Path(tempfile.gettempdir()) / 'synthetic/stapler')}


class FakeMac:
    """Model artifact/mount changes, without accepting its results as release QA."""
    def __init__(self):
        self.calls = []
        self.images = {}
        self.info = {}
        self.fail = None

    def __call__(self, command, **kwargs):
        args = [str(x) for x in command]
        self.calls.append(args)
        if self.fail and self.fail(args):
            raise subprocess.CalledProcessError(1, args, output="credential-secret-never-print")
        stdout, stderr = "", ""
        if args[0].endswith("ditto"):
            source, destination = Path(args[-2]), Path(args[-1])
            if "-c" in args:
                destination.write_bytes(b"synthetic ZIP")
            elif source.is_dir():
                shutil.copytree(source, destination, symlinks=True, dirs_exist_ok=True)
            else:
                shutil.copyfile(source, destination)
                if source in self.images:
                    self.images[destination] = self.images[source]
        elif args[0].endswith("hdiutil"):
            if args[1] == "create":
                payload = Path(args[args.index("-srcfolder") + 1])
                destination = Path(args[-1])
                source = next(payload.glob("*.app"))
                # Keep a fixture copy after the implementation clears private payload.
                snapshot = destination.parents[1] / (destination.parent.name + "-snapshot.app")
                shutil.copytree(source, snapshot, symlinks=True)
                self.images[destination] = snapshot
                destination.write_bytes(b"synthetic DMG")
            elif args[1] == "verify":
                path = Path(args[-1])
                # Image publication hard-links preserve content; lookup by sibling
                # snapshot for the fixture, independent of its final path.
                if path not in self.images:
                    snapshots = sorted(path.parent.glob(".dmg-stage-*-snapshot.app"))
                    if snapshots:
                        self.images[path] = snapshots[-1]
            elif args[1] == "attach":
                mount = Path(args[args.index("-mountpoint") + 1])
                shutil.copytree(self.images[Path(args[-1])], mount / "FamilyReview.app", symlinks=True)
            elif args[1] == "detach":
                shutil.rmtree(Path(args[-1]) / "FamilyReview.app")
        elif args[0].endswith("codesign") and "--display" in args:
            stderr = f"Authority={IDENTITY}\nflags=0x10000(runtime)\n"
        elif args[0].endswith("notarytool") and args[1] == "info":
            stdout = json.dumps(self.info)
        return subprocess.CompletedProcess(args, 0, stdout, stderr)


class DistributionFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "repo"
        self.root.mkdir()
        (self.root / "release").mkdir()
        (self.root / "source.swift").write_text("// synthetic source\n")
        (self.root / "release/runtime-lock.json").write_text('{"synthetic":true}')
        (self.root / "release/source-allowlist.json").write_text(json.dumps({
            "profiles": {"production": ["source.swift", "release/runtime-lock.json"]}}))
        for args in (("init", "-q"), ("config", "user.name", "Synthetic"),
                     ("config", "user.email", "synthetic@example.invalid"),
                     ("add", "."), ("commit", "-qm", "fixture")):
            subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True, timeout=20)
        self.app = self.base / "Input.app"
        resources = self.app / "Contents/Resources"
        resources.mkdir(parents=True)
        for relative in ("Contents/MacOS/EvidenceBrowser", "Contents/Helpers/SyncHost"):
            target = self.app / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"synthetic Mach-O")
        self.version = {"app_version": "1.2.3", "build_number": 42}
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "local.banking.family-review", "CFBundleVersion": "42",
            "CFBundleShortVersionString": "1.2.3"}))
        (resources / "bootstrap.json").write_text(json.dumps({"kind": "empty", "workspace_created": False}))
        (resources / "runtime-manifest.json").write_text(json.dumps({"native_code": [], "files": []}))
        provenance = {"configuration": "release", "architecture": "arm64",
                      "version": self.version, "qa_identifier": False, "signing": "developer-id",
                      "additional_native_code": {},
                      "runtime_lock_sha256": distribution.digest_file(self.root / "release/runtime-lock.json"),
                      "runtime_manifest_sha256": distribution.digest_file(resources / "runtime-manifest.json"),
                      **distribution.source_identity(self.root, False)}
        (resources / "build-provenance.json").write_text(json.dumps(provenance))
        self.mac = FakeMac()
        self.stage = self.base / "stage"
        self.receipt = self.stage / "distribution-receipt.json"

    def prepare(self, candidate=False):
        if candidate:
            self.modify_provenance(signing="ad-hoc")
        with patch.object(distribution, "preflight", return_value={"identity": "-", "profile": None} if candidate else TOOLS):
            return distribution.prepare(self.root, self.stage, app=self.app,
                                        mode="candidate" if candidate else "developer-id", runner=self.mac)

    def modify_provenance(self, **values):
        path = self.app / "Contents/Resources/build-provenance.json"
        value = json.loads(path.read_text())
        value.update(values)
        path.write_text(json.dumps(value))

    def read(self):
        return json.loads(self.receipt.read_text())

    def submit(self, failure=False, unknown=False):
        def uploader(command, callback):
            self.assertEqual(self.read()["artifacts"][distribution.active_kind(self.read())]["state"], "submission_started")
            if not unknown:
                callback(SUBMISSION)
            if failure or unknown:
                raise distribution.DistributionError("UPLOAD_TIMEOUT_RESUME_RECEIPT")
        return distribution.submit(self.receipt, runner=self.mac, uploader=uploader)

    def accept(self, status="Accepted"):
        value = self.read()
        artifact = value["artifacts"][distribution.active_kind(value)]
        self.mac.info = {"id": SUBMISSION, "name": artifact["name"], "status": status}

    def test_candidate_creates_verified_mounted_dmg_without_apple_calls(self):
        result = self.prepare(candidate=True)
        self.assertEqual(result["phase"], "candidate_dmg")
        self.assertFalse(result["distribution_ready"])
        self.assertFalse(result["installed"])
        self.assertTrue(any(args[1] == "attach" for args in self.mac.calls))
        self.assertFalse(any("notarytool" in args[0] or "spctl" in args[0] for args in self.mac.calls))
        with self.assertRaisesRegex(distribution.DistributionError, "CANDIDATE_CANNOT_NOTARIZE"):
            self.submit()

    def test_two_async_submissions_staple_app_then_dmg_and_verify_gatekeeper(self):
        self.prepare()
        self.submit()
        self.accept("In Progress")
        self.assertEqual(distribution.resume(self.receipt, runner=self.mac)["phase"], "app_pending")
        self.accept()
        self.assertEqual(distribution.resume(self.receipt, runner=self.mac)["phase"], "dmg_prepared")
        self.submit()
        self.accept()
        result = distribution.resume(self.receipt, runner=self.mac)
        self.assertEqual(result["phase"], "distribution_verified")
        self.assertEqual(result["status"], "candidate")  # does not grant distribution approval
        self.assertTrue(result["distribution_ready"])
        self.assertEqual(len([args for args in self.mac.calls if "spctl" in args[0]]), 2)
        self.assertEqual(distribution.resume(self.receipt, runner=self.mac)["phase"], "distribution_verified")

    def test_upload_timeout_preserves_id_and_blocks_duplicate_submit(self):
        self.prepare()
        with self.assertRaises(distribution.DistributionError):
            self.submit(failure=True)
        self.assertEqual(self.read()["artifacts"]["app"]["submission_id"], SUBMISSION)
        with self.assertRaisesRegex(distribution.DistributionError, "RESUME_EXISTING_SUBMISSION"):
            self.submit()
        self.accept()
        self.assertEqual(distribution.resume(self.receipt, runner=self.mac)["phase"], "dmg_prepared")

    def test_unknown_submission_fenced_and_history_id_recovery_bound_to_name(self):
        self.prepare()
        with self.assertRaises(distribution.DistributionError):
            self.submit(unknown=True)
        with self.assertRaisesRegex(distribution.DistributionError, "SUBMISSION_ID_UNKNOWN"):
            distribution.resume(self.receipt, runner=self.mac)
        self.accept()
        self.mac.info["name"] = "another-upload.zip"
        with self.assertRaisesRegex(distribution.DistributionError, "NOTARY_RECEIPT_MISMATCH"):
            distribution.resume(self.receipt, submission_id=SUBMISSION, runner=self.mac)
        self.accept()
        self.assertEqual(distribution.resume(self.receipt, submission_id=SUBMISSION, runner=self.mac)["phase"], "dmg_prepared")

    def test_rejected_notary_result_never_marks_distribution_ready(self):
        self.prepare()
        self.submit()
        self.accept("Invalid")
        with self.assertRaisesRegex(distribution.DistributionError, "NOTARIZATION_REJECTED"):
            distribution.resume(self.receipt, runner=self.mac)
        self.assertEqual(self.read()["phase"], "app_rejected")
        self.assertFalse(self.read()["distribution_ready"])

    def test_artifact_mutation_blocks_resume_before_network(self):
        self.prepare()
        self.submit()
        archive = self.stage / self.read()["artifacts"]["app"]["name"]
        archive.write_bytes(b"tampered")
        self.mac.calls.clear()
        with self.assertRaisesRegex(distribution.DistributionError, "ARTIFACT_CHANGED"):
            distribution.resume(self.receipt, runner=self.mac)
        self.assertFalse(self.mac.calls)

    def test_stapling_failure_can_resume_without_reupload(self):
        self.prepare()
        self.submit()
        self.accept()
        self.mac.fail = lambda args: "stapler" in args[0] and args[1] == "staple"
        with self.assertRaises(subprocess.SubprocessError):
            distribution.resume(self.receipt, runner=self.mac)
        self.assertFalse(self.read()["distribution_ready"])
        self.mac.fail = None
        self.assertEqual(distribution.resume(self.receipt, runner=self.mac)["phase"], "dmg_prepared")

    def test_gatekeeper_failure_does_not_mark_ready_and_detaches_mount(self):
        self.prepare()
        self.submit()
        self.accept()
        distribution.resume(self.receipt, runner=self.mac)
        self.submit()
        self.accept()
        self.mac.fail = lambda args: "spctl" in args[0] and "execute" in args
        with self.assertRaises(subprocess.SubprocessError):
            distribution.resume(self.receipt, runner=self.mac)
        self.assertFalse(self.read()["distribution_ready"])
        self.assertEqual(self.mac.calls[-1][1], "detach")
        self.mac.fail = None
        self.assertTrue(distribution.resume(self.receipt, runner=self.mac)["distribution_ready"])

    def test_existing_stage_rejected_without_overwrite(self):
        self.stage.mkdir()
        with self.assertRaisesRegex(distribution.DistributionError, "NEW_STAGING_DIRECTORY_REQUIRED"):
            self.prepare()

    def test_dirty_checkout_blocks_production_before_stage(self):
        (self.root / "source.swift").write_text("// dirty\n")
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse(self.stage.exists())

    def test_mismatched_commit_provenance_rejected(self):
        self.modify_provenance(commit="0" * 40)
        with self.assertRaisesRegex(distribution.DistributionError, "APP_SOURCE_PROVENANCE_MISMATCH"):
            self.prepare()

    def test_qa_identifier_is_not_production(self):
        self.modify_provenance(qa_identifier=True)
        with self.assertRaisesRegex(distribution.DistributionError, "CLEAN_PRODUCTION_COMMIT_REQUIRED"):
            self.prepare()

    def test_nonempty_bootstrap_rejected(self):
        (self.app / "Contents/Resources/bootstrap.json").write_text('{"kind":"workspace","workspace_created":true}')
        with self.assertRaisesRegex(distribution.DistributionError, "EMPTY_BOOTSTRAP_REQUIRED"):
            self.prepare()

    def test_external_symlink_rejected(self):
        (self.app / "Contents/Resources/private-data").symlink_to(self.root / "source.swift")
        with self.assertRaisesRegex(distribution.DistributionError, "EXTERNAL_APP_SYMLINK"):
            self.prepare()

    def test_receipt_path_escape_rejected(self):
        with self.assertRaisesRegex(distribution.DistributionError, "UNSAFE_ARTIFACT_PATH"):
            distribution.stage_file(self.stage, "../Installed.app")

    def test_receipt_and_staging_guards_share_canonical_os_applications_root(self):
        applications = self.base.resolve() / 'mock-os-applications'
        applications.mkdir()
        receipt = applications / 'distribution-receipt.json'
        original = b'{"schema_version":1,"mode":"candidate"}'
        receipt.write_bytes(original)
        alias = self.base / 'mock-os-applications-alias'
        alias.symlink_to(applications, target_is_directory=True)
        for discovered in (applications, alias):
            with self.subTest(discovered=discovered), patch.object(distribution, 'macos_directory', return_value=discovered):
                with self.assertRaisesRegex(distribution.DistributionError, 'UNSAFE_RECEIPT'):
                    with distribution.locked_receipt(receipt):
                        self.fail('applications receipt was accepted')
                with self.assertRaisesRegex(distribution.DistributionError, 'UNSAFE_STAGING_DIRECTORY'):
                    distribution.stage_file(applications, 'artifact.zip')
                self.assertEqual(receipt.read_bytes(), original)
                self.assertFalse(receipt.with_suffix('.lock').exists())

    def test_ignored_production_source_is_not_a_committed_input(self):
        (self.root / ".git/info/exclude").write_text("ignored.swift\n")
        (self.root / "ignored.swift").write_text("// uncommitted release source\n")
        source = distribution.source_identity(self.root, False)
        source["source_files"]["ignored.swift"] = distribution.digest_file(self.root / "ignored.swift")
        with self.assertRaises(subprocess.SubprocessError):
            distribution.committed_inputs(self.root, source)

    def test_final_recheck_failure_revokes_readiness(self):
        self.prepare()
        self.submit()
        self.accept()
        distribution.resume(self.receipt, runner=self.mac)
        self.submit()
        self.accept()
        distribution.resume(self.receipt, runner=self.mac)
        self.mac.fail = lambda args: "spctl" in args[0]
        with self.assertRaises(subprocess.SubprocessError):
            distribution.resume(self.receipt, runner=self.mac)
        self.assertFalse(self.read()["distribution_ready"])

    def test_failed_dmg_creation_retries_from_accepted_app_without_reupload(self):
        self.prepare()
        self.submit()
        self.accept()
        self.mac.fail = lambda args: args[0].endswith("hdiutil") and args[1] == "create"
        with self.assertRaises(subprocess.SubprocessError):
            distribution.resume(self.receipt, runner=self.mac)
        self.mac.fail = None
        self.assertEqual(distribution.resume(self.receipt, runner=self.mac)["phase"], "dmg_prepared")


class DistributionPreflightTests(unittest.TestCase):
    def test_no_identity_or_development_identity_accepted_for_production(self):
        for identity in (None, "-", "Apple Development: Synthetic (ABCDEFGHIJ)"):
            with self.assertRaisesRegex(distribution.DistributionError, "EXPLICIT_DEVELOPER_ID_REQUIRED"):
                distribution.preflight("developer-id", identity, "fixture")

    def test_candidate_does_not_allow_misleading_notary_profile(self):
        with self.assertRaisesRegex(distribution.DistributionError, "CANDIDATE_USES_AD_HOC_ONLY"):
            distribution.preflight("candidate", None, "fixture")

    def test_profile_is_required_and_credentials_cannot_enter_cli_args(self):
        with self.assertRaisesRegex(distribution.DistributionError, "EXPLICIT_KEYCHAIN_PROFILE_REQUIRED"):
            distribution.preflight("developer-id", IDENTITY, "--password secret")

    def test_unavailable_developer_id_fails_without_echoing_inventory(self):
        runner = lambda args: subprocess.CompletedProcess(args, 0, '"Apple Development: secret"', "")
        with self.assertRaisesRegex(distribution.DistributionError, "DEVELOPER_ID_UNAVAILABLE"):
            distribution.preflight("developer-id", IDENTITY, "fixture", runner)

    def test_streaming_upload_keeps_id_even_on_timeout(self):
        recorded = []
        code = f"import time; print('id: {SUBMISSION}', flush=True); time.sleep(2)"
        with self.assertRaisesRegex(distribution.DistributionError, "UPLOAD_TIMEOUT"):
            distribution.upload([sys.executable, "-c", code], recorded.append, timeout=0.15)
        self.assertEqual(recorded, [SUBMISSION])

    def test_platform_runners_and_upload_worker_remove_real_environment_injection(self):
        injected = {'DYLD_INSERT_LIBRARIES': '/synthetic/injection.dylib',
            'PYTHONPATH': '/synthetic/python', 'BANKING_VIDEO_HELPER': '/synthetic/helper',
            'DEVELOPER_DIR': '/synthetic/Xcode', 'HOME': '/synthetic/home', 'PATH': '/synthetic/bin'}
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        probe = Path(temporary.name).resolve() / 'neutral-worker-environment.json'
        code = 'import json,os; print(json.dumps(dict(os.environ)))'
        upload_code = ('import json,os; from pathlib import Path; Path(' + repr(str(probe)) +
            ').write_text(json.dumps(dict(os.environ))); print(' + repr('id: ' + SUBMISSION) + ', flush=True)')
        recorded = []
        with patch.dict(os.environ, injected):
            first = json.loads(distribution.run([sys.executable, '-c', code], env=injected).stdout)
            second = json.loads(packaging.run([sys.executable, '-c', code], env=injected).stdout)
            # Exercise the streaming worker using only a neutral local process;
            # no notarytool or remote submission is invoked by this test.
            distribution.upload([sys.executable, '-c', upload_code], recorded.append, timeout=5)
            expected = distribution.controlled_environment()
        third = json.loads(probe.read_text())
        self.assertEqual(recorded, [SUBMISSION])
        for environment in (first, second, third):
            self.assertFalse(any(key.startswith(('DYLD', 'PYTHON', 'BANKING')) for key in environment))
            self.assertNotIn('DEVELOPER_DIR', environment)
            self.assertEqual({key: environment[key] for key in expected}, expected)
            self.assertNotEqual(environment['HOME'], injected['HOME'])


if __name__ == "__main__":
    unittest.main()
