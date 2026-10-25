"""Synthetic transaction/crash tests. Never touch a user's workspace or cloud."""
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

from scripts import workspace_state as state
from scripts.release_contracts import canonical_json, digest_bytes, parse_json
from scripts.workspace_effects import derive_membership

ROOT = Path(__file__).resolve().parents[1]


def initialize(transaction):
    connection = transaction.connect()
    connection.execute("CREATE TABLE records(id TEXT PRIMARY KEY, value INTEGER NOT NULL)")
    connection.commit()
    transaction.write_json("config/review-import-sources.json", {"sources": []})
    transaction.write_json("review/financial-review.json", {"summary": {"total": 0, "from": None}})
    transaction.write_json("review/payment-evidence.json", {"summary": {"total": 0}})
    transaction.write_json("review/coverage.json", {"mode": "empty",
        "from": None, "to": None, "observed_from": None, "observed_to": None,
        "pending_from": None, "pending_to": None, "basis": {"kind": "no-reliable-dates",
        "source_ids": []}, "revision": 0})


def operation(transaction, request="request-a", effect="record-a"):
    ledger = parse_json((transaction.root / "operation-results.json").read_bytes())
    included = [item for item in ledger['results'] if item['request_id'] == request]
    if included:
        return included[0]
    connection = transaction.connect()
    connection.execute("INSERT OR IGNORE INTO records VALUES (?, 1)", (effect,))
    connection.commit()
    return {"version": 2, "operation_id": "operation-" + request, "request_id": request,
        "input_hash": digest_bytes(canonical_json([])), "algorithm_version": "synthetic-1",
        "outcome": "success", "inputs": [], "membership": derive_membership(transaction, request, ledger)}


class WorkspaceTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name).resolve()
        self.paths = state.WorkspacePaths.create(self.directory / "workspace", initialize)

    def tearDown(self):
        self.temporary.cleanup()

    def test_create_fresh_identity_empty_defaults_without_host_authority(self):
        other = state.WorkspacePaths.create(self.directory / "other", initialize)
        self.assertNotEqual(self.paths.workspace_id, other.workspace_id)
        identity = parse_json((self.paths.workspace / "device/device-identity.json").read_bytes())
        self.assertEqual(set(identity), {"device_id"})
        self.assertFalse((self.paths.workspace / "device/host-authorization.json").exists())
        self.assertNotEqual(identity["device_id"], parse_json((other.workspace / "device/device-identity.json").read_bytes())["device_id"])
        handle = self.paths.resolve_active()
        self.assertEqual(handle.local_revision, 0)
        self.assertEqual(self.paths.report_paths()[0], handle.review / "financial-review.json")
        with self.assertRaises(state.WorkspaceError):
            state.WorkspacePaths.create(self.paths.workspace, initialize)

    def test_failed_create_leaves_no_selectable_workspace(self):
        target = self.directory / "failed"
        def broken(transaction):
            initialize(transaction)
            raise OSError("full disk")
        with self.assertRaises(OSError):
            state.WorkspacePaths.create(target, broken)
        self.assertFalse(target.exists())
        self.assertFalse(list(target.parent.glob(".failed.*.creating")))

    def test_cancel_after_initialization_is_observed_before_workspace_publish(self):
        target = self.directory / "cancelled-create"
        before = self.paths.resolve_active().pointer
        initialized = []
        def initializer(transaction):
            initialize(transaction)
            initialized.append(True)
        def cancel():
            self.assertEqual(initialized, [True])
            self.assertFalse(target.exists())
            raise state.WorkspaceError("cancelled before publication")
        with self.assertRaises(state.WorkspaceError):
            state.WorkspacePaths.create(target, initializer, before_publish=cancel)
        self.assertFalse(target.exists())
        self.assertFalse(list(target.parent.glob(".cancelled-create.*.creating")))
        self.assertEqual(self.paths.resolve_active().pointer, before)

    def test_mutable_snapshot_has_independent_inode_and_abort_leaves_active(self):
        before = self.paths.resolve_active()
        with state.MaintenanceGate(self.paths).acquire("processor") as token:
            with state.StateTransaction.begin(self.paths, token) as transaction:
                for relative in ("banking.sqlite3", "review/financial-review.json", "operation-results.json"):
                    self.assertNotEqual((before.root / relative).stat().st_ino,
                                        (transaction.root / relative).stat().st_ino)
                connection = transaction.connect()
                connection.execute("INSERT INTO records VALUES ('a', 7)")
                connection.commit()
                transaction.write_json("review/financial-review.json", {"summary": {"total": 7}})
        self.assertEqual(self.paths.resolve_active().pointer, before.pointer)
        with closing(sqlite3.connect(before.database)) as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM records").fetchone()[0], 0)

    def test_noop_does_not_advance_revision(self):
        before = self.paths.resolve_active()
        with state.MaintenanceGate(self.paths).acquire("edit") as token:
            with state.StateTransaction.begin(self.paths, token) as transaction:
                transaction.prepare()
                self.assertTrue(transaction.is_noop)
                self.assertEqual(transaction.commit().pointer, before.pointer)
        self.assertEqual(self.paths.resolve_active().pointer, before.pointer)

    def test_commit_freezes_state_and_ledger_with_deduplicated_effects(self):
        before = self.paths.resolve_active()
        with state.MaintenanceGate(self.paths).acquire("processor") as token:
            with state.StateTransaction.begin(self.paths, token) as transaction:
                connection = transaction.connect()
                connection.execute("INSERT INTO records VALUES ('a', 7)")
                connection.commit()
                transaction.prepare(operation(transaction))
                self.assertEqual(transaction.prepared_result["phase"], "prepared")
                self.assertIsNone(transaction.prepared_result["outcome"])
                handle = transaction.commit()
        self.assertEqual(handle.local_revision, before.local_revision + 1)
        self.assertTrue(before.root.exists())
        manifest = parse_json((handle.root / "state-manifest.json").read_bytes())
        self.assertEqual(manifest["parent_pointer"], before.pointer)
        ledger = parse_json((handle.root / "operation-results.json").read_bytes())
        self.assertEqual(ledger["state_id"], handle.state_id)
        self.assertEqual(ledger["results"][0]["phase"], "committed")
        with state.MaintenanceGate(self.paths).acquire("retry") as token:
            with state.StateTransaction.begin(self.paths, token) as retry:
                retry.prepare(operation(retry))
                self.assertEqual(retry.commit().pointer, handle.pointer)
            with state.StateTransaction.begin(self.paths, token) as duplicate:
                with self.assertRaises(state.StateConflict):
                    prior = parse_json((duplicate.root / "operation-results.json").read_bytes())['results'][0]
                    duplicate.prepare(dict(prior, operation_id='operation-request-b', request_id='request-b'))

    def test_duplicate_request_cannot_add_new_effects_or_business_changes(self):
        with state.MaintenanceGate(self.paths).acquire("processor") as token:
            with state.StateTransaction.begin(self.paths, token) as first:
                first.prepare(operation(first))
                first.commit()
            before = self.paths.resolve_active()
            with state.StateTransaction.begin(self.paths, token) as retry:
                retry.write_json("review/financial-review.json", {"summary": {"total": 10}})
                with self.assertRaises(state.WorkspaceError):
                    retry.prepare(operation(retry))
            self.assertEqual(self.paths.resolve_active().pointer, before.pointer)

    def test_source_store_links_only_immutable_materials_and_preserves_parent(self):
        material = self.directory / "original.csv"
        material.write_bytes(b"date,amount\n2026-10-01,7\n")
        with state.MaintenanceGate(self.paths).acquire("processor") as token:
            source_hash = self.paths.retain_source(material, token)
            with state.StateTransaction.begin(self.paths, token) as transaction:
                attached = transaction.attach_source(source_hash, "sources/original.csv")
                self.assertFalse(attached.stat().st_mode & 0o222)
                with self.assertRaises(state.WorkspaceError):
                    transaction.path("sources/original.csv")
                transaction.prepare(operation(transaction))
                committed = transaction.commit()
            with state.StateTransaction.begin(self.paths, token) as next_state:
                linked = next_state.root / "sources/original.csv"
                self.assertEqual(linked.stat().st_ino,
                                 (committed.root / "sources/original.csv").stat().st_ino)
                next_state.prepare()
                self.assertEqual(next_state.commit().pointer, committed.pointer)
            with state.StateTransaction.begin(self.paths, token) as invalid:
                with self.assertRaises(state.WorkspaceError):
                    invalid.attach_source(source_hash, "review/financial-review.json")

    def test_pointer_replace_fsync_failure_is_still_locally_committed(self):
        before = self.paths.resolve_active()
        original = state._sync_dir
        def fail(directory):
            if directory == self.paths.active_pointer.parent:
                raise OSError("pointer directory fsync failed")
            return original(directory)
        with state.MaintenanceGate(self.paths).acquire("processor") as token:
            transaction = state.StateTransaction.begin(self.paths, token)
            transaction.prepare(operation(transaction))
            with patch.object(state, "_sync_dir", side_effect=fail):
                with self.assertRaises(OSError):
                    transaction.commit()
            self.assertTrue(transaction.committed)
            transaction.abort()
            recovered = state.StateTransaction.recover(self.paths, token)
            self.assertEqual(next(item for item in recovered if item["state_id"] == transaction.state_id)["phase"], "committed")
        self.assertNotEqual(self.paths.resolve_active().pointer, before.pointer)

    def test_full_pointer_CAS_and_active_file_bypass_detected(self):
        before = self.paths.resolve_active()
        with state.MaintenanceGate(self.paths).acquire("processor") as token:
            with state.StateTransaction.begin(self.paths, token) as transaction:
                transaction.prepare(operation(transaction))
                pointer = dict(before.pointer, local_revision=before.local_revision + 3)
                state._write(self.paths.active_pointer, pointer)
                with self.assertRaises(state.StateConflict):
                    transaction.commit()
                state._write(self.paths.active_pointer, before.pointer)
            with state.StateTransaction.begin(self.paths, token) as transaction:
                transaction.prepare(operation(transaction))
                state._write(before.review / "financial-review.json", {"summary": {"total": 999}})
                with self.assertRaises(state.WorkspaceError):
                    transaction.commit()

    def test_uncommitted_connection_and_missing_required_files_block_prepare(self):
        with state.MaintenanceGate(self.paths).acquire("processor") as token:
            with state.StateTransaction.begin(self.paths, token) as transaction:
                connection = transaction.connect()
                connection.execute("INSERT INTO records VALUES ('a', 1)")
                with self.assertRaises(state.WorkspaceError):
                    transaction.prepare()
            with state.StateTransaction.begin(self.paths, token) as transaction:
                (transaction.review / "coverage.json").unlink()
                with self.assertRaises(FileNotFoundError):
                    transaction.prepare()

    def test_cancel_before_commit_and_prepared_tamper(self):
        before = self.paths.resolve_active()
        with state.MaintenanceGate(self.paths).acquire("processor") as token:
            with state.StateTransaction.begin(self.paths, token) as transaction:
                transaction.prepare(operation(transaction))
                with self.assertRaises(state.WorkspaceError):
                    transaction.commit(cancelled=True)
            with state.StateTransaction.begin(self.paths, token) as transaction:
                transaction.prepare(operation(transaction))
                with self.assertRaises(state.WorkspaceError):
                    transaction.write_json("review/financial-review.json", {})
                (transaction.review / "financial-review.json").write_bytes(b"{}")
                with self.assertRaises(state.WorkspaceError):
                    transaction.commit()
        self.assertEqual(self.paths.resolve_active().pointer, before.pointer)

    def test_crash_boundary_recovery_uses_pointer_and_never_replays(self):
        for point, committed in (("prepared", False), ("before_state_rename", False),
                ("after_state_rename", False), ("before_pointer_replace", False),
                ("after_pointer_replace", True), ("committed_journal", True)):
            with self.subTest(point=point):
                paths = state.WorkspacePaths.create(self.directory / point, initialize)
                before = paths.resolve_active()
                def fail(current):
                    if current == point:
                        raise RuntimeError("simulated crash")
                with state.MaintenanceGate(paths).acquire("processor") as token:
                    transaction = state.StateTransaction.begin(paths, token, failure_hook=fail)
                    try:
                        transaction.prepare(operation(transaction))
                        transaction.commit()
                    except RuntimeError:
                        pass  # Deliberately omit context cleanup, matching process death.
                    recovered = state.StateTransaction.recover(paths, token)
                    handle = paths.resolve_active()
                    self.assertEqual(handle.pointer != before.pointer, committed)
                    self.assertEqual(next(item for item in recovered if item["state_id"] == transaction.state_id)["phase"], "committed" if committed else "needsReview")
                    again = state.StateTransaction.recover(paths, token)
                    self.assertEqual(paths.resolve_active().pointer, handle.pointer)
                    if committed:
                        self.assertEqual(next(item for item in again if item["state_id"] == transaction.state_id)["result"]["operation_id"], "operation-request-a")

    def test_symlink_and_path_escape_rejected(self):
        before = self.paths.resolve_active()
        with state.MaintenanceGate(self.paths).acquire("processor") as token:
            with state.StateTransaction.begin(self.paths, token) as transaction:
                for name in ("../outside", str(self.directory / 'outside'), "review/../outside", "review\\outside"):
                    with self.assertRaises(state.ContractError):
                        transaction.path(name)
                (transaction.review / "alias.json").symlink_to(before.review / "financial-review.json")
                with self.assertRaises(state.WorkspaceError):
                    transaction.prepare()

    def test_stream_copy_bounded_and_sqlite_backup_includes_WAL(self):
        source = self.directory / "wal.sqlite3"
        with closing(sqlite3.connect(source)) as connection:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("CREATE TABLE items(value INTEGER)")
            connection.execute("INSERT INTO items VALUES (42)")
            connection.commit()
            before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.directory.glob("wal.sqlite3*")}
            target = source.with_name("snapshot.sqlite3")
            state._backup(source, target)
            self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.directory.glob("wal.sqlite3*")})
            with closing(sqlite3.connect(target)) as snapshot:
                self.assertEqual(snapshot.execute("SELECT value FROM items").fetchone()[0], 42)
        material = self.directory / "material.bin"
        material.write_bytes(b"a" * (2 * 1024 * 1024 + 9))
        copied = material.with_name("copied.bin")
        original = state.shutil.copyfileobj
        lengths = []
        def bounded(src, dst, length):
            lengths.append(length)
            return original(src, dst, length=length)
        with patch.object(state.shutil, "copyfileobj", side_effect=bounded):
            state._stream_copy(material, copied)
        self.assertEqual(lengths, [1024 * 1024])
        self.assertEqual(state.digest_file(material), state.digest_file(copied))

    def test_sealed_WAL_header_read_and_backup_do_not_create_sidecars(self):
        from scripts.workspace_effects import current_entities
        directory = self.directory / "sealed-reader"
        directory.mkdir()
        source = directory / "banking.sqlite3"
        with closing(sqlite3.connect(source)) as connection:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)")
            connection.execute("INSERT INTO items VALUES(1,'retained')")
            connection.commit()
        before = {p.name: p.read_bytes() for p in directory.iterdir()}
        self.assertEqual(set(before), {"banking.sqlite3"})
        self.assertEqual(before["banking.sqlite3"][18:20], b"\x02\x02")
        self.assertTrue(current_entities(directory))
        target = self.directory / "sealed-snapshot.sqlite3"
        state._backup(source, target)
        self.assertEqual(before, {p.name: p.read_bytes() for p in directory.iterdir()})
        with closing(sqlite3.connect(target)) as snapshot:
            self.assertEqual(snapshot.execute("SELECT value FROM items").fetchone()[0], "retained")

    def test_gate_reentrancy_and_cross_process_contention(self):
        gate = state.MaintenanceGate(self.paths)
        code = "from scripts.workspace_state import *; import sys; p=WorkspacePaths(sys.argv[1]);\ntry:\n MaintenanceGate(p).acquire('child').close()\nexcept GateBusy:\n sys.exit(23)"
        with gate.acquire("processor") as token:
            token.validate(self.paths)
            with self.assertRaises(state.GateBusy):
                gate.acquire("edit")
            completed = subprocess.run([sys.executable, "-c", code, str(self.paths.workspace)],
                                       cwd=ROOT, timeout=10, capture_output=True)
            self.assertEqual(completed.returncode, 23, completed.stderr.decode())
        completed = subprocess.run([sys.executable, "-c", code, str(self.paths.workspace)],
                                   cwd=ROOT, timeout=10, capture_output=True)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode())

    def test_processor_retry_reuses_retained_input_without_repeating_action(self):
        from scripts.processor_result import execute_workspace
        from scripts.workspace_initialization import create_workspace
        self.paths = create_workspace(self.directory.resolve() / "product-workspace")
        for kind, filename in [('csv', 'input.csv'), ('review', 'review.json')]:
            original = self.directory / filename
            original.write_bytes(b'{}' if kind == 'review' else b'date,amount\n2026-10-01,7\n')
            calls = []
            def action(transaction, retained):
                calls.append(retained)
                report = parse_json((transaction.review / 'financial-review.json').read_bytes())
                report['summary']['synthetic_test_total'] = len(calls)
                transaction.write_json('review/financial-review.json', report)
                return {}
            request = 'retry-' + kind
            expected = self.paths.read_pointer()
            with state.MaintenanceGate(self.paths).acquire('processor') as token:
                first, code = execute_workspace(self.paths.workspace, expected, request, request,
                    None, action, [{'path': str(original), 'kind': kind}], token=token)
                self.assertEqual(code, 0, first)
                active = self.paths.read_pointer()
                # Retry carries its original CAS tuple. Exact ledger membership
                # takes precedence over that stale pointer, without any replay.
                repeated, code = execute_workspace(self.paths.workspace, expected, request, request,
                    None, action, [{'path': str(original), 'kind': kind}], token=token)
                self.assertEqual(code, 0, repeated)
                self.assertEqual(repeated, first)
                self.assertEqual(self.paths.read_pointer(), active)
                self.assertEqual(len(calls), 1)
                # External result publication is secondary to current-state
                # membership, including a no-op retry with a stale CAS tuple.
                from scripts import processor_result
                with patch.object(processor_result, '_write_result', side_effect=OSError('disk full')):
                    recovered, code = execute_workspace(self.paths.workspace, expected, request, request,
                        self.directory / 'unwritable.json', action,
                        [{'path': str(original), 'kind': kind}], token=token)
                self.assertEqual(code, 0, recovered)
                self.assertEqual(recovered, first)
                self.assertEqual(len(calls), 1)

    def test_inherited_fd_zero_adoption_does_not_unlock_parent(self):
        code = "from scripts.workspace_state import *; import sys; p=WorkspacePaths(sys.argv[1]); t=MaintenanceGate(p).adopt_inherited(0); t.validate(p); t.close()"
        with state.MaintenanceGate(self.paths).acquire("processor") as token:
            completed = subprocess.run([sys.executable, "-c", code, str(self.paths.workspace)],
                cwd=ROOT, stdin=token.fd, pass_fds=(token.fd,), timeout=10, capture_output=True)
            self.assertEqual(completed.returncode, 0, completed.stderr.decode())
            # Child token.close must not flock(LOCK_UN) on the shared open description.
            probe = os.open(self.paths.lock, os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    state.fcntl.flock(probe, state.fcntl.LOCK_EX | state.fcntl.LOCK_NB)
            finally:
                os.close(probe)
        with open(self.paths.lock, "rb") as unlocked:
            with self.assertRaises(state.WorkspaceError):
                state.MaintenanceGate(self.paths).adopt_inherited(unlocked.fileno())


if __name__ == "__main__":
    unittest.main()
