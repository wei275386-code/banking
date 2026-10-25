import XCTest
import Foundation
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class CompletionMilestoneAuditTests: XCTestCase {
    private func fixture() throws -> URL {
        try StoreFixtures.directory(files: ["financial-review.json", "payment-evidence.json", "review-overrides.json", "review-state.json", "preview.png"])
    }
    private func setup(_ root: URL) async -> FinancialStore {
        let store = FinancialStore(); await store.loadFixture(root)
        store.completion.allDates = true; store.completion.refresh(store, BrowserStore())
        return store
    }
    private func editable(_ store: FinancialStore) throws -> CompletionEntry {
        try XCTUnwrap(store.completion.entries.first { $0.component != nil })
    }
    private func object(_ bytes: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func facts(_ report: FinancialReport) throws -> Data {
        var value = try object(JSONEncoder().encode(report))
        var records = try XCTUnwrap(value["records"] as? [[String: Any]])
        for index in records.indices {
            var components = try XCTUnwrap(records[index]["components"] as? [[String: Any]])
            for ci in components.indices {
                for key in ["primary", "secondary", "classification_basis", "recurrence", "tags", "tag_basis", "completion_confirmation"] { components[ci].removeValue(forKey: key) }
            }
            records[index]["components"] = components
        }
        value["records"] = records
        return try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
    }
    func testFixtureOverridesMetadataReloadUndoFactsAndPerformance() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("review-overrides.json")
        let initial = try Data(contentsOf: file)
        let initialCount = try object(initial).count
        XCTAssertGreaterThan(initialCount, 0)
        let store = await setup(root); XCTAssertNil(store.error)
        let baseline = try XCTUnwrap(store.report)
        let beforeFacts = try facts(baseline); let beforeStats = store.stats
        let queueStart = DispatchTime.now().uptimeNanoseconds
        let queue = CompletionQueue.build(baseline.records, from: "", to: "9999")
        let queueMS = Double(DispatchTime.now().uptimeNanoseconds - queueStart) / 1_000_000
        let entry = try XCTUnwrap(queue.first { $0.component != nil && store.overrides[$0.id] != nil })
        var augmented = try object(initial)
        var target = try XCTUnwrap(augmented[entry.id] as? [String: Any])
        target["auditUnknown"] = ["nested": ["keep": true], "number": 17]
        augmented[entry.id] = target
        let before = try JSONSerialization.data(withJSONObject: augmented, options: .sortedKeys)
        try before.write(to: file)
        await store.loadFixture(root); store.completion.refresh(store, BrowserStore())
        let live = try XCTUnwrap(store.completion.entries.first { $0.id == entry.id })
        var draft = try XCTUnwrap(store.completion.draft(live)); draft.recurrence = "one_time"; draft.tags = ["审计临时副本"]
        store.completion.edit(live, draft)
        XCTAssertEqual(try facts(XCTUnwrap(store.report)), beforeFacts)
        let saveStart = DispatchTime.now().uptimeNanoseconds
        let saved = await store.saveCompletion(live)
        let saveMS = Double(DispatchTime.now().uptimeNanoseconds - saveStart) / 1_000_000
        XCTAssertTrue(saved); XCTAssertNil(store.error)
        let after = try Data(contentsOf: file)
        XCTAssertEqual(try object(after).count, initialCount)
        for key in augmented.keys where key != entry.id {
            XCTAssertEqual(try CompletionOverrideFile.entry(key, in: before), try CompletionOverrideFile.entry(key, in: after))
        }
        let savedTarget = try XCTUnwrap(try object(after)[entry.id] as? [String: Any])
        XCTAssertNotNil(savedTarget["auditUnknown"])
        for key in target.keys where !["primary", "secondary", "recurrence", "tags", "classification_basis", "completion_confirmation"].contains(key) {
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: ["v": target[key]!], options: .sortedKeys), try JSONSerialization.data(withJSONObject: ["v": savedTarget[key]!], options: .sortedKeys))
        }
        XCTAssertEqual(try facts(XCTUnwrap(store.report)), beforeFacts)
        XCTAssertEqual(store.stats.net, beforeStats.net); XCTAssertEqual(store.stats.gross, beforeStats.gross); XCTAssertEqual(store.stats.refunds, beforeStats.refunds); XCTAssertEqual(store.stats.pending, beforeStats.pending)
        await store.loadFixture(root); XCTAssertEqual(store.report?.records.flatMap(\.components).first { $0.id == entry.id }?.tags, draft.tags)
        await store.undoCompletion(); XCTAssertNil(store.error)
        XCTAssertEqual(try object(Data(contentsOf: file)).count, initialCount)
        XCTAssertEqual(try CompletionOverrideFile.entry(entry.id, in: Data(contentsOf: file)), try CompletionOverrideFile.entry(entry.id, in: before))
        await store.loadFixture(root); XCTAssertEqual(try facts(XCTUnwrap(store.report)), beforeFacts); XCTAssertEqual(store.stats.net, beforeStats.net)
        let sample: [String: Any] = ["records": baseline.records.count, "components": baseline.records.flatMap(\.components).count, "overrides": initialCount, "queueEntries": queue.count, "queueMS": queueMS, "saveMS": saveMS, "configuration": "debug", "samples": 1, "netCents": beforeStats.net]
        let output = root.appendingPathComponent("pure-queue-regression-sample.json")
        try JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }
    func testBusyAndCorruptFileNeverCommitAndKeepDraft() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = await setup(root); let entry = try editable(store)
        var draft = try XCTUnwrap(store.completion.draft(entry)); draft.recurrence = "one_time"; store.completion.edit(entry, draft)
        let file = root.appendingPathComponent("review-overrides.json"); let before = try Data(contentsOf: file)
        store.completionSaving = true
        let busySaved = await store.saveCompletion(entry); XCTAssertFalse(busySaved); XCTAssertEqual(try Data(contentsOf: file), before)
        store.completionSaving = false
        let corrupt = Data("broken".utf8); try corrupt.write(to: file)
        let corruptSaved = await store.saveCompletion(entry); XCTAssertFalse(corruptSaved); XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: file), corrupt); XCTAssertEqual(store.completion.draft(entry), draft); XCTAssertFalse(store.completionSaving)
    }
    func testDirectoryReadErrorNeverReplacesOverridePath() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = await setup(root); let entry = try editable(store)
        let file = root.appendingPathComponent("review-overrides.json")
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let succeeded = await store.saveCompletion(entry); XCTAssertFalse(succeeded); XCTAssertNotNil(store.error)
        var directory: ObjCBool = false; XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &directory)); XCTAssertTrue(directory.boolValue)
    }
    func testExternalTargetChangeBlocksSaveAndUndo() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = await setup(root); let entry = try editable(store)
        var draft = try XCTUnwrap(store.completion.draft(entry)); draft.recurrence = "one_time"; store.completion.edit(entry, draft)
        let file = root.appendingPathComponent("review-overrides.json")
        var current = try object(Data(contentsOf: file)); current[entry.id] = ["primary": draft.primary, "secondary": draft.secondary, "externalMetadata": true]
        let external = try JSONSerialization.data(withJSONObject: current, options: .sortedKeys); try external.write(to: file)
        let saved = await store.saveCompletion(entry); XCTAssertFalse(saved); XCTAssertEqual(try Data(contentsOf: file), external); XCTAssertEqual(store.completion.draft(entry), draft)
        await store.loadFixture(root); store.completion.refresh(store, BrowserStore()); let live = try XCTUnwrap(store.completion.entries.first { $0.id == entry.id })
        let savedAgain = await store.saveCompletion(live); XCTAssertTrue(savedAgain)
        try external.write(to: file); await store.undoCompletion(); XCTAssertNotNil(store.error); XCTAssertEqual(try Data(contentsOf: file), external)
    }
    func testDatasetRefreshClearsDraftUndoAndSessionSavedState() async throws {
        let root = try fixture(); let other = try fixture(); defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let store = await setup(root); let evidence = BrowserStore(); let entry = try editable(store)
        var draft = try XCTUnwrap(store.completion.draft(entry)); draft.tags = ["旧数据集草稿"]; store.completion.edit(entry, draft)
        await store.loadFixture(other); store.completion.refresh(store, evidence)
        XCTAssertTrue(store.completion.drafts.isEmpty); XCTAssertNil(store.completion.undo); XCTAssertTrue(store.completion.saved.isEmpty)
    }
    func testStaleEntryCannotSaveIntoOtherDatasetBeforeWorkspaceRefresh() async throws {
        let root = try fixture(); let other = try fixture(); defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let store = await setup(root); let entry = try editable(store)
        var draft = try XCTUnwrap(store.completion.draft(entry)); draft.tags = ["不应进入新数据集"]; store.completion.edit(entry, draft)
        let reportURL = other.appendingPathComponent("financial-review.json")
        var report = try object(Data(contentsOf: reportURL)); report["dataset_id"] = "audit-other-dataset"
        try JSONSerialization.data(withJSONObject: report).write(to: reportURL)
        let file = other.appendingPathComponent("review-overrides.json"); let before = try Data(contentsOf: file)
        await store.loadFixture(other)
        let succeeded = await store.saveCompletion(entry)
        XCTAssertFalse(succeeded, "跨数据集旧 entry 应由写入口拒绝，不能依赖稍后的 SwiftUI refresh")
        XCTAssertEqual(try Data(contentsOf: file), before, "新数据集 overrides 不应被旧草稿写入")
    }
    func testSavedViewIncludesFullyResolvedSavedEntry() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = await setup(root)
        let entry = try XCTUnwrap(store.completion.entries.first { $0.component != nil && !$0.factsPending })
        var draft = try XCTUnwrap(store.completion.draft(entry))
        draft.primary = "生产力工具"; draft.secondary = "设备"; draft.recurrence = "one_time"
        store.completion.edit(entry, draft)
        let succeeded = await store.saveCompletion(entry); XCTAssertTrue(succeeded)
        store.completion.refresh(store, BrowserStore()); store.completion.mode = "本次已保存"
        XCTAssertTrue(store.completion.visible.contains { $0.id == entry.id }, "已完成的保存项应可在本次已保存复查")
    }
}
