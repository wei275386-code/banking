import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

/// `importReporting` must report what the import actually did, independent of
/// whether the store's error text happens to repeat.
@MainActor final class ImportReportingTests: XCTestCase {
    private let busy = "素材未导入：正在处理其他操作或暂时无法开始，请稍后重试。"
    private var material: URL!
    private var temporary: URL!

    override func setUp() async throws {
        guard let physical = Darwin.realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadNoSuchFile) }
        defer { free(physical) }
        temporary = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("import-reporting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        material = temporary.appendingPathComponent("statement.csv")
        try Data("date,amount\n".utf8).write(to: material)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: temporary) }

    func testBusyRejectionKeepsRunningProgressAndSaysNotImported() async {
        let store = FinancialStore()
        store.root = temporary
        store.importing = true; store.importState = "正在保存原始材料、解析和更新复盘…"
        await importReporting(store, [material], success: "ok")
        XCTAssertEqual(store.importState, "正在保存原始材料、解析和更新复盘…")
        XCTAssertEqual(ToastCenter.shared.current?.text, busy)
    }

    func testRepeatedIdenticalLocalFailureIsReportedBothTimes() async throws {
        let store = FinancialStore()
        store.root = temporary.appendingPathComponent("not-a-workspace")
        await importReporting(store, [material], success: "ok")
        let first = try XCTUnwrap(store.error)
        XCTAssertEqual(ToastCenter.shared.current?.text, first)
        ToastCenter.shared.dismiss()
        await importReporting(store, [material], success: "ok")
        XCTAssertEqual(store.error, first, "fixture should repeat the same failure text")
        XCTAssertEqual(ToastCenter.shared.current?.text, first)
        XCTAssertNotEqual(ToastCenter.shared.current?.text, busy)
    }

    func testRepeatedClientRejectionShowsItsErrorEachTime() async throws {
        let store = FinancialStore()
        store.clientWorkspacePaths = try WorkspacePaths(workspace: temporary.appendingPathComponent("client"))
        for _ in 0..<2 {
            ToastCenter.shared.dismiss()
            await importReporting(store, [material], success: "ok")
            let error = try XCTUnwrap(store.error)
            XCTAssertEqual(ToastCenter.shared.current?.text, error)
        }
    }
}
