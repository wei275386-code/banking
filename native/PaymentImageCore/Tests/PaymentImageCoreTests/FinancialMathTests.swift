import XCTest
@testable import PaymentImageCore

final class FinancialMathTests: XCTestCase {
    func testLifecycleEventsAreNotAdditionalExpenses() {
        let c = FinancialComponent(id: "meal", title: "餐饮", gross_cents: 3000, refund_cents: 500, net_cents: 2500,
                                   primary: "生活", secondary: "餐饮", classification_basis: "人工", included: true, reason: "")
        let pending = FinancialComponent(id: "pending", title: "待关联", gross_cents: 1000, refund_cents: 0, net_cents: 1000,
                                         primary: "待分类", secondary: "待分类", classification_basis: "未知", included: false, reason: "可能重复")
        let event = FinancialEvent(id: "wallet", date: "2026-01-01", kind: "payment", source: "wechat", amount_cents: 3000, status: "支付成功")
        let r = FinancialLifecycle(id: "one", date: "2026-01-01", title: "餐饮", status: "部分退款", account_views: ["9001"], evidence_keys: [], components: [c,pending], events: [event,event], user_relation: "unknown", non_consumption: false, unallocated_credit_cents: 200)
        let statistics = FinancialMath.statistics([r])
        XCTAssertEqual(statistics.net, 2500); XCTAssertEqual(statistics.count, 1)
        XCTAssertEqual(statistics.refunds, 500); XCTAssertEqual(statistics.pending, 1000)
        XCTAssertEqual(statistics.unallocatedCredits, 200)
    }
    func testNativeSavePreservesUnexposedNestedParameters() throws {
        let base = Data(#"{"city":"合成城市","investing":{"annualReturn":0.06,"equityRatio":0.7},"trading":{"enabled":false}}"#.utf8)
        let next = Data(#"{"investing":{"annualReturn":0.04}}"#.utf8)
        let merged = try JSONSerialization.jsonObject(with: ParameterDocument.merging(base: base, changes: next)) as! [String: Any]
        XCTAssertEqual(merged["city"] as? String, "合成城市")
        let investing = merged["investing"] as! [String: Any]
        XCTAssertEqual(investing["equityRatio"] as? Double, 0.7)
        XCTAssertEqual(investing["annualReturn"] as? Double, 0.04)
        XCTAssertNotNil(merged["trading"])
    }
    func testContributionTargetAndInflationUseConsistentUnits() {
        XCTAssertEqual(FinancialMath.realReturn(nominal: 0.06, inflation: 0.025), 1.06 / 1.025 - 1, accuracy: 0.0000001)
        XCTAssertEqual(FinancialMath.project(assets: 100, annualContribution: 120, annualReturn: 0, years: 1), 220, accuracy: 0.0001)
        XCTAssertEqual(FinancialMath.requiredMonthly(assets: 100, target: 220, annualReturn: 0, years: 1), 10, accuracy: 0.0001)
        XCTAssertEqual(FinancialMath.capitalReduction(monthlySaving: 500, withdrawalRate: 0.035), 6000 / 0.035, accuracy: 0.0001)
        XCTAssertNil(FinancialMath.reachYears(assets: 0, target: 100, annualContribution: 0, annualReturn: 0))
    }
}

extension FinancialMathTests {
    func confirmedParameters() throws -> FireParameters {
        return try JSONDecoder().decode(FireParameters.self, from: CoreFixtures.data("fire-parameters.json"))
    }
    func testZeroRateMortgageAndUnaffordablePurchaseDoNotInventFunding() throws {
        XCTAssertEqual(FinancialMath.mortgage(principal: 300000, annualRate: 0, years: 30), 300000/360, accuracy: 0.001)
        var p = try confirmedParameters(); p.branches.housing.enabled = true; p.branches.housing.year = p.baseYear
        p.branches.housing.minLiquidAssets = 0
        let result = FinancialMath.branchProjection(p)
        XCTAssertNil(result.estimatedYears); XCTAssertEqual(result.fundingGap, 430000, accuracy: 0.001)
    }
    func testFutureChildCostsRaiseTargetAndDelayComparedWithBaseline() throws {
        var p = try confirmedParameters(); let base = FinancialMath.branchProjection(p)
        p.branches.children.enabled = true
        let result = FinancialMath.branchProjection(p)
        XCTAssertGreaterThan(result.targetAssets, base.targetAssets)
        XCTAssertGreaterThan(result.estimatedYears!, base.estimatedYears!)
        XCTAssertEqual(result.fundingGap, 0)
    }

    private func housingFixture() throws -> FireParameters {
        var p = try confirmedParameters()
        p.branches.children.enabled = false; p.buckets.includeBuckets = false
        p.expenseModes["normal"] = 70000; p.investing.withdrawalRate = 0.035
        p.investing.annualReturn = 0; p.investing.inflation = 0; p.annualContribution = 0
        p.currentFireAssets = 2200000
        p.branches.housing.enabled = true; p.branches.housing.year = p.baseYear
        p.branches.housing.totalPrice = 1000000; p.branches.housing.downPaymentRatio = 0.2
        p.branches.housing.loanRate = 0; p.branches.housing.loanYears = 30
        p.branches.housing.fees = 0; p.branches.housing.renovation = 0
        p.branches.housing.annualMaintenance = 0; p.branches.housing.reduceRent = false
        p.branches.housing.minLiquidAssets = 0
        return p
    }
    func testRetirementCannotIgnoreOutstandingMortgage() throws {
        let p = try housingFixture()
        let result = FinancialMath.branchProjection(p)
        XCTAssertNil(result.estimatedYears)
    }
    func testFundedFiniteMortgageAllowsRetirementWithoutPermanentMortgageBudget() throws {
        var p = try housingFixture(); p.currentFireAssets = 3000000
        let result = FinancialMath.branchProjection(p)
        XCTAssertEqual(result.estimatedYears, 0)
        XCTAssertEqual(result.targetAssets, 2800000, accuracy: 0.01)
        XCTAssertEqual(result.fundingGap, 0)
    }
    func testFutureMortgageIsReservedBeforePurchase() throws {
        var p = try housingFixture(); p.branches.housing.year = p.baseYear + 2
        let result = FinancialMath.branchProjection(p)
        XCTAssertNil(result.estimatedYears)
        p.currentFireAssets = 3000000
        let funded = FinancialMath.branchProjection(p)
        XCTAssertEqual(funded.estimatedYears, 0)
        XCTAssertEqual(funded.targetAssets, 3000000, accuracy: 0.01)
    }
    func testMortgageReserveUsesFinitePaymentPresentValue() throws {
        var p = try housingFixture(); p.currentFireAssets = 20000000
        p.investing.annualReturn = 0.06; p.investing.inflation = 0.025
        p.branches.housing.loanRate = 0.035
        let payment = FinancialMath.mortgage(principal: 800000, annualRate: 0.035, years: 30)
        let monthlyNominal = pow(1.06, 1.0 / 12) - 1
        let reserve = payment * (1 - pow(1 + monthlyNominal, -360)) / monthlyNominal
        let result = FinancialMath.branchProjection(p)
        XCTAssertEqual(result.estimatedYears, 0)
        XCTAssertEqual(result.targetAssets, 2000000 + reserve, accuracy: 0.01)
    }
    func testMinimumLiquidityIsRequiredAfterDownPayment() throws {
        var p = try housingFixture(); p.branches.housing.minLiquidAssets = 3000000
        let result = FinancialMath.branchProjection(p)
        XCTAssertNil(result.estimatedYears)
        XCTAssertEqual(result.fundingGap, 1000000, accuracy: 0.01)
        p.currentFireAssets = 3200000
        let funded = FinancialMath.branchProjection(p)
        XCTAssertEqual(funded.estimatedYears, 0)
        XCTAssertEqual(funded.targetAssets, 3000000, accuracy: 0.01)
    }
    func testFuturePurchaseCannotUseLiquidityFloorForDownPayment() throws {
        var p = try housingFixture(); p.currentFireAssets = 3000000
        p.branches.housing.year = p.baseYear + 2; p.branches.housing.minLiquidAssets = 3000000
        let result = FinancialMath.branchProjection(p)
        XCTAssertNil(result.estimatedYears)
        XCTAssertEqual(result.fundingGap, 200000, accuracy: 0.01)
    }
}
