import Foundation
import XCTest
import CSQLite
@testable import PaymentImageCore

/// Synthetic committed business data with no protocol activation or migration.
@MainActor enum CurrentWorkspaceFixtures {
    struct Fixture {
        let paths: WorkspacePaths
        let selection: ReviewFamilyBindingSelection
        func remove() { try? FileManager.default.removeItem(at: paths.workspace) }
    }
    static func make() throws -> Fixture {
        let canonical = try TestPlatform.temporaryDirectory().path
        let paths = try WorkspacePaths(workspace: URL(fileURLWithPath: canonical + "/current-workspace-test-" + UUID().uuidString))
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        let workspace = UUID().uuidString.lowercased(), state = UUID().uuidString.lowercased()
        let root = try paths.stateRoot(state)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["workspace_id": workspace, "created_at": "2026-10-14T00:00:00Z"]), to: paths.metadata)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("banking.sqlite3").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE facts(id TEXT PRIMARY KEY,amount INTEGER); INSERT INTO facts VALUES('record',42);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/current")
        let coverage = try WorkspaceIO.canonical(["mode": "explicit", "from": "2026-01-01", "to": "2026-09-30", "observed_from": NSNull(), "observed_to": NSNull(), "pending_from": NSNull(), "pending_to": NSNull(), "basis": ["kind": "user-confirmed", "source_ids": []], "revision": 0])
        var report = try Data(contentsOf: fixtures.appendingPathComponent("financial-review.json"))
        report = try ReleaseCanonicalJSON.replacingObjectMember(raw: report, key: "source_dataset_id", valueRaw: Data("\"synthetic-integration-v1\"".utf8))
        report = try ReleaseCanonicalJSON.replacingObjectMember(raw: report, key: "dataset_id", valueRaw: Data("\"independent-financial-projection\"".utf8))
        report = try ReleaseCanonicalJSON.replacingObjectMember(raw: report, key: "coverage", valueRaw: coverage)
        try WorkspaceIO.atomicWrite(report, to: root.appendingPathComponent("review/financial-review.json"))
        // The baseline contains the complete current parameter document.
        try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.canonicalFragment(raw: report, atObjectKeys: ["fire_parameters"])!, to: root.appendingPathComponent("config/fire-parameters.json"))
        var evidence = try Data(contentsOf: fixtures.appendingPathComponent("payment-evidence.json"))
        evidence = try ReleaseCanonicalJSON.replacingObjectMember(raw: evidence, key: "coverage", valueRaw: coverage)
        try WorkspaceIO.atomicWrite(evidence, to: root.appendingPathComponent("review/payment-evidence.json"))
        try WorkspaceIO.atomicWrite(Data(contentsOf: fixtures.appendingPathComponent("preview.png")), to: root.appendingPathComponent("review/preview.png"))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["state_id": state, "results": []]), to: root.appendingPathComponent("operation-results.json"))
        try WorkspaceIO.atomicWrite(coverage, to: root.appendingPathComponent("review/coverage.json"))
        try WorkspaceIO.atomicWrite(Data("{\"sources\":[]}".utf8), to: root.appendingPathComponent("config/review-import-sources.json"))
        var files = [String: String]()
        for path in try WorkspaceIO.regularFiles(root) { files[path] = try WorkspaceIO.hash(WorkspaceIO.safeChild(root, path)) }
        let manifest = try WorkspaceIO.canonical(["workspace_id": workspace, "state_id": state, "local_revision": 0, "files": files])
        try WorkspaceIO.atomicWrite(manifest, to: root.appendingPathComponent("state-manifest.json"))
        let pointer = WorkspaceStatePointer(workspaceID: workspace, stateID: state, localRevision: 0, manifestHash: WorkspaceIO.digest(manifest))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pointer.document), to: paths.activeState)
        let device = try ReviewDeviceIdentity.readOrCreate(paths: paths, token: token)
        let selection = try ReviewFamilyBindingSelection(workspaceID: workspace, bindingID: UUID().uuidString.lowercased(), hostID: device)
        return .init(paths: paths, selection: selection)
    }
    nonisolated static func validateBusiness(_ root: URL) throws {
        _ = try JSONDecoder().decode(FinancialReport.self, from: WorkspaceIO.read(root.appendingPathComponent("review/financial-review.json")))
        _ = try WorkspaceIO.object(WorkspaceIO.read(root.appendingPathComponent("review/payment-evidence.json")))
    }
}
