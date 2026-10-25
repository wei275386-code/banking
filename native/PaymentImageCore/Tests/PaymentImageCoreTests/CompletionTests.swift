import XCTest
@testable import PaymentImageCore

final class CompletionTests: XCTestCase {
    private func component(_ id: String = "c", included: Bool = true, primary: String = "待分类", recurrence: String? = "unconfirmed", amount: Int = 100) -> FinancialComponent {
        FinancialComponent(id: id, title: id, gross_cents: amount, refund_cents: 0, net_cents: amount,
            primary: primary, secondary: primary == "待分类" ? "待分类" : "设备", classification_basis: "证据", included: included, reason: included ? "" : "日期待核", recurrence: recurrence)
    }
    private func record(_ c: FinancialComponent, date: String = "2026-06-01") -> FinancialLifecycle {
        FinancialLifecycle(id: c.id, date: date, title: c.title, status: "支付", account_views: [], evidence_keys: [], components: [c], events: [], user_relation: "self", non_consumption: false, unallocated_credit_cents: 0, user_id: "fixture_owner_b", payment_accounts: ["9001"], payment_account_status: "identified")
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testQueueAmountsOverrideIssuePriorityAndRespectCutoffWithoutChangingFacts() {
        let records = [record(component("large", primary: "生产力工具", amount: 90000)), record(component("small", amount: 100)), record(component("pending", included: false, amount: 50)), record(component("future"), date: "2027-01-01"), record(component("done", primary: "生产力工具", recurrence: "one_time"))]
        let result = CompletionQueue.build(records, from: "2026-01-01", to: "2026-09-13")
        XCTAssertEqual(result.map(\.id), ["small", "pending"])
        XCTAssertFalse(result[1].record.components[0].included)
        XCTAssertEqual(result[1].record.components[0].reason, "日期待核")
    }
    func testFactsRemainAfterClassifyingAndFullyRefundedDoesNotRequireRecurrence() {
        var c = component(primary: "生产力工具")
        var r = record(c); r.payment_account_status = "unresolved"; r.payment_accounts = []
        let entries = CompletionQueue.build([r], from: "", to: "9999")
        XCTAssertEqual(entries.count, 1); XCTAssertTrue(entries[0].factsPending)
        XCTAssertFalse(entries[0].missingCategory)
        XCTAssertEqual(entries[0].issues, ["支付账户待关联"])
        c = component(primary: "生产力工具"); c = FinancialComponent(id: c.id, title: c.title, gross_cents: 100, refund_cents: 100, net_cents: 0, primary: c.primary, secondary: c.secondary, classification_basis: "证据", included: true, reason: "", recurrence: "unconfirmed")
        XCTAssertTrue(CompletionQueue.build([record(c)], from: "", to: "9999").isEmpty)
    }
    func testDefaultOneTimeOnlyExplicitRecurringEntersRecurringStatistics() {
        let records = [record(component("legacy", primary: "生产力工具")), record(component("missing", primary: "生产力工具", recurrence: nil)), record(component("recurring", primary: "生产力工具", recurrence: "recurring")), record(component("one_time", primary: "生产力工具", recurrence: "one_time"))]
        let snapshot = ReviewSnapshot(records: records, from: "2026-01-01", to: "2026-12-31", account: "全部账户", primary: "全部分类")
        XCTAssertEqual(snapshot.statistics.net, 400)
        XCTAssertEqual(snapshot.recurringStatistics.net, 100)
        XCTAssertEqual(CompletionDraft(records[0].components[0]).recurrence, "one_time")
        XCTAssertEqual(CompletionDraft(records[1].components[0]).recurrence, "one_time")
        XCTAssertTrue(CompletionQueue.build(records, from: "", to: "9999").isEmpty)
    }
    func testExcludedMultiComponentTransactionDoesNotEnterAnyStatisticsOrLinking() {
        var excluded = record(component("a", amount: 90000))
        excluded.components.append(component("b", included: false))
        excluded.excluded_from_completion_and_statistics = true
        let keep = record(component("keep", amount: 100))
        let snapshot = ReviewSnapshot(records: [excluded, keep], from: "2026-01-01", to: "2026-12-31", account: "全部账户", primary: "全部分类")
        XCTAssertEqual(snapshot.statistics.net, 100); XCTAssertEqual(snapshot.statistics.pendingCount, 0)
        XCTAssertEqual(snapshot.largestUnclassified.map { $0.1.id }, ["keep"])
        XCTAssertEqual(snapshot.records.count, 2, "Original detail records remain visible")
        let queue = CompletionQueue.build([excluded], from: "", to: "9999")
        XCTAssertEqual(queue.count, 1); XCTAssertTrue(queue[0].record.reviewExcluded)
        XCTAssertFalse(queue[0].factsPending)
        let empty = FinancialLifecycle(id: "empty", date: "2026-06-01", title: "资金流", status: "", account_views: [], evidence_keys: [], components: [], events: [], user_relation: "self", non_consumption: true, unallocated_credit_cents: 0, excluded_from_completion_and_statistics: true)
        XCTAssertEqual(CompletionQueue.build([empty], from: "", to: "9999").count, 1, "Excluded transactions without components can still be restored")
    }
    func testDraftValidationOnlyPermitsExistingFieldValuesAndEmptyTags() throws {
        let taxonomy = [FinancialCategory(primary: "待分类", secondaries: ["待分类"])]
        var draft = CompletionDraft(component()); draft.tags = ["  A  B ", "A B", ""]
        XCTAssertEqual(try draft.validated(taxonomy: taxonomy).tags, ["A B"])
        draft.tags = []; XCTAssertEqual(try draft.validated(taxonomy: taxonomy).override.tags, [])
        draft.recurrence = "周期"; XCTAssertThrowsError(try draft.validated(taxonomy: taxonomy))
        draft.recurrence = "one_time"; draft.secondary = "不存在"; XCTAssertThrowsError(try draft.validated(taxonomy: taxonomy))
    }
    func testMergePreservesMetadataOtherEntriesAndUndoOnlyRestoresTarget() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("review-overrides.json")
        let initial = Data(#"{"c":{"primary":"待分类","secondary":"待分类","purpose":"人工说明","title":"原标题","extra":{"a":1},"tags":["旧"]},"other":{"primary":"待分类","secondary":"待分类"}}"#.utf8)
        try initial.write(to: file)
        var draft = CompletionDraft(component()); draft.tags = []; draft.recurrence = "one_time"
        let write = try CompletionOverrideFile.save(root: root, id: "c", draft: draft, expected: CompletionOverrideFile.entry("c", in: initial))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: write.document) as? [String: [String: Any]])
        XCTAssertEqual(object["c"]?["purpose"] as? String, "人工说明"); XCTAssertEqual(object["c"]?["title"] as? String, "原标题")
        XCTAssertEqual(object["c"]?["tags"] as? [String], [])
        object["other"]?["tags"] = ["并发修改"]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let restored = try CompletionOverrideFile.restore(root: root, id: "c", previous: write.previousEntry, expected: write.savedEntry)
        XCTAssertEqual(try CompletionOverrideFile.entry("c", in: restored.document), try CompletionOverrideFile.entry("c", in: initial))
        let latest = try XCTUnwrap(JSONSerialization.jsonObject(with: restored.document) as? [String: [String: Any]])
        XCTAssertEqual(latest["other"]?["tags"] as? [String], ["并发修改"])
    }
    func testAbsentUndoAndTargetConflictNeverOverwrite() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let draft = CompletionDraft(component())
        let first = try CompletionOverrideFile.save(root: root, id: "c", draft: draft, expected: nil)
        XCTAssertThrowsError(try CompletionOverrideFile.save(root: root, id: "c", draft: draft, expected: nil))
        let restored = try CompletionOverrideFile.restore(root: root, id: "c", previous: nil, expected: first.savedEntry)
        XCTAssertNil(try CompletionOverrideFile.entry("c", in: restored.document))
        let next = try CompletionOverrideFile.save(root: root, id: "c", draft: draft, expected: nil)
        var updated = draft; updated.recurrence = "recurring"
        _ = try CompletionOverrideFile.save(root: root, id: "c", draft: updated, expected: next.savedEntry)
        let before = try Data(contentsOf: root.appendingPathComponent("review-overrides.json"))
        XCTAssertThrowsError(try CompletionOverrideFile.restore(root: root, id: "c", previous: nil, expected: next.savedEntry))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("review-overrides.json")), before)
    }
    func testAliasConflictAndCorruptDocumentFailBeforeCommit() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("review-overrides.json")
        let initial = Data(#"{"legacy":{"primary":"待分类","secondary":"待分类"}}"#.utf8)
        try initial.write(to: file)
        let dependencies = try CompletionOverrideFile.dependencies(["legacy"], in: initial)
        _ = try CompletionOverrideFile.save(root: root, id: "legacy", draft: CompletionDraft(component()), expected: CompletionOverrideFile.entry("legacy", in: initial))
        XCTAssertThrowsError(try CompletionOverrideFile.save(root: root, id: "c", draft: CompletionDraft(component()), expected: nil, dependencies: dependencies))
        for bytes in [Data("[]".utf8), Data("bad json".utf8), Data(#"{"other":{"wrong":1}}"#.utf8)] {
            try bytes.write(to: file)
            XCTAssertThrowsError(try CompletionOverrideFile.save(root: root, id: "c", draft: CompletionDraft(component()), expected: nil))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }
}
