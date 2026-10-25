"""Durable local state transactions. No reader or writer discovers staging data.

All mutations require the coordinator's WriteToken. A processor may adopt its
inherited lock descriptor (including fd 0), but must not acquire a second gate.
State directories are immutable after activation; sources/ hardlinks are allowed
only for explicitly verified immutable materials, never JSON or SQLite files.
"""
from __future__ import annotations

import copy
import errno
import fcntl
import os
import shutil
import sqlite3
import stat
import threading
import time
import tempfile
import uuid
from contextlib import closing, contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from scripts.release_contracts import (ContractError, business_result_digest,
    canonical_json, digest_bytes, digest_file, normalized_uuid, parse_json,
    validate_contract, validate_relative_path)

REQUIRED_FILES = ("banking.sqlite3", "config/review-import-sources.json",
    "review/financial-review.json", "review/payment-evidence.json",
    "review/coverage.json", "operation-results.json")
_LOCKS: set[tuple[int, int]] = set()
_LOCKS_MUTEX = threading.Lock()


class WorkspaceError(ContractError):
    pass


class GateBusy(WorkspaceError):
    pass


class StateConflict(WorkspaceError):
    pass


def _safe(path: Path) -> Path:
    """Reject symlinks and non-directories throughout every existing ancestor."""
    path = Path(os.path.abspath(path))
    parts = [path, *path.parents]
    for item in reversed(parts):
        try:
            mode = item.lstat().st_mode
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(mode):
            raise WorkspaceError(f"symlink is forbidden: {item}")
        if item != path and not stat.S_ISDIR(mode):
            raise WorkspaceError(f"not a directory: {item}")
    return path


def _regular(path: Path) -> Path:
    path = _safe(path)
    if not stat.S_ISREG(path.lstat().st_mode):
        raise WorkspaceError(f"not a regular file: {path}")
    return path


def _read(path: Path):
    _regular(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        return parse_json(stream.read())


def _sync_dir(path: Path):
    fd = os.open(_safe(path), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write(path: Path, value):
    path = _safe(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4()}.writing")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(canonical_json(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        _sync_dir(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def _files(root: Path):
    _safe(root)
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs:
            _safe(Path(directory) / name)
        for name in files:
            path = _regular(Path(directory) / name)
            yield path.relative_to(root).as_posix(), path


def _signature(path: Path):
    info = _regular(path).stat()
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _sqlite(path: Path) -> bool:
    with _regular(path).open("rb") as stream:
        return stream.read(16) == b"SQLite format 3\x00"


@contextmanager
def readonly_sqlite(source: Path):
    """Read without creating journals beside an original database.

    Callers hold the workspace maintenance gate for a live database. A sealed
    main file can use immutable mode even when its header retains WAL mode.
    Live journals are copied into a disposable shadow, where SQLite can perform
    recovery. The complete source file set must remain unchanged during copy.
    """
    source = _regular(source)
    siblings = [Path(str(source) + suffix) for suffix in ("-wal", "-shm", "-journal")]
    present = [path for path in siblings if path.exists() or path.is_symlink()]
    for path in present:
        _regular(path)
    if not present:
        with closing(sqlite3.connect(source.as_uri() + "?mode=ro&immutable=1", uri=True)) as connection:
            connection.execute("PRAGMA query_only=ON")
            yield connection
        return
    signatures = {path: _signature(path) for path in [source, *present]}
    with tempfile.TemporaryDirectory(prefix="family-review-sqlite-reader-") as temporary:
        shadow = Path(temporary).resolve() / "snapshot.sqlite3"
        for path in [source, *present]:
            target = shadow if path == source else Path(str(shadow) + str(path)[len(str(source)):])
            _stream_copy(path, target)
        if ({path: _signature(path) for path in signatures} != signatures
                or any((path.exists() or path.is_symlink()) != (path in present) for path in siblings)):
            raise StateConflict("SQLite source changed while preparing readonly snapshot")
        # Only this private copy may create, recover or remove sidecars.
        with closing(sqlite3.connect(shadow)) as connection:
            connection.execute("SELECT name FROM sqlite_master LIMIT 1").fetchall()
            connection.execute("PRAGMA query_only=ON")
            yield connection


def _backup(source: Path, target: Path):
    """Include committed WAL pages while keeping every source file unchanged."""
    _safe(target)
    with readonly_sqlite(source) as src:
        with closing(sqlite3.connect(target)) as dst:
            src.backup(dst)
            dst.execute("PRAGMA journal_mode=DELETE")
            dst.commit()


def _stream_copy(source: Path, target: Path):
    _regular(source)
    _safe(target)
    with source.open("rb") as src, target.open("xb") as dst:
        shutil.copyfileobj(src, dst, length=1024 * 1024)
    os.chmod(target, 0o600)


class ReaderLease:
    """Shared with native readers; a collector needs the exclusive same-file lock."""
    def __init__(self, paths, state_id):
        directory = _safe(paths.workspace / 'device/readers/states')
        directory.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(directory / normalized_uuid(state_id), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
        try:
            if not stat.S_ISREG(os.fstat(self.fd).st_mode):
                raise WorkspaceError('invalid reader lock')
            fcntl.flock(self.fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BaseException:
            os.close(self.fd); self.fd = None
            raise
    def __del__(self):
        if getattr(self, 'fd', None) is not None:
            os.close(self.fd)


@dataclass(frozen=True)
class StateHandle:
    workspace_id: str
    state_id: str
    local_revision: int
    state_manifest_hash: str
    root: Path
    read_lease: ReaderLease | None = field(default=None, compare=False, repr=False)

    @property
    def review(self):
        return self.root / "review"

    @property
    def database(self):
        return self.root / "banking.sqlite3"

    @property
    def pointer(self):
        return {"workspace_id": self.workspace_id,
            "state_id": self.state_id, "local_revision": self.local_revision,
            "state_manifest_hash": self.state_manifest_hash}

    def path(self, relative: str):
        return _safe(self.root / validate_relative_path(relative))


class WorkspacePaths:
    def __init__(self, workspace: Path | str):
        self.workspace = _safe(Path(workspace))
        self.data = self.workspace / "data"
        self.active_pointer = self.data / "active-state.json"
        self.states = self.data / "states"
        self.sources = self.data / "sources"
        self.processing = self.data / "processing"
        self.staging = self.processing / "staging"
        self.journals = self.processing / "journals"
        self.lock = self.workspace / "device" / "locks" / "maintenance.lock"

    @property
    def workspace_id(self):
        metadata = _read(self.workspace / "workspace.json")
        validate_contract("workspace", metadata)
        return metadata["workspace_id"]

    def read_pointer(self):
        try:
            pointer = _read(self.active_pointer)
        except FileNotFoundError:
            return None
        validate_contract("active-state", pointer)
        if pointer["workspace_id"] != self.workspace_id:
            raise WorkspaceError("active pointer belongs to another workspace")
        normalized_uuid(pointer["state_id"])
        if pointer["state_id"] != normalized_uuid(pointer["state_id"]):
            raise WorkspaceError("state ID must be a normalized UUID")
        return pointer

    def resolve_active(self, *, verify_files=True) -> StateHandle:
        pointer = self.read_pointer()
        if pointer is None:
            raise WorkspaceError("workspace has no committed state")
        lease = ReaderLease(self, pointer["state_id"])
        root = _safe(self.states / pointer["state_id"])
        manifest_path = _regular(root / "state-manifest.json")
        if digest_file(manifest_path) != pointer["state_manifest_hash"]:
            raise WorkspaceError("active state manifest digest mismatch")
        manifest = _read(manifest_path)
        validate_contract("state-manifest", manifest)
        for field in ("workspace_id", "state_id", "local_revision"):
            if manifest[field] != pointer[field]:
                raise WorkspaceError("manifest disagrees with active pointer")
        actual = {name for name, _ in _files(root) if name != "state-manifest.json"}
        if actual != set(manifest["files"]):
            raise WorkspaceError("unlisted or missing state files")
        if verify_files:
            for relative, expected in manifest["files"].items():
                if digest_file(_regular(root / relative)) != expected:
                    raise WorkspaceError(f"state file digest mismatch: {relative}")
        ledger = _read(root / "operation-results.json")
        validate_contract("request-results", ledger)
        if ledger["state_id"] != pointer["state_id"] or any(
                result["workspace_id"] != pointer["workspace_id"] for result in ledger["results"]):
            raise WorkspaceError("result ledger identity mismatch")
        if verify_files:
            from scripts.workspace_effects import verify_current_membership
            verify_current_membership(root, ledger)
        return StateHandle(pointer["workspace_id"], pointer["state_id"],
            pointer["local_revision"], pointer["state_manifest_hash"], root, lease)

    def report_paths(self):
        handle = self.resolve_active()
        return handle.review / "financial-review.json", handle.review / "payment-evidence.json"

    def retain_source(self, source: Path | str, token: "WriteToken", *, expected_hash=None):
        """Durably retain an original in the content-addressed immutable store."""
        token.validate(self)
        source = _regular(Path(source))
        _safe(self.sources).mkdir(parents=True, exist_ok=True)
        temporary = self.sources / ("." + str(uuid.uuid4()) + ".incoming")
        try:
            _stream_copy(source, temporary)
            source_hash = digest_file(temporary)
            if expected_hash is not None and source_hash != expected_hash:
                raise WorkspaceError("source input digest mismatch")
            fd = os.open(temporary, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
            os.chmod(temporary, 0o400)
            fd = os.open(temporary, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
            destination = self.sources / source_hash
            if destination.exists():
                if digest_file(_regular(destination)) != source_hash:
                    raise WorkspaceError("existing source object is corrupt")
            else:
                os.rename(temporary, destination)
                _sync_dir(self.sources)
            return source_hash
        finally:
            if temporary.exists():
                temporary.unlink()

    @classmethod
    def create(cls, destination: Path | str, initializer: Callable[["StateTransaction"], None], *, before_publish=None):
        """Create fresh identity only after a caller's real empty model validates.

        Never load Seed, select host, or reuse a directory containing existing data.
        The complete workspace is renamed from a sibling staging directory.
        """
        destination = _safe(Path(destination))
        if destination.exists():
            raise WorkspaceError("create destination already exists")
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(f".{destination.name}.{uuid.uuid4()}.creating")
        temporary.mkdir(mode=0o700)
        paths = cls(temporary)
        try:
            _write(temporary / "workspace.json", {"workspace_id": str(uuid.uuid4()), "created_at": datetime.now(timezone.utc).isoformat(),
                })
            _write(temporary / "device" / "device-identity.json", {"device_id": str(uuid.uuid4())})
            with MaintenanceGate(paths).acquire("create") as token:
                with StateTransaction.begin(paths, token, allow_empty=True) as transaction:
                    initializer(transaction)
                    transaction.prepare()
                    transaction.commit()
            # rename must not replace an empty destination created by another actor.
            # Reserve its name first; os.rename on macOS can replace empty dirs.
            if before_publish is not None:
                before_publish()
            destination.mkdir(mode=0o700)
            try:
                os.rename(temporary, destination)
            except BaseException:
                destination.rmdir()
                raise
            _sync_dir(destination.parent)
            return cls(destination)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)


class WriteToken:
    def __init__(self, paths, fd, kind, *, inherited=False):
        self.paths, self.fd, self.kind = paths, fd, kind
        self.inherited, self.pid, self.closed = inherited, os.getpid(), False
        info = os.fstat(fd)
        self.identity = (info.st_dev, info.st_ino)

    def validate(self, paths):
        if self.closed or self.pid != os.getpid() or paths.workspace != self.paths.workspace:
            raise WorkspaceError("invalid or foreign write token")
        file_info = _regular(paths.lock).stat()
        fd_info = os.fstat(self.fd)
        if (file_info.st_dev, file_info.st_ino) != self.identity or (
                fd_info.st_dev, fd_info.st_ino) != self.identity:
            raise WorkspaceError("maintenance lock inode changed")
        return self

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            if not self.inherited:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
        finally:
            os.close(self.fd)
            with _LOCKS_MUTEX:
                _LOCKS.discard(self.identity)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class MaintenanceGate:
    def __init__(self, paths: WorkspacePaths):
        self.paths = paths

    def acquire(self, kind: str, *, timeout=0) -> WriteToken:
        if not kind or timeout < 0:
            raise WorkspaceError("invalid gate operation")
        lock = _safe(self.paths.lock)
        lock.parent.mkdir(parents=True, exist_ok=True)
        if lock.exists():
            _regular(lock)
        fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        info = os.fstat(fd)
        identity = (info.st_dev, info.st_ino)
        with _LOCKS_MUTEX:
            if identity in _LOCKS:
                os.close(fd)
                raise GateBusy("gate is already held in this process; pass its WriteToken")
            _LOCKS.add(identity)
        deadline = time.monotonic() + timeout
        try:
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    os.fsync(fd)
                    _sync_dir(lock.parent)
                    return WriteToken(self.paths, fd, kind)
                except BlockingIOError as error:
                    if time.monotonic() >= deadline:
                        raise GateBusy("workspace maintenance gate is busy") from error
                    time.sleep(min(0.05, max(0, deadline - time.monotonic())))
        except BaseException:
            os.close(fd)
            with _LOCKS_MUTEX:
                _LOCKS.discard(identity)
            raise

    def adopt_inherited(self, fd=0, *, kind="processor") -> WriteToken:
        """Prove fd refers to the held exclusive gate before adopting a duplicate.

        An independent probe must be blocked, and flock on the inherited open
        description must succeed. An unlocked fd or another process's unrelated
        descriptor cannot pass both checks. Closing this token never unlocks the
        parent's inherited open description.
        """
        path = _regular(self.paths.lock)
        supplied = os.fstat(fd)
        expected = path.stat()
        identity = (expected.st_dev, expected.st_ino)
        if not stat.S_ISREG(supplied.st_mode) or (supplied.st_dev, supplied.st_ino) != identity:
            raise WorkspaceError("inherited descriptor is not this maintenance gate")
        with _LOCKS_MUTEX:
            if identity in _LOCKS:
                raise GateBusy("pass the existing token instead of adopting it again")
            _LOCKS.add(identity)
        probe = None
        duplicate = None
        try:
            probe = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                fcntl.flock(probe, fcntl.LOCK_UN)
                raise WorkspaceError("inherited descriptor does not hold a gate")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            duplicate = os.dup(fd)
            return WriteToken(self.paths, duplicate, kind, inherited=True)
        except BaseException:
            if duplicate is not None:
                os.close(duplicate)
            with _LOCKS_MUTEX:
                _LOCKS.discard(identity)
            raise
        finally:
            if probe is not None:
                os.close(probe)


class StateTransaction:
    @classmethod
    def begin(cls, paths: WorkspacePaths, token: WriteToken, *, allow_empty=False,
              immutable_paths=None, failure_hook=None, operation_context=None):
        token.validate(paths)
        for name in ("create-family.json", "host-publication-family.json"):
            pending = _safe(paths.workspace / "device" / name)
            if pending.exists():
                row = _read(pending)
                if (name != 'create-family.json' or row.get('phase') != 'complete'):
                    raise WorkspaceError("finish pending family host publication before writing")
        transaction = cls()
        transaction.paths, transaction.token = paths, token
        transaction.expected = copy.deepcopy(paths.read_pointer())
        if transaction.expected is None and not allow_empty:
            raise WorkspaceError("cannot process an uninitialized workspace")
        transaction.parent = paths.resolve_active() if transaction.expected else None
        transaction.workspace_id = paths.workspace_id
        transaction.state_id = str(uuid.uuid4())
        transaction.local_revision = transaction.parent.local_revision + 1 if transaction.parent else 0
        transaction.root = paths.staging / transaction.state_id
        _safe(transaction.root).mkdir(parents=True, mode=0o700)
        transaction.review = transaction.root / "review"
        transaction.review.mkdir()
        transaction.journal = paths.journals / (transaction.state_id + ".json")
        transaction.connections = []
        transaction.prepared = transaction.committed = transaction.closed = transaction.is_noop = False
        transaction.result = transaction.prepared_result = None
        transaction.operation_context = copy.deepcopy(operation_context)
        transaction.failure_hook = failure_hook or (lambda point: None)
        transaction.immutable_hashes = {}
        transaction.immutable_signatures = {}
        transaction.parent_signatures = {}
        transaction.baseline_hashes = {}
        try:
            transaction._journal("processing")
            transaction.failure_hook("begin")
            if transaction.parent:
                manifest = _read(transaction.parent.root / "state-manifest.json")
                transaction.parent_signatures = {name: _signature(path)
                    for name, path in _files(transaction.parent.root)}
                immutable = set(immutable_paths) if immutable_paths is not None else {
                    name for name, source in _files(transaction.parent.root)
                    if name.startswith("sources/") and not source.stat().st_mode & 0o222
                    and not name.endswith((".json", ".sqlite3", ".sqlite", ".db")) and not _sqlite(source)}
                for relative in immutable:
                    validate_relative_path(relative)
                    if not relative.startswith("sources/") or relative.endswith((".json", ".sqlite3", ".sqlite", ".db")):
                        raise WorkspaceError("only verified sources materials can be immutable links")
                    if relative not in manifest["files"]:
                        raise WorkspaceError("immutable material is not in the active manifest")
                databases = {relative for relative, source in _files(transaction.parent.root)
                             if _sqlite(source)}
                for relative, source in _files(transaction.parent.root):
                    if relative == "state-manifest.json" or any(relative == db + suffix
                            for db in databases for suffix in ("-wal", "-shm", "-journal")):
                        continue
                    target = transaction.root / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    if relative in databases:
                        _backup(source, target)
                    elif relative in immutable:
                        # Active verification above hashed the bytes under this gate.
                        try:
                            if source.stat().st_mode & 0o222:
                                raise OSError(errno.EPERM, "writable source cannot be linked")
                            os.link(source, target, follow_symlinks=False)
                        except OSError as error:
                            if error.errno not in (errno.EXDEV, errno.ENOTSUP, errno.EPERM):
                                raise
                            _stream_copy(source, target)
                            os.chmod(target, 0o400)
                        transaction.immutable_hashes[relative] = manifest["files"][relative]
                        transaction.immutable_signatures[relative] = _signature(target)
                    else:
                        _stream_copy(source, target)
            else:
                transaction.write_json("operation-results.json", {"state_id": transaction.state_id, "results": []})
            if transaction.parent:
                # Creating a verified source link changes its inode ctime. Capture
                # the frozen parent signatures after those controlled metadata changes.
                transaction.parent_signatures = {name: _signature(path)
                    for name, path in _files(transaction.parent.root)}
                transaction.immutable_signatures = {name: _signature(transaction.root / name)
                    for name in transaction.immutable_hashes}
                for relative, path in _files(transaction.root):
                    if relative != "operation-results.json":
                        transaction.baseline_hashes[relative] = (transaction.immutable_hashes.get(relative)
                            or digest_file(path))
            transaction._journal("processing")
            return transaction
        except BaseException:
            transaction.abort()
            raise

    def _check(self):
        self.token.validate(self.paths)
        if self.closed or self.committed:
            raise WorkspaceError("transaction is closed")

    def path(self, relative):
        self._check()
        if self.prepared:
            raise WorkspaceError("prepared state is frozen")
        relative = validate_relative_path(relative)
        if relative in self.immutable_hashes:
            raise WorkspaceError("immutable linked material cannot be mutated")
        return _safe(self.root / relative)

    def write_json(self, relative, value):
        _write(self.path(relative), value)

    def attach_source(self, source_hash: str, relative: str):
        """Create a root-relative source view without linking mutable state files."""
        if len(source_hash) != 64 or any(c not in "0123456789abcdef" for c in source_hash):
            raise WorkspaceError("invalid source object digest")
        validate_relative_path(relative)
        if not relative.startswith("sources/") or relative.endswith((".json", ".sqlite3", ".sqlite", ".db")):
            raise WorkspaceError("source view must be an immutable material path")
        source = _regular(self.paths.sources / source_hash)
        if source.stat().st_mode & 0o222 or digest_file(source) != source_hash or _sqlite(source):
            raise WorkspaceError("source object is not a verified immutable material")
        # A retried request snapshots the already-retained source view. Reuse
        # only the exact immutable object; never overwrite a conflicting view.
        target = _safe(self.root / validate_relative_path(relative))
        self._check()
        if self.prepared:
            raise WorkspaceError("prepared state is frozen")
        if target.exists():
            existing = _regular(target)
            if existing.stat().st_mode & 0o222 or digest_file(existing) != source_hash:
                raise StateConflict("existing source view conflicts with retained input")
            self.immutable_hashes[relative] = source_hash
            self.immutable_signatures[relative] = _signature(existing)
            return existing
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(source, target, follow_symlinks=False)
        except OSError as error:
            if error.errno not in (errno.EXDEV, errno.ENOTSUP, errno.EPERM):
                raise
            _stream_copy(source, target)
            os.chmod(target, 0o400)
        self.immutable_hashes[relative] = source_hash
        linked_identity = _signature(target)[:2]
        for name in self.immutable_hashes:
            signature = _signature(self.root / name)
            if signature[:2] == linked_identity:
                self.immutable_signatures[name] = signature
        if self.parent:
            for name, signature in self.parent_signatures.items():
                if signature[:2] == linked_identity:
                    current = _signature(self.parent.root / name)
                    if current[:5] != signature[:5]:
                        raise WorkspaceError("parent material changed while linking")
                    self.parent_signatures[name] = current
        return target

    def connect(self, relative="banking.sqlite3"):
        path = self.path(relative)
        path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(path)
        self.connections.append(connection)
        return connection

    def _journal(self, phase):
        _write(self.journal, {"workspace_id": self.workspace_id,
            "state_id": self.state_id, "expected_pointer": self.expected,
            "phase": phase, "target_pointer": getattr(self, "pointer", None),
            "result": self.prepared_result if phase == "prepared" else self.result,
            "operation": self.operation_context})

    def record_processing(self, context):
        self._check()
        if self.prepared:
            raise WorkspaceError("prepared operation cannot change")
        self.operation_context = copy.deepcopy(context)
        self._journal("processing")

    def prepare(self, result=None, *, validator=None):
        self._check()
        if self.prepared:
            raise WorkspaceError("transaction already prepared")
        for connection in self.connections:
            try:
                pending = connection.in_transaction
            except sqlite3.ProgrammingError:  # Caller has already closed its handle.
                continue
            if pending:
                raise WorkspaceError("transaction has an uncommitted SQLite connection")
            connection.close()
        self.connections.clear()
        databases = [(relative, path) for relative, path in _files(self.root) if _sqlite(path)]
        for relative, path in databases:
            with closing(sqlite3.connect(path)) as connection:
                checkpoint = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
                if checkpoint and checkpoint[0] != 0:
                    raise WorkspaceError(f"SQLite checkpoint is busy: {relative}")
                if connection.execute("PRAGMA journal_mode=DELETE").fetchone()[0].lower() != 'delete':
                    raise WorkspaceError(f"SQLite writers must close before prepare: {relative}")
                if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                    raise WorkspaceError(f"SQLite integrity check failed: {relative}")
            # Read-only WAL connections can leave an orphan SHM after the mode
            # switch. Remove it only after all writers are proven closed.
            wal = Path(str(path) + '-wal')
            if wal.exists():
                if _regular(wal).stat().st_size:
                    raise WorkspaceError(f"SQLite has unsealed WAL pages: {relative}")
                wal.unlink()
            shm = Path(str(path) + '-shm')
            if shm.exists():
                _regular(shm).unlink()
        ledger = _read(self.root / "operation-results.json")
        duplicate_result = False
        if result is not None:
            result = copy.deepcopy(result)
            result.update(version=2, workspace_id=self.workspace_id, state_id=self.state_id,
                          phase="committed", result_generation=None)
            result["result_digest"] = business_result_digest(result)
            validate_contract("result", result)
            existing = [entry for entry in ledger["results"] if
                entry["request_id"] == result["request_id"] or entry["operation_id"] == result["operation_id"]]
            if existing:
                # Retrying an included request is a no-op only with exact input identity.
                lifecycle = {"phase", "state_id", "result_digest", "result_generation"}
                if len(existing) != 1 or canonical_json({key: value for key, value in existing[0].items() if key not in lifecycle}) != canonical_json({key: value for key, value in result.items() if key not in lifecycle}):
                    raise StateConflict("included operation identity or effects conflict")
                self.result = existing[0]
                duplicate_result = True
            else:
                keys = {effect["key"] for entry in ledger["results"] for effect in entry["membership"]}
                if keys.intersection(effect["key"] for effect in result["membership"]):
                    raise StateConflict("effect is already included by another operation")
                ledger["results"].append(result)
                self.result = result
            self.prepared_result = copy.deepcopy(self.result)
            self.prepared_result.update(phase="prepared", outcome=None)
            validate_contract("result", self.prepared_result)
        ledger["state_id"] = self.state_id
        validate_contract("request-results", ledger)
        from scripts.workspace_effects import verify_current_membership
        verify_current_membership(self.root, ledger)
        self.write_json("operation-results.json", ledger)
        for relative in REQUIRED_FILES:
            _regular(self.root / relative)
        if not _sqlite(self.root / "banking.sqlite3"):
            raise WorkspaceError("banking.sqlite3 is not a SQLite database")
        validate_contract("coverage", _read(self.review / "coverage.json"))
        for relative in ("config/review-import-sources.json", "review/financial-review.json", "review/payment-evidence.json"):
            if not isinstance(_read(self.root / relative), dict):
                raise WorkspaceError(f"state JSON must be an object: {relative}")
        if validator is not None:
            validator(self)
        hashes = {}
        for relative, path in _files(self.root):
            if relative in self.immutable_hashes:
                if _signature(path) != self.immutable_signatures[relative]:
                    raise WorkspaceError("immutable material was modified")
                hashes[relative] = self.immutable_hashes[relative]
            else:
                hashes[relative] = digest_file(path)
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        self.manifest = {"workspace_id": self.workspace_id,
            "state_id": self.state_id, "local_revision": self.local_revision, "files": hashes,
            "parent_pointer": copy.deepcopy(self.parent.pointer) if self.parent else None}
        validate_contract("state-manifest", self.manifest)
        _write(self.root / "state-manifest.json", self.manifest)
        for directory, _, _ in os.walk(self.root, topdown=False):
            _sync_dir(Path(directory))
        self.pointer = {"workspace_id": self.workspace_id,
            "state_id": self.state_id, "local_revision": self.local_revision,
            "state_manifest_hash": digest_bytes(canonical_json(self.manifest))}
        validate_contract("active-state", self.pointer)
        if self.parent:
            old_ledger = _read(self.parent.root / "operation-results.json")
            self.is_noop = (self.baseline_hashes ==
                {k: v for k, v in hashes.items() if k != "operation-results.json"} and
                ledger["results"] == old_ledger["results"])
        if duplicate_result and not self.is_noop:
            raise StateConflict("included operation retry attempted new business changes")
        self.prepared_signatures = {name: _signature(path) for name, path in _files(self.root)}
        self.prepared = True
        self._journal("prepared")
        self.failure_hook("prepared")
        return self.pointer

    def commit(self, *, cancelled=False):
        self._check()
        if not self.prepared:
            raise WorkspaceError("prepare is required before commit")
        if cancelled:
            self.abort()
            raise WorkspaceError("cancelled before commit")
        if self.paths.read_pointer() != self.expected:
            raise StateConflict("active state tuple changed before commit")
        # Detect writers that bypassed the gate, including unchanged pointer edits.
        if self.parent:
            self.paths.resolve_active(verify_files=False)
            if {name: _signature(path) for name, path in _files(self.parent.root)} != self.parent_signatures:
                raise WorkspaceError("active state changed outside maintenance gate")
        if {name: _signature(path) for name, path in _files(self.root)} != self.prepared_signatures:
            raise WorkspaceError("prepared state changed before commit")
        if self.is_noop:
            self.abort(phase="no-op")
            return self.parent
        self.failure_hook("before_state_rename")
        self.paths.states.mkdir(parents=True, exist_ok=True)
        target = self.paths.states / self.state_id
        _safe(target)
        if target.exists():
            raise StateConflict("new state ID already exists")
        os.rename(self.root, target)
        _sync_dir(self.paths.states)
        _sync_dir(self.paths.staging)
        self.failure_hook("after_state_rename")
        self.failure_hook("before_pointer_replace")
        try:
            _write(self.paths.active_pointer, self.pointer)
        except BaseException:
            # fsync can fail after replace. Pointer membership still wins locally;
            # surface the durability error without falsely cancelling or replaying.
            if self.paths.read_pointer() == self.pointer:
                self.committed = self.closed = True
                self.root, self.review = target, target / "review"
            raise
        # From this point, failures cannot change committed into failed or replay it.
        self.committed = self.closed = True
        self.root = target
        self.review = target / "review"
        self.failure_hook("after_pointer_replace")
        self._journal("committed")
        self.failure_hook("committed_journal")
        return StateHandle(self.workspace_id, self.state_id, self.local_revision,
            self.pointer["state_manifest_hash"], target, ReaderLease(self.paths, self.state_id))

    def abort(self, *, phase="cancelled"):
        if self.committed or self.closed:
            return
        self.token.validate(self.paths)
        for connection in self.connections:
            connection.close()
        self.connections.clear()
        if self.root.exists():
            shutil.rmtree(_safe(self.root))
        self.closed = True
        self._journal(phase)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        if not self.closed:
            self.abort(phase="failed" if exc and exc[0] else "cancelled")

    @staticmethod
    def recover(paths: WorkspacePaths, token: WriteToken):
        """Reconcile metadata from current state membership, never replay effects.

        Staging/orphan state directories remain forensic data, not activation
        candidates. Historical receipts are intentionally not consulted.
        """
        token.validate(paths)
        pointer = paths.read_pointer()
        handle = paths.resolve_active() if pointer else None
        ledger = _read(handle.root / "operation-results.json") if handle else {"results": []}
        results = {entry["operation_id"]: entry for entry in ledger["results"]}
        reconciled = []
        if not paths.journals.exists():
            return reconciled
        for name, journal_path in _files(paths.journals):
            if "/" in name or not name.endswith(".json"):
                raise WorkspaceError("unexpected processing journal path")
            journal = _read(journal_path)
            if journal.get("workspace_id") != paths.workspace_id:
                raise WorkspaceError("foreign workspace journal")
            result = journal.get("result")
            if result is None and journal.get("phase") == "committed" and journal.get("target_pointer") != pointer:
                continue  # Historical non-operation state commit; no effects to replay.
            context = result if isinstance(result, dict) else journal.get("operation")
            included = results.get(context.get("operation_id")) if isinstance(context, dict) else None
            if included and any(context.get(key) is not None and included.get(key) != context.get(key) for key in
                    ("request_id", "input_hash", "result_digest", "algorithm_version")):
                raise StateConflict("journal identity conflicts with current membership")
            if included or (pointer and journal.get("target_pointer") == pointer):
                journal.update(phase="committed", result=included or result)
            elif journal.get("phase") in ("processing", "prepared", "committed"):
                journal.update(phase="needsReview", reason="not-in-current-state; no automatic replay")
            else:
                continue
            _write(journal_path, journal)
            reconciled.append(journal)
        return reconciled
