import Foundation
import XCTest
@testable import PaymentImageCore

@MainActor final class WorkspaceReclamationTests: XCTestCase {
    private func advance(_ paths: WorkspacePaths) throws -> StateHandle {
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        let transaction = try WorkspaceCoordinator(paths: paths).begin(token: token, expectedPointer: paths.readPointer())
        _ = try transaction.prepare(token: token)
        return try transaction.commit(token: token)
    }
    private func collect(_ paths: WorkspacePaths) throws -> WorkspaceReclamation.Result {
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        return try WorkspaceReclamation.collect(paths: paths, token: token)
    }
    func testHeldStateSurvivesThenUnreferencedAncestorIsRemoved() throws {
        let fixture = try ReviewFamilyHostTests().fixture(); defer { fixture.remove() }
        _ = try collect(fixture.paths)
        var reader: StateHandle? = try fixture.paths.readState()
        let oldRoot = try XCTUnwrap(reader).root
        let current = try advance(fixture.paths)
        XCTAssertEqual(try collect(fixture.paths).states, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertEqual(try WorkspaceIO.read(XCTUnwrap(reader).manifest).count > 0, true)
        reader = nil
        XCTAssertEqual(try collect(fixture.paths).states, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertEqual(try fixture.paths.readState().pointer, current.pointer)
        try WorkspaceBusinessValidator.validate(current.root)
    }
    func testPendingJournalPinsItsBaseAndOriginalButOrphanSourceIsCollected() throws {
        let fixture = try ReviewFamilyHostTests().fixture(); defer { fixture.remove() }
        _ = try collect(fixture.paths)
        let previous = try fixture.paths.readPointer(), oldRoot = try fixture.paths.stateRoot(previous.stateID)
        _ = try advance(fixture.paths)
        let needed = Data("unfinished input".utf8), orphan = Data("unreferenced input".utf8)
        let neededHash = WorkspaceIO.digest(needed), orphanHash = WorkspaceIO.digest(orphan)
        try WorkspaceIO.atomicWrite(needed, to: fixture.paths.sources.appendingPathComponent(neededHash))
        try WorkspaceIO.atomicWrite(orphan, to: fixture.paths.sources.appendingPathComponent(orphanHash))
        let journal = fixture.paths.journals.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["workspace_id": previous.workspaceID, "phase": "needsReview",
            "state_id": UUID().uuidString.lowercased(), "expected_pointer": previous.document,
            "operation": ["operation_id": "pending", "inputs": [["sha256": neededHash]]]]), to: journal)
        let result = try collect(fixture.paths)
        XCTAssertEqual(result.states, 0); XCTAssertEqual(result.sourceObjects, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertEqual(try WorkspaceIO.read(fixture.paths.sources.appendingPathComponent(neededHash)), needed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }
    #if os(macOS)
    func testPythonReaderLeaseAlsoProtectsAStateFromNativeCollection() throws {
        let fixture = try ReviewFamilyHostTests().fixture(); defer { fixture.remove() }
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        _ = try collect(fixture.paths)
        let ready = fixture.paths.workspace.appendingPathComponent("reader-ready")
        let pipe = Pipe(), process = Process()
        process.executableURL = try TestPlatform.python()
        process.arguments = ["-B", "-c", "import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);from scripts.workspace_state import WorkspacePaths;s=WorkspacePaths(sys.argv[2]).resolve_active();Path(sys.argv[3]).write_text(s.state_id);sys.stdin.read(1)", repository.path, fixture.paths.workspace.path, ready.path]
        process.standardInput = pipe
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        _ = try advance(fixture.paths)
        XCTAssertEqual(try collect(fixture.paths).states, 0)
        try pipe.fileHandleForWriting.write(contentsOf: Data("x".utf8)); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try collect(fixture.paths).states, 1)
    }
    #endif
    func testSelectedAndPreparedClientViewsRemainPinnedUntilReadersRelease() throws {
        let owner = ReviewFamilyHostTests(), fixture = try owner.fixture(), remote = owner.remote(fixture)
        let helper = ReviewFamilyClientSessionTests(), client = try helper.client(fixture.paths)
        defer { fixture.remove(); for root in [remote, client.workspace] { try? FileManager.default.removeItem(at: root) } }
        _ = try ReviewFamilyHost.create(paths: fixture.paths, remote: remote)
        var old: ReviewFamilyClientHandle? = try helper.connect(client, remote: remote)
        let oldRoot = try XCTUnwrap(old).review
        let (_, current) = try ReviewFamilyClientSession.edit(paths: client, expected: XCTUnwrap(old)) { root, _ in try helper.change(root, salary: 44) }
        do {
            let token = try WorkspaceCoordinator(paths: client).acquireWriteToken()
            XCTAssertEqual(try WorkspaceReclamation.collectClientViews(paths: client, token: token), 0)
        }
        old = nil
        do {
            let token = try WorkspaceCoordinator(paths: client).acquireWriteToken()
            XCTAssertEqual(try WorkspaceReclamation.collectClientViews(paths: client, token: token), 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertEqual(try ReviewFamilyClientSession.read(paths: client)?.version, current.version)
    }
    func testClientCacheCollectsReleasedSnapshotButKeepsSelectedOfflineDataAndQueue() throws {
        let owner = ReviewFamilyHostTests(), fixture = try owner.fixture(), remote = owner.remote(fixture)
        let helper = ReviewFamilyClientSessionTests(), client = try helper.client(fixture.paths)
        defer { fixture.remove(); for root in [remote, client.workspace] { try? FileManager.default.removeItem(at: root) } }
        let connection = try ReviewFamilyHost.create(paths: fixture.paths, remote: remote)
        var old: ReviewFamilyClientHandle? = try helper.connect(client, remote: remote)
        let previous = try XCTUnwrap(old).checkpoint.generation
        try HouseholdWorkBackupTests().edit(fixture.paths) { tx, token in
            try WorkspaceIO.atomicWrite(Data("{\"afterTaxSalary\":51}".utf8), to: tx.file("review/fire-parameters-user.json", token: token))
        }
        _ = try ReviewFamilyHost.publish(paths: fixture.paths)
        let current = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: client))
        let cache = client.device.appendingPathComponent("family-sync/client/" + connection.selection.bindingID)
        do {
            let token = try WorkspaceCoordinator(paths: client).acquireWriteToken()
            _ = try ReviewFamilyClientSession.collect(paths: client, token: token)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("snapshots/" + previous).path))
        old = nil
        do {
            let token = try WorkspaceCoordinator(paths: client).acquireWriteToken()
            _ = try ReviewFamilyClientSession.collect(paths: client, token: token)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("snapshots/" + previous).path))
        try FileManager.default.removeItem(at: remote)
        XCTAssertEqual(try ReviewFamilyClientSession.read(paths: client)?.version, current.version)
        XCTAssertEqual(current.fields.causal.values["parameter/afterTaxSalary"], "51")
    }
    func testProviderCollectionKeepsLatestAndPendingTransferReferences() throws {
        let owner = ReviewFamilyHostTests(), fixture = try owner.fixture(), remote = owner.remote(fixture)
        defer { fixture.remove(); try? FileManager.default.removeItem(at: remote) }
        let connection = try ReviewFamilyHost.create(paths: fixture.paths, remote: remote)
        let head = try WorkspaceIO.object(WorkspaceIO.read(remote.appendingPathComponent("current.json")))
        let generation = try WorkspaceIO.string(head, "generation")
        let old = Data("obsolete complete snapshot".utf8), orphan = Data("orphan object".utf8)
        try WorkspaceIO.atomicWrite(old, to: remote.appendingPathComponent("snapshots/" + WorkspaceIO.digest(old)))
        try WorkspaceIO.atomicWrite(orphan, to: remote.appendingPathComponent("objects/" + WorkspaceIO.digest(orphan)))
        let pending = Data("pending original".utf8), pendingHash = WorkspaceIO.digest(pending), request = UUID().uuidString.lowercased()
        // The envelope becomes visible before original bytes. Both an incomplete
        // transfer and a completed original remain referenced during collection.
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["binding_id": connection.selection.bindingID,
            "payload_hash": String(repeating: "a", count: 64), "files": [["sha256": pendingHash]]]), to: remote.appendingPathComponent("requests/" + request + ".json"))
        let first = try ReviewFamilyReclamation.collect(remote: remote, selection: connection.selection, expectedGeneration: generation)
        XCTAssertEqual(first.snapshots, 1); XCTAssertEqual(first.objects, 1)
        try WorkspaceIO.atomicWrite(pending, to: remote.appendingPathComponent("objects/" + pendingHash))
        XCTAssertEqual(try ReviewFamilyReclamation.collect(remote: remote, selection: connection.selection, expectedGeneration: generation).objects, 0)
        let client = try ReviewFamilyClientSessionTests().client(fixture.paths)
        defer { try? FileManager.default.removeItem(at: client.workspace) }
        let handle = try ReviewFamilyClientSessionTests().connect(client, remote: remote)
        XCTAssertEqual(handle.checkpoint.generation, generation)
        XCTAssertEqual(try WorkspaceIO.read(remote.appendingPathComponent("objects/" + pendingHash)), pending)
    }
    func testProviderCleanupRejectsStaleHeadBeforeRemovingAnything() throws {
        let owner = ReviewFamilyHostTests(), fixture = try owner.fixture(), remote = owner.remote(fixture)
        defer { fixture.remove(); try? FileManager.default.removeItem(at: remote) }
        let connection = try ReviewFamilyHost.create(paths: fixture.paths, remote: remote)
        let orphan = Data("keep on failed collection".utf8), path = remote.appendingPathComponent("objects/" + WorkspaceIO.digest(orphan))
        try WorkspaceIO.atomicWrite(orphan, to: path)
        XCTAssertThrowsError(try ReviewFamilyReclamation.collect(remote: remote, selection: connection.selection, expectedGeneration: String(repeating: "f", count: 64)))
        XCTAssertEqual(try WorkspaceIO.read(path), orphan)
    }
}
