import XCTest
import Foundation
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class CompletionFinalBoundaryTests: XCTestCase {
    private func fixture() throws -> URL {
        try StoreFixtures.directory(files: ["financial-review.json", "payment-evidence.json", "review-overrides.json", "review-state.json", "preview.png"])
    }
    private func object(_ bytes: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func setup(_ root: URL) async -> FinancialStore {
        let store = FinancialStore(); await store.loadFixture(root)
        store.completion.from = store.from; store.completion.to = store.to
        store.completion.allDates = true; store.completion.refresh(store, BrowserStore())
        return store
    }
    private func entry(_ store: FinancialStore) throws -> CompletionEntry {
        try XCTUnwrap(store.completion.entries.first { $0.component != nil })
    }
    private func workflow(dataset: String, invalid: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["datasetID": dataset, "deferred": invalid ? 99 as Any : [String]() as Any, "extra": ["nested": ["preserve": true]]], options: .sortedKeys)
    }
    func testSameRootDifferentDatasetRejectsOldEntryAndUndoWithoutRefresh() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = await setup(root); let oldEntry = try entry(store)
        let succeeded = await store.saveCompletion(oldEntry); XCTAssertTrue(succeeded)
        let oldUndo = try XCTUnwrap(store.completion.undo)
        let financial = root.appendingPathComponent("financial-review.json")
        var raw = try object(Data(contentsOf: financial)); raw["dataset_id"] = "audit-new-dataset-same-root"
        try JSONSerialization.data(withJSONObject: raw).write(to: financial)
        let file = root.appendingPathComponent("review-overrides.json"); let before = try Data(contentsOf: file)
        await store.loadFixture(root)
        XCTAssertTrue(store.completion.drafts.isEmpty); XCTAssertNil(store.completion.undo)
        let staleSaved = await store.saveCompletion(oldEntry); XCTAssertFalse(staleSaved)
        store.completion.undo = oldUndo
        await store.undoCompletion()
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testSameDatasetDifferentRootRejectsOldEntryAndUndoWithoutRefresh() async throws {
        let root = try fixture(); let other = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let store = await setup(root); let oldEntry = try entry(store)
        let saved = await store.saveCompletion(oldEntry); XCTAssertTrue(saved)
        let oldUndo = try XCTUnwrap(store.completion.undo)
        let file = other.appendingPathComponent("review-overrides.json"); let before = try Data(contentsOf: file)
        await store.loadFixture(other)
        XCTAssertEqual(store.report?.dataset_id, oldEntry.datasetID)
        XCTAssertNil(store.completion.undo)
        let staleSaved = await store.saveCompletion(oldEntry); XCTAssertFalse(staleSaved)
        store.completion.undo = oldUndo; await store.undoCompletion()
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testWorkflowReadRejectsMalformedAndCorruptWithoutChangingBytes() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let finance = try JSONDecoder().decode(FinancialReport.self, from: Data(contentsOf: root.appendingPathComponent("financial-review.json")))
        let file = root.appendingPathComponent("completion-workflow.json")
        let variants = [Data("broken".utf8), Data("[]".utf8), Data("{}".utf8), try workflow(dataset: finance.dataset_id, invalid: true)]
        for bytes in variants {
            try bytes.write(to: file)
            let store = await setup(root)
            XCTAssertNotNil(store.completion.workflowError)
            await store.completion.setDeferred("audit-id", value: true)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertFalse(store.completion.deferred.contains("audit-id"))
        }
    }
    func testWorkflowWriteRevalidatesMalformedAndCorruptCreatedAfterLoad() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("completion-workflow.json")
        let store = await setup(root); let dataset = try XCTUnwrap(store.report?.dataset_id)
        let variants = [Data("broken".utf8), Data("[]".utf8), Data("{}".utf8), try workflow(dataset: dataset, invalid: true)]
        for bytes in variants {
            let valid = try workflow(dataset: dataset)
            try valid.write(to: file)
            let workspace = CompletionWorkspace(); workspace.resetContext(folder: root, datasetID: dataset)
            XCTAssertNil(workspace.workflowError)
            try bytes.write(to: file)
            await workspace.setDeferred("audit-id", value: true)
            XCTAssertEqual(try Data(contentsOf: file), bytes, "写入前发现现有文件损坏或未来schema应保留原字节")
            XCTAssertFalse(workspace.deferred.contains("audit-id"))
        }
    }
    func testWorkflowMergePreservesExtraAndBusyBlocksOldAndNewWrites() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = await setup(root); let current = try entry(store)
        let file = root.appendingPathComponent("completion-workflow.json")
        let valid = try workflow(dataset: current.datasetID); try valid.write(to: file)
        await store.completion.setDeferred(current.id, value: true)
        let after = try object(Data(contentsOf: file)); let before = try object(valid)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: after["extra"]!, options: .sortedKeys), try JSONSerialization.data(withJSONObject: before["extra"]!, options: .sortedKeys))
        let overridesFile = root.appendingPathComponent("review-overrides.json"); let overrides = try Data(contentsOf: overridesFile)
        store.completion.persisting = true
        let saved = await store.saveCompletion(current); XCTAssertFalse(saved)
        let c = try XCTUnwrap(current.component)
        store.classify(current.id, primary: c.primary, secondary: c.secondary, recurrence: "one_time")
        XCTAssertEqual(try Data(contentsOf: overridesFile), overrides)
        store.completion.persisting = false
    }
    func testUnknownAmountAndUndatedRefundAppearOnlyInAllDatesWithoutChangingFacts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("financial-review.json")
        var raw = try object(Data(contentsOf: file))
        let records = try XCTUnwrap(raw["records"] as? [[String: Any]])
        var record = try XCTUnwrap(records.first { ($0["components"] as? [[String: Any]])?.isEmpty == false })
        var component = try XCTUnwrap((record["components"] as? [[String: Any]])?.first)
        component["id"] = "audit-unknown-component"; component["gross_cents"] = 0; component["refund_cents"] = 0; component["net_cents"] = 0
        component["primary"] = "待分类"; component["secondary"] = "待分类"; component["included"] = false; component["reason"] = "支付金额待确定"; component["classification_keys"] = [String]()
        record["id"] = "audit-undated-payment"; record["date"] = ""; record["non_consumption"] = false; record["unallocated_credit_cents"] = 0; record["components"] = [component]
        var refund = record; refund["id"] = "audit-undated-refund"; refund["non_consumption"] = true; refund["components"] = [[String: Any]](); refund["unallocated_credit_cents"] = 1234
        raw["records"] = [record, refund]
        for key in ["source_record_sets", "source_record_set_candidates", "source_record_set_unresolved"] { raw.removeValue(forKey:key) }
        try JSONSerialization.data(withJSONObject: raw).write(to: file)
        let store = await setup(root); XCTAssertNil(store.error)
        store.completion.allDates = false; store.completion.refresh(store, BrowserStore()); XCTAssertTrue(store.completion.entries.isEmpty)
        store.completion.allDates = true; store.completion.refresh(store, BrowserStore())
        XCTAssertEqual(store.completion.entries.count, 2)
        let unknown = try XCTUnwrap(store.completion.entries.first { $0.id == "audit-unknown-component" })
        XCTAssertTrue(unknown.amountUnknown); XCTAssertTrue(unknown.factsPending); XCTAssertEqual(unknown.component?.reason, "支付金额待确定")
        XCTAssertEqual(unknown.component?.gross_cents, 0); XCTAssertEqual(unknown.record.date, ""); XCTAssertEqual(unknown.component?.included, false)
        let pendingRefund = try XCTUnwrap(store.completion.entries.first { $0.id == "audit-undated-refund:facts" })
        XCTAssertNil(pendingRefund.component); XCTAssertTrue(pendingRefund.issues.contains("退款归属待核")); XCTAssertEqual(pendingRefund.impact, 1234)
        XCTAssertNotNil(store.preparedCompletionQueues[CompletionQueue.key(from: "", to: "9999")])
    }
    func testPreparedWorkerSaveUndoAndCacheRefreshPerformanceWithSavedIncludeIDs() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); let evidence = BrowserStore(); var samples = [[String: Any]]()
        for index in 0..<3 {
            let loadStart = DispatchTime.now().uptimeNanoseconds; await store.loadFixture(root)
            let loadMS = Double(DispatchTime.now().uptimeNanoseconds - loadStart) / 1_000_000
            XCTAssertNil(store.error)
            store.completion.from = store.from; store.completion.to = store.to; store.completion.allDates = false
            XCTAssertNotNil(store.preparedCompletionQueues[CompletionQueue.key(from: store.from, to: store.to)])
            let currentStart = DispatchTime.now().uptimeNanoseconds; store.completion.refresh(store, evidence)
            let currentCacheMS = Double(DispatchTime.now().uptimeNanoseconds - currentStart) / 1_000_000
            store.completion.allDates = true
            XCTAssertNotNil(store.preparedCompletionQueues[CompletionQueue.key(from: "", to: "9999")])
            let allStart = DispatchTime.now().uptimeNanoseconds; store.completion.refresh(store, evidence)
            let allCacheMS = Double(DispatchTime.now().uptimeNanoseconds - allStart) / 1_000_000
            let current = try XCTUnwrap(store.completion.entries.first { $0.component != nil && !$0.factsPending })
            let statsBefore = store.stats
            var draft = try XCTUnwrap(store.completion.draft(current)); draft.primary = "生产力工具"; draft.secondary = "设备"; draft.recurrence = "one_time"; draft.tags = ["临时缓存样本"]
            store.completion.edit(current, draft)
            let saveStart = DispatchTime.now().uptimeNanoseconds; let succeeded = await store.saveCompletion(current)
            let saveMS = Double(DispatchTime.now().uptimeNanoseconds - saveStart) / 1_000_000
            XCTAssertTrue(succeeded); XCTAssertNil(store.error)
            let cached = try XCTUnwrap(store.preparedCompletionQueues[CompletionQueue.key(from: "", to: "9999")])
            let resolved = try XCTUnwrap(cached.first { $0.id == current.id }); XCTAssertTrue(resolved.issues.isEmpty)
            let refreshStart = DispatchTime.now().uptimeNanoseconds; store.completion.refresh(store, evidence)
            let afterSaveCacheMS = Double(DispatchTime.now().uptimeNanoseconds - refreshStart) / 1_000_000
            store.completion.mode = "本次已保存"; XCTAssertTrue(store.completion.visible.contains { $0.id == current.id })
            await store.loadFixture(root); store.completion.refresh(store, evidence)
            XCTAssertTrue(store.completion.visible.contains { $0.id == current.id })
            let undoStart = DispatchTime.now().uptimeNanoseconds; await store.undoCompletion()
            let undoMS = Double(DispatchTime.now().uptimeNanoseconds - undoStart) / 1_000_000
            XCTAssertNil(store.error); XCTAssertEqual(store.stats.net, statsBefore.net)
            XCTAssertNotNil(store.preparedCompletionQueues[CompletionQueue.key(from: "", to: "9999")])
            let undoRefreshStart = DispatchTime.now().uptimeNanoseconds; store.completion.refresh(store, evidence)
            let afterUndoCacheMS = Double(DispatchTime.now().uptimeNanoseconds - undoRefreshStart) / 1_000_000
            store.completion.mode = "优先补全"
            samples.append(["index": index, "fixtureLoadAndDiscoveryMS": loadMS, "currentRangeCacheRefreshMS": currentCacheMS, "allDatesCacheRefreshMS": allCacheMS, "saveWorkerAndPublishMS": saveMS, "afterSaveCacheRefreshMS": afterSaveCacheMS, "undoWorkerAndPublishMS": undoMS, "afterUndoCacheRefreshMS": afterUndoCacheMS, "queueEntries": cached.count])
        }
        let report = try XCTUnwrap(store.report)
        let payload: [String: Any] = ["configuration": "debug", "sampleCount": samples.count, "records": report.records.count, "components": report.records.flatMap(\.components).count, "overrides": store.overrides.count, "samples": samples, "measurement": "Synthetic v1; DispatchTime wall-clock. Fixture load includes initial isolated merchant discovery. Cache keys are checked before refresh. Save and undo include await and MainActor publication."]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("worker-cache-performance.json"))
    }
}
