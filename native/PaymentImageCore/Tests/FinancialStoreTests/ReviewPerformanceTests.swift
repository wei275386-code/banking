import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class ReviewPerformanceTests: XCTestCase {
    private func fixture() throws -> URL {
        try StoreFixtures.directory(files: ["financial-review.json", "payment-evidence.json", "preview.png"])
    }
    private func reference(_ store: FinancialStore) -> [FinancialLifecycle] {
        (store.report?.records ?? []).filter { r in
            r.date >= store.from && r.date <= store.to && (store.account == "全部账户" || r.account_views.contains(store.account)) &&
            (store.primary == "全部分类" || r.components.contains { $0.primary == store.primary }) &&
            (store.section != "details" || store.query.isEmpty || matchesSearch(r, query: store.query))
        }.map { record in
            var r = record; if store.primary != "全部分类" { r.components = r.components.filter { $0.primary == store.primary } }; return r
        }
    }
    private func matchesSearch(_ record: FinancialLifecycle, query: String) -> Bool {
        // The public search covers the original source merchant, date and
        // references as well as the projected transaction and its amounts.
        var values = [record.title, record.date, record.user_id ?? "", record.userDisplayName]
        for component in record.components {
            values += [component.title, money(component.net_cents), String(format:"%.2f", Double(component.net_cents)/100)] + component.tags
        }
        for source in record.trace_sources ?? [] {
            values += [source.merchant, source.title, source.date, source.provider_reference, source.merchant_reference].compactMap { $0 }
        }
        return values.joined(separator:" ").localizedCaseInsensitiveContains(query)
    }
    private func assertStats(_ a: ReviewStatistics, _ b: ReviewStatistics, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.net, b.net, file: file, line: line); XCTAssertEqual(a.gross, b.gross, file: file, line: line)
        XCTAssertEqual(a.refunds, b.refunds, file: file, line: line); XCTAssertEqual(a.count, b.count, file: file, line: line)
        XCTAssertEqual(a.pending, b.pending, file: file, line: line); XCTAssertEqual(a.pendingCount, b.pendingCount, file: file, line: line)
        XCTAssertEqual(a.unallocatedCredits, b.unallocatedCredits, file: file, line: line)
        XCTAssertEqual(a.byPrimary, b.byPrimary, file: file, line: line); XCTAssertEqual(a.bySecondary, b.bySecondary, file: file, line: line)
        XCTAssertEqual(a.byMonth, b.byMonth, file: file, line: line)
    }
    func testFilteredSnapshotsMatchOriginalAcrossAccountsRangesCategoriesAndSearch() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = FinancialStore(); await store.loadFixture(folder)
        XCTAssertNil(store.error)
        for range in ["今年", "近30天", "近90天", "全部"] {
            store.selectRange(range)
            for account in ["全部账户"] + store.accounts.prefix(2) {
                store.account = account
                for category in ["全部分类"] + (store.report?.taxonomy.map(\.primary) ?? []) {
                    store.primary = category
                    assertStats(store.stats, FinancialMath.statistics(reference(store)))
                    let complete = reference(store).filter { store.fullMonths.contains(String($0.date.prefix(7))) }
                    assertStats(store.monthlyStats, FinancialMath.statistics(complete))
                    let recurring = complete.map { r in var r = r; r.components.removeAll { $0.effectiveRecurrence != "recurring" }; return r }
                    assertStats(store.recurringStats, FinancialMath.statistics(recurring))
                }
            }
        }
        store.account = "全部账户"; store.primary = "全部分类"; store.selectRange("今年")
        for query in ["咖啡", "2026-02", "24.00", "不存在的商户"] {
            store.query = query; store.section = "details"
            assertStats(store.stats, FinancialMath.statistics(reference(store)))
            store.section = "overview"
            assertStats(store.stats, FinancialMath.statistics(reference(store)))
        }
        store.selectRange("全部"); store.section = "details"; store.query = "2025-12-23 08:11"
        let jdBankIDs = Set(["trace-purchase-0", "trace-purchase-1", "trace-purchase-2"])
        let matches = store.visibleRecords.filter { !jdBankIDs.isDisjoint(with: $0.evidence_keys) }
        XCTAssertEqual(matches.count, 3, "An unpaired source time must retain all three independent bank purchases")
        XCTAssertTrue(matches.allSatisfy { $0.date == "2025-12-23" })
    }
    func testClassificationAndReloadInvalidateCachedAggregatesAndRemoveOldOverrides() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = FinancialStore(); await store.loadFixture(folder)
        let before = store.stats
        let component = try XCTUnwrap(store.records.flatMap(\.components).first { $0.included && $0.primary != "待分类" })
        let category = try XCTUnwrap(store.report?.taxonomy.first { $0.primary == "待分类" })
        store.classify(component.id, primary: category.primary, secondary: try XCTUnwrap(category.secondaries.first), recurrence: "one_time")
        XCTAssertNil(store.error)
        XCTAssertEqual(store.stats.net, before.net)
        XCTAssertEqual(store.stats.byPrimary["待分类", default: 0], before.byPrimary["待分类", default: 0] + component.net_cents)
        await store.loadFixture(folder)
        XCTAssertEqual(store.records.flatMap(\.components).first { $0.id == component.id }?.recurrence, "one_time")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("review-overrides.json"))
        await store.loadFixture(folder)
        assertStats(store.stats, before)
        XCTAssertTrue(store.overrides.isEmpty)
    }
    func testParameterEditsSelectionAndHiddenSearchKeepCorrectAggregates() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = FinancialStore(); await store.loadFixture(folder)
        let stats = store.stats
        store.report?.fire_parameters.currentFireAssets += 100
        // Amount ordering can put a non-consumption flow first in all records.
        // Select a row visible in the default consumer list for this search test.
        store.savingPercent = 35; store.selected = store.visibleRecords.first?.id; store.query = "没有匹配"
        assertStats(store.stats, stats)
        store.section = "details"; XCTAssertTrue(store.visibleRecords.isEmpty); XCTAssertNil(store.selectedRecord)
        store.query = ""; XCTAssertNotNil(store.selectedRecord)
    }
    func testLegacyWalletClassificationSurvivesCanonicalIDAndFurtherEdits() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let reportFile = folder.appendingPathComponent("financial-review.json")
        var report = try JSONDecoder().decode(FinancialReport.self, from: Data(contentsOf: reportFile))
        let recordIndex = try XCTUnwrap(report.records.firstIndex { $0.components.contains { $0.included } })
        let componentIndex = try XCTUnwrap(report.records[recordIndex].components.firstIndex { $0.included })
        let old = report.records[recordIndex].components[componentIndex]
        var canonical = FinancialComponent(id: "bank:regression", title: old.title, gross_cents: old.gross_cents,
            refund_cents: old.refund_cents, net_cents: old.net_cents, primary: "待分类", secondary: "待分类",
            classification_basis: "证据不足", included: true, reason: "")
        canonical.classification_keys = ["legacy-wallet"]
        report.records[recordIndex].components[componentIndex] = canonical
        try JSONEncoder().encode(report).write(to: reportFile)
        let overrideFile = folder.appendingPathComponent("review-overrides.json")
        try JSONEncoder().encode(["legacy-wallet": CategoryOverride(primary: "生产力工具", secondary: "设备", recurrence: "one_time")]).write(to: overrideFile)
        let store = FinancialStore(); await store.loadFixture(folder)
        XCTAssertNil(store.error)
        var loaded = try XCTUnwrap(store.report?.records[recordIndex].components[componentIndex])
        XCTAssertEqual(loaded.primary, "生产力工具"); XCTAssertEqual(loaded.recurrence, "one_time")
        let secondary = try XCTUnwrap(store.report?.taxonomy.first { $0.primary == "日常消费" }?.secondaries.first)
        store.classify("bank:regression", primary: "日常消费", secondary: secondary)
        XCTAssertNil(store.error)
        await store.loadFixture(folder)
        loaded = try XCTUnwrap(store.report?.records[recordIndex].components[componentIndex])
        XCTAssertEqual(loaded.primary, "日常消费"); XCTAssertEqual(loaded.secondary, secondary)
        XCTAssertEqual(loaded.recurrence, "one_time")
        let persisted = try JSONDecoder().decode([String: CategoryOverride].self, from: Data(contentsOf: overrideFile))
        XCTAssertEqual(persisted["legacy-wallet"]?.primary, "生产力工具")
        XCTAssertEqual(persisted["bank:regression"]?.recurrence, "one_time")
    }
    func testCalendarBoundariesIncludeLeapMonthsAndExcludePartialMonths() {
        XCTAssertEqual(ReviewSnapshot.completeMonths(from: "2024-02-01", to: "2024-02-29"), ["2024-02"])
        XCTAssertEqual(ReviewSnapshot.completeMonths(from: "2024-02-02", to: "2024-03-30"), [])
        XCTAssertEqual(ReviewSnapshot.completeMonths(from: "2025-12-15", to: "2026-03-01"), ["2026-01", "2026-02"])
        XCTAssertEqual(ReviewSnapshot.completeMonths(from: "2026-05-01", to: "2026-04-01"), [])
    }
    func testEvidenceImageIsVerifiedDecodedAndReusedAtBoundedResolution() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserStore()
        await store.load(root)
        XCTAssertNil(store.error)
        let record = try XCTUnwrap(store.records.first { $0.evidence.image != nil })
        await store.preview(record)
        let preview = try XCTUnwrap(store.previews[record.id])
        XCTAssertNil(preview.error)
        let image = try XCTUnwrap(preview.image?.pixels)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 2200)
        await store.preview(record)
        XCTAssertTrue(store.previews[record.id]?.image?.pixels === image)
        XCTAssertTrue(store.previewTasks.isEmpty)
    }
}

extension ReviewPerformanceTests {
    func testMultipleTagsIntersectWithinComponentAndPersistDeletion() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("financial-review.json")
        var report = try JSONDecoder().decode(FinancialReport.self, from: Data(contentsOf: file))
        let index = try XCTUnwrap(report.records.firstIndex { $0.components.contains { $0.included } && $0.date >= "2026-01-01" })
        let original = try XCTUnwrap(report.records[index].components.first { $0.included })
        func component(_ id: String, _ tags: [String], _ amount: Int) -> FinancialComponent {
            var c = FinancialComponent(id: id, title: id, gross_cents: amount, refund_cents: 0, net_cents: amount,
                primary: original.primary, secondary: original.secondary, classification_basis: "证据", included: true, reason: "")
            c.tags = tags; return c
        }
        report.records[index].components = [component("a", ["旅行场景", "便利店", "便利店"], 100), component("b", ["旅行场景"], 200), component("c", ["便利店"], 300)]
        report.records = [report.records[index]]
        report.source_record_sets = nil; report.source_record_set_candidates = nil
        try JSONEncoder().encode(report).write(to: file)
        let store = FinancialStore(); await store.loadFixture(folder)
        XCTAssertNil(store.error); XCTAssertEqual(store.stats.net, 600)
        XCTAssertEqual(store.stats.byTag["旅行场景"], 300); XCTAssertEqual(store.stats.byTag["便利店"], 400)
        store.selectedTags = ["旅行场景", "便利店"]
        XCTAssertEqual(store.stats.net, 100)
        store.tagMatch = "any"; XCTAssertEqual(store.stats.net, 600)
        store.tagMatch = "all"; store.selectedTags = ["旅行场景"]
        let c = try XCTUnwrap(store.records.flatMap(\.components).first { $0.id == "a" })
        store.setTags([], for: c)
        XCTAssertNil(store.error); XCTAssertEqual(store.stats.net, 200)
        await store.loadFixture(folder)
        XCTAssertEqual(store.stats.net, 200)
        store.selectedTags = []; XCTAssertEqual(store.stats.net, 600)
        XCTAssertEqual(store.records.flatMap(\.components).first { $0.id == "a" }?.tags, [])
    }
    func testOldReportWithoutTagsDecodesAndKeepsAmounts() throws {
        let data = Data(#"{"id":"old","title":"old","gross_cents":100,"refund_cents":30,"net_cents":70,"primary":"待分类","secondary":"待分类","classification_basis":"证据不足","included":true,"reason":""}"#.utf8)
        let c = try JSONDecoder().decode(FinancialComponent.self, from: data)
        XCTAssertTrue(c.tags.isEmpty); XCTAssertEqual(c.net_cents, 70)
    }
}
