#if os(macOS)
import XCTest
import Foundation
@testable import PaymentImageCore
@testable import EvidenceBrowser

/// Generates only marker/descriptor metadata; no retained household fixtures.
@MainActor final class PendingSelectionStoreTests: XCTestCase {
    private func familyFixture() async throws -> (URL, WorkspacePaths, URL, ReviewFamilyConnection, FinancialStore) {
        let root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("native-family-host-loop-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: root) } }
        let paths = try WorkspacePaths(workspace: root.appendingPathComponent("host")), remote = root.appendingPathComponent("provider")
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let source = repository
        let connection = try await Task.detached {
            let process = Process()
            process.executableURL = try SystemToolLocations.executable("python3", searchPath: ProcessInfo.processInfo.environment["PATH"])
            process.currentDirectoryURL = source
            process.arguments = ["-B", "-m", "scripts.workspace_cli", "--workspace", paths.workspace.path, "create", "--timeout-seconds", "10"]
            var environment = ProcessInfo.processInfo.environment
            for key in environment.keys where key.hasPrefix("PYTHON") || key.hasPrefix("BANKING_") { environment.removeValue(forKey: key) }
            environment["PYTHONDONTWRITEBYTECODE"] = "1"; process.environment = environment
            let log = root.appendingPathComponent("initializer.log")
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
            process.standardOutput = output; process.standardError = output
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw WorkspaceError.invalid("synthetic initializer failed") }
            return try ReviewFamilyHost.create(paths: paths, remote: remote)
        }.value
        let store = FinancialStore(); _ = store.expectWorkspace(paths)
        store.workspacePaths = paths; store.workspaceState = try paths.readState(); store.workspaceWritable = true; store.workspaceProcessorEligible = false
        await store.load(try paths.readState().review)
        XCTAssertNil(store.error); XCTAssertNotNil(store.report)
        complete = true; return (root, paths, remote, connection, store)
    }
    private func incomingName(root: URL, remote: URL, name: String) async throws -> WorkspacePaths {
        let client = try WorkspacePaths(workspace: root.appendingPathComponent("client-" + UUID().uuidString.lowercased()))
        _ = try ReviewFamilyClientSession.connect(paths: client, remote: remote, bookmark: nil)
        let handle = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: client))
        _ = try ReviewFamilyClientSession.edit(paths: client, expected: handle) { review, _ in
            let file = review.appendingPathComponent("family-profile.json")
            try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.replacingObjectMember(raw: WorkspaceIO.read(file), key: "household_name", valueRaw: JSONEncoder().encode(name)), to: file)
        }
        try await ReviewFamilyClientSession.transfer(paths: client)
        return client
    }
    func testFamilyHostAutomaticSyncResumesOnceAndPublishesIncomingWithoutManualAction() async throws {
        let (root, paths, remote, connection, store) = try await familyFixture()
        defer { store.familyHostSyncController?.stop(); store.workspaceRuntimeTask?.cancel(); try? FileManager.default.removeItem(at: root) }
        let client = try await incomingName(root: root, remote: remote, name: "Synthetic automatic household")
        store.editorPauseReason = "synthetic setup"
        await store.resumeDisplayedWorkspace(try paths.readState().review, evidence: BrowserStore())
        let controller = try XCTUnwrap(store.familyHostSyncController); controller.stop()
        let activated = expectation(description: "background loop applies actual synchronization")
        controller.refreshBarrier = { phase in if phase == .activated { activated.fulfill() } }
        store.editorPauseReason = nil
        await store.resumeDisplayedWorkspace(try paths.readState().review, evidence: BrowserStore())
        let polling = controller.pollingGeneration
        await store.resumeDisplayedWorkspace(try paths.readState().review, evidence: BrowserStore())
        XCTAssertTrue(store.familyHostSyncController === controller); XCTAssertEqual(controller.pollingGeneration, polling)
        await fulfillment(of: [activated], timeout: 15)
        controller.stop(); controller.refreshBarrier = nil
        let publications = await controller.driver.publicationCount
        await controller.refresh()
        let afterIdlePoll = await controller.driver.publicationCount
        XCTAssertEqual(publications, 1); XCTAssertEqual(afterIdlePoll, publications, "idle polls must not rehash/rebuild the full published household")
        let refreshed = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: client))
        XCTAssertEqual(refreshed.settings.householdName, "Synthetic automatic household")
        XCTAssertEqual(refreshed.selection, connection.selection)
        XCTAssertEqual(store.workspaceState?.pointer, try paths.readPointer())
        XCTAssertNil(store.familyClientSyncController)
        XCTAssertTrue(store.syncStatus.contains("家庭同步已核对"))
    }
    func testFamilyHostAutomaticSyncWaitsForDraftAndKeepsOfflineProviderUnchanged() async throws {
        let (root, paths, remote, _, store) = try await familyFixture()
        defer { store.familyHostSyncController?.stop(); store.workspaceRuntimeTask?.cancel(); try? FileManager.default.removeItem(at: root) }
        _ = try await incomingName(root: root, remote: remote, name: "Queued behind draft")
        let before = try WorkspaceIO.read(remote.appendingPathComponent("current.json")), pointer = try paths.readPointer()
        store.report?.fire_parameters.currentFireAssets = 42
        XCTAssertTrue(store.hasUnsavedParameters)
        await store.resumeDisplayedWorkspace(try paths.readState().review, evidence: BrowserStore())
        let controller = try XCTUnwrap(store.familyHostSyncController); controller.stop()
        await controller.refresh()
        XCTAssertEqual(try WorkspaceIO.read(remote.appendingPathComponent("current.json")), before)
        XCTAssertEqual(try paths.readPointer(), pointer)
        XCTAssertEqual(store.report?.fire_parameters.currentFireAssets, 42)
        store.report?.fire_parameters = try JSONDecoder().decode(FireParameters.self, from: XCTUnwrap(store.parameterDocument))
        XCTAssertFalse(store.hasUnsavedParameters)
        await controller.refresh(); controller.stop()
        _ = try await incomingName(root: root, remote: remote, name: "Concurrent choice one")
        _ = try await incomingName(root: root, remote: remote, name: "Concurrent choice two")
        let conflictPointer = try paths.readPointer()
        await controller.refresh()
        XCTAssertTrue(store.syncStatus.contains("等待家庭同步"))
        XCTAssertEqual(try paths.readPointer(), conflictPointer)
        await controller.refresh()
        XCTAssertTrue(store.syncStatus.contains("等待家庭同步"), "a failed incoming union must remain dirty on the next poll")
        XCTAssertEqual(try paths.readPointer(), conflictPointer)
        let published = try WorkspaceIO.read(remote.appendingPathComponent("current.json"))
        let offline = root.appendingPathComponent("offline-provider")
        try FileManager.default.moveItem(at: remote, to: offline)
        await controller.refresh()
        XCTAssertTrue(store.syncStatus.contains("等待家庭同步"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path))
        XCTAssertEqual(try WorkspaceIO.read(offline.appendingPathComponent("current.json")), published)
        XCTAssertEqual(try paths.readPointer(), conflictPointer)
        XCTAssertNil(store.editorPauseReason)
    }
    func testFamilyHostAutomaticSyncLateResultCannotReplaceNewPendingFamily() async throws {
        let (root, paths, remote, connection, store) = try await familyFixture()
        let controller = try MacFamilyHostSyncController(paths: paths, connection: connection, store: store, evidence: nil, selectionGeneration: store.workspaceSelectionGeneration)
        store.familyHostSyncController = controller
        defer { controller.stop(); store.workspaceRuntimeTask?.cancel(); try? FileManager.default.removeItem(at: root) }
        _ = try await incomingName(root: root, remote: remote, name: "Committed only in old household")
        XCTAssertTrue(controller.isCurrent(store)); XCTAssertTrue(store.workspaceWritable)
        XCTAssertFalse(store.loading); XCTAssertFalse(store.hasUnsavedParameters)
        XCTAssertNil(store.editorPauseReason); XCTAssertTrue(store.completion.drafts.isEmpty)
        let synchronized = expectation(description: "old core committed before UI activation")
        var continuation: CheckedContinuation<Void, Never>?
        controller.refreshBarrier = { phase in
            if phase == .synchronized { await withCheckedContinuation { continuation = $0; synchronized.fulfill() } }
        }
        let refresh = Task { await controller.refresh() }
        let wait = await XCTWaiter.fulfillment(of: [synchronized], timeout: 15)
        guard wait == .completed else {
            continuation?.resume(); await refresh.value
            return XCTFail("Host synchronization did not reach activation: " + store.syncStatus)
        }
        let pending = try WorkspacePaths(workspace: root.appendingPathComponent("new-pending-family"))
        let pendingRemote = root.appendingPathComponent("offline-other-family")
        let pendingSelection = try ReviewFamilyBindingSelection(workspaceID: UUID().uuidString.lowercased(), bindingID: UUID().uuidString.lowercased(), hostID: UUID().uuidString.lowercased())
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pendingSelection.document), to: pendingRemote.appendingPathComponent("family.json"))
        _ = try ReviewFamilyClientSession.connect(paths: pending, remote: pendingRemote, bookmark: nil)
        try FileManager.default.removeItem(at: pendingRemote)
        let generation = try store.selectPendingWorkspace(paths: pending, connectionSaved: {})
        store.syncStatus = "new pending family"; store.error = "new family status"
        continuation?.resume(); continuation = nil; await refresh.value
        XCTAssertNil(store.familyHostSyncController); XCTAssertNil(store.root); XCTAssertNil(store.report)
        XCTAssertTrue(store.isWorkspaceSelectionCurrent(paths: pending, generation: generation))
        XCTAssertEqual(store.syncStatus, "new pending family"); XCTAssertEqual(store.error, "new family status")
        let retained = try HouseholdSettingsState.read(paths: paths, state: paths.readState(), currencyCodes: ["CNY"], referencedMemberIDs: [], referencedAccountIDs: [])
        XCTAssertEqual(retained.settings.householdName, "Committed only in old household")
        await controller.refresh()
        XCTAssertEqual(store.syncStatus, "new pending family")
    }
    func testConnectAndPendingReauthorizationCommitSameMockSelectionBeforeTransfer() async throws {
        let root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("pending-store-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try AppStorageLocations(applicationSupport: root.appendingPathComponent("support"),
            caches: root.appendingPathComponent("cache"), temporary: root.appendingPathComponent("temp"))
        let paths = try WorkspacePaths(workspace: storage.newWorkspaceURL())
        let selection = try ReviewFamilyBindingSelection(workspaceID: UUID().uuidString.lowercased(),
            bindingID: UUID().uuidString.lowercased(), hostID: UUID().uuidString.lowercased())
        let remote = root.appendingPathComponent("provider")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try WorkspaceIO.canonical(selection.document).write(to: remote.appendingPathComponent("family.json"))
        let first = FinancialStore()
        defer { first.familyClientSyncController?.stop() }
        var commits = 0
        try await first.connectWorkspaceClient(paths: paths, remote: remote, evidence: nil) {
            XCTAssertNotNil(try ReviewFamilyClientSession.readConnection(paths: paths))
            XCTAssertNil(first.familyClientSyncController, "selection must precede provider transfer/controller activation")
            try AppStorageIndex(locations: storage).select(containerID: paths.workspace.lastPathComponent, shape: .snapshotClient)
            commits += 1
        }
        await first.familyClientSyncController?.stopAndWait()
        XCTAssertEqual(commits, 1)
        XCTAssertNil(first.root)
        XCTAssertFalse(first.editingAvailable)
        XCTAssertFalse(first.processorAvailable)
        XCTAssertNil(first.clientWorkspacePaths, "no first checkpoint has been supplied")
        let saved = try XCTUnwrap(AppStorageIndex(locations: storage).selected())
        XCTAssertEqual(saved.url.path, paths.workspace.path)
        let retained = paths.device.appendingPathComponent("retained.mock")
        try Data("retained-offline-bytes".utf8).write(to: retained)
        let reauthorized = root.appendingPathComponent("provider-new-location")
        try FileManager.default.moveItem(at: remote, to: reauthorized)
        let reopened = FinancialStore()
        defer { reopened.familyClientSyncController?.stop() }
        try await reopened.reconnectWorkspaceSync(paths: WorkspacePaths(workspace: saved.url), remote: reauthorized, evidence: nil) {
            XCTAssertNil(reopened.familyClientSyncController)
            try AppStorageIndex(locations: storage).select(containerID: saved.entry.containerID, shape: .snapshotClient)
            commits += 1
        }
        await reopened.familyClientSyncController?.stopAndWait()
        XCTAssertEqual(commits, 2)
        XCTAssertNil(reopened.root)
        XCTAssertFalse(reopened.editingAvailable)
        XCTAssertFalse(reopened.processorAvailable)
        XCTAssertEqual(try AppStorageIndex(locations: storage).selected()?.entry.containerID, saved.entry.containerID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.workspaces.path), [saved.entry.containerID])
        XCTAssertEqual(try Data(contentsOf: retained), Data("retained-offline-bytes".utf8))
        XCTAssertEqual(try ReviewFamilyClientSession.readConnection(paths: paths)?.selection, selection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.device.appendingPathComponent("host-authorization.json").path))
    }
}
#endif
