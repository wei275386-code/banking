import XCTest
@testable import PaymentImageCore

final class CategoryHeuristicsTests: XCTestCase {
    private func component(_ id: String, _ title: String, primary: String = "待分类", secondary: String = "待分类") -> FinancialComponent {
        FinancialComponent(id: id, title: title, gross_cents: 100, refund_cents: 0, net_cents: 100, primary: primary, secondary: secondary, classification_basis: "test", included: true, reason: "", recurrence: "one_time", tags: ["保留"])
    }
    private func record(_ components: [FinancialComponent]) -> FinancialLifecycle {
        FinancialLifecycle(id: "r", date: "2025-01-01", title: "test", status: "paid", account_views: [], evidence_keys: [], components: components, events: [], user_relation: "self", non_consumption: false, unallocated_credit_cents: 0)
    }
    private func draft(_ c: FinancialComponent) -> CompletionDraft {
        var d = CompletionDraft(c); d.primary = "日常"; d.secondary = "交通"; return d
    }
    func testExactPropagationExcludesClassifiedDraftsAndConflicts() {
        let a = component("a", "合成交通股份有限公司"), b = component("b", "合成交通股份有限公司"), c = component("c", "合成交通股份有限公司（APP）充值")
        XCTAssertEqual(CategoryHeuristics.linkedTargets(source: a, draft: draft(a), records: [record([a,b,c])]).map(\.id), ["b"])
        XCTAssertTrue(CategoryHeuristics.linkedTargets(source: a, draft: draft(a), records: [record([a,b])], excluding: ["b"]).isEmpty)
        let conflict = component("x", a.title, primary: "日常", secondary: "餐饮")
        XCTAssertTrue(CategoryHeuristics.linkedTargets(source: a, draft: draft(a), records: [record([a,b,conflict])]).isEmpty)
        XCTAssertTrue(CategoryHeuristics.linkedTargets(source: a, draft: CompletionDraft(a), records: [record([a,b])]).isEmpty)
    }
    func testPlatformsAndAmbiguousNamesNeverPropagate() {
        for title in ["淘宝", "淘宝平台商家", "京东商城平台商户", "MEITUAN CHN CN", "银联转账（云闪付）", "上海拉扎斯信息科技有限…", "sk**店", "微信支付", "May · 收钱码收款"] {
            let a = component("a", title), b = component("b", title)
            XCTAssertTrue(CategoryHeuristics.linkedTargets(source: a, draft: draft(a), records: [record([a,b])]).isEmpty, title)
        }
    }
    func testFuzzyRankingAndEqualScoreConflicts() {
        let a = component("a", "合成交通股份有限公司"), b = component("b", "合成交通有限公司", primary: "日常", secondary: "交通"), c = component("c", "合成餐厅", primary: "日常", secondary: "餐饮")
        let taxonomy = [FinancialCategory(primary: "日常", secondaries: ["交通", "餐饮"])]
        let best = CategoryHeuristics.suggestion(for: a, records: [record([a,c,b])], taxonomy: taxonomy)
        XCTAssertEqual(best?.source.id, "b"); XCTAssertEqual(best?.score, 99)
        let conflict = component("d", b.title, primary: "日常", secondary: "餐饮")
        XCTAssertTrue(CategoryHeuristics.suggestion(for: a, records: [record([conflict,b])], taxonomy: taxonomy)?.ambiguous == true)
        XCTAssertEqual(CategoryHeuristics.similarity("A[1]Shop", "A[1]Shop"), 100)
        XCTAssertLessThan(CategoryHeuristics.similarity("门店123", "门店456"), 100)
    }
    func testAtomicSaveUndoMetadataAndStaleBatch() throws {
        let root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("review-overrides.json")
        let original = Data(#"{"b":{"primary":"待分类","secondary":"待分类","recurrence":"one_time","tags":["保留"],"note":"未知备注"}}"#.utf8)
        try original.write(to: path)
        let a = component("a", "合成交通股份有限公司"), b = component("b", a.title)
        let result = try CompletionOverrideFile.saveLinked(root: root, source: a, draft: draft(a), targets: [b], expectedDocument: original)
        let saved = try JSONSerialization.jsonObject(with: result.document) as! [String: [String: Any]]
        XCTAssertEqual(saved["b"]?["recurrence"] as? String, "one_time")
        XCTAssertEqual(saved["b"]?["note"] as? String, "未知备注")
        XCTAssertEqual(saved["b"]?["tags"] as? [String], ["保留"])
        XCTAssertEqual(saved["b"]?["classification_basis"] as? String, "同名商家联动")
        XCTAssertThrowsError(try CompletionOverrideFile.saveLinked(root: root, source: a, draft: draft(a), targets: [b], expectedDocument: original))
        XCTAssertEqual(try Data(contentsOf: path), result.document)
        var changed = saved; changed["b"]?["secondary"] = "餐饮"
        try JSONSerialization.data(withJSONObject: changed).write(to: path)
        XCTAssertThrowsError(try CompletionOverrideFile.restoreLinked(root: root, previous: result.previous, expected: result.saved, dependencies: [:]))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]).count, 2)
        try result.document.write(to: path)
        let undo = try CompletionOverrideFile.restoreLinked(root: root, previous: result.previous, expected: result.saved, dependencies: [:])
        XCTAssertNil(try CompletionOverrideFile.entry("a", in: undo.document))
        XCTAssertEqual(try CompletionOverrideFile.entry("b", in: undo.document), try CompletionOverrideFile.entry("b", in: original))
    }
    func testConfirmationPlanningDoesNotWriteAndCommitRejectsNewerSave() throws {
        let root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("review-overrides.json")
        let source = component("source", "合成交通股份有限公司", primary: "日常", secondary: "交通")
        let target = component("target", source.title)
        let manual = CategoryOverride(primary: source.primary, secondary: source.secondary, recurrence: source.recurrence, tags: source.tags, classification_basis: "人工分类")
        let original = try JSONEncoder().encode([source.id: manual]); try original.write(to: path)
        let plan = try XCTUnwrap(CompletionOverrideFile.prepareConfirmed(records: [record([source, target])], expectedDocument: original))
        XCTAssertEqual(try Data(contentsOf: path), original)
        let edited = CategoryOverride(primary: source.primary, secondary: source.secondary, tags: ["扫描期间保存"], classification_basis: "人工分类")
        let newer = try JSONEncoder().encode([source.id: edited]); try newer.write(to: path)
        XCTAssertThrowsError(try CompletionOverrideFile.applyConfirmed(root: root, plan: plan))
        XCTAssertEqual(try Data(contentsOf: path), newer)
    }
    @MainActor func testLinkedBatchAndUndoReachAnotherClient() async throws {
        let owner = ReviewFamilyHostTests(), f = try owner.fixture(), remote = owner.remote(f)
        let source = component("source", "合成交通股份有限公司"), target = component("target", source.title)
        try HouseholdWorkBackupTests().edit(f.paths) { tx, token in
            let file = try tx.file("review/financial-review.json", token: token)
            var report = try JSONDecoder().decode(FinancialReport.self, from: WorkspaceIO.read(file))
            report.records = [record([source, target])]
            try WorkspaceIO.atomicWrite(JSONEncoder().encode(report), to: file)
        }
        _ = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        let helper = ReviewFamilyClientSessionTests(), a = try helper.client(f.paths), b = try helper.client(f.paths)
        defer { f.remove(); for url in [remote, a.workspace, b.workspace] { try? FileManager.default.removeItem(at: url) } }
        var ah = try helper.connect(a, remote: remote); _ = try helper.connect(b, remote: remote)
        let (saved, edited) = try ReviewFamilyClientSession.edit(paths: a, expected: ah) { root, _ in
            try CompletionOverrideFile.saveLinked(root: root, source: source, draft: draft(source), targets: [target], expectedDocument: Data(contentsOf: root.appendingPathComponent("review-overrides.json")))
        }
        ah = edited
        try await ReviewFamilyClientSession.transfer(paths: a); _ = try await ReviewFamilyHost.synchronize(paths: f.paths)
        let bh = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: b))
        let received = try JSONDecoder().decode([String: CategoryOverride].self, from: WorkspaceIO.read(bh.review.appendingPathComponent("review-overrides.json")))
        XCTAssertEqual(received["source"]?.secondary, "交通"); XCTAssertEqual(received["target"]?.secondary, "交通")
        XCTAssertEqual(received["target"]?.classification_basis, "同名商家联动")
        ah = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: a))
        _ = try ReviewFamilyClientSession.edit(paths: a, expected: ah) { root, _ in
            try CompletionOverrideFile.restoreLinked(root: root, previous: saved.previous, expected: saved.saved, dependencies: [:])
        }
        try await ReviewFamilyClientSession.transfer(paths: a); _ = try await ReviewFamilyHost.synchronize(paths: f.paths)
        let restored = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: b))
        let values = try JSONDecoder().decode([String: CategoryOverride].self, from: WorkspaceIO.read(restored.review.appendingPathComponent("review-overrides.json")))
        XCTAssertTrue(values.isEmpty)
    }

    func testConfirmationFingerprintInvalidatesWhenFieldsChange() {
        var c = component("jpg", "Synthetic coffee 合成甲店", primary: "日常", secondary: "咖啡")
        c.completion_confirmation = CompletionConfirmation(draft: CompletionDraft(c), origin: "linked", sourceID: "source")
        XCTAssertTrue(c.completionConfirmed)
        c.tags.append("修改后的标签"); XCTAssertFalse(c.completionConfirmed)
        c.completion_confirmation = CompletionConfirmation(draft: CompletionDraft(c), origin: "field_edit")
        XCTAssertFalse(c.completionConfirmed)
    }
    func testAlreadyClassifiedSameNameNeedsConfirmationButPlatformsDoNot() {
        let a = component("a", "Synthetic coffee 合成甲店", primary: "日常", secondary: "咖啡")
        let b = component("b", a.title, primary: a.primary, secondary: a.secondary)
        XCTAssertEqual(CategoryHeuristics.linkedTargets(source: a, draft: CompletionDraft(a), records: [record([a,b])]).map(\.id), ["b"])
        let platform = component("p", "淘宝平台商户", primary: "日常", secondary: "咖啡")
        let twin = component("q", platform.title, primary: "日常", secondary: "咖啡")
        XCTAssertTrue(CategoryHeuristics.linkedTargets(source: platform, draft: CompletionDraft(platform), records: [record([platform,twin])]).isEmpty)
    }

    func testKnownOrderWrappersPreserveMerchantAndBranch() {
        let merchant = CategoryHeuristics.merchantName("Synthetic coffee（合成甲店） 订单详情")
        XCTAssertEqual(CategoryHeuristics.merchantName("Synthetic coffee（合成甲店）-\(String(repeating: "1", count: 19))"), merchant)
        XCTAssertEqual(CategoryHeuristics.merchantName("美团 · Synthetic coffee（合成甲店）-美团App-\(String(repeating: "2", count: 32))"), merchant)
        XCTAssertEqual(CategoryHeuristics.merchantName("淘宝闪购 · Synthetic coffee(合成甲店)外卖订单"), merchant)
        XCTAssertNotEqual(CategoryHeuristics.merchantName("Synthetic coffee（合成乙店） 订单详情"), merchant)
        XCTAssertNotEqual(CategoryHeuristics.merchantName("合成餐饮管理有限公司 · JPG"), merchant)
        XCTAssertFalse(CategoryHeuristics.blocksAutomation("淘宝闪购 · Synthetic coffee(合成甲店)外卖订单"))
        XCTAssertTrue(CategoryHeuristics.blocksAutomation("美团 · JPG-\(String(repeating: "3", count: 32))"))
        XCTAssertTrue(CategoryHeuristics.blocksAutomation("淘宝平台商户"))
        XCTAssertTrue(CategoryHeuristics.blocksAutomation("APPLE.COM/US.."))
    }

}
