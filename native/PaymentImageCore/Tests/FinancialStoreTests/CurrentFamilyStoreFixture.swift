#if os(macOS)
import Foundation
import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

/// Actual current host and two client stores, using only synthetic business data.
@MainActor struct CurrentFamilyStoreFixture {
    let root: URL, host: WorkspacePaths, a: WorkspacePaths, b: WorkspacePaths
    let first: FinancialStore, second: FinancialStore

    static func make(review: URL) async throws -> Self {
        let host = try WorkspaceStoreTests().emptyWorkspace()
        let root = host.workspace.deletingLastPathComponent().appendingPathComponent("current-business-sync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: host.workspace) } }
        do {
        let token = try WorkspaceCoordinator(paths: host).acquireWriteToken()
        let tx = try WorkspaceCoordinator(paths: host).begin(token: token, expectedPointer: host.readPointer())
        var financial = try WorkspaceIO.object(WorkspaceIO.read(review.appendingPathComponent("financial-review.json")))
        var evidence = try WorkspaceIO.object(StoreFixtures.data("payment-evidence.json"))
        let cutoff = financial["cutoff"] as? String
        let coverage: [String: Any] = ["mode": cutoff == nil ? "empty" : "explicit",
            "from": cutoff.map { String($0.prefix(4)) + "-01-01" } as Any? ?? NSNull(), "to": cutoff as Any? ?? NSNull(),
            "observed_from": NSNull(), "observed_to": NSNull(), "pending_from": NSNull(), "pending_to": NSNull(),
            "revision": 0, "basis": ["kind": cutoff == nil ? "no-reliable-dates" : "user-confirmed", "source_ids": []]]
        financial["source_dataset_id"] = evidence["dataset_id"]; financial["coverage"] = coverage
        evidence["coverage"] = coverage; evidence["backfill_cutoff_date"] = cutoff as Any? ?? NSNull()
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(financial), to: tx.file("review/financial-review.json", token: token))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(evidence), to: tx.file("review/payment-evidence.json", token: token))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(coverage), to: tx.file("review/coverage.json", token: token))
        try WorkspaceIO.atomicWrite(StoreFixtures.data("preview.png"), to: tx.file("review/preview.png", token: token))
        for name in ["review-overrides.json", "category-catalog.json", "completion-workflow.json", "fire-parameters-user.json"] {
            let file = review.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try WorkspaceIO.atomicWrite(WorkspaceIO.read(file), to: tx.file("review/" + name, token: token)) }
        }
        _ = try NativeWorkspaceEffects.record(transaction: tx, token: token)
        _ = try tx.prepare(token: token, validator: WorkspaceBusinessValidator.validate)
        _ = try tx.commit(token: token)
        withExtendedLifetime(token) {}
        }
        // Release the write lease before the explicit family action.
        return try await open(root: root, host: host, completed: &complete)
    }
    private static func open(root: URL, host: WorkspacePaths, completed: inout Bool) async throws -> Self {
        let remote = root.appendingPathComponent("provider")
        _ = try ReviewFamilyHost.create(paths: host, remote: remote)
        let a = try WorkspacePaths(workspace: root.appendingPathComponent("a")), b = try WorkspacePaths(workspace: root.appendingPathComponent("b"))
        _ = try ReviewFamilyClientSession.connect(paths: a, remote: remote, bookmark: nil)
        _ = try ReviewFamilyClientSession.connect(paths: b, remote: remote, bookmark: nil)
        let first = FinancialStore(), second = FinancialStore()
        _ = first.expectWorkspace(a); _ = second.expectWorkspace(b)
        try await first.loadFamilyClient(paths: a, handle: XCTUnwrap(ReviewFamilyClientSession.refresh(paths: a)))
        try await second.loadFamilyClient(paths: b, handle: XCTUnwrap(ReviewFamilyClientSession.refresh(paths: b)))
        completed = true
        return .init(root: root, host: host, a: a, b: b, first: first, second: second)
    }
    func sync(from paths: WorkspacePaths) async throws {
        try await ReviewFamilyClientSession.transfer(paths: paths)
        _ = try await ReviewFamilyHost.synchronize(paths: host)
        try await refresh()
    }
    func refresh() async throws {
        try await first.loadFamilyClient(paths: a, handle: XCTUnwrap(ReviewFamilyClientSession.refresh(paths: a)))
        try await second.loadFamilyClient(paths: b, handle: XCTUnwrap(ReviewFamilyClientSession.refresh(paths: b)))
    }
    func edit(_ paths: WorkspacePaths, body: (URL) throws -> Void) async throws {
        let handle = try XCTUnwrap(ReviewFamilyClientSession.read(paths: paths))
        let (_, updated) = try ReviewFamilyClientSession.edit(paths: paths, expected: handle) { review, _ in try body(review) }
        if paths == a { try await first.loadFamilyClient(paths: a, handle: updated) }
        else { try await second.loadFamilyClient(paths: b, handle: updated) }
    }
    func cleanup() { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: host.workspace) }
}
#endif
