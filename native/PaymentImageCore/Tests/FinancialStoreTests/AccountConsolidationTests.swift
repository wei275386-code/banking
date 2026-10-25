import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class AccountConsolidationTests: XCTestCase {
    private func reports() throws -> (FinancialReport, FinancialReport, [String: CategoryOverride]) {
        let overrides = try JSONDecoder().decode([String: CategoryOverride].self, from: StoreFixtures.data("accounts-overrides.json"))
        return (try StoreFixtures.report("accounts-before.json"), try StoreFixtures.report("accounts-after.json"), overrides)
    }
    func testAllFactSignaturesAmountsRefundsAndConfirmationStatesSurvive() throws {
        var (before, after, overrides) = try reports()
        XCTAssertEqual(before.records.count, 5)
        XCTAssertEqual(after.records.count, before.records.count)
        for (old, new) in zip(before.records, after.records) {
            XCTAssertEqual(old.id, new.id)
            XCTAssertEqual(try TransactionFacts.signature(old), try TransactionFacts.signature(new), old.id)
            XCTAssertEqual(old.events, new.events)
            XCTAssertEqual(old.components, new.components)
        }
        FinancialStore.applyCompletion(overrides, to: &before)
        FinancialStore.applyCompletion(overrides, to: &after)
        let bs = FinancialMath.statistics(before.records), ns = FinancialMath.statistics(after.records)
        XCTAssertEqual(bs.gross, ns.gross); XCTAssertEqual(bs.refunds, ns.refunds); XCTAssertEqual(bs.net, ns.net)
        XCTAssertGreaterThan(bs.gross, 0); XCTAssertGreaterThan(bs.refunds, 0)
        XCTAssertGreaterThan(bs.pending, 0); XCTAssertGreaterThan(bs.unallocatedCredits, 0)
        XCTAssertEqual(bs.pending, ns.pending); XCTAssertEqual(bs.unallocatedCredits, ns.unallocatedCredits)
        XCTAssertTrue(before.records.flatMap(\.components).contains { $0.completionConfirmed })
        XCTAssertTrue(before.records.flatMap(\.components).contains { !$0.completionConfirmed })
        XCTAssertEqual(before.records.flatMap(\.components).map(\.completionConfirmed), after.records.flatMap(\.components).map(\.completionConfirmed))
        XCTAssertTrue(after.records.filter { $0.account_identity_before_consolidation != nil }.allSatisfy { $0.account_views == $0.payment_accounts })
    }
    func testExclusionsSurviveOverridesAndOlderPeerAliasesRemainUsable() throws {
        let (before, proposed, _) = try reports()
        let policy = try XCTUnwrap(proposed.account_consolidation)
        let excluded = Set(policy.excluded_lifecycle_ids)
        var after = proposed
        var overrides = [String: CategoryOverride]()
        for old in before.records where excluded.contains(old.id) {
            var fact = try TransactionFactReview(record: old)
            fact.userID = "不应传播"; fact.account = "9001"
            overrides[old.reviewOverrideKey] = CategoryOverride(primary: "", secondary: "", excluded_from_completion_and_statistics: true, transaction_facts: fact)
        }
        FinancialStore.applyCompletion(overrides, to: &after)
        for old in before.records where excluded.contains(old.id) { XCTAssertEqual(after.records.first { $0.id == old.id }, old) }
        XCTAssertEqual(AccountConsolidation.canonical("fixture-owner-b · 余额宝&红包", policy: policy), "余额宝")
        XCTAssertEqual(AccountConsolidation.canonical("9001（已确认来源的美团ApplePay）", policy: policy), "Synthetic bank card(9001)")
        XCTAssertNil(AccountConsolidation.canonical("微信支付", policy: policy))
        let source = try XCTUnwrap(after.records.first { !excluded.contains($0.id) })
        var fact = try TransactionFactReview(record: source); fact.account = "9001（银联7001）"
        FinancialStore.applyCompletion([source.reviewOverrideKey: CategoryOverride(primary: "", secondary: "", transaction_facts: fact)], to: &after)
        let effective = try XCTUnwrap(after.records.first { $0.id == source.id })
        XCTAssertTrue(effective.factReviewConfirmed)
        XCTAssertEqual(effective.payment_accounts, ["Synthetic bank card(9001)"])
        XCTAssertEqual(effective.account_views, effective.payment_accounts)
        XCTAssertEqual(effective.components, source.components)
    }
    func testUnknownChannelsAndNamesStayDistinctFromFunding() throws {
        let (_, after, _) = try reports()
        for (channel, known, pending) in [("微信支付", 1, 1), ("ApplePay", 1, 1)] {
            let records = after.records.filter { ($0.payment_channels ?? []).contains(channel) }
            XCTAssertEqual(records.filter { !($0.payment_accounts ?? []).isEmpty }.count, known)
            let unknown = records.filter { ($0.payment_accounts ?? []).isEmpty }
            XCTAssertEqual(unknown.count, pending)
            XCTAssertTrue(unknown.allSatisfy { $0.payment_account_status == "unresolved" })
            XCTAssertTrue(records.allSatisfy { !$0.account_views.contains(channel) })
        }
        XCTAssertEqual(after.records.filter { $0.user_id == "fixture-owner-a" }.count, 1)
        XCTAssertEqual(after.records.filter { $0.user_relation == "other_user" }.count, 1)
        XCTAssertEqual(AccountConsolidation.displayName("fixture-owner-b"), "fixture-owner-b")
        XCTAssertEqual(AccountConsolidation.displayName("fixture-owner-a"), "fixture-owner-a")
        var configured = after.records[0]
        configured.user_id = "selected-member"; configured.payment_account_status = "unresolved"
        configured.review_exclusion_allowed = true
        XCTAssertTrue(configured.canExcludeFromReview)
        configured.user_display_name = "Configured display"
        XCTAssertEqual(configured.userDisplayName, "Configured display")
        configured.review_exclusion_allowed = nil
        XCTAssertFalse(configured.canExcludeFromReview)
        configured.review_exclusion_allowed = true; configured.user_id = nil
        XCTAssertFalse(configured.canExcludeFromReview)
    }
}
