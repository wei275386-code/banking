import XCTest
@testable import EvidenceBrowser
@testable import PaymentImageCore

@MainActor final class MerchantTagStoreTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("merchant-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var object = try JSONSerialization.jsonObject(with: StoreFixtures.data("financial-review.json")) as! [String: Any]
        let records = object["records"] as! [[String: Any]]
        var one = records.first { !($0["non_consumption"] as? Bool ?? true) && !($0["components"] as! [[String: Any]]).isEmpty }!
        var component = (one["components"] as! [[String: Any]])[0]
        component["id"] = "qa:meal"; component["classification_keys"] = ["qa:meal"]
        component["gross_cents"] = 2350; component["net_cents"] = 2350; component["refund_cents"] = 0
        component["tags"] = ["外卖"]
        component.removeValue(forKey: "completion_confirmation")
        var trace: [String: Any] = ["id": "qa:meal", "association": "linked", "basis": "fixture", "platform": "alipay", "date": "2026-09-05", "merchant": "上海宽娱数码科技有限公司", "amount_cents": 2350, "currency": "CNY", "event_kind": "payment", "status": "paid", "location": "fixture"]
        one["id"] = "qa:transaction"; one["date"] = "2026-09-05"; one["components"] = [component]; one["trace_sources"] = [trace]
        one.removeValue(forKey: "excluded_from_completion_and_statistics")
        var two = one
        component["id"] = "qa:second"; component["classification_keys"] = ["qa:second"]
        trace["id"] = "qa:second"
        two["id"] = "qa:transaction2"; two["components"] = [component]; two["trace_sources"] = [trace]
        object["records"] = [one, two]; object["source_record_sets"] = []; object["source_record_set_candidates"] = []; object["refund_candidates"] = []
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("financial-review.json"))
        return root
    }
    func testCandidateConfirmBackfillReuseRemovalAndRuleDisable() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore()
        store.discoveryDatabaseURL = root.appendingPathComponent("household/rules.sqlite3")
        await store.loadFixture(root)
        await store.discoverMerchantTags()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.discoveryCandidates.first?.count, 2)
        let originalFacts = try XCTUnwrap(store.report).records.map { ($0.components[0].gross_cents, $0.components[0].net_cents) }
        await store.discoverMerchantTags(decision: .init(payee: "上海宽娱数码科技有限公司", decision: .merchant, tag: "哔哩哔哩"))
        XCTAssertNil(store.error)
        XCTAssertTrue(store.report!.records.allSatisfy { Set($0.components[0].tags) == ["外卖", "哔哩哔哩"] })
        let firstWrite = try Data(contentsOf: root.appendingPathComponent("review-overrides.json"))
        let history = root.appendingPathComponent("review-history")
        let count = try FileManager.default.contentsOfDirectory(atPath: history.path).count
        await store.discoverMerchantTags()
        XCTAssertTrue(store.discoveryMessage.contains("新处理 0 项，复用 2 项"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("review-overrides.json")), firstWrite)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.path).count, count)
        let component = store.report!.records[0].components[0]
        store.setTags(["外卖"], for: component)
        await store.discoverMerchantTags(force: true)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.report!.records[0].components[0].tags, ["外卖"])
        XCTAssertEqual(store.overrides[component.id]?.suppressed_discovery_tags, ["哔哩哔哩"])
        store.setTags(["外卖", "哔哩哔哩"], for: store.report!.records[0].components[0])
        XCTAssertEqual(store.overrides[component.id]?.suppressed_discovery_tags, [])
        await store.discoverMerchantTags(decision: .init(payee: "上海宽娱数码科技有限公司", decision: .no_tag))
        XCTAssertNil(store.error)
        XCTAssertTrue(store.report!.records.allSatisfy { $0.components[0].tags.contains("哔哩哔哩") })
        for (i, record) in store.report!.records.enumerated() {
            XCTAssertEqual(record.components[0].gross_cents, originalFacts[i].0)
            XCTAssertEqual(record.components[0].net_cents, originalFacts[i].1)
        }
    }
}
