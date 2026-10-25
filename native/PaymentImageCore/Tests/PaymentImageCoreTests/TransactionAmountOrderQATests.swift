import XCTest
@testable import PaymentImageCore

final class TransactionAmountOrderQATests: XCTestCase {
    private func component(_ id: String, _ amount: Int, primary: String = "A", reason: String = "") -> FinancialComponent {
        FinancialComponent(id: id, title: id, gross_cents: max(amount, 0), refund_cents: 0, net_cents: amount,
            primary: primary, secondary: primary, classification_basis: "QA", included: reason.isEmpty, reason: reason)
    }
    private func record(_ id: String, _ components: [FinancialComponent], date: String = "2026-09-01") -> FinancialLifecycle {
        FinancialLifecycle(id: id, date: date, title: id, status: "支付", account_views: ["QA"], evidence_keys: [],
            components: components, events: [], user_relation: "self", non_consumption: false,
            unallocated_credit_cents: 0, user_id: "QA", payment_accounts: ["QA"], payment_account_status: "identified")
    }
    func testSignedAmountsUnknownZeroTiesAndMinimumInteger() {
        struct Row { let id: String; let date: String; let amount: Int? }
        let rows = [Row(id:"unknown",date:"9999",amount:nil), Row(id:"zero",date:"9999",amount:0),
            Row(id:"old",date:"2025",amount:100), Row(id:"b",date:"2026",amount:-100),
            Row(id:"a",date:"2026",amount:100), Row(id:"minimum",date:"2024",amount:Int.min)]
        XCTAssertEqual(TransactionListOrder.sorted(rows, amount: \.amount, date: \.date, id: \.id).map(\.id),
                       ["minimum", "a", "b", "old", "zero", "unknown"])
    }
    func testCategoryProjectionChangesOrderWithoutMutatingFactsOrStatistics() {
        let large = record("large-lifecycle", [component("small-A",100),component("large-B",900,primary:"B")])
        let medium = record("medium-lifecycle", [component("medium-A",500)])
        let original = [medium,large]
        let all = ReviewSnapshot(records:original,from:"2026-01-01",to:"2026-12-31",account:"全部账户",primary:"全部分类")
        XCTAssertEqual(all.records.map(\.id), ["large-lifecycle","medium-lifecycle"])
        XCTAssertEqual(all.statistics.net,1500)
        let category = ReviewSnapshot(records:original,from:"2026-01-01",to:"2026-12-31",account:"全部账户",primary:"A")
        XCTAssertEqual(category.classifiedRecords.map(\.id),["medium-lifecycle","large-lifecycle"])
        XCTAssertEqual(category.statistics.net,600)
        XCTAssertEqual(all.spendingTransactions(primary:"A",secondary:"A").map(\.id),["medium-lifecycle","large-lifecycle"])
        XCTAssertEqual(original,[medium,large]); XCTAssertEqual(large.components.count,2)
    }
    func testLifecycleDisplayedAmountKnownCreditAndNonConsumption() {
        var unknown = record("unknown",[component("u",0,reason:"支付金额待确定")])
        XCTAssertNil(unknown.transactionListAmount)
        unknown.unallocated_credit_cents = 750; XCTAssertEqual(unknown.transactionListAmount,750)
        let zero = record("zero",[component("z",0)]); XCTAssertEqual(zero.transactionListAmount,0)
        let event = FinancialEvent(id:"e",date:"2026-01-01",kind:"bank_credit",source:"QA",amount_cents:-880,status:"")
        let flow = FinancialLifecycle(id:"flow",date:"2026-01-01",title:"flow",status:"",account_views:[],evidence_keys:[],components:[],events:[event],user_relation:"self",non_consumption:true,unallocated_credit_cents:0)
        XCTAssertEqual(flow.transactionListAmount,-880)
        XCTAssertEqual(TransactionListOrder.sorted([unknown,zero,flow]).map(\.id),["flow","unknown","zero"])
        XCTAssertEqual(flow.events,[event])
    }
    func testCompletionLargerLowPriorityPrecedesHighPriorityAndUnknown() {
        let large = record("large",[component("large",90000,primary:"待分类")])
        let pending = record("pending",[component("pending",100,reason:"日期待核")])
        let unknown = record("unknown",[component("unknown",0,reason:"支付金额待确定")])
        var zeroComponent = component("zero",0,primary:"待分类"); zeroComponent.gross_cents = 100; zeroComponent.refund_cents = 100
        let result = CompletionQueue.build([unknown,pending,large,record("zero",[zeroComponent])],from:"",to:"9999")
        XCTAssertEqual(result.map(\.id),["large","pending","zero","unknown"])
        XCTAssertGreaterThan(result[0].rank,result[1].rank)
        XCTAssertTrue(result.last!.amountUnknown)
    }
    func testAmountKeyIsComputedOnceAndLargeSortHasBoundedCost() {
        let values = Array((0..<50000).reversed())
        var calls = 0
        let start = DispatchTime.now().uptimeNanoseconds
        let result = TransactionListOrder.sorted(values,amount:{ calls += 1; return ($0 * 7919) % 50000 },date:{ _ in "2026" },id:{ String($0) })
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertEqual(calls,values.count); XCTAssertEqual(result.count,values.count)
        XCTAssertEqual((result.first! * 7919) % 50000,49999)
        XCTAssertLessThan(milliseconds,3000,"50k rows must stay within the 3s Debug QA budget")
        print("QA_PERF amount-sort rows=50000 amount-key-calls=\(calls) elapsed-ms=\(milliseconds) budget-ms=3000")
    }
}
