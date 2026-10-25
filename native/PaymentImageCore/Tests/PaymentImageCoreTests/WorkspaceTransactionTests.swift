import XCTest
import Foundation
import Darwin
import CSQLite
@testable import PaymentImageCore

final class WorkspaceTransactionTests: XCTestCase {
    enum Injected: Error { case crash }
    struct Fixture {
        let paths: WorkspacePaths
        let handle: StateHandle
        let database: OpaquePointer?
        func close() { sqlite3_close(database); try? FileManager.default.removeItem(at: paths.workspace) }
    }
    private func fixture(wal: Bool = false) throws -> Fixture {
        // Preserve the physical OS temporary root without Foundation aliasing.
        let canonicalTemporary = try TestPlatform.temporaryDirectory().path
        let workspace = URL(fileURLWithPath: canonicalTemporary + "/workspace-test-" + UUID().uuidString, isDirectory: true)
        let paths = try WorkspacePaths(workspace: workspace)
        let workspaceID = UUID().uuidString.lowercased(), stateID = UUID().uuidString.lowercased()
        let root = try paths.stateRoot(stateID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["workspace_id": workspaceID,
                                      "created_at": "2026-10-14T00:00:00Z"]
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(metadata), to: paths.metadata)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("banking.sqlite3").path, &database), SQLITE_OK)
        if wal { XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil), SQLITE_OK) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE facts (id TEXT PRIMARY KEY, amount INTEGER); INSERT INTO facts VALUES ('stable-source',42);", nil, nil, nil), SQLITE_OK)
        if !wal { sqlite3_close(database); database = nil }
        for name in WorkspaceIO.requiredFiles where name != "banking.sqlite3" {
            let bytes: Data
            switch name {
            case "operation-results.json": bytes = try WorkspaceIO.canonical(["state_id": stateID, "results": []])
            case "review/financial-review.json": bytes = Data("{\"records\":[]}".utf8)
            default: bytes = Data("{}".utf8)
            }
            try WorkspaceIO.atomicWrite(bytes, to: WorkspaceIO.safeChild(root, name))
        }
        var hashes = [String: String]()
        for name in WorkspaceIO.requiredFiles { hashes[name] = try WorkspaceIO.hash(WorkspaceIO.safeChild(root, name)) }
        let manifest = try WorkspaceIO.canonical(["workspace_id": workspaceID, "state_id": stateID, "local_revision": 0, "files": hashes])
        try WorkspaceIO.atomicWrite(manifest, to: root.appendingPathComponent("state-manifest.json"))
        let pointer = WorkspaceStatePointer(workspaceID: workspaceID, stateID: stateID, localRevision: 0, manifestHash: WorkspaceIO.digest(manifest))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pointer.document), to: paths.activeState)
        return Fixture(paths: paths, handle: StateHandle(pointer: pointer, root: root), database: database)
    }
    private func prepare(_ transaction: WorkspaceTransaction, token: WorkspaceWriteToken, operation: Bool = false) throws {
        if operation {
            try WorkspaceIO.atomicWrite(Data("{\"records\":[{\"id\":\"stable-source\",\"amount\":43}]}".utf8),
                                        to: transaction.file("review/financial-review.json", token: token))
            try execute("UPDATE facts SET amount=43", database: transaction.database)
            XCTAssertTrue(try NativeWorkspaceEffects.record(transaction: transaction, token: token))
        } else {
            XCTAssertFalse(try NativeWorkspaceEffects.record(transaction: transaction, token: token))
        }
        _ = try transaction.prepare(token: token)
    }
    private func execute(_ sql: String, database file: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(file.path, &database) == SQLITE_OK else { throw WorkspaceError.invalid("test database open") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw WorkspaceError.invalid("test database update") }
    }
    func testSnapshotIncludesUncheckpointedWALAndKeepsStableIDs() throws {
        let fixture = try fixture(wal: true); defer { fixture.close() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.handle.database.path + "-wal"))
        // A live legacy DB can have WAL; an immutable committed state cannot.
        let snapshot = try WorkspaceIO.safeChild(fixture.paths.workspace, "legacy-snapshot")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try WorkspaceIO.snapshot(from: fixture.handle.root, to: snapshot)
        var database: OpaquePointer?, statement: OpaquePointer?
        let copiedFile = try WorkspaceIO.safeChild(snapshot, "banking.sqlite3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedFile.path))
        // The backup is mutable staging; seal its WAL header before immutable reads.
        try WorkspaceIO.sqliteSeal(copiedFile)
        guard sqlite3_open_v2(copiedFile.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return XCTFail("cannot open snapshot: " + copiedFile.path) }
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT amount FROM facts WHERE id='stable-source'", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 42)
    }
    func testSnapshotPreservesMerchantDatabaseCommittedWAL() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let merchant = fixture.handle.root.appendingPathComponent("merchant.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(merchant.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE decisions(id TEXT PRIMARY KEY); INSERT INTO decisions VALUES ('confirmed');", nil, nil, nil), SQLITE_OK)
        let snapshot = try WorkspaceIO.safeChild(fixture.paths.workspace, "merchant-snapshot")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try WorkspaceIO.snapshot(from: fixture.handle.root, to: snapshot)
        var copied: OpaquePointer?, statement: OpaquePointer?
        let copiedFile = try WorkspaceIO.safeChild(snapshot, "merchant.sqlite3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedFile.path))
        try WorkspaceIO.sqliteSeal(copiedFile)
        guard sqlite3_open_v2(copiedFile.path, &copied, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return XCTFail("cannot open snapshot: " + copiedFile.path) }
        defer { sqlite3_finalize(statement); sqlite3_close(copied) }
        XCTAssertEqual(sqlite3_prepare_v2(copied, "SELECT id FROM decisions", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0))), "confirmed")
    }
    func testUnlistedFileCannotEnterPreparedOrActiveState() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let coordinator = WorkspaceCoordinator(paths: fixture.paths), token = try coordinator.acquireWriteToken()
        let transaction = try coordinator.begin(token: token, expectedPointer: fixture.handle.pointer)
        try prepare(transaction, token: token)
        try Data("{}".utf8).write(to: transaction.root.appendingPathComponent("unlisted.json"))
        XCTAssertThrowsError(try transaction.commit(token: token))
        XCTAssertEqual(try fixture.paths.readPointer(), fixture.handle.pointer)
        try Data("{}".utf8).write(to: fixture.handle.root.appendingPathComponent("unlisted.json"))
        XCTAssertThrowsError(try fixture.paths.readState())
    }
    func testMutableJSONAndDatabaseAreIndependentInodes() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let coordinator = WorkspaceCoordinator(paths: fixture.paths), token = try coordinator.acquireWriteToken()
        let transaction = try coordinator.begin(token: token, expectedPointer: fixture.handle.pointer)
        for path in ["review/financial-review.json", "banking.sqlite3"] {
            var old = stat(), new = stat()
            XCTAssertEqual(lstat(try fixture.handle.file(path).path, &old), 0)
            XCTAssertEqual(lstat(try transaction.file(path, token: token).path, &new), 0)
            XCTAssertNotEqual(old.st_ino, new.st_ino)
        }
        try Data("{\"changed\":true}".utf8).write(to: transaction.file("review/financial-review.json", token: token))
        XCTAssertEqual(try Data(contentsOf: fixture.handle.review.appendingPathComponent("financial-review.json")), Data("{\"records\":[]}".utf8))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(transaction.database.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "UPDATE facts SET amount=99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let manifest = try WorkspaceIO.object(WorkspaceIO.read(fixture.handle.manifest))
        let oldHashes = try XCTUnwrap(manifest["files"] as? [String: String])
        XCTAssertEqual(try WorkspaceIO.hash(fixture.handle.database), oldHashes["banking.sqlite3"])
    }
    func testGateUsesOneStableInodeAndNestedToken() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let coordinator = WorkspaceCoordinator(paths: fixture.paths)
        var first: WorkspaceWriteToken? = try coordinator.acquireWriteToken()
        var initial = stat(); XCTAssertEqual(lstat(fixture.paths.maintenanceLock.path, &initial), 0)
        XCTAssertThrowsError(try coordinator.acquireWriteToken())
        try first!.validate(for: fixture.paths)
        first = nil
        let second = try coordinator.acquireWriteToken()
        var reopened = stat(); XCTAssertEqual(lstat(fixture.paths.maintenanceLock.path, &reopened), 0)
        XCTAssertEqual(initial.st_ino, reopened.st_ino)
        try second.validate(for: fixture.paths)
    }
    func testFullTupleCASAndFixedReadHandle() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let fixedRead = try fixture.paths.readState()
        let coordinator = WorkspaceCoordinator(paths: fixture.paths), token = try coordinator.acquireWriteToken()
        let transaction = try coordinator.begin(token: token, expectedPointer: fixture.handle.pointer)
        try prepare(transaction, token: token)
        let tampered = WorkspaceStatePointer(workspaceID: fixedRead.pointer.workspaceID, stateID: fixedRead.pointer.stateID,
                                             localRevision: 1, manifestHash: fixedRead.pointer.manifestHash)
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(tampered.document), to: fixture.paths.activeState)
        XCTAssertThrowsError(try transaction.commit(token: token))
        XCTAssertEqual(fixedRead.root.path, fixture.handle.root.path)
        XCTAssertEqual(fixedRead.pointer.localRevision, 0)
    }
    func testCrashAfterPointerUsesMembershipEvenWhenJournalIsPrepared() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let coordinator = WorkspaceCoordinator(paths: fixture.paths), token = try coordinator.acquireWriteToken()
        let transaction = try coordinator.begin(token: token, expectedPointer: fixture.handle.pointer)
        try prepare(transaction, token: token, operation: true)
        XCTAssertThrowsError(try transaction.commit(token: token, failureInjector: { if $0 == .pointerCommitted { throw Injected.crash } }))
        let journal = try WorkspaceIO.object(WorkspaceIO.read(fixture.paths.journals.appendingPathComponent(transaction.stateID + ".json")))
        XCTAssertEqual(journal["phase"] as? String, "prepared")
        guard case .committed(let active) = try coordinator.recover(operationID: transaction.operationID) else { return XCTFail("pointer membership must prove commit") }
        XCTAssertEqual(active.pointer.stateID, transaction.stateID)
        XCTAssertThrowsError(try transaction.abandon(token: token))
    }
    func testCrashBeforePointerDoesNotActivateInstalledOrphanState() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let coordinator = WorkspaceCoordinator(paths: fixture.paths), token = try coordinator.acquireWriteToken()
        let transaction = try coordinator.begin(token: token, expectedPointer: fixture.handle.pointer)
        try prepare(transaction, token: token, operation: true)
        XCTAssertThrowsError(try transaction.commit(token: token, failureInjector: { if $0 == .stateInstalled { throw Injected.crash } }))
        XCTAssertEqual(try fixture.paths.readState().pointer, fixture.handle.pointer)
        XCTAssertEqual(try coordinator.recover(operationID: transaction.operationID), .uncommitted)
    }
    func testNoOpPrepareDoesNotInventOperationReceipt() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let coordinator = WorkspaceCoordinator(paths: fixture.paths), token = try coordinator.acquireWriteToken()
        let transaction = try coordinator.begin(token: token, expectedPointer: fixture.handle.pointer)
        try prepare(transaction, token: token)
        let committed = try transaction.commit(token: token)
        let ledger = try WorkspaceIO.object(WorkspaceIO.read(committed.operationResults))
        XCTAssertEqual((ledger["results"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(try coordinator.recover(operationID: transaction.operationID), .uncommitted)
    }
    func testUnledgeredDeletionSkipsTombstoneButRetainsDocumentProof() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let coordinator = WorkspaceCoordinator(paths: fixture.paths), token = try coordinator.acquireWriteToken()
        let transaction = try coordinator.begin(token: token, expectedPointer: fixture.handle.pointer)
        try execute("DELETE FROM facts", database: transaction.database)
        try WorkspaceIO.atomicWrite(Data("{\"records\":[],\"updated\":true}".utf8),
                                    to: transaction.file("review/financial-review.json", token: token))
        XCTAssertTrue(try NativeWorkspaceEffects.record(transaction: transaction, token: token))
        _ = try transaction.prepare(token: token)
        let committed = try transaction.commit(token: token)
        let ledger = try WorkspaceIO.object(WorkspaceIO.read(committed.operationResults))
        let results = try XCTUnwrap(ledger["results"] as? [[String: Any]])
        let effects = try XCTUnwrap(results.last?["membership"] as? [[String: Any]])
        XCTAssertEqual(effects.compactMap { $0["entity_key"] as? String }, ["document:review/financial-review.json"])
        XCTAssertFalse(effects.contains { $0["kind"] as? String == "tombstone" })
        _ = try fixture.paths.readState()
    }
    func testLedgeredDeletionSupersedesRealRecordAndDatabaseEffects() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let coordinator = WorkspaceCoordinator(paths: fixture.paths), token = try coordinator.acquireWriteToken()
        let first = try coordinator.begin(token: token, expectedPointer: fixture.handle.pointer)
        try prepare(first, token: token, operation: true)
        let previous = try first.commit(token: token)
        let transaction = try coordinator.begin(token: token, expectedPointer: previous.pointer)
        try execute("DELETE FROM facts", database: transaction.database)
        try WorkspaceIO.atomicWrite(Data("{\"records\":[]}".utf8),
                                    to: transaction.file("review/financial-review.json", token: token))
        XCTAssertTrue(try NativeWorkspaceEffects.record(transaction: transaction, token: token))
        _ = try transaction.prepare(token: token)
        let committed = try transaction.commit(token: token)
        let ledger = try WorkspaceIO.object(WorkspaceIO.read(committed.operationResults))
        let results = try XCTUnwrap(ledger["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 2)
        let original = try XCTUnwrap(results.first?["membership"] as? [[String: Any]])
        let current = try XCTUnwrap(results.last?["membership"] as? [[String: Any]])
        let tombstones = current.filter { $0["kind"] as? String == "tombstone" }
        XCTAssertEqual(tombstones.count, 2)
        for effect in tombstones {
            let entity = try XCTUnwrap(effect["entity_key"] as? String)
            let earlier = original.filter { $0["entity_key"] as? String == entity }.compactMap { $0["key"] as? String }
            XCTAssertFalse(earlier.isEmpty)
            XCTAssertEqual(effect["supersedes"] as? [String], earlier.sorted())
            XCTAssertEqual(effect["digest"] as? String, WorkspaceIO.digest(try WorkspaceIO.canonical(["entity": entity, "deleted": true])))
        }
        _ = try fixture.paths.readState()
    }
    func testPrepareRetargetsOnlyTopLevelLedgerAndPreservesUnknownInteger() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let coordinator = WorkspaceCoordinator(paths: fixture.paths), token = try coordinator.acquireWriteToken()
        let transaction = try coordinator.begin(token: token, expectedPointer: fixture.handle.pointer)
        let raw = Data(("{\"state_id\":\"" + fixture.handle.pointer.stateID + "\",\"results\":[],\"metadata\":{\"exact\":900719925474099312345678901234567890}}").utf8)
        try WorkspaceIO.atomicWrite(raw, to: transaction.file("operation-results.json", token: token))
        _ = try transaction.prepare(token: token)
        let normalized = try WorkspaceIO.read(transaction.root.appendingPathComponent("operation-results.json"))
        XCTAssertEqual(try WorkspaceIO.string(WorkspaceIO.object(normalized), "state_id"), transaction.stateID)
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: normalized, atObjectKeys: ["metadata", "exact"]), Data("900719925474099312345678901234567890".utf8))
    }
    func testPreparedClosureRejectsBypassMutationAndCancelledStateCannotCommit() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let coordinator = WorkspaceCoordinator(paths: fixture.paths), token = try coordinator.acquireWriteToken()
        let transaction = try coordinator.begin(token: token, expectedPointer: fixture.handle.pointer)
        try prepare(transaction, token: token)
        try Data("{\"changed\":true}".utf8).write(to: fixture.handle.review.appendingPathComponent("financial-review.json"))
        XCTAssertThrowsError(try transaction.commit(token: token))
        XCTAssertEqual(try fixture.paths.readPointer(), fixture.handle.pointer)
        try transaction.abandon(token: token)
        XCTAssertThrowsError(try transaction.commit(token: token))
    }
    func testPointerFieldTypesAndSymlinkFailClosed() throws {
        let fixture = try fixture(); defer { fixture.close() }
        var document = fixture.handle.pointer.document; document["local_revision"] = true
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(document), to: fixture.paths.activeState)
        XCTAssertThrowsError(try fixture.paths.readState())
        let raw = String(data: try WorkspaceIO.canonical(fixture.handle.pointer.document), encoding: .utf8)!.replacingOccurrences(of: "\"local_revision\":0", with: "\"local_revision\":0.0")
        try WorkspaceIO.atomicWrite(Data(raw.utf8), to: fixture.paths.activeState)
        XCTAssertThrowsError(try fixture.paths.readState())
        XCTAssertThrowsError(try fixture.paths.stateRoot("../escape"))
        let link = fixture.paths.workspace.appendingPathComponent("linked")
        XCTAssertEqual(symlink(fixture.handle.root.path, link.path), 0)
        XCTAssertThrowsError(try WorkspacePaths(workspace: link))
    }
    func testMetadataAndHashRejectFIFOWithoutBlockingAndPreserveMissingError() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let fifo = fixture.paths.workspace.appendingPathComponent("provider-fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()
        XCTAssertThrowsError(try WorkspaceIO.read(fifo))
        XCTAssertThrowsError(try WorkspaceIO.hash(fifo))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let missing = fixture.paths.workspace.appendingPathComponent("not-arrived")
        XCTAssertThrowsError(try WorkspaceIO.read(missing)) {
            XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual(($0 as NSError).code, Int(ENOENT))
        }
        let large = fixture.paths.workspace.appendingPathComponent("large-metadata")
        try Data(repeating: 0, count: 4097).write(to: large)
        XCTAssertThrowsError(try WorkspaceIO.read(large, limit: 4096))
        XCTAssertEqual(try WorkspaceIO.read(large, limit: 4097).count, 4097)
    }
}
