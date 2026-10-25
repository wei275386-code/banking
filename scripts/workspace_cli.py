"""Explicit workspace maintenance CLI. New destinations, durable verified receipts."""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import signal
import threading
from contextlib import contextmanager
import sys
import time
import uuid
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.release_contracts import canonical_json, digest_file, normalized_uuid
from scripts.workspace_state import (MaintenanceGate, StateTransaction, WorkspacePaths,
    _read, _regular, _safe, _write)

MAINTENANCE_COMMANDS = {"create"}
MAX_RECEIPT_BYTES = 1024 * 1024


def _receipt_bytes(receipt):
    encoded = canonical_json(receipt)
    if len(encoded) > MAX_RECEIPT_BYTES:
        raise ValueError("maintenance receipt exceeds producer limit")
    return encoded


def _parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--inherited-fd", type=int, help="recovery/repair only; fd 0 is valid")
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create", help="create a new empty production workspace")
    create.add_argument("--result-file", type=Path)
    create.add_argument("--receipt-id")
    create.add_argument("--cancel-file", type=Path)
    create.add_argument("--timeout-seconds", type=float)
    commands.add_parser("inspect", help="verify and report the committed state")
    commands.add_parser("recover", help="reconcile journals; never replay effects")
    repair = commands.add_parser("repair-input", help="finish one retained pending video stage")
    repair.add_argument("--parent-request-id", required=True)
    repair.add_argument("--input-id", required=True)
    repair.add_argument("--expected-pointer-json", type=Path, required=True)
    repair.add_argument("--result-file", type=Path, required=True)
    repair.add_argument("--cancel-file", type=Path)
    repair.add_argument("--timeout-seconds", type=float)
    return parser


def _state(paths):
    from scripts.workspace_effects import verify_current_membership
    handle = paths.resolve_active()
    verify_current_membership(handle.root, _read(handle.root / "operation-results.json"))
    financial = _read(handle.root / "review/financial-review.json")
    evidence = _read(handle.root / "review/payment-evidence.json")
    coverage = _read(handle.root / "review/coverage.json")
    if not isinstance(financial, dict) or not isinstance(evidence, dict) or financial.get("coverage") != coverage or evidence.get("coverage") != coverage:
        raise ValueError("current report/coverage closure differs")
    return {key: handle.pointer[key] for key in ("state_id", "local_revision", "state_manifest_hash")}


def _locations(args):
    if len(str(args.workspace)) > 4096:
        raise ValueError("workspace path exceeds producer limit")
    return None, {"kind": "workspace", "path": str(_safe(args.workspace))}


def _result_target(args, source, destination):
    target = getattr(args, "result_file", None)
    if target is None:
        return None, None
    target = _safe(target)
    roots = [Path(value["path"]) for value in (source, destination) if value]
    if source and "output" in source:
        roots.append(Path(source["output"]))
    if any(target == root or root in target.parents for root in roots):
        raise ValueError("result file must be outside source and destination trees")
    if target.exists():
        raise ValueError("result file already exists; choose a new receipt path")
    target.parent.mkdir(parents=True, exist_ok=True)
    lock = _safe(target.with_name(target.name + ".lock"))
    fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if target.exists():
            raise ValueError("result file already exists")
        return target, fd
    except BaseException:
        os.close(fd)
        raise


@contextmanager
def _termination_cancellation(args):
    # SIGTERM marks cancellation without raising inside finally/rmtree. A
    # bounded streaming checkpoint unwinds the operation, then it can finish
    # owned staging cleanup and publish its failed receipt. Native retains its
    # SIGKILL bound for unresponsive children; published targets stay intact.
    requested = False
    def terminate(signum, frame):
        nonlocal requested
        requested = True
    previous = None
    enabled = threading.current_thread() is threading.main_thread()
    if enabled:
        previous = signal.signal(signal.SIGTERM, terminate)
    args.termination_requested = lambda: requested
    try:
        yield
    finally:
        if enabled:
            signal.signal(signal.SIGTERM, previous)


def _maintenance(args):
    from scripts.workspace_initialization import create_workspace
    if args.inherited_fd is not None:
        raise ValueError("maintenance commands acquire their own gate; do not pass inherited fd")
    receipt_id = normalized_uuid(args.receipt_id) if args.receipt_id else str(uuid.uuid4())
    source, destination = _locations(args)
    target, fd = _result_target(args, source, destination)
    receipt = {"receipt_id": receipt_id,
        "command": args.command,
        "outcome": "failed", "exit_code": 1, "workspace_id": None, "state": None,
        "source": source, "destination": destination, "artifact": None, "verification": {},
        "result": {}, "error": None}
    existed = bool(destination and Path(destination["path"]).exists())
    published = False
    started = time.monotonic()
    def check(point=None):
        if getattr(args, "termination_requested", lambda: False)():
            raise ValueError("maintenance cancelled before publication")
        cancel = getattr(args, "cancel_file", None)
        if cancel is not None and _safe(cancel).exists():
            raise ValueError("maintenance cancelled before publication")
        limit = getattr(args, "timeout_seconds", None)
        if limit is not None and (limit <= 0 or time.monotonic() - started >= limit):
            raise ValueError("maintenance timeout before publication")
    try:
        check()
        _receipt_bytes(receipt)  # Preflight bounded location/identity envelope.
        paths = create_workspace(args.workspace, before_publish=lambda: check("before-publish"))
        published = True
        receipt["result"] = {"kind": "new", "processor_eligible": False}
        with MaintenanceGate(paths).acquire("creation-receipt"):
            receipt["state"] = _state(paths)
            receipt["workspace_id"] = paths.workspace_id
            artifact = paths.resolve_active(verify_files=False).root / "state-manifest.json"
            receipt["artifact"] = {"kind": "state-manifest", "path": str(artifact), "sha256": digest_file(artifact)}
        receipt["outcome"], receipt["exit_code"] = "success", 0
        receipt["verification"]["state_verified"] = True
        _receipt_bytes(receipt)
        if published:
            with MaintenanceGate(paths).acquire("maintenance-receipt"):
                if _state(paths) != receipt["state"]:
                    raise ValueError("published workspace changed before durable receipt")
                _write(paths.workspace / "device/maintenance-receipts" / (receipt["receipt_id"] + ".json"), receipt)
    except Exception as error:
        newly_published = bool(destination and not existed and Path(destination["path"]).exists())
        published = published or newly_published
        receipt["outcome"], receipt["exit_code"] = ("needsReview", 2) if published else ("failed", 1)
        receipt["verification"]["state_verified"] = False
        receipt["error"] = {"code": type(error).__name__, "message": str(error)[:4096]}
    try:
        if target is not None:
            _receipt_bytes(receipt)
            _write(target, receipt)
    except Exception as error:
        receipt["outcome"], receipt["exit_code"] = ("needsReview", 2) if published else ("failed", 1)
        receipt["error"] = {"code": "ReceiptPublicationFailed", "message": str(error)[:4096]}
    finally:
        if fd is not None:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
    print(_receipt_bytes(receipt).decode("utf-8"))
    return receipt["exit_code"]


def main(argv=None):
    args = _parser().parse_args(argv)
    if args.command in MAINTENANCE_COMMANDS:
        with _termination_cancellation(args):
            return _maintenance(args)
    paths = WorkspacePaths(args.workspace)
    if args.command == "inspect":
        handle = paths.resolve_active()
        result = {**handle.pointer, "root": str(handle.root), "review": str(handle.review), "database": str(handle.database)}
    elif args.command == "repair-input":
        from scripts.workspace_repair import repair_input
        gate = MaintenanceGate(paths)
        token = gate.adopt_inherited(args.inherited_fd, kind="repair-input") if args.inherited_fd is not None else gate.acquire("repair-input")
        with token:
            result, status = repair_input(args.workspace, args.expected_pointer_json,
                args.parent_request_id, args.input_id, result_file=args.result_file, token=token,
                cancelled=(lambda: args.cancel_file.exists()) if args.cancel_file else None,
                timeout_seconds=args.timeout_seconds)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return status
    else:
        gate = MaintenanceGate(paths)
        token = gate.adopt_inherited(args.inherited_fd, kind="recovery") if args.inherited_fd is not None else gate.acquire("recovery")
        with token:
            result = {"reconciled": StateTransaction.recover(paths, token)}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
