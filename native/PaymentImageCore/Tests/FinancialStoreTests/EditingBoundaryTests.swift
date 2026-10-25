import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class EditingBoundaryTests: XCTestCase {
    private func loaded() async throws -> (URL, FinancialStore, FinancialLifecycle, FactEdit) {
        let root = try StoreFixtures.directory()
        let store = FinancialStore(); await store.loadFixture(root)
        let record = try XCTUnwrap(store.report?.records.first { !$0.non_consumption && !$0.components.isEmpty })
        let edit = try XCTUnwrap(store.beginFactEdit(record))
        return (root, store, record, edit)
    }
    func testFactFormTokenIsInvalidAfterSameDatasetReload() async throws {
        let (root, store, _, edit) = try await loaded(); defer { try? FileManager.default.removeItem(at: root) }
        await store.loadFixture(root)
        let before = store.report?.records
        let saved = await store.saveFacts(edit, review: edit.initial)
        XCTAssertFalse(saved); XCTAssertNotNil(store.error)
        XCTAssertEqual(store.report?.records, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-overrides.json").path))
    }
    func testFactTokenCannotCrossWorkspaceWithSameDataset() async throws {
        let (root, store, _, edit) = try await loaded()
        let other = try StoreFixtures.directory(); defer { for folder in [root, other] { try? FileManager.default.removeItem(at: folder) } }
        await store.loadFixture(other)
        let saved = await store.saveFacts(edit, review: edit.initial)
        XCTAssertFalse(saved)
        for folder in [root, other] { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("review-overrides.json").path)) }
    }
    func testChangedProjectionOnDiskRefusesStaleFactBeforeWrite() async throws {
        let (root, store, _, edit) = try await loaded(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("financial-review.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        object["coverage_note"] = "New projection, same dataset identity"
        try ReviewSyncIO.json(object).write(to: file, options: .atomic)
        let saved = await store.saveFacts(edit, review: edit.initial)
        XCTAssertFalse(saved); XCTAssertNotNil(store.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-history").path))
    }
    func testChangedCatalogOnDiskRefusesStaleFactBeforeWrite() async throws {
        let (root, store, _, edit) = try await loaded(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("category-catalog.json")
        let original = try Data(contentsOf: file)
        // A different export must invalidate the token before domain decoding.
        try (original + Data("\n".utf8)).write(to: file, options: .atomic)
        let saved = await store.saveFacts(edit, review: edit.initial)
        XCTAssertFalse(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-overrides.json").path))
    }
    func testProcessorLeaseBlocksEditorAndPreservesDraft() async throws {
        let (root, store, _, edit) = try await loaded(); defer { try? FileManager.default.removeItem(at: root) }
        let lease = try ReviewProcessLease(root: root)
        let saved = await store.saveFacts(edit, review: edit.initial)
        XCTAssertFalse(saved); XCTAssertNotNil(store.error); XCTAssertFalse(store.completionSaving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-overrides.json").path))
        withExtendedLifetime(lease) {}
    }
    func testUnrelatedPeerEntryIsMergedThroughPublicFactAPI() async throws {
        let (root, store, _, edit) = try await loaded(); defer { try? FileManager.default.removeItem(at: root) }
        let unknown = ["primary": "", "secondary": "", "future_field": "preserved"]
        try ReviewSyncIO.json(["unrelated-entry": unknown]).write(to: root.appendingPathComponent("review-overrides.json"))
        let saved = await store.saveFacts(edit, review: edit.initial)
        XCTAssertTrue(saved, store.error ?? "")
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("review-overrides.json"))) as! [String: [String: Any]]
        XCTAssertEqual(document["unrelated-entry"]?["future_field"] as? String, "preserved")
        XCTAssertEqual(store.overrides.keys.count, 2)
        XCTAssertEqual(store.report?.records.first { $0.id == edit.record.id }?.factReviewConfirmed, true)
    }
    func testFieldEditAndFullCompletionKeepDifferentConfirmationSemantics() async throws {
        let (root, store, record, _) = try await loaded(); defer { try? FileManager.default.removeItem(at: root) }
        let component = try XCTUnwrap(record.components.first)
        store.classify(component.id, primary: "生产力工具", secondary: "设备", recurrence: "one_time", tags: ["field"])
        XCTAssertNil(store.error)
        let field = try XCTUnwrap(store.report?.records.flatMap(\.components).first { $0.id == component.id })
        XCTAssertFalse(field.completionConfirmed)
        await store.loadFixture(root)
        let evidence = BrowserStore(); store.completion.from = store.from; store.completion.to = store.to
        store.completion.refresh(store, evidence)
        let entry = try XCTUnwrap(CompletionQueue.build(try XCTUnwrap(store.report).records, from: "", to: "9999", includeIDs: [component.id], datasetID: try XCTUnwrap(store.report).dataset_id, rootPath: root.path).first { $0.id == component.id })
        let saved = await store.saveCompletion(entry); XCTAssertTrue(saved, store.error ?? "")
        XCTAssertTrue(store.report?.records.flatMap(\.components).first { $0.id == component.id }?.completionConfirmed == true)
        await store.undoCompletion()
        XCTAssertFalse(store.report?.records.flatMap(\.components).first { $0.id == component.id }?.completionConfirmed == true)
        XCTAssertEqual(store.report?.records.flatMap(\.components).first { $0.id == component.id }?.tags, ["field"])
    }
}
