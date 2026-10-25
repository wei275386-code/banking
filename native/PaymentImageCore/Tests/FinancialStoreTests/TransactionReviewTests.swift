import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class TransactionReviewTests: XCTestCase {
    private func fixture() throws -> URL {
        try StoreFixtures.directory(files: ["financial-review.json", "payment-evidence.json", "preview.png"])
    }
    func testSecondaryTransactionsMatchTotalsAndKeepOnlyContributingItems() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let report = try JSONDecoder().decode(FinancialReport.self, from: Data(contentsOf: root.appendingPathComponent("financial-review.json")))
        func item(_ id: String, primary: String = "日常", secondary: String = "餐饮", included: Bool = true, tags: [String] = ["旅行"], net: Int = 700) -> FinancialComponent {
            var c = FinancialComponent(id: id, title: id, gross_cents: 1000, refund_cents: 1000 - net, net_cents: net,
                primary: primary, secondary: secondary, classification_basis: "测试", included: included, reason: included ? "" : "待核")
            c.tags = tags; return c
        }
        var records = Array(report.records.prefix(6))
        for i in records.indices {
            records[i].date = "2026-02-01"; records[i].account_views = ["测试账户"]
            records[i].non_consumption = false; records[i].excluded_from_completion_and_statistics = false
            records[i].components = [item("item-\(i)")]
        }
        records[0].components = [item("meal"), item("same-category", net: 200), item("sibling", secondary: "商超"),
            item("same-name-other-primary", primary: "旅行"), item("pending", included: false), item("other-tag", tags: ["居家"]), item("refunded", net: 0)]
        records[0].unallocated_credit_cents = 500
        records[1].date = "2026-01-31"
        records[2].account_views = ["其他账户"]
        records[3].non_consumption = true
        records[4].excluded_from_completion_and_statistics = true
        records[5].components = [item("tag-mismatch", tags: ["居家"])]
        let snapshot = ReviewSnapshot(records: records, from: "2026-02-01", to: "2026-02-28", account: "测试账户", primary: "全部分类", tags: ["旅行"])
        let transactions = snapshot.spendingTransactions(primary: "日常", secondary: "餐饮")
        XCTAssertEqual(transactions.map(\.id), [records[0].id])
        XCTAssertEqual(transactions[0].components.map(\.id), ["meal", "same-category", "refunded"])
        XCTAssertEqual(FinancialMath.statistics(transactions).net, snapshot.statistics.bySecondary["日常 / 餐饮"])
        XCTAssertEqual(FinancialMath.statistics(transactions).net, 900)
        XCTAssertEqual(transactions[0].unallocated_credit_cents, 0)
        XCTAssertEqual(transactions[0].evidence_keys, records[0].evidence_keys)
        XCTAssertEqual(transactions[0].events, records[0].events)
    }
    func testCategoryTransactionOpensFullLifecycleAndClearsHiddenSearch() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); await store.loadFixture(root)
        let full = try XCTUnwrap(store.records.first { !$0.non_consumption && !$0.reviewExcluded && $0.components.contains { $0.included } })
        let component = try XCTUnwrap(full.components.first { $0.included })
        store.query = "隐藏的旧搜索"; store.recordView = "资金流"
        let transactions = store.spendingTransactions(primary: component.primary, secondary: component.secondary)
        XCTAssertTrue(transactions.contains { $0.id == full.id })
        XCTAssertEqual(FinancialMath.statistics(transactions).net, store.stats.bySecondary[component.primary + " / " + component.secondary])
        let before = store.stats.net
        store.inspectTransaction(full.id)
        XCTAssertEqual(store.section, "details"); XCTAssertEqual(store.selected, full.id); XCTAssertEqual(store.directDetailID, full.id)
        XCTAssertEqual(store.query, ""); XCTAssertEqual(store.recordView, "全部消费")
        XCTAssertEqual(store.selectedRecord?.components, full.components)
        XCTAssertEqual(store.stats.net, before)
    }
    func testWholeTransactionExclusionPersistsRestoresAndPreservesFacts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); let evidence = BrowserStore(); await store.loadFixture(root)
        let record = try XCTUnwrap(store.report?.records.first { $0.canExcludeFromReview && !$0.non_consumption && !$0.components.isEmpty })
        let before = try XCTUnwrap(store.report).records
        store.completion.allDates = true; store.completion.refresh(store, evidence)
        await store.setReviewExcluded(record, value: true)
        XCTAssertNil(store.error)
        let changed = try XCTUnwrap(store.report?.records.first { $0.id == record.id })
        XCTAssertTrue(changed.reviewExcluded)
        XCTAssertEqual(changed.components, record.components); XCTAssertEqual(changed.events, record.events)
        let actual = FinancialMath.statistics(try XCTUnwrap(store.report).records)
        let expected = FinancialMath.statistics(before.filter { $0.id != record.id })
        XCTAssertEqual(actual.net, expected.net); XCTAssertEqual(actual.pendingCount, expected.pendingCount)
        XCTAssertEqual(actual.unallocatedCredits, expected.unallocatedCredits)
        store.completion.refresh(store, evidence)
        XCTAssertFalse(store.completion.visible.contains { $0.record.id == record.id })
        store.completion.mode = "已排除"
        XCTAssertEqual(store.completion.visible.filter { $0.record.id == record.id }.count, 1)
        await store.loadFixture(root)
        let reloaded = try XCTUnwrap(store.report?.records.first { $0.id == record.id })
        XCTAssertTrue(reloaded.reviewExcluded)
        await store.setReviewExcluded(reloaded, value: false)
        XCTAssertNil(store.error)
        let restored = try XCTUnwrap(store.report?.records.first { $0.id == record.id })
        XCTAssertFalse(restored.reviewExcluded); XCTAssertEqual(restored.components, record.components)
        XCTAssertEqual(FinancialMath.statistics(try XCTUnwrap(store.report).records).net, FinancialMath.statistics(before).net)
        await store.loadFixture(root)
        XCTAssertFalse(try XCTUnwrap(store.report?.records.first { $0.id == record.id }).reviewExcluded)
    }
    func testExclusionCannotApplyToOtherUserOrIdentifiedAccount() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); await store.loadFixture(root)
        let record = try XCTUnwrap(store.report?.records.first { !$0.canExcludeFromReview })
        await store.setReviewExcluded(record, value: true)
        XCTAssertFalse(try XCTUnwrap(store.report?.records.first { $0.id == record.id }).reviewExcluded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-overrides.json").path))
    }
    func testLegacyNatureDefaultsAndConfirmationRemainCompatible() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); await store.loadFixture(root)
        var component = try XCTUnwrap(store.report?.records.flatMap(\.components).first)
        component.recurrence = "unconfirmed"
        let draft = CompletionDraft(component)
        XCTAssertEqual(draft.recurrence, "one_time")
        XCTAssertEqual(component.effectiveRecurrence, "one_time")
        var legacy = draft; legacy.recurrence = "unconfirmed"
        XCTAssertThrowsError(try legacy.validated(taxonomy: try XCTUnwrap(store.report).taxonomy))
        component.completion_confirmation = CompletionConfirmation(draft: legacy, origin: "manual")
        if component.primary != "待分类" { XCTAssertTrue(component.completionConfirmed) }
        component.recurrence = nil; XCTAssertEqual(CompletionDraft(component).recurrence, "one_time")
        component.recurrence = "recurring"; XCTAssertEqual(CompletionDraft(component).recurrence, "recurring")
    }
}
