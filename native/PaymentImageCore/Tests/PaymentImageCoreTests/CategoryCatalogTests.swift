import XCTest
@testable import PaymentImageCore

final class CategoryCatalogTests: XCTestCase {
    private func catalog() -> CategoryCatalog {
        CategoryCatalog(taxonomy: [.init(primary: "日常", secondaries: ["餐饮", "出行"]), .init(primary: "空目录", secondaries: [])])
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testDeterministicMigrationFromTaxonomyAndObservedPaths() throws {
        let c = catalog(), d = catalog()
        XCTAssertEqual(c, d); XCTAssertNoThrow(try c.validated())
        XCTAssertEqual(c.primaries[0].id, "p-f648d6712cf804d1769fac12b82eed246931fc47fa7602be12cb678bf932971c")
        XCTAssertEqual(c.taxonomy[1].secondaries, [])
        XCTAssertEqual(c.resolve(primary: "missing", secondary: "missing").primary, "待分类")
    }
    func testRenameMoveAndDeletionRetainAllHistoricalPaths() throws {
        var c = catalog()
        let parent = c.primaries[0].id, destination = c.primaries[1].id, leaf = c.secondaries[0].id
        try c.renamePrimary(id: parent, name: " 生活 ")
        try c.renameSecondary(id: leaf, name: "用餐", primaryID: destination)
        XCTAssertEqual(c.resolve(primary: "日常", secondary: "餐饮"), .init(primary: "空目录", secondary: "用餐", id: leaf))
        XCTAssertEqual(c.resolve(primary: "生活", secondary: "餐饮").id, leaf)
        let pending = c.resolve(primary: "待分类", secondary: "待分类").id!
        try c.deletePrimary(id: destination, replacementID: pending)
        XCTAssertTrue(c.resolve(primary: "日常", secondary: "餐饮").wasRedirected)
        XCTAssertThrowsError(try c.addSecondary(primaryID: parent, name: "餐饮"))
        try c.deletePrimary(id: parent, replacementID: pending)
        let empty = try c.addPrimary(name: "空")
        try c.deletePrimary(id: empty, replacementID: pending)
        XCTAssertEqual(c.primaries.count, 1)
    }
    func testInvalidEditsAreAtomicAndReservedCategoriesAreProtected() throws {
        var c = catalog(); let original = c
        for name in ["", "全部分类", String(repeating: "长", count: 41), "日常", "含\n换行"] { XCTAssertThrowsError(try c.addPrimary(name: name)) }
        XCTAssertEqual(c, original)
        let work = try c.addPrimary(name: "Work")
        XCTAssertThrowsError(try c.addPrimary(name: "work"))
        _ = try c.addSecondary(primaryID: work, name: "Cafe\u{301}")
        XCTAssertThrowsError(try c.addSecondary(primaryID: work, name: "Café"))
        XCTAssertThrowsError(try c.addSecondary(primaryID: "missing", name: "新分类"))
        let pending = c.resolve(primary: "待分类", secondary: "待分类").id!
        let pendingParent = c.secondaries.first { $0.id == pending }!.primaryID
        XCTAssertThrowsError(try c.renamePrimary(id: pendingParent, name: "Other"))
        XCTAssertThrowsError(try c.renameSecondary(id: pending, name: "Other", primaryID: work))
        XCTAssertThrowsError(try c.deleteSecondary(id: pending, replacementID: c.secondaries[0].id))
        XCTAssertThrowsError(try c.deletePrimary(id: c.primaries[0].id, replacementID: c.secondaries[0].id))
    }
    func testSQLiteReopenCASAndJSONTransportRecovery() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try CategoryCatalogFile.load(root: directory, taxonomy: catalog().taxonomy)
        var edited = initial; _ = try edited.addPrimary(name: "新增")
        try CategoryCatalogFile.save(edited, root: directory, expected: initial)
        XCTAssertThrowsError(try CategoryCatalogFile.save(initial, root: directory, expected: initial))
        XCTAssertEqual(try CategoryCatalogFile.load(root: directory, taxonomy: []), edited)
        let transport = directory.appendingPathComponent("category-catalog.json")
        try FileManager.default.removeItem(at: transport)
        XCTAssertEqual(try CategoryCatalogFile.load(root: directory, taxonomy: []), edited)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transport.path))
        var downloaded = edited; _ = try downloaded.addPrimary(name: "同步目录")
        try JSONEncoder().encode(downloaded).write(to: transport, options: .atomic)
        XCTAssertEqual(try CategoryCatalogFile.load(root: directory, taxonomy: []), downloaded)
        try FileManager.default.removeItem(at: transport)
        XCTAssertEqual(try CategoryCatalogFile.load(root: directory, taxonomy: []), downloaded)
        try Data("{}".utf8).write(to: transport, options: .atomic)
        XCTAssertThrowsError(try CategoryCatalogFile.load(root: directory, taxonomy: []))
    }
    func testProjectionPreservesConfirmationForSameLeafAndResetsRedirect() throws {
        var c = catalog()
        var component = FinancialComponent(id: "c", title: "消费", gross_cents: 100, refund_cents: 0, net_cents: 100, primary: "日常", secondary: "餐饮", classification_basis: "人工分类", included: true, reason: "", recurrence: "one_time")
        component.completion_confirmation = .init(draft: CompletionDraft(component), origin: "manual")
        XCTAssertTrue(component.completionConfirmed)
        let parent = c.primaries[0].id, leaf = c.secondaries[0].id
        try c.renamePrimary(id: parent, name: "生活")
        try c.renameSecondary(id: leaf, name: "用餐", primaryID: c.primaries[1].id)
        CategoryResolver(catalog: c).applying(to: &component)
        XCTAssertTrue(component.completionConfirmed); XCTAssertEqual(component.primary, "空目录")
        XCTAssertEqual(component.net_cents, 100); XCTAssertEqual(component.classification_basis, "人工分类")
        try c.deleteSecondary(id: leaf, replacementID: c.secondaries[1].id)
        CategoryResolver(catalog: c).applying(to: &component)
        XCTAssertNil(component.completion_confirmation); XCTAssertEqual(component.secondary, "出行")
    }
}
