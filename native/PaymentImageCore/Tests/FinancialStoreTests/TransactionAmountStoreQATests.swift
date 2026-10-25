import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class TransactionAmountStoreQATests: XCTestCase {
    private func fixture() throws -> URL {
        try StoreFixtures.directory(files: ["financial-review.json", "payment-evidence.json", "preview.png"])
    }
    private func assertDescending(_ records: [FinancialLifecycle], file: StaticString = #filePath, line: UInt = #line) {
        var previous: UInt? = nil; var sawUnknown = false
        for row in records {
            guard let amount = row.transactionListAmount else { sawUnknown = true; continue }
            XCTAssertFalse(sawUnknown,file:file,line:line)
            if let previous { XCTAssertGreaterThanOrEqual(previous,amount.magnitude,file:file,line:line) }
            previous = amount.magnitude
        }
    }
    func testFixtureFiltersModesCachesReloadAndStatisticsKeepOrder() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let store = FinancialStore(); await store.loadFixture(root); XCTAssertNil(store.error)
        let original = try XCTUnwrap(store.report?.records)
        let before = FinancialMath.statistics(original)
        store.selectRange("全部"); store.section = "details"
        assertDescending(store.allTransactionsByAmount)
        for mode in ["全部消费","待处理","账户待关联","资金流"] {
            store.recordView = mode; assertDescending(store.visibleRecords)
            XCTAssertEqual(store.visibleRecords,store.visibleRecords)
        }
        store.recordView = "全部消费"
        for account in ["全部账户"] + Array(store.accounts.prefix(2)) {
            store.account = account
            for primary in ["全部分类"] + (store.report?.taxonomy.map(\.primary) ?? []) {
                store.primary = primary; assertDescending(store.visibleRecords)
            }
        }
        store.primary = "全部分类"; store.account = "全部账户"
        for query in ["咖啡","2026-02","不存在"] { store.query = query; assertDescending(store.visibleRecords) }
        store.query = ""; store.section = "overview"
        XCTAssertEqual(store.stats.net,before.net); XCTAssertEqual(store.stats.gross,before.gross)
        XCTAssertEqual(store.stats.refunds,before.refunds); XCTAssertEqual(store.report?.records,original)
        let file = root.appendingPathComponent("financial-review.json")
        var object = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        var rows = object["records"] as! [[String:Any]]
        let index = try XCTUnwrap(rows.firstIndex { !(($0["components"] as? [[String:Any]]) ?? []).isEmpty && ($0["non_consumption"] as? Bool) == false })
        var components = rows[index]["components"] as! [[String:Any]]
        components[0]["net_cents"] = 987654321; components[0]["gross_cents"] = 987654321
        components[0]["reason"] = ""; rows[index]["components"] = components; rows[index]["unallocated_credit_cents"] = 0
        object["records"] = rows; try JSONSerialization.data(withJSONObject:object).write(to:file)
        await store.loadFixture(root); XCTAssertNil(store.error)
        XCTAssertEqual(store.allTransactionsByAmount.first?.id,rows[index]["id"] as? String)
        assertDescending(store.allTransactionsByAmount)
        for category in store.report?.taxonomy ?? [] {
            for secondary in category.secondaries {
                assertDescending(store.spendingTransactions(primary:category.primary,secondary:secondary))
                XCTAssertEqual(store.spendingTransactions(primary:category.primary,secondary:secondary),store.spendingTransactions(primary:category.primary,secondary:secondary))
            }
        }
    }
    func testEvidenceCandidatesAndSearchPreserveAmountOrder() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let browser = BrowserStore(); await browser.load(root); XCTAssertNil(browser.error)
        func check(_ rows: [BrowseRecord]) {
            var previous: UInt?; var unknown = false
            for row in rows {
                guard let amount = row.amount else { unknown = true; continue }
                XCTAssertFalse(unknown)
                if let previous { XCTAssertGreaterThanOrEqual(previous,amount.magnitude) }
                previous = amount.magnitude
            }
        }
        check(browser.records)
        for section in ["records","cards","needs_review","all_links"] {
            browser.section = section
            for query in ["","咖啡","2026-02"] { browser.query = query; check(browser.visibleRecords) }
        }
        var previous: UInt?
        let lookup = Dictionary(browser.records.map { ($0.id,$0.amount) },uniquingKeysWith:{ a,_ in a })
        for candidate in browser.orderedCandidates {
            let amount = (candidate.record_ids + candidate.bank_ids).compactMap { lookup[$0] ?? nil }.map(\.magnitude).max()
            if let amount, let previous { XCTAssertGreaterThanOrEqual(previous,amount) }
            previous = amount
        }
    }
    func testCompletionCandidateUnionIsGloballyDescendingAcrossEvidenceKeys() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let store = FinancialStore(); await store.loadFixture(root)
        let browser = BrowserStore(); await browser.load(root)
        let reference = try XCTUnwrap(browser.records.first?.evidence)
        let c = FinancialComponent(id:"qa-entry",title:"QA",gross_cents:100,refund_cents:0,net_cents:100,primary:"待分类",secondary:"待分类",classification_basis:"QA",included:true,reason:"")
        let record = FinancialLifecycle(id:"qa-entry",date:"2026-09-01",title:"QA",status:"",account_views:[],evidence_keys:["qa-low","qa-high"],components:[c],events:[],user_relation:"self",non_consumption:false,unallocated_credit_cents:0)
        let entry = CompletionEntry(id:c.id,datasetID:"QA",rootPath:root.path,record:record,component:c,issues:["分类待补"],rank:1,impact:100)
        browser.records = [BrowseRecord(id:"qa-high",platform:"bank",date:"2026-09-01",title:"high",amount:90000,status:"",evidence:reference),
                           BrowseRecord(id:"qa-low",platform:"bank",date:"2026-09-02",title:"low",amount:100,status:"",evidence:reference)]
        browser.orderedCandidates = [Candidate(candidate_id:"high",kind:"QA",record_ids:["qa-high"],bank_ids:[],association_status:"待核",review_required:true,active_competing_candidate_ids:nil),
                                     Candidate(candidate_id:"low",kind:"QA",record_ids:["qa-low"],bank_ids:[],association_status:"待核",review_required:true,active_competing_candidate_ids:nil)]
        browser.previewGeneration = UUID()
        store.completion.refresh(store,browser)
        XCTAssertEqual(store.completion.relevantCandidates(entry).map(\.id),["high","low"],
            "Merging candidates from different evidence keys must retain global amount order")
    }
}
