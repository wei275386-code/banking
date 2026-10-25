import XCTest
import Foundation
@testable import PaymentImageCore

final class MobileStorageSelectionTests: XCTestCase {
    private var root: URL!
    private var suites = [String]()
    override func setUpWithError() throws {
        root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("mobile-selection-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
        try FileManager.default.removeItem(at: root)
    }
    private func qaStorage() throws -> AppStorageLocations {
        let domain = AppStorageLocations.domain(bundleIdentifier: "example.review." + UUID().uuidString.lowercased() + ".ReleaseQA")
        let storage = try AppStorageLocations(applicationSupport: root.appendingPathComponent("support"),
            caches: root.appendingPathComponent("cache"), temporary: root.appendingPathComponent("temp"), domain: domain)
        suites.append(try XCTUnwrap(storage.preferencesSuiteName))
        return storage
    }
    func testReleaseQAImportedSelectionSurvivesNormalRestartWithoutLaunchFlags() throws {
        let storage = try qaStorage(), id = String(repeating: "b", count: 64)
        let imported = try MobileStoragePlan.importedReviewURL(locations: storage, identity: id)
        let queue = imported.appendingPathComponent("Client/device/retained-outbox")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        let original = queue.appendingPathComponent("pending.mock")
        try Data("same-offline-obligation".utf8).write(to: original)
        try storage.preferences().set(id, forKey: "review.imported.workspace")
        let restarted = try MobileStoragePlan.resolve(locations: storage,
            importedWorkspace: storage.preferences().string(forKey: "review.imported.workspace"))
        XCTAssertEqual(restarted.root.path, imported.path)
        XCTAssertEqual(restarted.root.appendingPathComponent("Client/device/retained-outbox").path, queue.path)
        XCTAssertEqual(try Data(contentsOf: original), Data("same-offline-obligation".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.support.appendingPathComponent("Mobile/FamilyReviewQA").path))
    }
    func testExplicitFixtureModeOwnsItsRootAndDoesNotAdoptImportedSelection() throws {
        let storage = try qaStorage()
        let plan = try MobileStoragePlan.resolve(locations: storage,
            importedWorkspace: "irrelevant-normal-selection", qaName: "FamilyReviewFactsQA")
        XCTAssertEqual(plan.root.lastPathComponent, "FamilyReviewFactsQA")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.root.path))
    }
    func testIndependentQAPreferencesActuallyPersistWithoutCrossDomainReads() throws {
        let a = try qaStorage(), b = try qaStorage()
        try a.preferences().set("mock-a", forKey: "review.imported.workspace")
        try b.preferences().set("mock-b", forKey: "review.imported.workspace")
        XCTAssertNotEqual(a.preferencesSuiteName, b.preferencesSuiteName)
        XCTAssertEqual(try a.preferences().string(forKey: "review.imported.workspace"), "mock-a")
        XCTAssertEqual(try b.preferences().string(forKey: "review.imported.workspace"), "mock-b")
    }
    func testSavedImportedDirectoryMovedOfflinePreservesSelectionAndOriginalsUntilRestored() throws {
        let storage = try qaStorage(), id = String(repeating: "e", count: 64)
        let preferences = try storage.preferences()
        preferences.set(id, forKey: "review.imported.workspace")
        let imported = try MobileStoragePlan.importedReviewURL(locations: storage, identity: id)
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        for name in ["financial-review.json", "payment-evidence.json", "retained.mock"] {
            try Data(("original-" + name).utf8).write(to: imported.appendingPathComponent(name))
        }
        try MobileStoragePlan.requireSelectedImportedStorage(locations: storage, identity: id)
        let retained = root.appendingPathComponent("offline-originals")
        try FileManager.default.moveItem(at: imported, to: retained)
        for _ in 0..<2 {
            XCTAssertThrowsError(try MobileStoragePlan.requireSelectedImportedStorage(locations: storage, identity: id))
            XCTAssertEqual(preferences.string(forKey: "review.imported.workspace"), id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: imported.path))
            XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("retained.mock")), Data("original-retained.mock".utf8))
        }
        try FileManager.default.moveItem(at: retained, to: imported)
        try MobileStoragePlan.requireSelectedImportedStorage(locations: storage, identity: id)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: imported.path)),
                       Set(["financial-review.json", "payment-evidence.json", "retained.mock"]))
    }
    func testSavedImportedIDWithoutCompleteTargetCannotBecomeFirstConnection() throws {
        let storage = try qaStorage(), id = String(repeating: "f", count: 64)
        let preferences = try storage.preferences()
        preferences.set(id, forKey: "review.imported.workspace")
        let imported = try MobileStoragePlan.importedReviewURL(locations: storage, identity: id)
        XCTAssertThrowsError(try MobileStoragePlan.requireSelectedImportedStorage(locations: storage, identity: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.path))
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        XCTAssertThrowsError(try MobileStoragePlan.requireSelectedImportedStorage(locations: storage, identity: id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imported.path), [])
        let original = imported.appendingPathComponent("financial-review.json")
        try Data("retained-partial-report".utf8).write(to: original)
        XCTAssertThrowsError(try MobileStoragePlan.requireSelectedImportedStorage(locations: storage, identity: id))
        XCTAssertEqual(try Data(contentsOf: original), Data("retained-partial-report".utf8))
        XCTAssertEqual(preferences.string(forKey: "review.imported.workspace"), id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.appendingPathComponent("Client").path))
    }
    func testSavedImportedPendingClientChecksOnlyLocalDescriptorAndPreservesIdentity() throws {
        let storage = try qaStorage(), id = String(repeating: "a", count: 64)
        let imported = try MobileStoragePlan.importedReviewURL(locations: storage, identity: id)
        let paths = try WorkspacePaths(workspace: imported.appendingPathComponent("Client"))
        let provider = root.appendingPathComponent("provider")
        let selection = try ReviewFamilyBindingSelection(workspaceID: UUID().uuidString.lowercased(), bindingID: UUID().uuidString.lowercased(), hostID: UUID().uuidString.lowercased())
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(selection.document), to: provider.appendingPathComponent("family.json"))
        _ = try ReviewFamilyClientSession.connect(paths: paths, remote: provider, bookmark: nil)
        try FileManager.default.removeItem(at: provider)
        let descriptor = paths.device.appendingPathComponent("family-connection.json")
        let before = try Data(contentsOf: descriptor)
        try MobileStoragePlan.requireSelectedImportedStorage(locations: storage, identity: id)
        XCTAssertEqual(try Data(contentsOf: descriptor), before)
        XCTAssertEqual(try ReviewFamilyClientSession.readConnection(paths: paths)?.selection, selection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: provider.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.appendingPathComponent("financial-review.json").path))
        var invalid = try WorkspaceIO.object(before); invalid["role"] = "host"
        let invalidBytes = try WorkspaceIO.canonical(invalid)
        try invalidBytes.write(to: descriptor)
        XCTAssertThrowsError(try MobileStoragePlan.requireSelectedImportedStorage(locations: storage, identity: id))
        XCTAssertEqual(try Data(contentsOf: descriptor), invalidBytes)
    }
}
