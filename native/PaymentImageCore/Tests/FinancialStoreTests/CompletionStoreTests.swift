import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class CompletionStoreTests: XCTestCase {
    private func fixture() throws -> URL {
        try StoreFixtures.directory()
    }
    func testDraftSaveUndoReloadAndNetStayConsistent() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); let evidence = BrowserStore(); await store.loadFixture(root)
        store.completion.from = store.from; store.completion.to = store.to; store.completion.refresh(store, evidence)
        let entry = try XCTUnwrap(store.completion.entries.first { $0.component?.included == true && $0.missingCategory })
        let before = store.stats; let original = try XCTUnwrap(entry.component)
        var draft = try XCTUnwrap(store.completion.draft(entry)); draft.primary = "生产力工具"; draft.secondary = "设备"; draft.recurrence = "one_time"; draft.tags = ["验收"]
        store.completion.edit(entry, draft)
        XCTAssertEqual(store.report?.records.flatMap(\.components).first { $0.id == entry.id }, original)
        let succeeded = await store.saveCompletion(entry); XCTAssertTrue(succeeded); XCTAssertNil(store.error)
        XCTAssertEqual(store.stats.net, before.net); XCTAssertEqual(store.stats.gross, before.gross); XCTAssertEqual(store.stats.refunds, before.refunds)
        await store.loadFixture(root)
        XCTAssertEqual(store.report?.records.flatMap(\.components).first { $0.id == entry.id }?.tags, ["验收"])
        await store.undoCompletion(); XCTAssertNil(store.error)
        XCTAssertEqual(store.report?.records.flatMap(\.components).first { $0.id == entry.id }, original)
        XCTAssertNil(try CompletionOverrideFile.entry(entry.id, in: Data(contentsOf: root.appendingPathComponent("review-overrides.json"))))
        await store.loadFixture(root); XCTAssertEqual(store.stats.net, before.net)
    }
    func testFailedSaveKeepsDraftAndDoesNotAdvanceOrClaimSuccess() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); let evidence = BrowserStore(); await store.loadFixture(root)
        store.completion.from = store.from; store.completion.to = store.to; store.completion.refresh(store, evidence)
        let entry = try XCTUnwrap(store.completion.entries.first { $0.component != nil })
        var draft = try XCTUnwrap(store.completion.draft(entry)); draft.recurrence = "invalid"
        store.completion.edit(entry, draft); let before = store.report?.records
        let succeeded = await store.saveCompletion(entry); XCTAssertFalse(succeeded); XCTAssertNotNil(store.error)
        XCTAssertEqual(store.completion.draft(entry), draft); XCTAssertEqual(store.report?.records, before)
        XCTAssertFalse(store.completion.saved.contains(entry.id)); XCTAssertFalse(store.completionSaving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-overrides.json").path))
    }
    func testDeferIsReversibleAndDoesNotModifyTransactionFields() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); let evidence = BrowserStore(); await store.loadFixture(root)
        store.completion.from = store.from; store.completion.to = store.to; store.completion.refresh(store, evidence)
        let entry = try XCTUnwrap(store.completion.entries.first); let before = store.report?.records
        await store.completion.setDeferred(entry.id, value: true)
        XCTAssertTrue(store.completion.deferred.contains(entry.id)); XCTAssertFalse(store.completion.visible.contains { $0.id == entry.id })
        store.completion.mode = "暂放"; XCTAssertTrue(store.completion.visible.contains { $0.id == entry.id })
        await store.completion.setDeferred(entry.id, value: false)
        XCTAssertFalse(store.completion.deferred.contains(entry.id)); XCTAssertEqual(store.report?.records, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-overrides.json").path))
    }
    func testLinkedSaveAcrossDatesPreservesFactsAndUndoOnReload() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("financial-review.json")
        var report = try JSONDecoder().decode(FinancialReport.self, from: Data(contentsOf: url))
        let candidates = report.records.indices.filter { report.records[$0].components.count == 1 && !report.records[$0].non_consumption }
        let sourceIndex = try XCTUnwrap(candidates.first)
        let targetIndex = try XCTUnwrap(candidates.dropFirst().first)
        // Change only classification fields in synthetic, independent lifecycle records.
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
        var records = object["records"] as! [[String: Any]]
        for index in [sourceIndex, targetIndex] {
            var components = records[index]["components"] as! [[String: Any]]
            components[0]["title"] = "QA合成交通股份有限公司"
            components[0]["primary"] = "待分类"; components[0]["secondary"] = "待分类"
            components[0]["recurrence"] = "one_time"; components[0]["tags"] = ["原标签"]
            records[index]["components"] = components
        }
        records[targetIndex]["date"] = "2024-01-01"
        object["records"] = records
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        report = try JSONDecoder().decode(FinancialReport.self, from: Data(contentsOf: url))
        let source = report.records[sourceIndex].components[0], target = report.records[targetIndex].components[0]
        let store = FinancialStore(); let evidence = BrowserStore(); await store.loadFixture(root)
        store.completion.allDates = true; store.completion.refresh(store, evidence)
        let entry = try XCTUnwrap(store.completion.entries.first { $0.id == source.id })
        let before = store.report?.records
        var draft = CompletionDraft(source); draft.primary = "日常消费"; draft.secondary = "交通出行"; draft.tags = ["只属于来源"]; draft.recurrence = "recurring"
        store.completion.edit(entry, draft)
        let ok = await store.saveCompletion(entry); XCTAssertTrue(ok, store.error ?? "")
        XCTAssertTrue(store.completion.message.contains("已联动补齐 1 项"))
        await store.loadFixture(root)
        let linked = try XCTUnwrap(store.report?.records.flatMap(\.components).first { $0.id == target.id })
        XCTAssertEqual(linked.primary, "日常消费"); XCTAssertEqual(linked.secondary, "交通出行")
        XCTAssertEqual(linked.recurrence, "one_time"); XCTAssertEqual(linked.tags, ["原标签"])
        XCTAssertEqual(linked.gross_cents, target.gross_cents); XCTAssertEqual(linked.refund_cents, target.refund_cents)
        XCTAssertEqual(linked.included, target.included); XCTAssertEqual(linked.classification_basis, "同名商家联动")
        await store.undoCompletion(); XCTAssertNil(store.error); XCTAssertEqual(store.report?.records, before)
    }

    func testUnchangedSiblingConfirmationCompletesSiblingsAndSurvivesReload() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); let evidence = BrowserStore(); await store.loadFixture(root)
        store.completion.allDates = true; store.completion.refresh(store, evidence)
        let name = "Fixture coffee 订单详情"
        let entry = try XCTUnwrap(store.completion.entries.first { $0.component?.title == name })
        let before = try XCTUnwrap(store.report).records
        let siblings = before.flatMap(\.components).filter { $0.title == name }
        XCTAssertGreaterThan(siblings.count, 3)
        XCTAssertEqual(entry.component?.primary, "日常消费")
        XCTAssertEqual(entry.component?.secondary, "咖啡茶饮")
        // Save unchanged classification fields to confirm every same-name sibling.
        let ok = await store.saveCompletion(entry); XCTAssertTrue(ok, store.error ?? "")
        store.completion.refresh(store, evidence)
        XCTAssertFalse(store.completion.visible.contains { $0.component?.title == name })
        XCTAssertEqual(store.completion.saved.intersection(siblings.map(\.id)).count, siblings.count)
        await store.loadFixture(root); store.completion.refresh(store, evidence)
        XCTAssertFalse(store.completion.visible.contains { $0.component?.title == name })
        store.completion.mode = "已确认"
        XCTAssertEqual(store.completion.visible.filter { $0.component?.title == name }.count, siblings.count)
        for original in siblings {
            let current = try XCTUnwrap(store.report?.records.flatMap(\.components).first { $0.id == original.id })
            XCTAssertTrue(current.completionConfirmed)
            XCTAssertEqual(CompletionDraft(current), CompletionDraft(original))
            XCTAssertEqual(current.gross_cents, original.gross_cents); XCTAssertEqual(current.refund_cents, original.refund_cents)
        }
        await store.undoCompletion(); XCTAssertNil(store.error)
        store.completion.mode = "优先补全"; store.completion.refresh(store, evidence)
        XCTAssertTrue(store.completion.visible.contains { $0.component?.title == name })
        XCTAssertEqual(store.report?.records, before)
    }
    func testLegacySiblingReplayKeepsOneTimeLocalAndProtectsDrafts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); let evidence = BrowserStore(); await store.loadFixture(root)
        store.completion.allDates = true; store.completion.refresh(store, evidence)
        let name = "Fixture coffee 订单详情"
        let entries = store.completion.entries.filter { $0.component?.title == name }
        let source = try XCTUnwrap(entries.first), protected = try XCTUnwrap(entries.dropFirst().first)
        var edited = try XCTUnwrap(store.completion.draft(protected)); edited.tags = ["未保存草稿"]
        store.completion.edit(protected, edited)
        let previous = try XCTUnwrap(store.report).records
        let override = CategoryOverride(primary: "日常消费", secondary: "咖啡茶饮", recurrence: "one_time", tags: ["仅此笔"], classification_basis: "人工分类")
        try JSONEncoder().encode([source.id: override]).write(to: root.appendingPathComponent("review-overrides.json"))
        await store.loadFixture(root); await store.reconcileCompletion(); store.completion.refresh(store, evidence)
        let matches = try XCTUnwrap(store.report).records.flatMap(\.components).filter { $0.title == name }
        XCTAssertTrue(matches.first { $0.id == source.id }?.completionConfirmed == true)
        XCTAssertFalse(matches.first { $0.id == protected.id }?.completionConfirmed == true)
        for current in matches where current.id != source.id && current.id != protected.id {
            XCTAssertTrue(current.completionConfirmed)
            let original = try XCTUnwrap(previous.flatMap(\.components).first { $0.id == current.id })
            XCTAssertEqual(current.effectiveRecurrence, original.effectiveRecurrence); XCTAssertEqual(current.tags, original.tags)
        }
        let bytes = try Data(contentsOf: root.appendingPathComponent("review-overrides.json"))
        await store.loadFixture(root); await store.reconcileCompletion()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("review-overrides.json")), bytes, "Replay is idempotent and still protects the draft")
    }

}
