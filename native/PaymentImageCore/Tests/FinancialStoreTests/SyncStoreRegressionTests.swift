import XCTest
import Observation
import Darwin
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class SyncStoreRegressionTests: XCTestCase {
    private func fixture() throws -> URL {
        let created = try StoreFixtures.directory(files: ["financial-review.json", "payment-evidence.json", "preview.png"])
        guard let physical = Darwin.realpath(created.path, nil) else { throw CocoaError(.fileReadNoSuchFile) }
        defer { free(physical) }
        return URL(fileURLWithPath: String(cString: physical))
    }
    func testSavingParameterDraftPreservesNewRemoteUneditedLeaf() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let store = FinancialStore(); await store.loadFixture(root); XCTAssertNil(store.error)
        let original = try XCTUnwrap(store.report?.fire_parameters)
        let base = try XCTUnwrap(store.parameterDocument)
        store.report?.fire_parameters.currentFireAssets = original.currentFireAssets + 123
        var remote = original; remote.annualContribution += 456
        let merged = try ParameterDocument.merging(base:base,changes:JSONEncoder().encode(remote))
        try merged.write(to:root.appendingPathComponent("fire-parameters-user.json"),options:.atomic)
        store.saveParameters(); XCTAssertNil(store.error)
        let saved = try JSONDecoder().decode(FireParameters.self,from:Data(contentsOf:root.appendingPathComponent("fire-parameters-user.json")))
        XCTAssertEqual(saved.currentFireAssets,original.currentFireAssets + 123)
        XCTAssertEqual(saved.annualContribution,original.annualContribution + 456,"Stale unedited model leaves must not overwrite a synced remote change")
    }
    func testDeferredLeafDeltaPreservesNewRemoteDeferredItems() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let store = FinancialStore(), evidence = BrowserStore(); await store.loadFixture(root)
        store.completion.refresh(store,evidence)
        let workflow = CompletionWorkflow(datasetID:try XCTUnwrap(store.report?.dataset_id),deferred:["remote-item"])
        try JSONEncoder().encode(workflow).write(to:root.appendingPathComponent("completion-workflow.json"),options:.atomic)
        await store.completion.setDeferred("local-item",value:true)
        var saved = try JSONDecoder().decode(CompletionWorkflow.self,from:Data(contentsOf:root.appendingPathComponent("completion-workflow.json")))
        XCTAssertEqual(Set(saved.deferred),Set(["remote-item","local-item"]))
        await store.completion.setDeferred("local-item",value:false)
        saved = try JSONDecoder().decode(CompletionWorkflow.self,from:Data(contentsOf:root.appendingPathComponent("completion-workflow.json")))
        XCTAssertEqual(saved.deferred,["remote-item"])
    }
    func testInvalidParametersCannotCommitOrReplaceLastValidDocument() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let store = FinancialStore(); await store.loadFixture(root)
        store.saveParameters(); XCTAssertNil(store.error)
        let file = root.appendingPathComponent("fire-parameters-user.json"), original = try Data(contentsOf:file)
        store.report?.fire_parameters.investing.withdrawalRate = 0
        store.saveParameters(); XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf:file),original)
        store.report?.fire_parameters.investing.withdrawalRate = 0.04
        store.report?.fire_parameters.branches.housing.downPaymentRatio = 1.1
        store.saveParameters(); XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf:file),original)
    }
    func testCompletionSaveAndDeferredEditsSurviveStagedRemoteTransfer() async throws {
        let review = try fixture(); defer { try? FileManager.default.removeItem(at: review) }
        let family = try await CurrentFamilyStoreFixture.make(review: review); defer { family.cleanup() }
        let store = family.first, evidence = BrowserStore()
        store.completion.from = store.from; store.completion.to = store.to
        store.completion.refresh(store, evidence)
        let entry = try XCTUnwrap(store.completion.entries.first { $0.component != nil && $0.missingCategory })
        let remoteID = try XCTUnwrap(store.report?.records.flatMap(\.components).first { $0.id != entry.id }?.id)
        var draft = try XCTUnwrap(store.completion.draft(entry))
        draft.primary = "生产力工具"; draft.secondary = "设备"; draft.recurrence = "one_time"; draft.tags = ["传输期间保存"]
        store.completion.edit(entry, draft)
        try await family.edit(family.b) { root in
            try ReviewSyncIO.json([remoteID: ["primary": "生产力工具", "secondary": "设备", "recurrence": "one_time", "tags": ["另一设备"]]])
                .write(to: root.appendingPathComponent("review-overrides.json"))
        }
        try await ReviewFamilyClientSession.transfer(paths: family.b)
        _ = try await ReviewFamilyHost.synchronize(paths: family.host)
        let staged = try ReviewFamilyClientSession.prepareRefresh(paths: family.a)
        XCTAssertFalse(store.completionSaving); XCTAssertFalse(store.completion.persisting)
        let saved = await store.saveCompletion(entry); XCTAssertTrue(saved, store.error ?? "")
        await store.completion.setDeferred("saved-during-transfer", value: true)
        let selected = store.completion.selected
        guard case .ready(let prepared) = staged else { return XCTFail("Expected prepared current snapshot") }
        XCTAssertThrowsError(try ReviewFamilyClientSession.commitRefresh(paths: family.a, prepared: prepared), "A save invalidates the older prepared queue CAS")
        try await family.refresh()
        store.completion.refresh(store, evidence)
        XCTAssertEqual(store.report?.records.flatMap(\.components).first { $0.id == entry.id }?.tags, ["传输期间保存"])
        XCTAssertTrue(store.completion.saved.contains(entry.id))
        XCTAssertEqual(store.completion.selected, selected)
        let root = try XCTUnwrap(store.root)
        let workflow = try JSONDecoder().decode(CompletionWorkflow.self, from: Data(contentsOf: root.appendingPathComponent("completion-workflow.json")))
        XCTAssertTrue(workflow.deferred.contains("saved-during-transfer"))
        XCTAssertNoThrow(try JSONDecoder().decode([String: CategoryOverride].self, from: Data(contentsOf: root.appendingPathComponent("review-overrides.json"))))
        XCTAssertNotNil(store.completion.undo)
        await store.undoCompletion(); XCTAssertNil(store.error)
        let overrides = try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(store.root).appendingPathComponent("review-overrides.json"))) as! [String: Any]
        XCTAssertNotNil(overrides[remoteID]); XCTAssertNil(overrides[entry.id])
    }

    #if os(macOS)
    private func loadedStores(_ root: URL) async throws -> (FinancialStore, BrowserStore) {
        let store = FinancialStore(), evidence = BrowserStore()
        await store.loadFixture(root); await evidence.load(root, finance: store.report)
        XCTAssertNil(store.error); XCTAssertNil(evidence.error)
        store.completion.from = store.from; store.completion.to = store.to
        store.completion.refresh(store, evidence)
        return (store, evidence)
    }
    func testMacPollDoesNotReloadAfterOwnSaveUndoDeferredOrParameterWrite() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, evidence) = try await loadedStores(root)
        let entry = try XCTUnwrap(store.completion.entries.first { $0.component != nil && $0.missingCategory })
        var draft = try XCTUnwrap(store.completion.draft(entry))
        draft.primary = "生产力工具"; draft.secondary = "设备"; draft.recurrence = "one_time"; draft.tags = ["本机保存"]
        store.completion.edit(entry, draft)
        let saved = await store.saveCompletion(entry); XCTAssertTrue(saved, store.error ?? "")
        var revision = store.revision
        let preview = evidence.previewGeneration
        var acknowledged = await store.refreshLocalFilesIfNeeded(evidence)
        XCTAssertTrue(acknowledged); XCTAssertEqual(store.revision, revision); XCTAssertEqual(evidence.previewGeneration, preview)
        await store.undoCompletion(); XCTAssertNil(store.error); revision = store.revision
        acknowledged = await store.refreshLocalFilesIfNeeded(evidence)
        XCTAssertTrue(acknowledged); XCTAssertEqual(store.revision, revision)
        await store.completion.setDeferred(entry.id, value: true)
        acknowledged = await store.refreshLocalFilesIfNeeded(evidence)
        XCTAssertTrue(acknowledged); XCTAssertEqual(store.revision, revision); XCTAssertTrue(store.completion.deferred.contains(entry.id))
        store.report?.fire_parameters.currentFireAssets += 123
        store.saveParameters(); XCTAssertNil(store.error)
        acknowledged = await store.refreshLocalFilesIfNeeded(evidence)
        XCTAssertTrue(acknowledged); XCTAssertEqual(store.revision, revision); XCTAssertEqual(evidence.previewGeneration, preview)
    }
    func testMacPollIgnoresMtimeChangesWhenContentsMatch() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, evidence) = try await loadedStores(root)
        let revision = store.revision, preview = evidence.previewGeneration
        for name in ["financial-review.json", "payment-evidence.json"] {
            let file = root.appendingPathComponent(name)
            try Data(contentsOf: file).write(to: file, options: .atomic)
        }
        let acknowledged = await store.refreshLocalFilesIfNeeded(evidence)
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(store.revision, revision); XCTAssertEqual(evidence.previewGeneration, preview)
        XCTAssertFalse(store.loading); XCTAssertFalse(store.completionSaving); XCTAssertFalse(evidence.loading)
    }
    func testMacExternalChangeWaitsForSaveThenPreservesDraftsAndRebasesParameters() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, evidence) = try await loadedStores(root)
        let entry = try XCTUnwrap(store.completion.entries.first { $0.component != nil })
        var draft = try XCTUnwrap(store.completion.draft(entry)); draft.tags.append("未保存草稿")
        store.completion.edit(entry, draft)
        let original = try XCTUnwrap(store.report?.fire_parameters)
        store.report?.fire_parameters.currentFireAssets = original.currentFireAssets + 123
        var remote = original; remote.annualContribution += 456
        try JSONEncoder().encode(remote).write(to: root.appendingPathComponent("fire-parameters-user.json"), options: .atomic)
        let revision = store.revision
        store.completionSaving = true
        let blocked = await store.refreshLocalFilesIfNeeded(evidence); XCTAssertFalse(blocked)
        XCTAssertEqual(store.revision, revision)
        store.completionSaving = false
        let applied = await store.refreshLocalFilesIfNeeded(evidence); XCTAssertTrue(applied)
        XCTAssertGreaterThan(store.revision, revision)
        XCTAssertEqual(store.report?.fire_parameters.currentFireAssets, original.currentFireAssets + 123)
        XCTAssertEqual(store.report?.fire_parameters.annualContribution, original.annualContribution + 456)
        XCTAssertEqual(store.completion.draft(entry), draft)
        XCTAssertFalse(store.loading); XCTAssertFalse(store.completionSaving); XCTAssertFalse(store.completion.persisting)
        let after = store.revision, preview = evidence.previewGeneration
        let repeated = await store.refreshLocalFilesIfNeeded(evidence); XCTAssertTrue(repeated)
        XCTAssertEqual(store.revision, after); XCTAssertEqual(evidence.previewGeneration, preview)
    }
    func testEmptyAutomaticConfirmationScanDoesNotDisableEditor() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = try await loadedStores(root)
        let changed = expectation(description: "No save state transition for a scan with no writes")
        changed.isInverted = true
        withObservationTracking { _ = store.completionSaving } onChange: { changed.fulfill() }
        let revision = store.revision
        await store.reconcileCompletion()
        await fulfillment(of: [changed], timeout: 0.01)
        XCTAssertEqual(store.revision, revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-overrides.json").path))
    }
    #endif

}
