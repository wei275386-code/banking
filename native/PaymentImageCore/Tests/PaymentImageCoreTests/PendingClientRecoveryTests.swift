import XCTest
import Foundation
@testable import PaymentImageCore

final class PendingClientRecoveryTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var storage: AppStorageLocations!
    private var paths: WorkspacePaths!
    private var selection: ReviewFamilyBindingSelection!
    override func setUpWithError() throws {
        root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("pending-client-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storage = try AppStorageLocations(applicationSupport: root.appendingPathComponent("support"),
            caches: root.appendingPathComponent("cache"), temporary: root.appendingPathComponent("temp"))
        paths = try WorkspacePaths(workspace: storage.newWorkspaceURL())
        selection = try ReviewFamilyBindingSelection(workspaceID: UUID().uuidString.lowercased(),
            bindingID: UUID().uuidString.lowercased(), hostID: UUID().uuidString.lowercased())
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func savePending() throws {
        let remote = try provider(selection)
        _ = try ReviewFamilyClientSession.connect(paths: paths, remote: remote, bookmark: Data("invalid-but-retained-old-bookmark".utf8))
        try FileManager.default.removeItem(at: remote)
        try AppStorageIndex(locations: storage).select(containerID: paths.workspace.lastPathComponent, shape: .snapshotClient)
    }
    private func provider(_ selected: ReviewFamilyBindingSelection) throws -> URL {
        let remote = root.appendingPathComponent("reauthorized-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try WorkspaceIO.canonical(selected.document).write(to: remote.appendingPathComponent("family.json"))
        return remote
    }
    func testLocalPendingDescriptorDoesNotNeedProviderOrResolvableBookmark() throws {
        try savePending()
        let file = paths.device.appendingPathComponent("family-connection.json")
        let before = try Data(contentsOf: file)
        let descriptor = try XCTUnwrap(ReviewFamilyClientSession.readConnection(paths: paths))
        XCTAssertEqual(descriptor.selection, selection)
        XCTAssertEqual(descriptor.bookmark, Data("invalid-but-retained-old-bookmark".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.remote.path))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.device.appendingPathComponent("client-active.json").path))
    }
    func testRestartAndReauthorizationReuseTheOriginalContainerAndIdentity() async throws {
        try savePending()
        let oldID = paths.workspace.lastPathComponent
        let selected = try XCTUnwrap(AppStorageIndex(locations: storage).selected())
        let restarted = try WorkspacePaths(workspace: selected.url)
        let remote = try provider(selection)
        let reconnected = try ReviewFamilyClientSession.connect(paths: restarted, remote: remote,
                                                                           bookmark: Data("new-local-permission".utf8))
        XCTAssertEqual(reconnected.selection, selection)
        XCTAssertEqual(reconnected.remote.path, remote.path)
        XCTAssertEqual(try AppStorageIndex(locations: storage).selected()?.entry.containerID, oldID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.workspaces.path), [oldID])
        XCTAssertEqual(try ReviewFamilyClientSession.readConnection(paths: restarted)?.selection, selection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.device.appendingPathComponent("host-authorization.json").path))
    }
    func testWrongFamilyReauthorizationDoesNotChangeLocalDescriptor() async throws {
        try savePending()
        let file = paths.device.appendingPathComponent("family-connection.json"), before = try Data(contentsOf: file)
        let other = try ReviewFamilyBindingSelection(workspaceID: UUID().uuidString.lowercased(),
            bindingID: UUID().uuidString.lowercased(), hostID: UUID().uuidString.lowercased())
        do {
            _ = try ReviewFamilyClientSession.connect(paths: paths, remote: provider(other), bookmark: nil)
            XCTFail("another family accepted")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try AppStorageIndex(locations: storage).selected()?.entry.containerID, paths.workspace.lastPathComponent)
    }
    func testMalformedLocalDescriptorFailsWithoutProviderAccess() throws {
        try savePending()
        let file = paths.device.appendingPathComponent("family-connection.json")
        var doc = try WorkspaceIO.object(Data(contentsOf: file))
        doc["role"] = "unknown-role"
        try WorkspaceIO.canonical(doc).write(to: file)
        XCTAssertThrowsError(try ReviewFamilyClientSession.readConnection(paths: paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("offline-provider").path))
    }
}
