import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class RefundCandidateTests: XCTestCase {
    func testTraceShowsRefundPlatformAndAllThreeConfirmedUnpairedPurchaseSourcesWithoutChangingSignatures() throws {
        let base = try report()
        let refund = try XCTUnwrap(base.records.first { $0.evidence_keys.contains("refund-single") })
        let trace = try XCTUnwrap(refund.trace_sources?.first { $0.platform == "unionpay" && $0.association == "linked" })
        XCTAssertEqual(trace.title, "Fixture platform merchant"); XCTAssertEqual(trace.date, "2026-04-01 03:29")
        XCTAssertNotNil(trace.source_evidence?.image)
        for key in ["trace-purchase-0", "trace-purchase-1", "trace-purchase-2"] {
            let purchase = try XCTUnwrap(base.records.first { $0.evidence_keys.contains(key) })
            let leads = purchase.trace_sources?.filter { $0.association == "linked" && $0.platform == "unionpay" } ?? []
            XCTAssertEqual(Set(leads.map(\.date)), ["2025-12-23 08:11", "2025-12-23 08:13", "2025-12-23 08:15"])
            XCTAssertTrue(leads.allSatisfy { $0.provider_reference == nil && $0.source_evidence != nil })
            XCTAssertTrue(leads.allSatisfy { $0.basis.contains("整组来源已确认，未指定逐笔配对") })
            var stripped = purchase; stripped.trace_sources = nil
            XCTAssertEqual(try TransactionFacts.signature(purchase), try TransactionFacts.signature(stripped))
            XCTAssertTrue(FinancialStore.searchIndex([purchase])[purchase.id]?.contains("Fixture platform merchant") == true)
        }
        var legacy = refund; legacy.trace_sources = nil
        let decoded = try JSONDecoder().decode(FinancialLifecycle.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.trace_sources)
        XCTAssertEqual(try TransactionFacts.signature(refund), try TransactionFacts.signature(decoded))
    }
    private func report() throws -> FinancialReport {
        try StoreFixtures.report("refund-review.json")
    }
    private func fixture(_ candidate: RefundCandidate, base: FinancialReport) throws -> URL {
        let root = try AppStorageLocations.physicalSystemDirectory(FileManager.default.temporaryDirectory).appendingPathComponent("refund-candidate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try StoreFixtures.data("preview.png").write(to: root.appendingPathComponent("preview.png"))
        var report = base
        let ids = Set(candidate.source_ids + candidate.targets.map(\.record_id))
        report.records = report.records.filter { ids.contains($0.id) }
        report.source_record_sets = nil; report.source_record_set_candidates = nil
        report.refund_candidates = [candidate]
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent("financial-review.json"))
        return root
    }
    func testEveryFixtureCandidateValidatesWithoutChangingSourceAndAppliesExactlyOnce() throws {
        let base = try report(), candidates = try XCTUnwrap(base.refund_candidates)
        XCTAssertEqual(candidates.count, 4)
        XCTAssertEqual(candidates.filter(\.competing).count, 2)
        XCTAssertEqual(Set(candidates.flatMap(\.source_ids)).count, 5)
        for candidate in candidates {
            let review = try RefundAssociations.review(candidate, records: base.records)
            let sourceID = try XCTUnwrap(candidate.source_ids.sorted().first)
            let source = try XCTUnwrap(base.records.first { $0.id == sourceID })
            _ = try TransactionFacts.validated(review, source: source, records: base.records, cutoff: base.cutoff)
            let overrides = [source.reviewOverrideKey: CategoryOverride(primary: "", secondary: "", transaction_facts: review)]
            var projected = base; TransactionFacts.apply(overrides, to: &projected)
            for id in candidate.source_ids {
                let result = try XCTUnwrap(projected.records.first { $0.id == id })
                XCTAssertEqual(result.unallocated_credit_cents, 0, candidate.id)
                XCTAssertTrue(result.non_consumption, candidate.id)
                XCTAssertTrue(result.factReviewConfirmed, candidate.id)
            }
            for target in candidate.targets {
                let before = try XCTUnwrap(base.records.first { $0.id == target.record_id }?.components.first { $0.id == target.component_id })
                let after = try XCTUnwrap(projected.records.first { $0.id == target.record_id }?.components.first { $0.id == target.component_id })
                XCTAssertEqual(after.refund_cents, before.refund_cents + target.refund_cents, candidate.id)
                XCTAssertEqual(after.net_cents, before.net_cents - target.refund_cents, candidate.id)
                XCTAssertEqual(after.primary, before.primary); XCTAssertEqual(after.tags, before.tags)
            }
            var rebuilt = base; TransactionFacts.apply(overrides, to: &rebuilt)
            XCTAssertEqual(rebuilt.records, projected.records)
        }
    }
    func testOneClickGroupSaveRestartResetAndPreservationOfEvidence() async throws {
        let base = try report()
        let candidate = try XCTUnwrap(base.refund_candidates?.first { $0.grouped && $0.targets.count == 1 })
        let root = try fixture(candidate, base: base); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: root.appendingPathComponent("financial-review.json"))
        let store = FinancialStore(); await store.loadFixture(root)
        let evidence = BrowserStore()
        store.completion.allDates = true; store.completion.mode = "退款候选"; store.completion.refresh(store, evidence)
        XCTAssertEqual(Set(store.completion.visible.map { $0.record.id }), Set(candidate.source_ids))
        let before = store.stats.net
        let saved = await store.confirmRefundCandidate(candidate); XCTAssertTrue(saved, store.error ?? "")
        XCTAssertEqual(store.stats.net, before - candidate.amount)
        XCTAssertEqual(store.stats.unallocatedCredits, 0)
        XCTAssertEqual(store.overrides.values.filter { $0.transaction_facts != nil }.count, 1)
        store.completion.refresh(store, evidence); XCTAssertTrue(store.completion.visible.isEmpty)
        let repeated = await store.confirmRefundCandidate(candidate); XCTAssertFalse(repeated)
        XCTAssertEqual(store.stats.net, before - candidate.amount)
        await store.loadFixture(root); XCTAssertEqual(store.stats.net, before - candidate.amount)
        let anchor = try XCTUnwrap(store.report?.records.first { $0.id == candidate.source_ids.sorted().first })
        let reset = await store.saveFacts(try XCTUnwrap(store.beginFactEdit(anchor)), review: nil); XCTAssertTrue(reset, store.error ?? "")
        XCTAssertEqual(store.stats.net, before)
        XCTAssertEqual(store.stats.unallocatedCredits, candidate.amount)
        store.completion.refresh(store, evidence)
        XCTAssertEqual(Set(store.completion.visible.map { $0.record.id }), Set(candidate.source_ids))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("financial-review.json")), bytes)
    }
    func testGroupedRefundRefusesChangedMemberAndConflictingManualUse() throws {
        let base = try report()
        let candidate = try XCTUnwrap(base.refund_candidates?.first { $0.grouped && $0.targets.count == 1 })
        let review = try RefundAssociations.review(candidate, records: base.records)
        let source = try XCTUnwrap(base.records.first { $0.id == candidate.source_ids.sorted().first })
        let other = try XCTUnwrap(base.records.first { candidate.source_ids.contains($0.id) && $0.id != source.id })
        var changed = base
        let index = try XCTUnwrap(changed.records.firstIndex { $0.id == other.id }); changed.records[index].date = "2026-06-02"
        XCTAssertThrowsError(try TransactionFacts.validated(review, source: source, records: changed.records, cutoff: base.cutoff))
        let target = try XCTUnwrap(base.records.first { $0.id == candidate.targets[0].record_id })
        var manual = try TransactionFactReview(record: other); manual.disposition = .refund
        manual.targetID = candidate.targets[0].component_id; manual.targetSignature = try TransactionFacts.signature(target)
        manual.refundCents = other.unallocated_credit_cents
        var projected = base
        TransactionFacts.apply([source.reviewOverrideKey: CategoryOverride(primary: "", secondary: "", transaction_facts: review),
                                other.reviewOverrideKey: CategoryOverride(primary: "", secondary: "", transaction_facts: manual)], to: &projected)
        XCTAssertEqual(projected.records.first { $0.id == target.id }?.components, target.components)
        for id in candidate.source_ids {
            XCTAssertGreaterThan(try XCTUnwrap(projected.records.first { $0.id == id }).unallocated_credit_cents, 0)
        }
        XCTAssertFalse(try XCTUnwrap(projected.records.first { $0.id == source.id }).factReviewConfirmed)
    }
    func testGroupDecisionSyncsAtomicallyAndResetRestoresPeerStatistics() async throws {
        let base = try report()
        let candidate = try XCTUnwrap(base.refund_candidates?.first { $0.grouped && $0.targets.count == 2 })
        let review = try fixture(candidate, base: base)
        defer { try? FileManager.default.removeItem(at: review) }
        let family = try await CurrentFamilyStoreFixture.make(review: review)
        defer { family.cleanup() }
        let store = family.first, phone = family.second, before = store.stats.net
        let saved = await store.confirmRefundCandidate(candidate); XCTAssertTrue(saved, store.error ?? "")
        try await family.sync(from: family.a)
        XCTAssertEqual(phone.stats.net, before - candidate.amount)
        XCTAssertEqual(phone.overrides.values.compactMap(\.transaction_facts).count, 1)
        let anchor = try XCTUnwrap(phone.report?.records.first { $0.id == candidate.source_ids.sorted().first })
        let reset = await phone.saveFacts(try XCTUnwrap(phone.beginFactEdit(anchor)), review: nil)
        XCTAssertTrue(reset, phone.error ?? "")
        try await family.sync(from: family.b)
        XCTAssertEqual(store.stats.net, before)
    }
    func testInsufficientOneTargetRejectsTheEntireGroupAllocation() throws {
        let base = try report()
        let candidate = try XCTUnwrap(base.refund_candidates?.first { $0.grouped && $0.targets.count == 2 })
        let review = try RefundAssociations.review(candidate, records: base.records)
        let sourceID = try XCTUnwrap(candidate.source_ids.sorted().first)
        let source = try XCTUnwrap(base.records.first { $0.id == sourceID })
        let badTarget = try XCTUnwrap(base.records.first { $0.id == candidate.targets[0].record_id })
        let untouchedTarget = try XCTUnwrap(base.records.first { $0.id == candidate.targets[1].record_id })
        var correction = try TransactionFactReview(record: badTarget)
        correction.amounts[candidate.targets[0].component_id] = FactAmounts(gross: 0, refund: 0)
        var projected = base
        TransactionFacts.apply([source.reviewOverrideKey: CategoryOverride(primary: "", secondary: "", transaction_facts: review),
                                badTarget.reviewOverrideKey: CategoryOverride(primary: "", secondary: "", transaction_facts: correction)], to: &projected)
        XCTAssertEqual(projected.records.first { $0.id == untouchedTarget.id }?.components, untouchedTarget.components)
        XCTAssertTrue(projected.records.first { $0.id == source.id }?.fact_review_status?.contains("超过") == true)
        for id in candidate.source_ids {
            XCTAssertGreaterThan(try XCTUnwrap(projected.records.first { $0.id == id }).unallocated_credit_cents, 0)
        }
    }
}
