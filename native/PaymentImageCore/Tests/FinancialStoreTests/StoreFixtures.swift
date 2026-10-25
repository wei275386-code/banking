import Foundation
@testable import PaymentImageCore
@testable import EvidenceBrowser

/// Versioned synthetic inputs. Each writer owns a separate temporary workspace.
enum StoreFixtures {
    static var root: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/current") }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(name)) }
    static func report(_ name: String = "financial-review.json") throws -> FinancialReport {
        try JSONDecoder().decode(FinancialReport.self, from: data(name))
    }
    static func directory(files: [String] = ["financial-review.json"]) throws -> URL {
        let folder = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("banking-fixture-v1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for name in files { try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: folder.appendingPathComponent(name)) }
            return folder
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}

extension FinancialStore {
    /// Set storage before load can schedule discovery. Await the initial scan so
    /// its background work does not race the test's CAS writes or cleanup.
    @MainActor func loadFixture(_ folder: URL) async {
        if discoveryDatabaseURL == nil || discoveryDatabaseURL?.lastPathComponent == "test-merchant-discovery.sqlite3" {
            discoveryDatabaseURL = folder.appendingPathComponent("test-merchant-discovery.sqlite3")
        }
        await load(folder)
        #if os(macOS)
        await discoverMerchantTags()
        while discoveryBusy { await Task.yield() }
        #endif
    }
}
