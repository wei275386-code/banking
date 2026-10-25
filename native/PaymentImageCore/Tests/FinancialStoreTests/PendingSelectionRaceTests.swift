#if os(macOS)
import XCTest
import Foundation
@testable import PaymentImageCore
@testable import EvidenceBrowser

/// Current family selection races exercise real local descriptors and snapshots.
@MainActor final class PendingSelectionRaceTests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL, remote: URL, pointer: URL, withheld: URL
        let a: WorkspacePaths, b: WorkspacePaths
        let storage: AppStorageLocations
        let store: FinancialStore
        let controller: MacFamilyClientSyncController
        func cleanup() {
            controller.stop(); store.familyClientSyncController?.stop(); store.familyHostSyncController?.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }
    @MainActor private final class Suspension {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in self.continuation = continuation; entered.fulfill() }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    private func fixture() async throws -> Fixture {
        let root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("current-selection-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = try WorkspaceStoreTests().emptyWorkspace()
        defer { try? FileManager.default.removeItem(at: host.workspace) }
        let remote = root.appendingPathComponent("provider-a")
        _ = try ReviewFamilyHost.create(paths: host, remote: remote)
        let pointer = remote.appendingPathComponent("current.json"), withheld = root.appendingPathComponent("withheld.json")
        try FileManager.default.moveItem(at: pointer, to: withheld)
        let storage = try AppStorageLocations(applicationSupport: root.appendingPathComponent("support"),
            caches: root.appendingPathComponent("cache"), temporary: root.appendingPathComponent("temp"))
        let a = try WorkspacePaths(workspace: storage.newWorkspaceURL()), b = try WorkspacePaths(workspace: storage.newWorkspaceURL())
        let store = FinancialStore()
        try await store.connectWorkspaceClient(paths: a, remote: remote, evidence: nil) {
            try AppStorageIndex(locations: storage).select(containerID: a.workspace.lastPathComponent, shape: .snapshotClient)
        }
        let controller = try XCTUnwrap(store.familyClientSyncController)
        await controller.stopAndWait()
        let providerB = root.appendingPathComponent("provider-b")
        let selection = try ReviewFamilyBindingSelection(workspaceID: UUID().uuidString.lowercased(),
            bindingID: UUID().uuidString.lowercased(), hostID: UUID().uuidString.lowercased())
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(selection.document), to: providerB.appendingPathComponent("family.json"))
        _ = try ReviewFamilyClientSession.connect(paths: b, remote: providerB, bookmark: nil)
        try FileManager.default.removeItem(at: providerB)
        return .init(root: root, remote: remote, pointer: pointer, withheld: withheld, a: a, b: b, storage: storage, store: store, controller: controller)
    }
    private func selectB(_ f: Fixture) throws -> UUID {
        try f.store.selectPendingWorkspace(paths: f.b) {
            try AppStorageIndex(locations: f.storage).select(containerID: f.b.workspace.lastPathComponent, shape: .snapshotClient)
        }
    }
    private func assertB(_ f: Fixture, generation: UUID) throws {
        XCTAssertTrue(f.store.isWorkspaceSelectionCurrent(paths: f.b, generation: generation))
        XCTAssertEqual(try AppStorageIndex(locations: f.storage).selected()?.url.path, f.b.workspace.path)
        XCTAssertNil(f.store.root); XCTAssertNil(f.store.report)
        XCTAssertFalse(f.store.editingAvailable); XCTAssertFalse(f.store.processorAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.b.activeState.path))
        XCTAssertNotNil(try ReviewFamilyClientSession.readConnection(paths: f.b))
    }
    func testSelectedPendingClientLoadsItsFirstVerifiedSnapshot() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        XCTAssertNil(f.store.root)
        try FileManager.default.moveItem(at: f.withheld, to: f.pointer)
        await f.controller.refresh()
        XCTAssertNotNil(f.store.report); XCTAssertTrue(f.store.editingAvailable)
        XCTAssertFalse(f.store.processorAvailable)
        XCTAssertEqual(f.store.familyClientPaths, f.a)
        XCTAssertNotNil(try ReviewFamilyClientSession.read(paths: f.a))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.a.activeState.path))
    }
    func testOfflinePendingSelectionRevokesPreviousControllerBeforeSnapshotArrives() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let generation = try selectB(f)
        try FileManager.default.moveItem(at: f.withheld, to: f.pointer)
        await f.controller.refresh()
        try assertB(f, generation: generation)
        XCTAssertNil(try ReviewFamilyClientSession.read(paths: f.a))
    }
    func testSelectingOfflineFamilyReplacesLoadedViewWithoutChangingSavedBytes() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        try FileManager.default.moveItem(at: f.withheld, to: f.pointer)
        await f.controller.refresh()
        let a = try XCTUnwrap(ReviewFamilyClientSession.read(paths: f.a))
        let bytes = try WorkspaceIO.read(a.review.appendingPathComponent("financial-review.json"))
        let generation = try selectB(f)
        try assertB(f, generation: generation)
        XCTAssertEqual(try WorkspaceIO.read(a.review.appendingPathComponent("financial-review.json")), bytes)
    }
    func testPendingSelectionPreservesUnsavedDraftBeforeIndexCommit() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        try FileManager.default.moveItem(at: f.withheld, to: f.pointer)
        await f.controller.refresh()
        f.store.report?.fire_parameters.currentFireAssets = 123
        XCTAssertTrue(f.store.hasUnsavedParameters)
        XCTAssertThrowsError(try selectB(f))
        XCTAssertEqual(f.store.report?.fire_parameters.currentFireAssets, 123)
        XCTAssertEqual(try AppStorageIndex(locations: f.storage).selected()?.url.path, f.a.workspace.path)
        XCTAssertTrue(f.store.familyClientSyncController === f.controller)
    }
    func testInvalidConnectionPreservesPendingSelectionAndDescriptor() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let descriptor = f.a.device.appendingPathComponent("family-connection.json"), raw = try WorkspaceIO.read(descriptor)
        let wrong = f.root.appendingPathComponent("wrong")
        var marker = try WorkspaceIO.object(WorkspaceIO.read(f.remote.appendingPathComponent("family.json")))
        marker["binding_id"] = UUID().uuidString.lowercased()
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(marker), to: wrong.appendingPathComponent("family.json"))
        do {
            try await f.store.connectWorkspaceClient(paths: f.a, remote: wrong, evidence: nil,
                connectionSaved: { XCTFail("Invalid connection cannot select") })
            XCTFail("Different family must fail")
        } catch {}
        XCTAssertEqual(try WorkspaceIO.read(descriptor), raw)
        XCTAssertTrue(f.store.familyClientSyncController === f.controller)
        XCTAssertEqual(try AppStorageIndex(locations: f.storage).selected()?.url.path, f.a.workspace.path)
    }
    private func verifyInFlightSelection(_ phase: MacFamilyClientSyncController.ClientActivationPhase) async throws {
        let f = try await fixture(); defer { f.cleanup() }
        try FileManager.default.moveItem(at: f.withheld, to: f.pointer)
        let suspension = Suspension(expectation(description: "current refresh suspended"))
        defer { suspension.release(); f.controller.clientActivationBarrier = nil }
        f.controller.clientActivationBarrier = { point in if point == phase { await suspension.wait() } }
        let refresh = Task { await f.controller.refresh() }
        guard await XCTWaiter.fulfillment(of: [suspension.entered], timeout: 10) == .completed else {
            suspension.release(); await refresh.value; return XCTFail("Refresh did not reach expected phase")
        }
        let generation = try selectB(f)
        f.store.error = "new family error"; let status = f.store.syncStatus
        suspension.release(); await refresh.value
        try assertB(f, generation: generation)
        XCTAssertEqual(f.store.error, "new family error"); XCTAssertEqual(f.store.syncStatus, status)
        if phase == .prepared { XCTAssertNil(try ReviewFamilyClientSession.read(paths: f.a)) }
        if phase == .committed { XCTAssertNotNil(try ReviewFamilyClientSession.read(paths: f.a)) }
    }
    func testPreparedSnapshotCannotCommitAfterSelectionChanges() async throws { try await verifyInFlightSelection(.prepared) }
    func testCommittedSnapshotCannotLoadAfterSelectionChanges() async throws { try await verifyInFlightSelection(.committed) }
    func testCapturedRefreshCannotStartAfterSelectionChanges() async throws { try await verifyInFlightSelection(.captured) }
    func testMainRootHandoffRestartsCurrentClientOnceAndStaleRootCannotReopen() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        try FileManager.default.moveItem(at: f.withheld, to: f.pointer)
        await f.controller.refresh()
        let review = try XCTUnwrap(f.store.root)
        await f.store.resumeDisplayedWorkspace(review, evidence: BrowserStore())
        let polling = f.controller.pollingGeneration
        XCTAssertNotNil(polling)
        await f.store.resumeDisplayedWorkspace(review, evidence: BrowserStore())
        XCTAssertEqual(f.controller.pollingGeneration, polling)
        await f.controller.stopAndWait()
        let generation = try selectB(f)
        await f.store.resumeDisplayedWorkspace(review, evidence: BrowserStore())
        try assertB(f, generation: generation)
        XCTAssertNil(f.store.familyClientSyncController)
    }
    func testCancelledRefreshRetainsConnectionAndCanContinueWithoutReauthorization() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        try FileManager.default.moveItem(at: f.withheld, to: f.pointer)
        let suspension = Suspension(expectation(description: "preparation suspended"))
        defer { suspension.release(); f.controller.clientActivationBarrier = nil }
        f.controller.clientActivationBarrier = { if $0 == .prepared { await suspension.wait() } }
        let work = Task { await f.controller.refresh() }
        guard await XCTWaiter.fulfillment(of: [suspension.entered], timeout: 10) == .completed else {
            suspension.release(); await work.value; return XCTFail("Preparation did not suspend")
        }
        work.cancel(); suspension.release(); await work.value
        XCTAssertNil(f.store.root); XCTAssertNotNil(try ReviewFamilyClientSession.readConnection(paths: f.a))
        f.controller.clientActivationBarrier = nil
        await f.controller.refresh()
        XCTAssertNotNil(f.store.report); XCTAssertTrue(f.store.editingAvailable)
    }
}
#endif
