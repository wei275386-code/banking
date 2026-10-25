"""Synthetic product CLI integration; no private workspace, install or cloud."""
import contextlib
import io
import shutil
import os
import signal
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from scripts import workspace_cli as cli
from scripts import workspace_state as state
from scripts.release_contracts import canonical_json, digest_file, parse_json
from scripts.workspace_initialization import create_workspace


class WorkspaceCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.workspace = self.root / "原资料 中文"
        self.paths = create_workspace(self.workspace)
        self.counter = 0

    def tearDown(self):
        self.temporary.cleanup()

    def invoke(self, command, *options, workspace=None):
        self.counter += 1
        result = self.root / ("receipt-" + str(self.counter) + ".json")
        receipt_id = str(uuid.uuid4())
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = cli.main(["--workspace", str(workspace or self.workspace), command,
                "--result-file", str(result), "--receipt-id", receipt_id, *map(str, options)])
        receipt = parse_json(output.getvalue().encode("utf-8"))
        if result.exists():
            self.assertEqual(canonical_json(state._read(result)), canonical_json(receipt))
        self.assertEqual(receipt["receipt_id"], receipt_id)
        self.assertEqual(receipt["exit_code"], status)
        return status, receipt

    def assert_tuple(self, receipt, workspace):
        paths = state.WorkspacePaths(workspace)
        pointer = paths.resolve_active(verify_files=False).pointer
        self.assertEqual(receipt["workspace_id"], paths.workspace_id)
        for key in ("state_id", "local_revision", "state_manifest_hash"):
            self.assertEqual(receipt["state"][key], pointer[key])
        artifact = receipt.get("artifact")
        if artifact:
            self.assertEqual(digest_file(Path(artifact["path"])), artifact["sha256"])

    def test_sigterm_handler_does_not_interrupt_owned_cleanup_and_is_restored(self):
        from argparse import Namespace
        args = Namespace()
        previous = signal.getsignal(signal.SIGTERM)
        with cli._termination_cancellation(args):
            handler = signal.getsignal(signal.SIGTERM)
            handler(signal.SIGTERM, None)
            self.assertTrue(args.termination_requested())
            handler(signal.SIGTERM, None)  # A second signal cannot raise in finally.
        self.assertIs(signal.getsignal(signal.SIGTERM), previous)

    def test_create_durable_receipt_pins_actual_new_state_manifest(self):
        target = self.root / "新的 家庭资料"
        status, receipt = self.invoke("create", workspace=target)
        self.assertEqual(status, 0)
        self.assertEqual(receipt["command"], "create")
        self.assertEqual(receipt["outcome"], "success")
        self.assert_tuple(receipt, target)
        self.assertEqual(receipt["artifact"]["kind"], "state-manifest")
        self.assertEqual(receipt["artifact"]["sha256"], receipt["state"]["state_manifest_hash"])
        internal = target / "device/maintenance-receipts" / (receipt["receipt_id"] + ".json")
        self.assertEqual(state._read(internal), receipt)
        before = dict(state.WorkspacePaths(target).resolve_active().pointer)
        status, rejected = self.invoke("create", workspace=target)
        self.assertEqual(status, 1)
        self.assertEqual(rejected["outcome"], "failed")
        self.assertEqual(dict(state.WorkspacePaths(target).resolve_active().pointer), before)

    def test_pre_cancel_never_publishes_new_workspace(self):
        cancel = self.root / "cancel"
        cancel.write_bytes(b"")
        target = self.root / "取消的新资料"
        status, receipt = self.invoke("create", "--cancel-file", cancel, workspace=target)
        self.assertEqual(status, 1)
        self.assertEqual(receipt["outcome"], "failed")
        self.assertFalse(target.exists())

    def test_cancel_during_initializer_is_checked_before_final_publication(self):
        from scripts import workspace_initialization as initialization
        cancel = self.root / "cancel-during-init"
        target = self.root / "initializer-cancelled"
        real_initialize = initialization.initialize_empty_state
        def initialize_then_cancel(transaction):
            real_initialize(transaction)
            cancel.write_bytes(b"")
        with patch.object(initialization, "initialize_empty_state", side_effect=initialize_then_cancel):
            status, receipt = self.invoke("create", "--cancel-file", cancel, workspace=target)
        self.assertEqual(status, 1)
        self.assertEqual(receipt["outcome"], "failed")
        self.assertIn("cancelled before publication", receipt["error"]["message"])
        self.assertFalse(target.exists())
        self.assertFalse(list(self.root.glob(".*.creating")))

    def test_timeout_during_initializer_is_checked_before_final_publication(self):
        from scripts import workspace_initialization as initialization
        target = self.root / "initializer-timeout"
        real_initialize = initialization.initialize_empty_state
        clock = {"value": 0}
        def initialize_then_timeout(transaction):
            real_initialize(transaction)
            clock["value"] = 10
        with patch.object(initialization, "initialize_empty_state", side_effect=initialize_then_timeout), patch.object(
                cli.time, "monotonic", side_effect=lambda: clock["value"]):
            status, receipt = self.invoke("create", "--timeout-seconds", 5, workspace=target)
        self.assertEqual(status, 1)
        self.assertIn("timeout before publication", receipt["error"]["message"])
        self.assertFalse(target.exists())

    def test_external_receipt_failure_keeps_internal_verified_published_proof(self):
        target = self.root / "已发布但外部receipt失败"
        real_write = cli._write
        def fail_external(path, value):
            if Path(path).parent == self.root:
                raise OSError("synthetic result-file failure")
            return real_write(path, value)
        with patch("scripts.workspace_cli._write", side_effect=fail_external):
            status, receipt = self.invoke("create", workspace=target)
        self.assertEqual(status, 2)
        self.assertEqual(receipt["outcome"], "needsReview")
        self.assert_tuple(receipt, target)
        internal = state._read(target / "device/maintenance-receipts" / (receipt["receipt_id"] + ".json"))
        self.assertEqual(internal["outcome"], "success")
        self.assert_tuple(internal, target)



if __name__ == "__main__":
    unittest.main()
