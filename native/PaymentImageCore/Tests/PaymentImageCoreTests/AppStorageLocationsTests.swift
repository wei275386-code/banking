import XCTest
import Foundation
@testable import PaymentImageCore

final class AppStorageLocationsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("storage-mock-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func locations(_ domain: AppStorageLocations.Domain = .production, base: URL? = nil) throws -> AppStorageLocations {
        let base = base ?? root!
        return try AppStorageLocations(applicationSupport: base.appendingPathComponent("support"),
                                       caches: base.appendingPathComponent("cache"), temporary: base.appendingPathComponent("temp"), domain: domain)
    }
    private func container(_ storage: AppStorageLocations) throws -> (String, URL) {
        let id = UUID().uuidString.lowercased(), url = try storage.workspaceURL(containerID: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (id, url)
    }
    func testResolutionNeverCreatesDataAndTwoRootsStayIndependent() throws {
        let a = try locations(), b = try locations(base: root.appendingPathComponent("another-user"))
        XCTAssertNotEqual(a.workspaces, b.workspaces)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.support.path))
        XCTAssertNil(try AppStorageIndex(locations: a).selected())
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.support.path))
        let (id, _) = try container(a)
        try AppStorageIndex(locations: a).select(containerID: id, shape: .workspace)
        XCTAssertNil(try AppStorageIndex(locations: b).selected())
    }
    func testQAStorageCachesPreferencesAndRegistryCannotOverlapProduction() throws {
        let production = try locations(), qa = try locations(.qa("mock-a")), other = try locations(.qa("mock-b"))
        for (a, b) in [(production.support, qa.support), (production.caches, qa.caches),
                       (production.temporary, qa.temporary), (qa.support, other.support)] {
            XCTAssertNotEqual(a, b)
            XCTAssertFalse(a.path.hasPrefix(b.path + "/"))
            XCTAssertFalse(b.path.hasPrefix(a.path + "/"))
        }
        XCTAssertNil(production.preferencesSuiteName)
        XCTAssertNotEqual(qa.preferencesSuiteName, other.preferencesSuiteName)
        XCTAssertThrowsError(try locations(.qa("../production")))
    }
    func testQABundleDomainsAreStableAndDistinctWithoutProductionOverrides() throws {
        let a = AppStorageLocations.domain(bundleIdentifier: "example.review.qa-one")
        let b = AppStorageLocations.domain(bundleIdentifier: "example.review.qa-two")
        XCTAssertNotEqual(a, .production)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, AppStorageLocations.domain(bundleIdentifier: "example.review.qa-one"))
        XCTAssertEqual(AppStorageLocations.domain(bundleIdentifier: "example.review"), .production)
        XCTAssertEqual(AppStorageLocations.domain(bundleIdentifier: nil), .production)
    }
    func testSelectedContainerAndShapeSurviveRestartAndRootMove() throws {
        let initial = try locations(), (id, _) = try container(initial)
        try AppStorageIndex(locations: initial).select(containerID: id, shape: .snapshotClient)
        XCTAssertEqual(try AppStorageIndex(locations: initial).selected()?.entry.shape, .snapshotClient)
        let newBase = root.appendingPathComponent("moved-user")
        try FileManager.default.createDirectory(at: newBase, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: initial.support.deletingLastPathComponent(), to: newBase.appendingPathComponent("support"))
        let moved = try locations(base: newBase)
        XCTAssertEqual(try AppStorageIndex(locations: moved).selected()?.url, try moved.workspaceURL(containerID: id))
        XCTAssertEqual(try AppStorageIndex(locations: moved).selected()?.entry.containerID, id)
    }
    func testMissingSelectedContainerFailsWithoutCreatingReplacement() throws {
        let storage = try locations(), (id, url) = try container(storage), index = AppStorageIndex(locations: storage)
        try index.select(containerID: id, shape: .workspace)
        try FileManager.default.removeItem(at: url)
        let before = try Data(contentsOf: storage.installationIndex)
        XCTAssertThrowsError(try index.selected())
        XCTAssertEqual(try Data(contentsOf: storage.installationIndex), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testCorruptOrFutureIndexDoesNotBecomeEmptyHousehold() throws {
        let storage = try locations()
        try FileManager.default.createDirectory(at: storage.support, withIntermediateDirectories: true)
        for raw in ["broken", "{\"selected_container_id\":null,\"entries\":[]}",
                    "{\"selected_container_id\":null,\"entries\":[],\"unexpected\":true}"] {
            try Data(raw.utf8).write(to: storage.installationIndex)
            XCTAssertThrowsError(try AppStorageIndex(locations: storage).selected())
            XCTAssertEqual(try String(contentsOf: storage.installationIndex, encoding: .utf8), raw)
        }
    }
    func testIndexCannotChangeExistingContainerShapeOrAcceptTraversal() throws {
        let storage = try locations(), (id, _) = try container(storage), index = AppStorageIndex(locations: storage)
        try index.select(containerID: id, shape: .workspace)
        XCTAssertThrowsError(try index.select(containerID: id, shape: .snapshotClient))
        XCTAssertThrowsError(try storage.workspaceURL(containerID: "../outside"))
        XCTAssertThrowsError(try storage.cacheURL(component: "../outside"))
        try index.clearSelection()
        XCTAssertNil(try index.selected())
    }
    func testLinkedStorageAndLinkedContainerRejected() throws {
        let storage = try locations(), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("support"), withDestinationURL: outside)
        XCTAssertThrowsError(try locations())
        try FileManager.default.removeItem(at: root.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: storage.workspaces, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        try FileManager.default.createSymbolicLink(at: storage.workspaces.appendingPathComponent(id), withDestinationURL: outside)
        XCTAssertThrowsError(try storage.workspaceURL(containerID: id))
    }
    func testSnapshotIndexDoesNotWriteInsideClientOrGrantHost() throws {
        let storage = try locations(), (id, url) = try container(storage)
        let device = url.appendingPathComponent("device")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let retained = device.appendingPathComponent("client-workspace-v3.json")
        try Data("retained-client-identity".utf8).write(to: retained)
        try AppStorageIndex(locations: storage).select(containerID: id, shape: .snapshotClient)
        XCTAssertEqual(try Data(contentsOf: retained), Data("retained-client-identity".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("workspace.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: device.path), [retained.lastPathComponent])
    }
    func testFreshMobileAndImportedIdentityUseSupportWithNoWrites() throws {
        let storage = try locations()
        let fresh = try MobileStoragePlan.resolve(locations: storage)
        XCTAssertEqual(fresh.root.lastPathComponent, "FamilyReview")
        let id = String(repeating: "a", count: 64)
        let imported = try MobileStoragePlan.resolve(locations: storage, importedWorkspace: id)
        XCTAssertEqual(imported.root, try MobileStoragePlan.importedReviewURL(locations: storage, identity: id))
        XCTAssertThrowsError(try MobileStoragePlan.resolve(locations: storage, importedWorkspace: "bad"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.support.path))
        XCTAssertThrowsError(try MobileStoragePlan.resolve(locations: storage, qaName: "FamilyReviewQA"))
    }
    func testToolDiscoveryAcceptsInjectedPrefixesAndRejectsRelativeSearchEntries() throws {
        let toolRoot = root.appendingPathComponent("tool-prefix")
        try FileManager.default.createDirectory(at: toolRoot, withIntermediateDirectories: true)
        let tool = toolRoot.appendingPathComponent("mock-tool")
        try Data("mock-executable".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        XCTAssertEqual(try SystemToolLocations.executable("mock-tool", searchPath: ".:" + toolRoot.path), tool)
        XCTAssertThrowsError(try SystemToolLocations.executable("../mock-tool", searchPath: toolRoot.path))
        XCTAssertThrowsError(try SystemToolLocations.executable("mock-tool", searchPath: "."))
        XCTAssertFalse(try SystemToolLocations.searchPath().isEmpty)
    }
}
