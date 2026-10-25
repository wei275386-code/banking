import XCTest
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class CategoryStoreTests: XCTestCase {
    private func fixture() throws -> URL {
        try StoreFixtures.directory(files: ["financial-review.json", "payment-evidence.json", "preview.png"])
    }
    private func component(_ id: String, _ store: FinancialStore) throws -> FinancialComponent { try XCTUnwrap(store.report?.records.flatMap(\.components).first { $0.id == id }) }
    private func save(_ next: CategoryCatalog, _ previous: CategoryCatalog, _ store: FinancialStore) async {
        let result = await store.saveCategoryCatalog(next, expected: previous)
        XCTAssertTrue(result, store.error ?? "")
    }
    func testCRUDReopenAliasesFiltersDirtyDraftsAndFinancialFacts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); let evidence = BrowserStore(); await store.loadFixture(root)
        let initial = try XCTUnwrap(store.categoryCatalog)
        let original = try XCTUnwrap(store.report?.records.flatMap(\.components).first { $0.primary != "待分类" && $0.included })
        let leaf = try XCTUnwrap(initial.resolve(primary: original.primary, secondary: original.secondary).id)
        let parent = try XCTUnwrap(initial.secondaries.first { $0.id == leaf }?.primaryID)
        let rawReport = try Data(contentsOf: root.appendingPathComponent("financial-review.json"))
        let facts = try XCTUnwrap(store.report).records
        let stats = FinancialMath.statistics(facts)
        store.completion.allDates = true; store.completion.refresh(store, evidence)
        let entry = try XCTUnwrap(store.completion.entries.first { $0.id == original.id })
        var draft = CompletionDraft(original); draft.tags.append("QA草稿")
        store.completion.edit(entry, draft); store.primary = original.primary
        var catalog = initial; let added = try catalog.addPrimary(name: "QA父级")
        let child = try catalog.addSecondary(primaryID: added, name: "QA子级")
        await save(catalog, initial, store)
        let beforeRename = catalog; try catalog.renamePrimary(id: parent, name: "QA原分类改名")
        await save(catalog, beforeRename, store)
        XCTAssertEqual(store.primary, "QA原分类改名")
        XCTAssertEqual(store.completion.drafts[entry.id]?.primary, "QA原分类改名")
        XCTAssertTrue(store.completion.drafts[entry.id]?.tags.contains("QA草稿") == true)
        XCTAssertEqual(store.completion.draftBases[entry.id]?.primary, "QA原分类改名")
        let beforeMove = catalog; try catalog.renameSecondary(id: leaf, name: "QA移动子级", primaryID: added)
        await save(catalog, beforeMove, store)
        XCTAssertEqual(try component(original.id, store).primary, "QA父级")
        XCTAssertEqual(store.completion.drafts[entry.id]?.secondary, "QA移动子级")
        let expectedUsage = store.report!.records.flatMap(\.components).filter { $0.primary == "QA父级" && $0.secondary == "QA移动子级" }.count
        XCTAssertEqual(store.categoryUsage[leaf], expectedUsage)
        let stale = await store.saveCategoryCatalog(initial, expected: initial); XCTAssertFalse(stale)
        XCTAssertEqual(store.categoryCatalog, catalog)
        // A legacy override carries the old raw path, which must resolve after every edit.
        let override = CategoryOverride(primary: original.primary, secondary: original.secondary, recurrence: original.effectiveRecurrence, tags: original.tags)
        try JSONEncoder().encode([original.id: override]).write(to: root.appendingPathComponent("review-overrides.json"))
        let reopened = FinancialStore(); await reopened.loadFixture(root)
        XCTAssertEqual(try component(original.id, reopened).secondary, "QA移动子级")
        let beforeDelete = catalog; let pending = try XCTUnwrap(catalog.resolve(primary: "待分类", secondary: "待分类").id)
        try catalog.deleteSecondary(id: leaf, replacementID: pending)
        await save(catalog, beforeDelete, reopened)
        XCTAssertEqual(try component(original.id, reopened).primary, "待分类")
        reopened.primary = "QA父级"
        let beforeParentDelete = catalog; try catalog.deletePrimary(id: added, replacementID: pending)
        await save(catalog, beforeParentDelete, reopened)
        XCTAssertFalse(catalog.secondaries.contains { $0.id == child })
        XCTAssertEqual(reopened.primary, "全部分类")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("financial-review.json")), rawReport)
        await reopened.loadFixture(root); XCTAssertEqual(reopened.categoryCatalog, catalog)
        let after = try XCTUnwrap(reopened.report).records
        XCTAssertEqual(FinancialMath.statistics(after).net, stats.net)
        XCTAssertEqual(FinancialMath.statistics(after).gross, stats.gross)
        XCTAssertEqual(FinancialMath.statistics(after).refunds, stats.refunds)
        for oldRecord in facts {
            let newRecord = try XCTUnwrap(after.first { $0.id == oldRecord.id })
            XCTAssertEqual(newRecord.events, oldRecord.events)
            for old in oldRecord.components {
                let new = try XCTUnwrap(newRecord.components.first { $0.id == old.id })
                XCTAssertEqual(new.gross_cents, old.gross_cents); XCTAssertEqual(new.refund_cents, old.refund_cents); XCTAssertEqual(new.net_cents, old.net_cents)
                XCTAssertEqual(new.tags, old.tags); XCTAssertEqual(new.effectiveRecurrence, old.effectiveRecurrence)
            }
        }
    }
    func testNewCategoryCompletionSaveUndoAndConfirmationRenameDelete() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); let evidence = BrowserStore(); await store.loadFixture(root)
        let initial = try XCTUnwrap(store.categoryCatalog); var next = initial
        let parent = try next.addPrimary(name: "QA新分类"), leaf = try next.addSecondary(primaryID: parent, name: "QA新用途")
        await save(next, initial, store)
        store.completion.allDates = true; store.completion.refresh(store, evidence)
        let entry = try XCTUnwrap(store.completion.entries.first { $0.component?.included == true })
        let original = try XCTUnwrap(entry.component)
        var draft = CompletionDraft(original); draft.primary = "QA新分类"; draft.secondary = "QA新用途"; draft.recurrence = "one_time"
        store.completion.edit(entry, draft)
        let saved = await store.saveCompletion(entry); XCTAssertTrue(saved, store.error ?? "")
        XCTAssertTrue(try component(entry.id, store).completionConfirmed)
        XCTAssertEqual(store.categoryUsage[leaf], 1)
        await store.undoCompletion(); XCTAssertNil(store.error)
        XCTAssertEqual(try component(entry.id, store).primary, original.primary)
        store.completion.refresh(store, evidence)
        let fresh = try XCTUnwrap(store.completion.entries.first { $0.id == entry.id }); store.completion.edit(fresh, draft)
        let again = await store.saveCompletion(fresh); XCTAssertTrue(again, store.error ?? "")
        let preRename = next; try next.renamePrimary(id: parent, name: "QA新分类改名")
        await save(next, preRename, store)
        XCTAssertTrue(try component(entry.id, store).completionConfirmed)
        XCTAssertEqual(try component(entry.id, store).completion_confirmation?.draft.primary, "QA新分类改名")
        XCTAssertNil(store.completion.undo)
        let preDelete = next; try next.deletePrimary(id: parent, replacementID: next.resolve(primary: "待分类", secondary: "待分类").id!)
        await save(next, preDelete, store)
        XCTAssertNil(try component(entry.id, store).completion_confirmation)
        await store.loadFixture(root); XCTAssertEqual(try component(entry.id, store).primary, "待分类")
    }
    func testOnDiskCatalogCASRejectsStaleStoreWithoutOverwriting() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = FinancialStore(), b = FinancialStore(); await a.loadFixture(root); await b.loadFixture(root)
        let original = try XCTUnwrap(a.categoryCatalog)
        var first = original; _ = try first.addPrimary(name: "QA先保存")
        await save(first, original, a)
        var second = original; _ = try second.addPrimary(name: "QA过期保存")
        let result = await b.saveCategoryCatalog(second, expected: original)
        XCTAssertFalse(result); XCTAssertNotNil(b.error)
        XCTAssertEqual(try CategoryCatalogFile.load(root: root, taxonomy: []), first)
    }

    func testBatchRebindUnbindPersistsAndPreservesFacts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); await store.loadFixture(root)
        let catalog = try XCTUnwrap(store.categoryCatalog)
        let original = try XCTUnwrap(store.report?.records.flatMap(\.components).first { $0.primary != "待分类" })
        let confirmation = CategoryOverride(primary: original.primary, secondary: original.secondary, recurrence: original.recurrence, tags: original.tags, completion_confirmation: CompletionConfirmation(draft: CompletionDraft(original), origin: "manual"))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(confirmation)) as! [String: Any]
        object["future_metadata"] = ["keep": true]
        try JSONSerialization.data(withJSONObject: [original.id: object]).write(to: root.appendingPathComponent("review-overrides.json"))
        await store.loadFixture(root)
        let source = try XCTUnwrap(catalog.secondaries.first { catalog.resolve(primary: original.primary, secondary: original.secondary).id == $0.id })
        let entries = store.categoryTransactions(primaryID: source.primaryID, secondaryID: source.id)
        XCTAssertFalse(entries.isEmpty)
        // Category management ignores unrelated date/account/global filters.
        store.from = "9999"; store.account = "不存在的账户"
        XCTAssertEqual(store.categoryTransactions(primaryID: source.primaryID, secondaryID: source.id).map(\.id), entries.map(\.id))
        let selected = [try XCTUnwrap(entries.first { $0.id == original.id })] + Array(entries.filter { $0.id != original.id }.prefix(1))
        let target = try XCTUnwrap(catalog.secondaries.first { $0.id != source.id && $0.name != "待分类" })
        let before = try XCTUnwrap(store.report).records
        let bytes = try Data(contentsOf: root.appendingPathComponent("financial-review.json"))
        let document = store.overrideDocument
        let rebound = await store.rebindCategoryTransactions(selected, targetID: target.id, expectedCatalog: catalog, expectedDocument: document)
        XCTAssertTrue(rebound, store.error ?? "")
        for entry in selected {
            let value = try component(entry.id, store)
            XCTAssertEqual(catalog.resolve(primary: value.primary, secondary: value.secondary).id, target.id)
            XCTAssertNil(value.completion_confirmation)
        }
        let savedObject = try JSONSerialization.jsonObject(with: store.overrideDocument) as! [String: [String: Any]]
        XCTAssertEqual((savedObject[original.id]?["future_metadata"] as? [String: Bool])?["keep"], true)
        let stale = await store.rebindCategoryTransactions(selected, targetID: source.id, expectedCatalog: catalog, expectedDocument: document)
        XCTAssertFalse(stale)
        let targetEntries = store.categoryTransactions(primaryID: target.primaryID, secondaryID: target.id).filter { selected.map(\.id).contains($0.id) }
        let pending = try XCTUnwrap(catalog.resolve(primary: "待分类", secondary: "待分类").id)
        let unbound = await store.rebindCategoryTransactions(targetEntries, targetID: pending, expectedCatalog: catalog, expectedDocument: store.overrideDocument)
        XCTAssertTrue(unbound, store.error ?? "")
        await store.loadFixture(root)
        for entry in selected { XCTAssertEqual(try component(entry.id, store).primary, "待分类") }
        let selectedIDs = Set(selected.map(\.id))
        for record in before {
            let after = try XCTUnwrap(store.report?.records.first { $0.id == record.id })
            XCTAssertEqual(after.events, record.events)
            for old in record.components {
                let value = try component(old.id, store)
                XCTAssertEqual(value.gross_cents, old.gross_cents); XCTAssertEqual(value.refund_cents, old.refund_cents)
                XCTAssertEqual(value.net_cents, old.net_cents); XCTAssertEqual(value.tags, old.tags)
                XCTAssertEqual(value.recurrence, old.recurrence); XCTAssertEqual(value.included, old.included)
                if !selectedIDs.contains(old.id) { XCTAssertEqual(value.primary, old.primary); XCTAssertEqual(value.secondary, old.secondary) }
            }
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("financial-review.json")), bytes)
    }

    func testBatchDiskConflictWritesNothing() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FinancialStore(); await store.loadFixture(root)
        let catalog = try XCTUnwrap(store.categoryCatalog)
        let leaf = try XCTUnwrap(catalog.secondaries.first { store.categoryUsage[$0.id, default: 0] > 1 })
        let entries = Array(store.categoryTransactions(primaryID: leaf.primaryID, secondaryID: leaf.id).prefix(2))
        let pending = try XCTUnwrap(catalog.resolve(primary: "待分类", secondary: "待分类").id)
        let other = Data("{\"external\":{\"primary\":\"待分类\",\"secondary\":\"待分类\"}}".utf8)
        try other.write(to: root.appendingPathComponent("review-overrides.json"))
        let result = await store.rebindCategoryTransactions(entries, targetID: pending, expectedCatalog: catalog, expectedDocument: store.overrideDocument)
        XCTAssertFalse(result)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("review-overrides.json")), other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-history").path))
    }
}
