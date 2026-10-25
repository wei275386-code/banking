import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class TransactionFactTests: XCTestCase {
    func testFactDecisionRoundTripPreservesMeaningWithoutFreeText() throws {
        let source = try record("current")
        var review = try TransactionFactReview(record: source); review.disposition = .include
        let clean = try TransactionFacts.validated(review, source: source, records: [source], cutoff: "2026-09-13")
        let bytes = try JSONEncoder().encode(clean), object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        XCTAssertNil(object["note"])
        let decoded = try JSONDecoder().decode(TransactionFactReview.self, from: bytes)
        XCTAssertEqual(try TransactionFacts.validated(decoded, source: source, records: [source], cutoff: "2026-09-13").disposition, .include)
        XCTAssertEqual(decoded.signature, clean.signature)
    }
    func testPaymentDisplayProjectionPreservesRawFactSignatureAndLegacyFallback() throws {
        var source = try record("projection")
        let signature = try TransactionFacts.signature(source)
        XCTAssertEqual(source.paymentEvents, source.events)
        source.payment_events = [FinancialEvent(id: "merged", date: "2026-02-24", kind: "payment", source: "ApplePay", amount_cents: 3359, status: "同一次付款")]
        XCTAssertEqual(source.paymentEvents.count, 1)
        XCTAssertEqual(source.paymentEvents[0].source, "ApplePay")
        XCTAssertEqual(try TransactionFacts.signature(source), signature)
        let roundtrip = try JSONDecoder().decode(FinancialLifecycle.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(roundtrip.paymentEvents, source.paymentEvents)
        XCTAssertEqual(roundtrip.events, source.events)
    }
    func testAgencyReceiptSurvivesAmountReviewAndCodableRoundtrip() throws {
        var source = try record("agency", gross: 529900, included: true)
        let signature = try TransactionFacts.signature(source)
        source.components[0].reimbursement_cents = 530000
        source.components[0].net_cents = -100
        XCTAssertEqual(try TransactionFacts.signature(source), signature)
        let decoded = try JSONDecoder().decode(FinancialLifecycle.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(decoded.components[0].reimbursement_cents, 530000)
        let (root, original) = try fixture([source])
        defer { try? FileManager.default.removeItem(at: root) }
        var report = original
        var review = try TransactionFactReview(record: source)
        review.amounts[source.components[0].id] = FactAmounts(gross: 529900, refund: 0)
        let override = try JSONDecoder().decode(CategoryOverride.self, from: ReviewSyncIO.json(["primary": "亲友代付", "secondary": "代购", "transaction_facts": try JSONSerialization.jsonObject(with: JSONEncoder().encode(review))]))
        TransactionFacts.apply([source.reviewOverrideKey: override], to: &report)
        XCTAssertEqual(report.records[0].components[0].net_cents, -100)
        XCTAssertEqual(report.records[0].components[0].refund_cents, 0)
    }
    private func record(_ id: String, gross: Int = 3359, included: Bool = false, credit: Int = 0) throws -> FinancialLifecycle {
        let object: [String: Any] = ["id": id, "date": "2026-02-24", "title": id, "status": "支付成立", "account_views": ["0786"], "evidence_keys": [id],
            "components": [["id": id + ":item", "title": id, "gross_cents": gross, "refund_cents": 0, "net_cents": gross, "primary": "日常消费", "secondary": "餐饮", "classification_basis": "规则推断", "included": included, "reason": included ? "" : "录屏记录与已有来源的关联待确定；年份筛选与日期星期不一致"]],
            "events": [["id": id, "date": "2026-02-24", "kind": credit > 0 ? "bank_credit" : "payment", "source": "bank", "amount_cents": credit > 0 ? credit : gross, "status": "原始证据"]],
            "user_relation": "unknown", "non_consumption": false, "unallocated_credit_cents": credit]
        return try JSONDecoder().decode(FinancialLifecycle.self, from: ReviewSyncIO.json(object))
    }
    private func fixture(_ records: [FinancialLifecycle]) throws -> (URL, FinancialReport) {
        var report = try StoreFixtures.report()
        report.records = records
        report.source_record_sets = nil; report.source_record_set_candidates = nil
        let root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("fact-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent("financial-review.json"))
        return (root, report)
    }
    func testIncludeUpdatesStatisticsPersistsAndResetKeepsOriginalEvidence() async throws {
        let source = try record("source")
        let (root, _) = try fixture([source]); defer { try? FileManager.default.removeItem(at: root) }
        let raw = try Data(contentsOf: root.appendingPathComponent("financial-review.json"))
        let store = FinancialStore(); await store.loadFixture(root)
        XCTAssertEqual(store.stats.net, 0)
        var review = try TransactionFactReview(record: source)
        review.disposition = .include
        review.date = "2026-03-01"; review.userID = "QA本人"; review.account = "QA账户"
        review.amounts[source.components[0].id] = FactAmounts(gross: 5000, refund: 1000)
        let saved = await store.saveFacts(try XCTUnwrap(store.beginFactEdit(source)), review: review); XCTAssertTrue(saved, store.error ?? "")
        XCTAssertEqual(store.stats.net, 4000); XCTAssertEqual(store.stats.refunds, 1000)
        XCTAssertEqual(store.stats.byMonth["2026-03"], 4000); XCTAssertTrue(store.accounts.contains("QA账户"))
        await store.loadFixture(root)
        let effective = try XCTUnwrap(store.report?.records.first)
        XCTAssertEqual(effective.user_id, "QA本人"); XCTAssertEqual(effective.date, "2026-03-01")
        XCTAssertEqual(effective.events, source.events)
        let reset = await store.saveFacts(try XCTUnwrap(store.beginFactEdit(effective)), review: nil); XCTAssertTrue(reset)
        XCTAssertEqual(store.stats.net, 0); XCTAssertEqual(store.report?.records.first?.date, source.date)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("financial-review.json")), raw)
    }
    func testIdentityAloneDoesNotForceStatisticalInclusionAndDateValidation() async throws {
        let source = try record("source"); let (root, _) = try fixture([source]); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); await store.loadFixture(root)
        var review = try TransactionFactReview(record: source); review.userID = "本人"
        let saved = await store.saveFacts(try XCTUnwrap(store.beginFactEdit(source)), review: review); XCTAssertTrue(saved)
        XCTAssertEqual(store.stats.net, 0); XCTAssertEqual(store.stats.pending, 3359)
        review.date = "2026-02-30"
        XCTAssertThrowsError(try TransactionFacts.validated(review, source: source, records: [source], cutoff: "2026-09-13"))
        review.date = "2027-01-01"; review.disposition = .include
        XCTAssertThrowsError(try TransactionFacts.validated(review, source: source, records: [source], cutoff: "2026-09-13"))
    }
    func testEvidenceChangesInvalidateReviewAndReturnToFactsQueue() throws {
        let source = try record("source"), changed = try record("source", gross: 4000)
        let (root, base) = try fixture([source]); defer { try? FileManager.default.removeItem(at: root) }
        var review = try TransactionFactReview(record: source); review.disposition = .include
        var report = base; report.records = [changed]
        FinancialStore.applyCompletion([source.reviewOverrideKey: CategoryOverride(primary: "", secondary: "", transaction_facts: review)], to: &report)
        XCTAssertEqual(FinancialMath.statistics(report.records).net, 0)
        XCTAssertTrue(report.records[0].fact_review_status?.contains("待复核") == true)
        XCTAssertTrue(CompletionQueue.build(report.records, from: "", to: "9999")[0].factsPending)
        var classified = source; classified.components[0].tags = ["新标签"]; classified.components[0].primary = "医疗健康"
        XCTAssertEqual(try TransactionFacts.signature(source), try TransactionFacts.signature(classified))
    }
    func testDuplicateKeepsTargetOnceAndRejectsCycles() throws {
        let source = try record("source", included: true), target = try record("target", included: true)
        let (root, base) = try fixture([source, target]); defer { try? FileManager.default.removeItem(at: root) }
        var first = try TransactionFactReview(record: source); first.disposition = .duplicate; first.targetID = target.id; first.targetSignature = try TransactionFacts.signature(target)
        let value = CategoryOverride(primary: "", secondary: "", transaction_facts: first)
        var report = base; FinancialStore.applyCompletion([source.reviewOverrideKey: value], to: &report)
        XCTAssertEqual(FinancialMath.statistics(report.records).net, 3359); XCTAssertTrue(report.records[0].reviewExcluded)
        var second = try TransactionFactReview(record: target); second.disposition = .duplicate; second.targetID = source.id; second.targetSignature = try TransactionFacts.signature(source)
        report = base
        FinancialStore.applyCompletion([source.reviewOverrideKey: value, target.reviewOverrideKey: CategoryOverride(primary: "", secondary: "", transaction_facts: second)], to: &report)
        XCTAssertFalse(report.records[0].reviewExcluded); XCTAssertFalse(report.records[1].reviewExcluded)
        XCTAssertTrue(report.records.allSatisfy { $0.fact_review_status?.contains("重新选择") == true })
    }
    func testRefundLinksDeductOnceAndOverRefundRemainsPending() throws {
        let purchase = try record("purchase", gross: 10000, included: true)
        let first = try record("refund-1", gross: 0, credit: 6000), second = try record("refund-2", gross: 0, credit: 6000)
        let (root, base) = try fixture([purchase, first, second]); defer { try? FileManager.default.removeItem(at: root) }
        func review(_ source: FinancialLifecycle) throws -> CategoryOverride {
            var value = try TransactionFactReview(record: source); value.disposition = .refund
            value.targetID = purchase.components[0].id; value.targetSignature = try TransactionFacts.signature(purchase); value.refundCents = 6000
            return CategoryOverride(primary: "", secondary: "", transaction_facts: value)
        }
        var report = base; FinancialStore.applyCompletion([first.reviewOverrideKey: try review(first)], to: &report)
        XCTAssertEqual(FinancialMath.statistics(report.records).net, 4000)
        XCTAssertEqual(report.records[1].unallocated_credit_cents, 0); XCTAssertTrue(report.records[1].non_consumption)
        FinancialStore.applyCompletion([first.reviewOverrideKey: try review(first)], to: &report)
        // Real store always rebuilds from base; a target's changed evidence causes
        // a repeated projection on an already-projected report to stay pending.
        XCTAssertEqual(FinancialMath.statistics(report.records).net, 4000)
        report = base; FinancialStore.applyCompletion([first.reviewOverrideKey: try review(first), second.reviewOverrideKey: try review(second)], to: &report)
        XCTAssertEqual(FinancialMath.statistics(report.records).net, 10000)
        XCTAssertEqual(FinancialMath.statistics(report.records).unallocatedCredits, 12000)
        XCTAssertTrue(report.records[1].fact_review_status?.contains("合计超过") == true)
    }
    func testRefundDateCorrectionsAndConfirmedNonConsumptionQueue() throws {
        let purchase = try record("purchase", gross: 10000, included: true)
        let refund = try record("refund", gross: 0, credit: 2500)
        let (root, base) = try fixture([purchase, refund]); defer { try? FileManager.default.removeItem(at: root) }
        var link = try TransactionFactReview(record: refund); link.disposition = .refund
        link.targetID = purchase.components[0].id; link.targetSignature = try TransactionFacts.signature(purchase); link.refundCents = 2500
        var purchaseReview = try TransactionFactReview(record: purchase); purchaseReview.date = "2026-03-01"
        var report = base
        FinancialStore.applyCompletion([refund.reviewOverrideKey: CategoryOverride(primary: "", secondary: "", transaction_facts: link), purchase.reviewOverrideKey: CategoryOverride(primary: "", secondary: "", transaction_facts: purchaseReview)], to: &report)
        XCTAssertEqual(FinancialMath.statistics(report.records).net, 10000)
        XCTAssertTrue(report.records[1].fact_review_status?.contains("日期冲突") == true)
        link.date = "2027-01-01"
        XCTAssertThrowsError(try TransactionFacts.validated(link, source: refund, records: base.records, cutoff: base.cutoff))
        var nonConsumption = try TransactionFactReview(record: refund); nonConsumption.disposition = .nonConsumption
        report = base
        FinancialStore.applyCompletion([refund.reviewOverrideKey: CategoryOverride(primary: "", secondary: "", transaction_facts: nonConsumption)], to: &report)
        let entry = try XCTUnwrap(CompletionQueue.build(report.records, from: "", to: "9999").first { $0.record.id == refund.id })
        XCTAssertFalse(entry.factsPending); XCTAssertTrue(entry.record.factReviewConfirmed)
        var changedAccount = purchase; changedAccount.payment_accounts = ["其他账户"]
        XCTAssertNotEqual(try TransactionFacts.signature(purchase), try TransactionFacts.signature(changedAccount))
    }
    func testFactCASPreservesUnknownMetadataAndRefusesStaleForm() throws {
        let source = try record("source"); let (root, _) = try fixture([source]); defer { try? FileManager.default.removeItem(at: root) }
        let document = try ReviewSyncIO.json([source.reviewOverrideKey: ["primary": "", "secondary": "", "extra": "保留其他字段"]])
        try document.write(to: root.appendingPathComponent("review-overrides.json"))
        let expected = try CompletionOverrideFile.entry(source.reviewOverrideKey, in: document)
        let review = try TransactionFactReview(record: source)
        let write = try CompletionOverrideFile.saveFacts(root: root, record: source, review: review, expected: expected)
        let object = try JSONSerialization.jsonObject(with: write.document) as! [String: [String: Any]]
        XCTAssertEqual(object[source.reviewOverrideKey]?["extra"] as? String, "保留其他字段")
        XCTAssertThrowsError(try CompletionOverrideFile.saveFacts(root: root, record: source, review: nil, expected: expected))
    }
    func testFactsSyncAndConcurrentDecisionsStayAtomic() async throws {
        let source = try record("source"), (review, _) = try fixture([source])
        defer { try? FileManager.default.removeItem(at: review) }
        let family = try await CurrentFamilyStoreFixture.make(review: review); defer { family.cleanup() }
        var left = try TransactionFactReview(record: source); left.disposition = .include; left.userID = "本人"
        var right = left; right.disposition = .exclude
        try await family.edit(family.a) { root in _ = try CompletionOverrideFile.saveFacts(root: root, record: source, review: left, expected: nil) }
        try await family.edit(family.b) { root in _ = try CompletionOverrideFile.saveFacts(root: root, record: source, review: right, expected: nil) }
        try await ReviewFamilyClientSession.transfer(paths: family.a)
        try await family.sync(from: family.b)
        let key = "override/" + source.reviewOverrideKey + "/transaction_facts"
        let observed = try XCTUnwrap(ReviewFamilyClientSession.read(paths: family.b))
        let options = try XCTUnwrap(observed.conflicts[key])
        XCTAssertEqual(options.count, 2)
        for option in options {
            let value = try JSONDecoder().decode(TransactionFactReview.self, from: Data(option.utf8))
            XCTAssertTrue(value == left || value == right)
        }
        let resolved = try ReviewFamilyClientSession.resolveConflicts(paths: family.b, expected: observed,
            choices: [key: try XCTUnwrap(options.first { try JSONDecoder().decode(TransactionFactReview.self, from: Data($0.utf8)) == left })])
        try await family.second.loadFamilyClient(paths: family.b, handle: resolved)
        try await family.sync(from: family.b)
        XCTAssertEqual(family.first.stats.net, 3359)
        let current = try XCTUnwrap(family.first.report?.records.first)
        let reset = await family.first.saveFacts(try XCTUnwrap(family.first.beginFactEdit(current)), review: nil)
        XCTAssertTrue(reset, family.first.error ?? "")
        try await family.sync(from: family.a)
        XCTAssertEqual(family.second.stats.net, 0)
    }

}
