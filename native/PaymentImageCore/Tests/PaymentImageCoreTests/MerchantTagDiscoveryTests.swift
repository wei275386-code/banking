import XCTest
@testable import PaymentImageCore

final class MerchantTagDiscoveryTests: XCTestCase {
    private func fixture() throws -> (URL, FinancialLifecycle) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("merchant-tags-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let component = FinancialComponent(id: "meal", title: "外卖商品提及肯德基", gross_cents: 2350, refund_cents: 0, net_cents: 2350, primary: "餐饮", secondary: "外卖", classification_basis: "现有分类", included: true, reason: "", classification_keys: ["meal"], tags: ["外卖"])
        let record = FinancialLifecycle(id: "transaction", date: "2026-09-05", title: "合并扣款", status: "paid", account_views: [], evidence_keys: ["meal"], components: [component], events: [], trace_sources: [trace("meal", "上海宽娱数码科技有限公司")], user_relation: "self", non_consumption: false, unallocated_credit_cents: 0)
        return (root, record)
    }
    private func trace(_ id: String, _ merchant: String?, association: String = "linked", platform: String = "alipay", kind: String = "payment") -> TransactionTraceSource {
        .init(id: id, association: association, basis: "fixture", owner_id: nil, platform: platform, date: "2026-09-05", post_date: nil, merchant: merchant, title: "商品标题：肯德基", amount_cents: 2350, currency: "CNY", payment_method: nil, event_kind: kind, status: "paid", provider_reference: nil, merchant_reference: nil, source_name: nil, location: "", source_evidence: nil)
    }
    private func scan(_ record: FinancialLifecycle, _ rules: [MerchantTagRule], cached: [String: MerchantTagIdentity] = [:], document: Data = Data("{}".utf8)) throws -> MerchantTagScan {
        try MerchantTagDiscovery.scan(records: [record], rules: rules, cached: cached, document: document)
    }
    func testNormalizationKeepsIdentityAndOnlyRemovesKnownWrappers() throws {
        XCTAssertEqual(MerchantTagDiscovery.normalizedPayee("广东赛壹便利店有限公司 · 多点订单：123"), "广东赛壹便利店有限公司")
        XCTAssertEqual(MerchantTagDiscovery.normalizedPayee("美团 · 肯德基(合成甲店)-美团App-123456789012 外卖订单"), "肯德基")
        XCTAssertEqual(MerchantTagDiscovery.normalizedPayee("椰记手作·海南清补凉"), "椰记手作·海南清补凉")
        XCTAssertEqual(MerchantTagDiscovery.normalizedPayee("甲商家 · 乙服务"), "甲商家 · 乙服务")
        XCTAssertNotEqual(MerchantTagDiscovery.normalizedPayee("甲商家 · 乙服务"), MerchantTagDiscovery.normalizedPayee("甲商家 · 丙服务"))
        XCTAssertEqual(MerchantTagDiscovery.normalizedPayee("肯德基宅急送"), "肯德基宅急送")
        XCTAssertNotEqual(MerchantTagDiscovery.normalizedPayee("上海宽娱"), "哔哩哔哩")
        XCTAssertEqual(MerchantTagDiscovery.normalizedPayee("７－Eleven | APPLE PAY 123"), "7-Eleven")
    }
    func testOnlyOwnedLinkedMerchantsNotTitlesRefundsOrCandidates() throws {
        let (root, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let rules = [MerchantTagRule(payee: "肯德基", decision: .merchant, tag: "肯德基"), .init(payee: "上海宽娱数码科技有限公司", decision: .merchant, tag: "哔哩哔哩")]
        var record = original
        record.trace_sources?.append(contentsOf: [trace("candidate", "肯德基", association: "candidate"), trace("refund", "肯德基", kind: "refund"), trace("bank", "肯德基", platform: "bank")])
        XCTAssertEqual(try scan(record, rules).additions, ["meal": "哔哩哔哩"])
        record.trace_sources = [trace("product", nil)]
        XCTAssertTrue(try scan(record, rules).additions.isEmpty)
    }
    func testCombinedMealAndCardStaySeparateAndConflictNeverWrites() throws {
        let (root, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var record = original
        var card = original.components[0]
        // Decode the second component because identifiers are immutable.
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as! [String: Any]
        object["id"] = "card"; object["classification_keys"] = ["card"]; object["title"] = "超级吃货卡"; object["gross_cents"] = 10; object["net_cents"] = 10; object["tags"] = []
        card = try JSONDecoder().decode(FinancialComponent.self, from: JSONSerialization.data(withJSONObject: object))
        record.components.append(card)
        record.trace_sources?.append(trace("card", "超级吃货卡"))
        let rule = MerchantTagRule(payee: "上海宽娱数码科技有限公司", decision: .merchant, tag: "哔哩哔哩")
        XCTAssertEqual(try scan(record, [rule]).additions, ["meal": "哔哩哔哩"])
        record.components = [original.components[0]]
        let result = try scan(record, [rule])
        XCTAssertEqual(result.conflicts, 1); XCTAssertTrue(result.additions.isEmpty)
    }
    func testProcessedBooleanCachesEmptyResultsAndInvalidatesOnInputChange() throws {
        let (root, record) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("household.sqlite3")
        let db = try MerchantTagDatabase(url: url)
        let first = try scan(record, [], cached: db.identities(root: root.path, signature: "projection-v1"))
        XCTAssertEqual(first.processed, 1)
        try db.markProcessed(root: root.path, signature: "projection-v1", identities: first.newIdentities)
        let reopened = try MerchantTagDatabase(url: url)
        let cached = try reopened.identities(root: root.path, signature: "projection-v1")
        let second = try scan(record, [], cached: cached)
        XCTAssertEqual(second.processed, 0); XCTAssertEqual(second.reused, 1)
        XCTAssertEqual(second.candidates.first?.payee, first.candidates.first?.payee)
        XCTAssertTrue(try reopened.identities(root: root.path, signature: "projection-v2").isEmpty)
        XCTAssertTrue(try reopened.identities(root: "another-dataset", signature: "projection-v1").isEmpty)
        var empty = record; empty.trace_sources = []
        let emptyScan = try scan(empty, [])
        try db.markProcessed(root: root.path, signature: "projection-v2", identities: emptyScan.newIdentities)
        XCTAssertEqual(try scan(empty, [], cached: db.identities(root: root.path, signature: "projection-v2")).reused, 1)
    }
    func testRulesPersistOutsideDatasetAndSeedDoesNotOverwriteDecisions() throws {
        let (root, record) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rules.sqlite3"), db = try MerchantTagDatabase(url: root.appendingPathComponent("rules.sqlite3"))
        let seed = Data(#"{"decisions":{"上海宽娱数码科技有限公司":{"decision":"merchant","tag":"哔哩哔哩"},"不加":{"decision":"no_tag"},"待定":{"decision":"deferred"},"其他用户":{"decision":"not_merchant"}}}"#.utf8)
        try db.seed(seed)
        let rule = try XCTUnwrap(db.rules().first { $0.payee == "上海宽娱数码科技有限公司" })
        XCTAssertEqual(try scan(record, db.rules()).additions.count, 1)
        try db.save(.init(payee: rule.payee, decision: .no_tag), expected: rule)
        try db.seed(seed)
        let reopened = try MerchantTagDatabase(url: url)
        XCTAssertEqual(try reopened.rules().count, 4)
        XCTAssertTrue(try scan(record, reopened.rules()).additions.isEmpty)
        XCTAssertThrowsError(try db.save(rule, expected: rule))
        try db.save(.init(payee: rule.payee, decision: .deferred), expected: .init(payee: rule.payee, decision: .no_tag))
        XCTAssertEqual(try scan(record, db.rules()).candidates.first?.decision, .deferred)
    }
    func testOlderScanCannotCommitIntoNewSignatureContext() throws {
        let (root, record) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rules.sqlite3")
        let older = try MerchantTagDatabase(url: url), newer = try MerchantTagDatabase(url: url)
        _ = try older.identities(root: root.path, signature: "old")
        let result = try scan(record, [])
        _ = try newer.identities(root: root.path, signature: "new")
        XCTAssertThrowsError(try older.markProcessed(root: root.path, signature: "old", identities: result.newIdentities))
        XCTAssertTrue(try newer.identities(root: root.path, signature: "new").isEmpty)
        try newer.markProcessed(root: root.path, signature: "new", identities: result.newIdentities)
        XCTAssertEqual(try newer.identities(root: root.path, signature: "new").count, 1)
    }
    func testUnionOneHistoryIdempotenceRemovalReaddAndConflict() throws {
        let (root, record) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let projection = Data("projection fixture".utf8)
        try projection.write(to: root.appendingPathComponent("financial-review.json"))
        let digest = ReviewSyncIO.digest(projection)
        let document = Data(#"{"meal":{"primary":"餐饮","secondary":"外卖","tags":["外卖"],"unknown":"keep"}}"#.utf8)
        try document.write(to: root.appendingPathComponent("review-overrides.json"))
        let updated = try CompletionOverrideFile.appendDiscoveryTags(root: root, records: [record], additions: ["meal": "哔哩哔哩"], expectedDocument: document, expectedProjection: digest)
        var values = try JSONDecoder().decode([String: CategoryOverride].self, from: updated)
        XCTAssertEqual(Set(values["meal"]?.tags ?? []), ["外卖", "哔哩哔哩"])
        XCTAssertTrue(String(decoding: updated, as: UTF8.self).contains("keep"))
        let history = root.appendingPathComponent("review-history")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.path).count, 1)
        var effective = record; effective.components[0].tags = values["meal"]!.tags!
        let again = try CompletionOverrideFile.appendDiscoveryTags(root: root, records: [effective], additions: [:], expectedDocument: updated, expectedProjection: digest)
        XCTAssertEqual(again, updated)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.path).count, 1)
        XCTAssertThrowsError(try CompletionOverrideFile.appendDiscoveryTags(root: root, records: [record], additions: ["meal": "其他"], expectedDocument: document, expectedProjection: digest))
        let source = effective.components[0]
        var draft = CompletionDraft(source); draft.tags = ["外卖"]
        let saved = try CompletionOverrideFile.saveLinked(root: root, source: source, draft: draft, targets: [], expectedDocument: updated)
        values = try JSONDecoder().decode([String: CategoryOverride].self, from: saved.document)
        XCTAssertEqual(values["meal"]?.suppressed_discovery_tags, ["哔哩哔哩"])
        let rules = [MerchantTagRule(payee: "上海宽娱数码科技有限公司", decision: .merchant, tag: "哔哩哔哩")]
        XCTAssertTrue(try scan(record, rules, document: saved.document).additions.isEmpty)
        draft.tags.append("哔哩哔哩")
        let readd = try CompletionOverrideFile.save(root: root, id: source.id, draft: draft, expected: saved.saved[source.id]!, previousTags: ["外卖"])
        XCTAssertEqual(try JSONDecoder().decode([String: CategoryOverride].self, from: readd.document)["meal"]?.suppressed_discovery_tags, [])
        XCTAssertThrowsError(try CompletionOverrideFile.appendDiscoveryTags(root: root, records: [record], additions: ["meal": "其他"], expectedDocument: readd.document, expectedProjection: "stale"))
        XCTAssertThrowsError(try CompletionOverrideFile.appendDiscoveryTags(root: root, records: [record], additions: [:], expectedDocument: readd.document, expectedProjection: "stale"))
    }
    func testLargeScanReusesAllIdentities() throws {
        let (root, record) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var records = [FinancialLifecycle]()
        for index in 0..<10_000 {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
            object["id"] = "r-\(index)"
            var components = object["components"] as! [[String: Any]]; components[0]["id"] = "c-\(index)"; object["components"] = components
            records.append(try JSONDecoder().decode(FinancialLifecycle.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        let start = Date()
        let first = try MerchantTagDiscovery.scan(records: records, rules: [], cached: [:], document: Data("{}".utf8))
        let initial = Date().timeIntervalSince(start)
        let warmStart = Date()
        let second = try MerchantTagDiscovery.scan(records: records, rules: [], cached: first.newIdentities, document: Data("{}".utf8))
        let warm = Date().timeIntervalSince(warmStart)
        XCTAssertEqual(first.processed, 10_000); XCTAssertEqual(second.reused, 10_000); XCTAssertEqual(second.processed, 0)
        XCTAssertEqual(second.candidates.first?.count, 10_000)
        print("merchant-discovery-benchmark components=10000 cold_seconds=\(initial) warm_seconds=\(warm)")
    }
}
