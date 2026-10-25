import Foundation
import XCTest
import CSQLite
import Darwin
@testable import PaymentImageCore

@MainActor final class ReviewClientBusinessProofTests: XCTestCase {
    nonisolated private static func physicalFootprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw WorkspaceError.io("task memory measurement") }
        return info.phys_footprint
    }
    func testOperatorSuppliedStagingValidationHasBoundedFootprint() throws {
        guard let path = ProcessInfo.processInfo.environment["BANKING_STAGING_QA_READ_ROOT"] else {
            throw XCTSkip("Requires an explicit operator-selected, inactive staging directory")
        }
        let root = URL(fileURLWithPath: path)
        try WorkspaceIO.rejectSymlinks(root)
        let before = try Self.physicalFootprint(), ceiling = before + 2 * 1024 * 1024 * 1024
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watchdog.schedule(deadline: .now(), repeating: .milliseconds(250))
        watchdog.setEventHandler { @Sendable in
            if let current = try? Self.physicalFootprint(), current > ceiling {
                fputs("Staging memory ceiling exceeded; terminating the read-only probe.\n", stderr)
                _exit(74)
            }
        }
        watchdog.resume(); defer { watchdog.cancel() }
        try autoreleasepool { try WorkspaceBusinessValidator.validate(root) }
        let members = try WorkspaceIO.regularFiles(root)
        let hashes = try WorkspaceIO.validatedMemberHashes(root, members: members)
        let after = try Self.physicalFootprint()
        XCTAssertLessThan(after, ceiling)
        if let output = ProcessInfo.processInfo.environment["BANKING_STAGING_QA_RESULT"] {
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["status": "passed", "file_count": hashes.count,
                "footprint_before": before, "footprint_after": after, "watchdog_delta_limit": ceiling - before,
                "business_validation": "passed", "canonical_documents_and_file_hashes": "passed", "source_bytes_modified": false]),
                to: URL(fileURLWithPath: output))
        }
    }
    func testHistoricalSQLiteReportsUseProjectionTextBudget() throws {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent("history-sqlite-budget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("financial-before.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE reports(payload TEXT); INSERT INTO reports VALUES(printf('%.*c', 3145728, 'x'));", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK); db = nil
        XCTAssertFalse(try NativeWorkspaceEffects.database(file, relative: "review/review-history/edit/financial-before.sqlite3").isEmpty)
        XCTAssertThrowsError(try NativeWorkspaceEffects.database(file, relative: "banking.sqlite3"))
    }
    func testHistoricalReportSnapshotsUseProjectionBudgetDuringMembershipValidation() throws {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent("history-budget-" + UUID().uuidString)
        let history = root.appendingPathComponent("review/review-history/edit")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var report = Data("{\"records\":[],\"padding\":\"".utf8)
        report.append(Data(repeating: 0x61, count: ReleaseCanonicalJSON.maximumInputBytes))
        report.append(Data("\"}".utf8))
        let relative = "review/review-history/edit/financial-before.json"
        try report.write(to: root.appendingPathComponent(relative))
        XCTAssertEqual(try ReviewWorkspaceMembership.currentEntities(root: root), ["document:" + relative: WorkspaceIO.digest(report)])
        let decision = "review/confirmed-outcomes.json"
        let decisionRaw = Data(#"{"purpose":"confirmed-outcomes","records":[]}"#.utf8)
        try decisionRaw.write(to: root.appendingPathComponent(decision))
        XCTAssertEqual(try ReviewWorkspaceMembership.currentEntities(root: root)["document:" + decision], WorkspaceIO.digest(decisionRaw))
        XCTAssertEqual(WorkspaceBusinessValidator.documentLimit("review/trace-refresh-before.json"), WorkspaceBusinessValidator.maximumProjectionBytes)
        XCTAssertEqual(WorkspaceBusinessValidator.documentLimit("review/unknown-large-metadata.json"), ReleaseCanonicalJSON.maximumInputBytes)
        try report.write(to: root.appendingPathComponent("review/unknown-large-metadata.json"))
        XCTAssertThrowsError(try ReviewWorkspaceMembership.currentEntities(root: root))
    }
    func testRepeatedImmutableHashingHasBoundedMemoryWithoutRunLoopDrain() throws {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent("hash-memory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("random-bytes")
        var bytes = Data(count: 8 * 1024 * 1024)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        try bytes.write(to: file)
        let expected = WorkspaceIO.digest(bytes)
        func footprint() throws -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard status == KERN_SUCCESS else { throw WorkspaceError.io("task memory measurement") }
            return info.phys_footprint
        }
        try autoreleasepool {
            XCTAssertEqual(try WorkspaceIO.hash(file), expected)
            XCTAssertEqual(try ReviewContentObjectIO.hash(file, maximumBytes: Int64(bytes.count)), expected)
        }
        try autoreleasepool {
            let before = try footprint()
            // Hash 1 GiB in one synchronous maintenance scope. File bytes must
            // leave the pool after each chunk, even when no run loop is running.
            for _ in 0..<64 {
                XCTAssertEqual(try WorkspaceIO.hash(file), expected)
                XCTAssertEqual(try ReviewContentObjectIO.hash(file, maximumBytes: Int64(bytes.count)), expected)
            }
            let after = try footprint()
            XCTAssertLessThan(after > before ? after - before : 0, 96 * 1024 * 1024)
        }
    }
    func testBatchObjectCopyReusesExistingBytesAndRejectsCollision() throws {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent("batch-copy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var sources = [String: URL]()
        for index in 0..<8 {
            let bytes = Data("immutable object \(index)".utf8), file = root.appendingPathComponent("source-\(index)")
            try bytes.write(to: file); sources[WorkspaceIO.digest(bytes)] = file
        }
        let destination = root.appendingPathComponent("objects")
        try ReviewContentObjectIO.copyBatch(sources, to: destination)
        try ReviewContentObjectIO.copyBatch(sources, to: destination)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, sources.count)
        for (hash, source) in sources {
            XCTAssertEqual(try WorkspaceIO.read(destination.appendingPathComponent(hash)), try WorkspaceIO.read(source))
        }
        try Data("wrong bytes".utf8).write(to: destination.appendingPathComponent(sources.keys.first!))
        XCTAssertThrowsError(try ReviewContentObjectIO.copyBatch(sources, to: destination))
    }
    func testImmutableObjectCopyHasIndependentInodeAndRejectsWrongBytes() throws {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent("immutable-copy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("objects/copy")
        let bytes = Data(repeating: 0x5a, count: 1024 * 1024), hash = WorkspaceIO.digest(bytes)
        try bytes.write(to: source)
        try ReviewContentObjectIO.copy(source, to: destination, hash: hash)
        let a = try FileManager.default.attributesOfItem(atPath: source.path)
        let b = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertNotEqual(a[.systemFileNumber] as? NSNumber, b[.systemFileNumber] as? NSNumber)
        try Data("changed source".utf8).write(to: source)
        XCTAssertEqual(try WorkspaceIO.read(destination), bytes)
        let rejected = root.appendingPathComponent("objects/rejected")
        XCTAssertThrowsError(try ReviewContentObjectIO.copy(source, to: rejected, hash: hash))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["copy"])
    }
    func testIndependentProjectionDatasetStillRequiresExactEvidenceSourceAndNoDanglingCandidate() throws {
        let fixture = try CurrentWorkspaceFixtures.make(); defer { fixture.remove() }
        let state = try fixture.paths.readState(), financial = try WorkspaceIO.read(state.review.appendingPathComponent("financial-review.json")), evidence = try WorkspaceIO.read(state.review.appendingPathComponent("payment-evidence.json"))
        try WorkspaceBusinessValidator.validateReportPair(financialRaw: financial, evidenceRaw: evidence)
        let wrongSource = try ReleaseCanonicalJSON.replacingObjectMember(raw: financial, key: "source_dataset_id", valueRaw: Data("\"wrong-source\"".utf8))
        XCTAssertThrowsError(try WorkspaceBusinessValidator.validateReportPair(financialRaw: wrongSource, evidenceRaw: evidence))
        var object = try WorkspaceIO.object(evidence), candidates = object["candidates"] as! [[String: Any]]
        candidates[0]["record_ids"] = ["missing-record"]; object["candidates"] = candidates
        XCTAssertThrowsError(try WorkspaceBusinessValidator.validateReportPair(financialRaw: financial, evidenceRaw: WorkspaceIO.canonical(object)))
    }
    func testSealedWALHeaderReadersPreserveSourceBytesAndPathSet() throws {
        let fixture = try CurrentWorkspaceFixtures.make(); defer { fixture.remove() }
        let root = fixture.paths.workspace.appendingPathComponent("sealed-sqlite-probe")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sealed.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL; CREATE TABLE facts(id INTEGER PRIMARY KEY,value INTEGER); INSERT INTO facts VALUES(1,9007199254740993); PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        // macOS SQLite may retain empty checkpointed sidecars on close. Build
        // the synthetic sealed artifact explicitly, retaining its WAL header.
        let wal = URL(fileURLWithPath: file.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) { XCTAssertEqual(try WorkspaceIO.read(wal).count, 0) }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: file.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
        let before = try WorkspaceIO.read(file)
        XCTAssertEqual(Array(before[18...19]), [2, 2])
        let names = try WorkspaceIO.regularFiles(root)
        XCTAssertEqual(names, ["sealed.sqlite3"])
        _ = try NativeWorkspaceEffects.database(file, relative: "sealed.sqlite3")
        let proof = try ReviewSQLiteReaderProof.build(file, relative: "sealed.sqlite3", neededEntities: [])
        XCTAssertEqual(proof.count, 1)
        XCTAssertEqual(try WorkspaceIO.regularFiles(root), names)
        XCTAssertEqual(try WorkspaceIO.read(file), before)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: file.path + suffix)
            try WorkspaceIO.atomicWrite(Data([1]), to: sidecar)
            XCTAssertThrowsError(try ReviewSQLiteReaderProof.build(file, relative: "sealed.sqlite3", neededEntities: []))
            XCTAssertThrowsError(try NativeWorkspaceEffects.database(file, relative: "sealed.sqlite3"))
            XCTAssertEqual(try WorkspaceIO.read(file), before)
            try FileManager.default.removeItem(at: sidecar)
        }
    }
    func testDescriptorCopyRejectsFIFOAndMetadataBudgetBeforeCaching() throws {
        let fixture = try CurrentWorkspaceFixtures.make(); defer { fixture.remove() }
        let fifo = fixture.paths.workspace.appendingPathComponent("fifo-object")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()
        XCTAssertThrowsError(try ReviewContentObjectIO.copy(fifo, to: fixture.paths.device.appendingPathComponent("copy"), hash: WorkspaceIO.digest(Data())))
        XCTAssertThrowsError(try ReviewSyncIO.read(fifo, limit: 4096))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let regular = fixture.paths.workspace.appendingPathComponent("regular-object")
        try WorkspaceIO.atomicWrite(Data(), to: regular)
        XCTAssertThrowsError(try ReviewContentObjectIO.copy(regular, to: fifo, hash: WorkspaceIO.digest(Data())))

    }
}
