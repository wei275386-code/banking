import Foundation
import XCTest
@testable import PaymentImageCore

@MainActor final class CategorySyncTests: XCTestCase {
    private struct Fixture {
        let host: CurrentWorkspaceFixtures.Fixture, remote: URL, a: WorkspacePaths, b: WorkspacePaths, base: CategoryCatalog
        func cleanup() { host.remove(); for url in [remote, a.workspace, b.workspace] { try? FileManager.default.removeItem(at: url) } }
    }
    private func fixture() throws -> Fixture {
        let owner = ReviewFamilyHostTests(), host = try owner.fixture(), remote = owner.remote(host)
        let base = CategoryCatalog(taxonomy: [.init(primary: "日常", secondaries: ["餐饮"])])
        try HouseholdWorkBackupTests().edit(host.paths) { tx, token in
            try WorkspaceIO.atomicWrite(JSONEncoder().encode(base), to: tx.file("review/category-catalog.json", token: token))
        }
        _ = try ReviewFamilyHost.create(paths: host.paths, remote: remote)
        let helper = ReviewFamilyClientSessionTests(), a = try helper.client(host.paths), b = try helper.client(host.paths)
        _ = try helper.connect(a, remote: remote); _ = try helper.connect(b, remote: remote)
        return .init(host: host, remote: remote, a: a, b: b, base: base)
    }
    private func write(_ catalog: CategoryCatalog, paths: WorkspacePaths) throws {
        let handle = try XCTUnwrap(ReviewFamilyClientSession.read(paths: paths))
        _ = try ReviewFamilyClientSession.edit(paths: paths, expected: handle) { root, _ in
            try WorkspaceIO.atomicWrite(JSONEncoder().encode(catalog), to: root.appendingPathComponent("category-catalog.json"))
        }
    }
    private func read(_ handle: ReviewFamilyClientHandle) throws -> CategoryCatalog {
        try JSONDecoder().decode(CategoryCatalog.self, from: WorkspaceIO.read(handle.review.appendingPathComponent("category-catalog.json")))
    }
    func testConcurrentCatalogHeadsStayAtomicAndExplicitResolutionConverges() async throws {
        let f = try fixture(); defer { f.cleanup() }
        var ca = f.base, cb = f.base; _ = try ca.addPrimary(name: "甲"); _ = try cb.addPrimary(name: "乙")
        try write(ca, paths: f.a); try write(cb, paths: f.b)
        try await ReviewFamilyClientSession.transfer(paths: f.a); try await ReviewFamilyClientSession.transfer(paths: f.b)
        _ = try await ReviewFamilyHost.synchronize(paths: f.host.paths)
        let a = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: f.a))
        XCTAssertTrue([ca, cb].contains(try read(a)))
        let choices = try XCTUnwrap(a.conflicts["catalog/@tree"]); XCTAssertEqual(choices.count, 2)
        for invalid in ["null", "{}"] {
            XCTAssertThrowsError(try ReviewFamilyClientSession.resolveConflicts(paths: f.a, expected: a, choices: ["catalog/@tree": invalid]))
            XCTAssertEqual(try ReviewFamilyClientSession.read(paths: f.a)?.version, a.version)
        }
        let chosen = try XCTUnwrap(choices.first { $0.contains("甲") })
        let resolved = try ReviewFamilyClientSession.resolveConflicts(paths: f.a, expected: a, choices: ["catalog/@tree": chosen])
        XCTAssertTrue(resolved.conflicts.isEmpty)
        try await ReviewFamilyClientSession.transfer(paths: f.a); _ = try await ReviewFamilyHost.synchronize(paths: f.host.paths)
        XCTAssertEqual(try read(XCTUnwrap(ReviewFamilyClientSession.refresh(paths: f.a))), ca)
        XCTAssertEqual(try read(XCTUnwrap(ReviewFamilyClientSession.refresh(paths: f.b))), ca)
    }
    func testPreparedCatalogRefreshCannotReplaceSaveAfterPlanning() async throws {
        let f = try fixture(); defer { f.cleanup() }
        var remote = f.base; _ = try remote.addPrimary(name: "远程")
        try write(remote, paths: f.b); try await ReviewFamilyClientSession.transfer(paths: f.b)
        _ = try await ReviewFamilyHost.synchronize(paths: f.host.paths)
        guard case .ready(let prepared) = try ReviewFamilyClientSession.prepareRefresh(paths: f.a) else { return XCTFail("Expected prepared snapshot") }
        var local = f.base; _ = try local.addPrimary(name: "计划后本地")
        try write(local, paths: f.a)
        XCTAssertThrowsError(try ReviewFamilyClientSession.commitRefresh(paths: f.a, prepared: prepared))
        let saved = try XCTUnwrap(ReviewFamilyClientSession.read(paths: f.a)); XCTAssertEqual(try read(saved), local)
        let retried = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: f.a))
        XCTAssertEqual(retried.conflicts.keys.sorted(), ["catalog/@tree"])
        XCTAssertTrue([local, remote].contains(try read(retried)))
    }
}
