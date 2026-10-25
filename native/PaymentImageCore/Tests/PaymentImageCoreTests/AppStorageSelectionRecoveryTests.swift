#if os(macOS)
import XCTest
import Foundation
@testable import PaymentImageCore

final class AppStorageSelectionRecoveryTests: XCTestCase {
    private var root: URL!
    private var storage: AppStorageLocations!
    override func setUpWithError() throws {
        root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("selection-recovery-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storage = try AppStorageLocations(applicationSupport: root.appendingPathComponent("support"),
            caches: root.appendingPathComponent("cache"), temporary: root.appendingPathComponent("temp"),
            domain: .qa(UUID().uuidString.lowercased()))
    }
    override func tearDownWithError() throws {
        if let suite = storage.preferencesSuiteName { try storage.preferences().removePersistentDomain(forName: suite) }
        try FileManager.default.removeItem(at: root)
    }
    private func container() throws -> (String, URL) {
        let id = UUID().uuidString.lowercased(), url = try storage.workspaceURL(containerID: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (id, url)
    }
    private func external() throws -> (URL, Data) {
        let url = root.appendingPathComponent("external-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
    }
    func testExplicitRepairPreservesCorruptionAndRestartsAtChosenContainer() throws {
        let (id, url) = try container(), index = AppStorageIndex(locations: storage)
        let marker = url.appendingPathComponent("mock-original")
        try Data("unchanged-original".utf8).write(to: marker)
        let damaged = Data("{known-index-corruption".utf8)
        try damaged.write(to: storage.installationIndex)
        XCTAssertThrowsError(try index.selected())
        XCTAssertThrowsError(try index.select(containerID: id, shape: .workspace))
        try index.select(containerID: id, shape: .workspace, repairCorrupt: true)
        XCTAssertEqual(try AppStorageIndex(locations: storage).selected()?.url.path, url.path)
        let retained = storage.support.appendingPathComponent("index-recovery/" + WorkspaceIO.digest(damaged) + ".json")
        XCTAssertEqual(try Data(contentsOf: retained), damaged)
        XCTAssertEqual(try Data(contentsOf: marker), Data("unchanged-original".utf8))
        XCTAssertEqual(try index.selected()?.revision, 1)
    }
    func testExternalBookmarkAndSelectionAreOneRestartRecord() throws {
        let (id, _) = try container(), (url, bookmark) = try external()
        let index = AppStorageIndex(locations: storage)
        try index.select(containerID: id, shape: .workspace)
        try index.selectExternal(url: url, bookmark: bookmark, shape: .snapshotClient)
        let selected = try XCTUnwrap(AppStorageIndex(locations: storage).selected())
        XCTAssertEqual(selected.url.path, url.path)
        XCTAssertEqual(selected.entry.bookmark, bookmark)
        XCTAssertEqual(selected.entry.externalPath, url.path)
        XCTAssertEqual(selected.revision, 2)
        // A delayed legacy preference write cannot become another authority.
        try storage.preferences().set(Data("stale-legacy-bookmark".utf8), forKey: "FamilyReview.workspaceBookmark.v1")
        XCTAssertEqual(try index.selected()?.url.path, url.path)
        XCTAssertTrue(index.hasRecord)
        try index.clearSelection()
        XCTAssertNil(try index.selected())
        XCTAssertTrue(index.hasRecord)
    }
    func testControlledSelectionInterleavingSerializesLocatorAndBookmark() throws {
        let (id, _) = try container(), (url, bookmark) = try external()
        let locked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let first = AppStorageIndex(locations: storage, beforeWrite: {
            locked.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw WorkspaceError.io("test barrier timed out") }
        })
        let second = AppStorageIndex(locations: storage)
        DispatchQueue.global().async {
            defer { finished.signal() }
            do { try first.select(containerID: id, shape: .workspace) }
            catch { XCTFail("first selection failed: " + error.localizedDescription) }
        }
        guard locked.wait(timeout: .now() + 5) == .success else { release.signal(); return XCTFail("selection did not reach barrier") }
        XCTAssertThrowsError(try second.selectExternal(url: url, bookmark: bookmark, shape: .snapshotClient)) { error in
            guard case WorkspaceError.busy = error else { return XCTFail("selection lock not respected") }
        }
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        try second.selectExternal(url: url, bookmark: bookmark, shape: .snapshotClient)
        let selected = try XCTUnwrap(second.selected())
        XCTAssertEqual(selected.url.path, url.path)
        XCTAssertEqual(selected.entry.bookmark, bookmark)
        XCTAssertEqual(selected.revision, 2)
    }
    func testMissingSelectionRevisionFailsWithoutRewritingIndex() throws {
        let (id, _) = try container()
        let raw = try WorkspaceIO.canonical(["selected_container_id": id, "entries": [["container_id": id, "shape": "workspace"]]])
        try raw.write(to: storage.installationIndex)
        XCTAssertThrowsError(try AppStorageIndex(locations: storage).selected())
        XCTAssertEqual(try Data(contentsOf: storage.installationIndex), raw)
    }
    func testFailureBeforeAtomicWriteKeepsCompletePreviousSelection() throws {
        let (id, _) = try container(), (url, bookmark) = try external()
        let index = AppStorageIndex(locations: storage)
        try index.select(containerID: id, shape: .workspace)
        let before = try Data(contentsOf: storage.installationIndex)
        let failing = AppStorageIndex(locations: storage, beforeWrite: { throw WorkspaceError.io("injected failure") })
        XCTAssertThrowsError(try failing.selectExternal(url: url, bookmark: bookmark, shape: .snapshotClient))
        XCTAssertEqual(try Data(contentsOf: storage.installationIndex), before)
        XCTAssertEqual(try index.selected()?.entry.containerID, id)
    }
}
#endif
