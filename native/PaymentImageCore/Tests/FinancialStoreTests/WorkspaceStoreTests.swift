#if os(macOS)
import XCTest
import Foundation
import CSQLite
import Darwin
@testable import PaymentImageCore
@testable import EvidenceBrowser

@MainActor final class WorkspaceStoreTests: XCTestCase {
    private func temporaryBase() throws -> String {
        guard let physical = Darwin.realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadNoSuchFile) }
        defer { free(physical) }
        return String(cString: physical)
    }
    private func python() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let python = try SystemToolLocations.executable("python3", searchPath: environment["PATH"])
        let candidates = [environment["BANKING_PROCESSOR_PYTHON"]].compactMap { $0 } + [python.path]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("Python runtime unavailable") }
        return URL(fileURLWithPath: path)
    }
    func emptyWorkspace(sourceIDs: [String] = []) throws -> WorkspacePaths {
        let folder = URL(fileURLWithPath: try temporaryBase() + "/native-workspace-" + UUID().uuidString)
        let paths = try WorkspacePaths(workspace: folder)
        let workspaceID = UUID().uuidString.lowercased(), stateID = UUID().uuidString.lowercased()
        let root = try paths.stateRoot(stateID)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("review"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["workspace_id": workspaceID,
            "created_at": "2026-10-14T00:00:00Z"]), to: paths.metadata)
        var financial = try JSONSerialization.jsonObject(with: StoreFixtures.data("financial-review.json")) as! [String: Any]
        var evidence = try JSONSerialization.jsonObject(with: StoreFixtures.data("payment-evidence.json")) as! [String: Any]
        let coverage: [String: Any] = ["mode": "empty", "from": NSNull(), "to": NSNull(),
            "observed_from": NSNull(), "observed_to": NSNull(), "pending_from": NSNull(), "pending_to": NSNull(),
            "revision": 0, "basis": ["kind": "no-reliable-dates", "source_ids": []]]
        financial["cutoff"] = NSNull(); financial["coverage"] = coverage
        financial["source_dataset_id"] = evidence["dataset_id"]; financial["records"] = []
        financial["source_record_sets"] = []; financial["source_record_set_candidates"] = []; financial["refund_candidates"] = []
        evidence["backfill_cutoff_date"] = NSNull(); evidence["clusters"] = []; evidence["bank_records"] = []
        evidence["candidates"] = []; evidence["documents"] = []; evidence["undated_bank_records"] = []
        evidence.removeValue(forKey: "ocr_probe"); evidence["coverage"] = coverage
        var registrySources = [[String: Any]](), clusters = [[String: Any]]()
        for (index, sourceID) in sourceIDs.enumerated() {
            let relative = "sources/synthetic-\(index).csv", bytes = Data("synthetic source \(index)".utf8)
            try WorkspaceIO.atomicWrite(bytes, to: root.appendingPathComponent(relative))
            let hash = WorkspaceIO.digest(bytes)
            registrySources.append(["id": sourceID, "path": relative, "platform": "alipay", "sha256": hash])
            clusters.append(["cluster_id": "synthetic-\(index)", "representative": ["platform": "alipay", "source_id": sourceID,
                "file_sha256": hash, "payment_method": "Synthetic card", "currency": "CNY", "transaction_time": "2026-02-01",
                "raw_status": "paid", "platform_reported_amount_cents": 100, "source_evidence": ["kind": "synthetic"]]])
        }
        evidence["clusters"] = clusters
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(financial), to: root.appendingPathComponent("review/financial-review.json"))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(evidence), to: root.appendingPathComponent("review/payment-evidence.json"))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(coverage), to: root.appendingPathComponent("review/coverage.json"))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["currency_codes": ["CNY"], "sources": registrySources]), to: root.appendingPathComponent("config/review-import-sources.json"))
        try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.canonicalize(raw: Data(#"{"household_name":"","members":[]}"#.utf8)), to: root.appendingPathComponent("config/family-profile.json"))
        try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.canonicalize(raw: Data(#"{"accounts":[],"routes":[],"aliases":[],"source_owners":{},"unknown_account_policy":{"mode":"needs_review","exclusion_member_ids":[]}}"#.utf8)), to: root.appendingPathComponent("config/account-policies.json"))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(try XCTUnwrap(financial["fire_parameters"] as? [String: Any])), to: root.appendingPathComponent("config/fire-parameters.json"))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["state_id": stateID, "results": []]), to: root.appendingPathComponent("operation-results.json"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("banking.sqlite3").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE facts(id TEXT PRIMARY KEY); CREATE TABLE transactions(id INTEGER PRIMARY KEY);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        var hashes = [String: String]()
        for file in try WorkspaceIO.regularFiles(root) { hashes[file] = try WorkspaceIO.hash(root.appendingPathComponent(file)) }
        let manifest = try WorkspaceIO.canonical(["workspace_id": workspaceID, "state_id": stateID, "local_revision": 0, "files": hashes])
        try WorkspaceIO.atomicWrite(manifest, to: root.appendingPathComponent("state-manifest.json"))
        let pointer = WorkspaceStatePointer(workspaceID: workspaceID, stateID: stateID, localRevision: 0, manifestHash: WorkspaceIO.digest(manifest))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pointer.document), to: paths.activeState)
        return paths
    }
    func testFamilyClientStoreSavesSettingsParametersAndCategoryThroughOriginTransaction() async throws {
        let host = try emptyWorkspace()
        let remote = host.workspace.deletingLastPathComponent().appendingPathComponent("family-store-provider-" + UUID().uuidString.lowercased())
        let paths = try WorkspacePaths(workspace: host.workspace.deletingLastPathComponent().appendingPathComponent("family-store-client-" + UUID().uuidString.lowercased()))
        defer { for path in [host.workspace, remote, paths.workspace] { try? FileManager.default.removeItem(at: path) } }
        _ = try ReviewFamilyHost.create(paths: host, remote: remote)
        _ = try ReviewFamilyClientSession.connect(paths: paths, remote: remote, bookmark: nil)
        let original = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: paths))
        let report = try WorkspaceIO.read(original.review.appendingPathComponent("financial-review.json"))
        let store = FinancialStore(); _ = store.expectWorkspace(paths)
        try await store.loadFamilyClient(paths: paths, handle: original)
        var draft = HouseholdSettingsDraft(.client(paths, original))
        draft.name = "Synthetic offline client"
        let saved = await store.persistHouseholdSettings(try draft.prepare())
        XCTAssertTrue(saved, store.error ?? "")
        store.report?.fire_parameters.$currentFireAssets = nil; store.report?.fire_parameters.afterTaxSalary = 0
        await store.persistParameters()
        XCTAssertNil(store.error)
        XCTAssertNil(store.report?.fire_parameters.$currentFireAssets)
        XCTAssertEqual(store.report?.fire_parameters.afterTaxSalary, 0)
        let prior = try XCTUnwrap(store.categoryCatalog)
        var catalog = prior
        let primary = try catalog.addPrimary(name: "Synthetic extra category")
        _ = try catalog.addSecondary(primaryID: primary, name: "Synthetic use")
        let categorySaved = await store.saveCategoryCatalog(catalog, expected: prior)
        XCTAssertTrue(categorySaved, store.error ?? "")
        let active = try XCTUnwrap(ReviewFamilyClientSession.read(paths: paths))
        XCTAssertEqual(active.version, store.familyClientHandle?.version)
        XCTAssertEqual(active.settings.householdName, "Synthetic offline client")
        XCTAssertEqual(active.fields.causal.values["parameter/afterTaxSalary"], "0")
        XCTAssertEqual(active.queue.count, 3)
        XCTAssertEqual(try WorkspaceIO.read(active.review.appendingPathComponent("financial-review.json")), report)
        XCTAssertEqual(try WorkspaceIO.read(original.review.appendingPathComponent("financial-review.json")), report)
        XCTAssertNil(store.workspacePaths); XCTAssertFalse(store.processorAvailable)
        try await ReviewFamilyClientSession.transfer(paths: paths)
        _ = try await ReviewFamilyHost.synchronize(paths: host)
        let updated = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: paths))
        XCTAssertEqual(updated.checkpoint.payload.fields.causal.revisions.count, 3)
        XCTAssertEqual(updated.settings.householdName, "Synthetic offline client")
        try await store.loadFamilyClient(paths: paths, handle: updated)
        XCTAssertNil(store.report?.fire_parameters.$currentFireAssets)
        XCTAssertEqual(store.report?.fire_parameters.afterTaxSalary, 0)
        XCTAssertEqual(updated.fields.causal.values["parameter/currentFireAssets"], "null")
    }

    func testHouseholdSettingsSaveUsesTransactionAndRetainsEvidence() async throws {
        let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let store = FinancialStore(); await store.loadWorkspace(paths)
        let original = try paths.readState(), report = try Data(contentsOf: original.review.appendingPathComponent("financial-review.json"))
        var draft = HouseholdSettingsDraft(try store.readHouseholdSettings())
        draft.name = "Synthetic household"
        draft.members.append(.init(memberID: "synthetic-member", name: "Synthetic member", active: true, exclusionAllowed: false))
        draft.accounts.append(.init(accountID: "synthetic-account", name: "Synthetic account", ownerID: "synthetic-member", active: true, currency: "CNY"))
        let saved = await store.persistHouseholdSettings(try draft.prepare())
        XCTAssertTrue(saved, store.error ?? "")
        let current = try paths.readState()
        XCTAssertEqual(current.pointer.localRevision, original.pointer.localRevision + 1)
        XCTAssertEqual(try Data(contentsOf: current.review.appendingPathComponent("financial-review.json")), report)
        XCTAssertEqual(try Data(contentsOf: original.review.appendingPathComponent("financial-review.json")), report)
        let settings = try store.readHouseholdSettings().settings
        XCTAssertEqual(settings.householdName, "Synthetic household")
        XCTAssertEqual(settings.members.first?.id, "synthetic-member")
        XCTAssertEqual(settings.accounts.first?.ownerMemberID, "synthetic-member")
        let ledger = try WorkspaceIO.object(Data(contentsOf: current.operationResults))
        let entities = (ledger["results"] as? [[String: Any]] ?? []).flatMap { $0["membership"] as? [[String: Any]] ?? [] }.compactMap { $0["entity_key"] as? String }
        XCTAssertTrue(entities.contains("document:config/family-profile.json"))
        XCTAssertTrue(entities.contains("document:config/account-policies.json"))
        try WorkspaceIO.validateManifest(original, validateFiles: true)
        try ReviewWorkspaceMembership.validate(state: current)

    }
    func testFireInputsUnsetZeroAndResetUseStateTransaction() async throws {
        let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let store = FinancialStore(); await store.loadWorkspace(paths)
        let original = try paths.readState(), rawReport = try Data(contentsOf: original.review.appendingPathComponent("financial-review.json"))
        store.report?.fire_parameters.$currentFireAssets = nil
        store.report?.fire_parameters.afterTaxSalary = 0
        store.parameterDocument = try ParameterDocument.merging(base: XCTUnwrap(store.parameterDocument), changes: Data(#"{"customAssumption":45}"#.utf8))
        XCTAssertTrue(try XCTUnwrap(store.report).fire_parameters.needsBaseInput)
        XCTAssertTrue(FinancialMath.target(try XCTUnwrap(store.report).fire_parameters).isNaN)
        await store.persistParameters(); XCTAssertNil(store.error)
        let saved = try paths.readState(), savedRaw = try Data(contentsOf: saved.review.appendingPathComponent("fire-parameters-user.json"))
        let savedObject = try WorkspaceIO.object(savedRaw)
        XCTAssertTrue(savedObject["currentFireAssets"] is NSNull)
        XCTAssertEqual(savedObject["afterTaxSalary"] as? Int, 0)
        XCTAssertEqual(savedObject["customAssumption"] as? Int, 45)
        await store.resetFireInputs(); XCTAssertNil(store.error)
        let cleared = try paths.readState(), clearedObject = try WorkspaceIO.object(Data(contentsOf: cleared.review.appendingPathComponent("fire-parameters-user.json")))
        XCTAssertTrue(clearedObject["afterTaxSalary"] is NSNull)
        XCTAssertTrue(clearedObject["customAssumption"] is NSNull)
        XCTAssertEqual(clearedObject["status"] as? String, "needs_input")
        XCTAssertEqual(try Data(contentsOf: original.review.appendingPathComponent("financial-review.json")), rawReport)
        XCTAssertEqual(try Data(contentsOf: cleared.review.appendingPathComponent("financial-review.json")), rawReport)
        try ReviewWorkspaceMembership.validate(state: cleared)
    }
    func testFireInputsExplicitZerosBecomeReadyAndClearingBudgetStaysUnset() throws {
        var parameters = try FireParameters.emptyInputs()
        XCTAssertNil(parameters.$baseYear); XCTAssertNil(parameters.$currentFireAssets)
        XCTAssertTrue(parameters.needsInput)
        parameters.baseYear = 2026; parameters.birthYear = 1990; parameters.targetAge = 55
        parameters.currentFireAssets = 0; parameters.afterTaxSalary = 0; parameters.annualContribution = 0
        parameters.annualHardCap = 0; parameters.expenseModes["normal"] = 0
        parameters.investing.annualReturn = 0; parameters.investing.inflation = 0
        XCTAssertFalse(parameters.needsBaseInput)
        XCTAssertEqual(FinancialMath.target(parameters), 0)
        parameters.expenseModes.removeValue(forKey: "normal")
        let roundtrip = try JSONDecoder().decode(FireParameters.self, from: ParameterDocument.encoding(parameters))
        XCTAssertNil(roundtrip.expenseModes["normal"])
        XCTAssertTrue(roundtrip.needsBaseInput)
        XCTAssertTrue(FinancialMath.branchProjection(roundtrip).targetAssets.isNaN)
    }
    func testHouseholdFundingEditorStoresScopedRulesAndPreviewsEvidence() async throws {
        let paths = try emptyWorkspace(sourceIDs: ["source-a", "source-b"])
        defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let store = FinancialStore(); await store.loadWorkspace(paths)
        XCTAssertNil(store.error)
        let original = try paths.readState(), evidence = try Data(contentsOf: original.review.appendingPathComponent("payment-evidence.json"))
        var draft = HouseholdSettingsDraft(try store.readHouseholdSettings())
        draft.members.append(.init(memberID: "synthetic-member", name: "Synthetic member", active: true, exclusionAllowed: false))
        draft.accounts.append(.init(accountID: "synthetic-account", name: "Synthetic account", ownerID: "synthetic-member", active: true, currency: "CNY"))
        draft.routes.append(.init(platform: "alipay", sourceID: "source-a", sourceAccountName: "Synthetic card",
            targetID: "synthetic-account", confirmed: true, basis: "From-zero declaration"))
        draft.aliases.append(.init(platform: "wechat", paymentChannel: "Synthetic pass-through", confirmed: true, basis: "From-zero non-funding declaration"))
        draft.sourceOwners[0].memberID = "synthetic-member"
        let (plan, impact) = try draft.preparePreview()
        XCTAssertEqual(impact.evidenceCount, 2); XCTAssertEqual(impact.changedFundingCount, 1)
        XCTAssertEqual(impact.resolvedCount, 1); XCTAssertEqual(impact.needsReviewCount, 1)
        XCTAssertEqual(impact.conflictingCount, 0)
        XCTAssertEqual(impact.changedSourceOwnerCount, 1)
        XCTAssertEqual(try paths.readState().pointer, original.pointer)
        let saved = await store.persistHouseholdSettings(plan); XCTAssertTrue(saved, store.error ?? "")
        let current = try paths.readState(), settings = try store.readHouseholdSettings().settings
        XCTAssertEqual(try Data(contentsOf: current.review.appendingPathComponent("payment-evidence.json")), evidence)
        XCTAssertEqual(settings.routes.first?.selector["source_id"], "source-a")
        XCTAssertEqual(settings.sourceOwners.first?.memberID, "synthetic-member")
        XCTAssertEqual(try settings.resolveFunding(.init(platform: "wechat", paymentChannel: "Synthetic pass-through")).status, "non_funding")
        XCTAssertEqual(try settings.resolveFunding(.init(platform: "alipay", sourceID: "source-b", sourceAccountName: "Synthetic card")).status, "needs_review")
    }
    func testHouseholdFundingEditorKeepsExactSourceIDsAndConflictsPending() async throws {
        let identifiers = ["\u{e9}", "e\u{301}"]
        let paths = try emptyWorkspace(sourceIDs: identifiers); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let store = FinancialStore(); await store.loadWorkspace(paths)
        XCTAssertNil(store.error)
        var draft = HouseholdSettingsDraft(try store.readHouseholdSettings())
        for suffix in ["a", "b"] {
            draft.members.append(.init(memberID: "member-" + suffix, name: "Synthetic " + suffix, active: true, exclusionAllowed: false))
            draft.accounts.append(.init(accountID: "account-" + suffix, name: "Synthetic " + suffix, ownerID: nil, active: true, currency: "CNY"))
        }
        draft.sourceOwners[0].memberID = "member-a"; draft.sourceOwners[1].memberID = "member-b"
        draft.routes.append(.init(platform: "alipay", sourceAccountName: "Synthetic card", targetID: "account-a", confirmed: true, basis: "Explicit general rule"))
        draft.routes.append(.init(platform: "alipay", sourceID: identifiers[0], sourceAccountName: "Synthetic card", targetID: "account-b", confirmed: true, basis: "Explicit overlapping rule"))
        let (plan, impact) = try draft.preparePreview()
        XCTAssertEqual(impact.needsReviewCount, 1); XCTAssertEqual(impact.resolvedCount, 1)
        XCTAssertEqual(impact.conflictingCount, 1)
        XCTAssertEqual(impact.changedSourceOwnerCount, 2)
        let saved = await store.persistHouseholdSettings(plan); XCTAssertTrue(saved, store.error ?? "")
        let reloaded = HouseholdSettingsDraft(try store.readHouseholdSettings())
        XCTAssertEqual(reloaded.sourceOwners.count, 2)
        XCTAssertEqual(reloaded.sourceOwners[0].memberID, "member-a"); XCTAssertEqual(reloaded.sourceOwners[1].memberID, "member-b")
        let sourceKeys = try ReleaseCanonicalJSON.canonicalObjectEntries(raw: plan.candidate.policiesData).first { $0.key == "source_owners" }!.value
        XCTAssertEqual(Set(try ReleaseCanonicalJSON.canonicalObjectEntries(raw: sourceKeys).map { Data($0.key.utf8) }), Set(identifiers.map { Data($0.utf8) }))
    }
    func testHouseholdSettingsStalePreviewCannotOverwriteNewState() async throws {
        let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let store = FinancialStore(); await store.loadWorkspace(paths)
        let session = try XCTUnwrap(store.workspaceEditSession)
        var first = HouseholdSettingsDraft(try store.readHouseholdSettings())
        first.name = "First explicit edit"
        var second = first; second.name = "Stale edit"
        let stalePlan = try second.prepare()
        let saved = try session.writeHouseholdSettings(first.prepare())
        XCTAssertThrowsError(try session.writeHouseholdSettings(stalePlan))
        XCTAssertEqual(try paths.readState().pointer, saved.pointer)
    }
    func testHouseholdSettingsPreviewCannotBypassSyncOrWritePause() async throws {
        let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let store = FinancialStore(); await store.loadWorkspace(paths)
        var draft = HouseholdSettingsDraft(try store.readHouseholdSettings()); draft.name = "Blocked edit"
        let plan = try draft.prepare(), original = try paths.readState().pointer
        store.editorPauseReason = "Synthetic pause"
        XCTAssertThrowsError(try XCTUnwrap(store.workspaceEditSession).writeHouseholdSettings(plan))
        store.editorPauseReason = nil
        try FileManager.default.createDirectory(at: paths.device, withIntermediateDirectories: true)
        try WorkspaceIO.atomicWrite(Data("{}".utf8), to: paths.device.appendingPathComponent("family-connection.json"))
        XCTAssertThrowsError(try store.readHouseholdSettings())
        XCTAssertThrowsError(try XCTUnwrap(store.workspaceEditSession).writeHouseholdSettings(plan))
        XCTAssertEqual(try paths.readState().pointer, original)
    }
    func testEmptyReadIsPinnedAndNeverInitializesImmutableState() async throws {
        let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let old = try paths.readState(), bytes = try Data(contentsOf: old.manifest)
        let store = FinancialStore(); await store.loadWorkspace(paths)
        XCTAssertNil(store.error)
        XCTAssertNotNil(store.report); XCTAssertEqual(store.report?.records.count, 0)
        XCTAssertNil(store.report?.cutoff); XCTAssertEqual(store.from, ""); XCTAssertEqual(store.to, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.review.appendingPathComponent("category-catalog.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.review.appendingPathComponent("financial-review.sqlite3").path))
        XCTAssertEqual(try Data(contentsOf: old.manifest), bytes)
        XCTAssertEqual(try paths.readState().pointer, old.pointer)
        XCTAssertEqual(store.workspaceState?.pointer, old.pointer)
    }
    func testEveryNativeSaveUsesNewStateAndRecordsEffects() async throws {
        let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let store = FinancialStore(); await store.loadWorkspace(paths)
        let original = try paths.readState()
        store.report?.fire_parameters.currentFireAssets += 100
        await store.persistParameters()
        XCTAssertNil(store.error)
        let parameters = try paths.readState()
        XCTAssertEqual(parameters.pointer.localRevision, original.pointer.localRevision + 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.review.appendingPathComponent("fire-parameters-user.json").path))
        await store.completion.setDeferred("synthetic", value: true, store: store)
        let workflow = try paths.readState()
        XCTAssertEqual(workflow.pointer.localRevision, parameters.pointer.localRevision + 1)
        XCTAssertTrue(store.completion.deferred.contains("synthetic"))
        let catalog = try XCTUnwrap(store.categoryCatalog)
        var changed = catalog; _ = try changed.addPrimary(name: "Synthetic new classification")
        let saved = await store.saveCategoryCatalog(changed, expected: catalog)
        XCTAssertTrue(saved, store.error ?? "")
        let categorized = try paths.readState()
        XCTAssertEqual(categorized.pointer.localRevision, workflow.pointer.localRevision + 1)
        await store.discoverMerchantTags()
        XCTAssertNil(store.error)
        let scanned = try paths.readState()
        XCTAssertEqual(scanned.pointer.localRevision, categorized.pointer.localRevision + 1)
        let ledger = try WorkspaceIO.object(Data(contentsOf: scanned.operationResults))
        let results = try XCTUnwrap(ledger["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results.allSatisfy { $0["algorithm_version"] as? String == "native-edit" })
        let entities = results.flatMap { $0["membership"] as? [[String: Any]] ?? [] }.compactMap { $0["entity_key"] as? String }
        XCTAssertTrue(entities.contains("document:review/fire-parameters-user.json"))
        XCTAssertTrue(entities.contains("document:review/completion-workflow.json"))
        XCTAssertTrue(entities.contains("document:review/category-catalog.json"))
        XCTAssertTrue(entities.contains { $0.hasPrefix("table-schema:config/merchant-tag-discovery.sqlite3:") })
        try WorkspaceIO.validateManifest(original, validateFiles: true)
        try WorkspaceIO.validateManifest(parameters, validateFiles: true)
    }

    func testClientCommitPauseBlocksEveryLocalSaveWithoutChangingPointer() async throws {
        let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let store = FinancialStore(); await store.loadWorkspace(paths)
        let original = try paths.readState()
        store.editorPauseReason = "正在切换已验证的 client snapshot。"
        store.report?.fire_parameters.currentFireAssets += 100
        store.saveParameters()
        await store.persistParameters()
        await store.completion.setDeferred("paused", value: true, store: store)
        let catalog = try XCTUnwrap(store.categoryCatalog)
        var changed = catalog; _ = try changed.addPrimary(name: "Paused classification")
        let saved = await store.saveCategoryCatalog(changed, expected: catalog)
        XCTAssertFalse(saved)
        XCTAssertFalse(store.editingAvailable); XCTAssertTrue(store.categoryBusy)
        XCTAssertEqual(try paths.readState().pointer, original.pointer)
        XCTAssertFalse(store.completion.deferred.contains("paused"))
        let session = try XCTUnwrap(store.workspaceEditSession)
        XCTAssertThrowsError(try session.write { _, _ in "blocked" })
        await store.loadWorkspace(paths)
        XCTAssertNotNil(store.editorPauseReason, "A verified snapshot reload must not release the driver's pause.")
        store.editorPauseReason = nil
        store.report?.fire_parameters.currentFireAssets += 100
        await store.persistParameters()
        XCTAssertEqual(try paths.readState().pointer.localRevision, original.pointer.localRevision + 1)
    }

    func testRuntimeFailurePreservesReadableStateAndBlocksWritesAndProcessor() async throws {
        let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let store = FinancialStore(); await store.loadWorkspace(paths)
        store.workspaceRuntimeTask?.cancel()
        let original = try paths.readState()
        let olderProbe = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        store.workspaceRuntimeTask = olderProbe
        await store.recordWorkspaceRuntimeFailure("Functional probe failed", paths: paths)
        XCTAssertTrue(olderProbe.isCancelled, "An older qualification task cannot restore availability after an integrity failure.")
        XCTAssertNotNil(store.report)
        XCTAssertFalse(store.processorAvailable); XCTAssertFalse(store.editingAvailable)
        store.report?.fire_parameters.currentFireAssets += 100
        await store.persistParameters()
        await store.completion.setDeferred("failed-runtime", value: true, store: store)
        XCTAssertEqual(try paths.readState().pointer, original.pointer)
        let session = try XCTUnwrap(store.workspaceEditSession)
        XCTAssertThrowsError(try session.write { _, _ in "blocked" })
        store.applyWorkspaceRuntimeQualification(.qualified(manifestSHA256: String(repeating: "a", count: 64)))
        XCTAssertTrue(store.editingAvailable)
        XCTAssertTrue(store.processorAvailable)
        // Runtime qualification never overrides a restored client's authority.
        store.workspaceProcessorEligible = false
        XCTAssertFalse(store.processorAvailable)
    }

    func testCurrentMacHostAndClientsSaveConflictQueueAndReopenOffline() async throws {
        #if !DEBUG
        throw XCTSkip("Explicit development runtime is a Debug-only test path.")
        #else
        let hostPaths = try emptyWorkspace()
        let parent = hostPaths.workspace
        var project = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { project.deleteLastPathComponent() }
        let configuration = parent.appendingPathComponent("processor-location.json")
        try WorkspaceIO.atomicWrite(JSONEncoder().encode(["project": project.path, "python": try python().path]), to: configuration)
        let previous = ProcessInfo.processInfo.environment["BANKING_PROCESSOR_CONFIG"]
        setenv("BANKING_PROCESSOR_CONFIG", configuration.path, 1)
        defer {
            if let previous { setenv("BANKING_PROCESSOR_CONFIG", previous, 1) } else { unsetenv("BANKING_PROCESSOR_CONFIG") }
            try? FileManager.default.removeItem(at: parent)
        }
        // The provider and clients are sibling containers, outside the host.
        let provider = parent.deletingLastPathComponent().appendingPathComponent("current-family-" + UUID().uuidString)
        let clientContainer = try WorkspacePaths(workspace: parent.deletingLastPathComponent().appendingPathComponent("current-client-" + UUID().uuidString))
        let peerContainer = try WorkspacePaths(workspace: parent.deletingLastPathComponent().appendingPathComponent("current-peer-" + UUID().uuidString))
        defer { for url in [provider, clientContainer.workspace, peerContainer.workspace] { try? FileManager.default.removeItem(at: url) } }
        let connection = try ReviewFamilyHost.create(paths: hostPaths, remote: provider)
        let host = FinancialStore(); await host.loadWorkspace(hostPaths)
        await host.familyHostSyncController?.stopAndWait()
        defer { host.familyHostSyncController?.stop() }
        await host.workspaceRuntimeTask?.value
        XCTAssertNil(host.workspaceRuntimeFailure)
        XCTAssertTrue(host.editingAvailable)
        let before = try hostPaths.readPointer()
        host.report?.fire_parameters.currentFireAssets = 12345
        await host.persistParameters()
        XCTAssertNil(host.error)
        XCTAssertEqual(try hostPaths.readPointer().localRevision, before.localRevision + 1)
        let driver = try ReviewFamilySyncDriver(paths: hostPaths, connection: connection)
        _ = try await driver.synchronize()
        let client = FinancialStore(), peer = FinancialStore()
        try await client.connectWorkspaceClient(paths: clientContainer, remote: provider, evidence: nil, connectionSaved: {})
        await client.familyClientSyncController?.stopAndWait()
        try await peer.connectWorkspaceClient(paths: peerContainer, remote: provider, evidence: nil, connectionSaved: {})
        await peer.familyClientSyncController?.stopAndWait()
        defer { client.familyClientSyncController?.stop(); peer.familyClientSyncController?.stop() }
        XCTAssertNotNil(client.report, client.syncStatus + " " + (client.error ?? ""))
        XCTAssertEqual(client.report?.fire_parameters.currentFireAssets, 12345)
        XCTAssertFalse(client.processorAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clientContainer.activeState.path))
        client.report?.fire_parameters.currentFireAssets = 23456
        await client.persistParameters()
        peer.report?.fire_parameters.currentFireAssets = 34567
        await peer.persistParameters()
        XCTAssertNil(client.error); XCTAssertNil(peer.error)
        try await ReviewFamilyClientSession.transfer(paths: clientContainer)
        try await ReviewFamilyClientSession.transfer(paths: peerContainer)
        _ = try await driver.synchronize()
        let hostChoices = try ReviewFamilyHost.conflictState(paths: hostPaths)
        XCTAssertEqual(hostChoices.options["parameter/currentFireAssets"], ["23456", "34567"])
        let observed = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: clientContainer))
        XCTAssertEqual(Set(observed.conflicts["parameter/currentFireAssets"] ?? []), ["23456", "34567"])
        let resolved = try ReviewFamilyClientSession.resolveConflicts(paths: clientContainer, expected: observed,
            choices: ["parameter/currentFireAssets": "23456"])
        XCTAssertNil(resolved.conflicts["parameter/currentFireAssets"])
        XCTAssertThrowsError(try ReviewFamilyClientSession.resolveConflicts(paths: clientContainer, expected: observed,
            choices: ["parameter/currentFireAssets": "34567"]))
        try await client.loadFamilyClient(paths: clientContainer, handle: resolved)
        let material = parent.appendingPathComponent("pending.csv")
        try WorkspaceIO.atomicWrite(Data("date,amount,title\n2026-10-01,12.34,Client request\n".utf8), to: material)
        await client.importMaterials([material]); XCTAssertNil(client.error)
        let requestID = try XCTUnwrap(client.workspaceRequestStatuses.keys.first)
        await client.updateWorkspaceRequest(requestID, cancel: true)
        XCTAssertEqual(client.workspaceRequestStatuses[requestID], "cancelled")
        await client.updateWorkspaceRequest(requestID, cancel: false)
        XCTAssertEqual(client.workspaceRequestStatuses, [requestID: "queued"])
        let offline = provider.appendingPathExtension("offline")
        try FileManager.default.moveItem(at: provider, to: offline)
        defer { try? FileManager.default.removeItem(at: offline) }
        let reopened = FinancialStore(); await reopened.loadWorkspace(clientContainer)
        XCTAssertNil(reopened.error)
        XCTAssertTrue(reopened.editingAvailable); XCTAssertFalse(reopened.processorAvailable)
        XCTAssertTrue(reopened.materialImportAvailable)
        XCTAssertEqual(reopened.report?.fire_parameters.currentFireAssets, 23456)
        XCTAssertEqual(reopened.workspaceRequestStatuses, [requestID: "queued"])
        await reopened.importMaterials([material]); XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.workspaceRequestStatuses.count, 2)
        let oldDescriptor = try WorkspaceIO.read(clientContainer.device.appendingPathComponent("family-connection.json"))
        let wrong = parent.deletingLastPathComponent().appendingPathComponent("wrong-family-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: wrong) }
        var marker = try WorkspaceIO.object(WorkspaceIO.read(offline.appendingPathComponent("family.json")))
        marker["binding_id"] = UUID().uuidString.lowercased()
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(marker), to: wrong.appendingPathComponent("family.json"))
        do {
            try await reopened.reconnectWorkspaceSync(paths: clientContainer, remote: wrong, evidence: nil,
                connectionSaved: { XCTFail("Wrong family cannot become the selected connection") })
            XCTFail("Wrong family must fail")
        } catch {}
        XCTAssertEqual(try WorkspaceIO.read(clientContainer.device.appendingPathComponent("family-connection.json")), oldDescriptor)
        try FileManager.default.moveItem(at: offline, to: provider)
        try await reopened.reconnectWorkspaceSync(paths: clientContainer, remote: provider, evidence: nil, connectionSaved: {})
        await reopened.familyClientSyncController?.stopAndWait()
        XCTAssertNil(reopened.workspacePaths)
        XCTAssertEqual(reopened.familyClientHandle?.selection, connection.selection)
        #endif
    }

    func testFirstReliableCoverageReplacesEmptyDatesThenPreservesUserRange() async throws {
        let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let store = FinancialStore(); await store.loadWorkspace(paths)
        XCTAssertEqual(store.from, "")
        let state = try paths.readState()
        let (_, committed) = try WorkspaceEditSession(paths: paths, state: state).write { review, _ in
            var coverage = try WorkspaceIO.object(Data(contentsOf: review.appendingPathComponent("coverage.json")))
            coverage["mode"] = "automatic"; coverage["from"] = "2025-12-20"; coverage["to"] = "2026-09-13"
            coverage["observed_from"] = "2025-12-20"; coverage["observed_to"] = "2026-09-13"; coverage["revision"] = 1
            coverage["basis"] = ["kind": "reliable-observations", "source_ids": []] as [String: Any]
            for (name, key) in [("financial-review.json", "cutoff"), ("payment-evidence.json", "backfill_cutoff_date")] {
                var document = try WorkspaceIO.object(Data(contentsOf: review.appendingPathComponent(name)))
                document[key] = "2026-09-13"; document["coverage"] = coverage
                try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(document), to: review.appendingPathComponent(name))
            }
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(coverage), to: review.appendingPathComponent("coverage.json"))
        }
        store.adoptWorkspaceState(committed)
        await store.loadWorkspace(paths)
        XCTAssertNil(store.error); XCTAssertEqual(store.from, "2025-12-20"); XCTAssertEqual(store.to, "2026-09-13")
        store.from = "2026-02-01"; store.to = "2026-07-31"
        await store.loadWorkspace(paths)
        XCTAssertEqual(store.from, "2026-02-01"); XCTAssertEqual(store.to, "2026-07-31")
    }
    func testHeldGateAndStaleHandleNeverWrite() async throws {
        let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let state = try paths.readState(), coordinator = WorkspaceCoordinator(paths: paths)
        var token: WorkspaceWriteToken? = try coordinator.acquireWriteToken()
        XCTAssertThrowsError(try WorkspaceEditSession(paths: paths, state: state).write { root, _ in
            try Data("{}".utf8).write(to: root.appendingPathComponent("should-not-write.json"))
        })
        withExtendedLifetime(token) {}; token = nil
        let session = WorkspaceEditSession(paths: paths, state: state)
        _ = try session.write { root, _ in try Data("{}".utf8).write(to: root.appendingPathComponent("test-extra.json")) }
        XCTAssertThrowsError(try session.write { _, _ in () })
        XCTAssertEqual(try paths.readPointer().localRevision, state.pointer.localRevision + 1)
    }
    func testBusinessValidationRefusesFutureProjectionOrDanglingAssetBeforeCommit() throws {
        let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let original = try paths.readState()
        let session = WorkspaceEditSession(paths: paths, state: original)
        XCTAssertThrowsError(try session.write { root, _ in
            let file = root.appendingPathComponent("financial-review.json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            object["dataset_id"] = 999
            try JSONSerialization.data(withJSONObject: object).write(to: file)
        })
        XCTAssertThrowsError(try session.write { root, _ in
            let file = root.appendingPathComponent("payment-evidence.json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            object["future_asset"] = ["path": "missing.png", "sha256": String(repeating: "a", count: 64)]
            try JSONSerialization.data(withJSONObject: object).write(to: file)
        })
        XCTAssertEqual(try paths.readPointer(), original.pointer)
        try WorkspaceIO.validateManifest(original, validateFiles: true)
    }
    func testProcessorCommitWinsWhenExternalResultIsMissingOrProcessTimesOut() async throws {
        for mode in ["exit", "hang"] {
            let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
            let code = paths.workspace.deletingLastPathComponent().appendingPathComponent("native-processor-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: code.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: code) }
            var project = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { project.deleteLastPathComponent() }
            let projectJSON = String(data: try JSONSerialization.data(withJSONObject: project.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
            let script = """
            import argparse,os,sys,time
            sys.path.insert(0, \(projectJSON))
            sys.path.insert(0, \(projectJSON) + '/scripts')
            from scripts.processor_result import execute_workspace
            p=argparse.ArgumentParser()
            for name in ['workspace','expected-pointer-json','operation-id','request-id','review','result-file']: p.add_argument('--'+name)
            p.add_argument('--gate-fd',type=int)
            a=p.parse_args()
            def action(transaction, retained):
                transaction.write_json('review/native-executor-test.json', {'value':1})
                return {'pending_video_sources':[]}
            result,status=execute_workspace(a.workspace,a.expected_pointer_json,a.operation_id,a.request_id,None,action,[a.review],inherited_fd=a.gate_fd)
            if status: raise RuntimeError(result)
            if '\(mode)' == 'hang': time.sleep(30)
            os._exit(7)
            """
            try Data(script.utf8).write(to: code.appendingPathComponent("scripts/app_review.py"))
            let runtime = try ProcessorRuntime(project: code, python: python())
            let original = try paths.readState()
            let executor = try ProcessorExecution(runtime: runtime, workspace: paths, state: original)
            let result = try await executor.run(operation: .review, input: Data("{}".utf8), timeout: mode == "hang" ? 0.6 : 4, terminationGrace: 0.05)
            XCTAssertTrue(result.isFullySuccessful)
            XCTAssertEqual(result.phase, "committed")
            XCTAssertEqual(try paths.readPointer().localRevision, original.pointer.localRevision + 1)
            let gate = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
            withExtendedLifetime(gate) {}
        }
    }

    func testPendingRecordingReopensRetriesOnlyMissingStageAndReleasesCancelledGate() async throws {
        let paths = try emptyWorkspace(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let code = paths.workspace.deletingLastPathComponent().appendingPathComponent("native-repair-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: code.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: code) }
        var project = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { project.deleteLastPathComponent() }
        let projectJSON = String(data: try JSONSerialization.data(withJSONObject: project.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
        let importScript = """
        import argparse,json,sqlite3,sys
        sys.path.insert(0, \(projectJSON))
        sys.path.insert(0, \(projectJSON) + '/scripts')
        from scripts.processor_result import execute_workspace
        p=argparse.ArgumentParser()
        for name in ['workspace','expected-pointer-json','operation-id','request-id','files-json','result-file']: p.add_argument('--'+name)
        p.add_argument('--gate-fd',type=int); a=p.parse_args()
        files=json.load(open(a.files_json))
        def action(transaction, retained):
            with sqlite3.connect(transaction.root/'banking.sqlite3') as db: db.execute("INSERT INTO facts VALUES('import-once')")
            transaction.write_json('review/retained-recording.json', {'original':files[0]})
            return {'pending_video_sources':[{'input_id':files[0],'reason_code':'unsupported_video_layout','reason':'待确认布局'}]}
        result,status=execute_workspace(a.workspace,a.expected_pointer_json,a.operation_id,a.request_id,a.result_file,action,files,inherited_fd=a.gate_fd)
        if status:print(result)
        raise SystemExit(status)
        """
        try Data(importScript.utf8).write(to: code.appendingPathComponent("scripts/import_review_materials.py"))
        let repairScript = """
        import argparse,json,os,sys,time
        from pathlib import Path
        sys.path.insert(0, \(projectJSON))
        sys.path.insert(0, \(projectJSON) + '/scripts')
        from scripts.processor_result import execute_workspace,InputProcessingError
        from scripts.workspace_repair import child_identity
        from scripts.workspace_state import WorkspacePaths
        p=argparse.ArgumentParser();p.add_argument('command',choices=['repair-input'])
        for name in ['workspace','expected-pointer-json','parent-request-id','input-id','result-file']:p.add_argument('--'+name,required=True)
        p.add_argument('--inherited-fd',type=int,required=True);a=p.parse_args()
        paths=WorkspacePaths(a.workspace);handle=paths.resolve_active()
        parent=next(r for r in json.load(open(handle.root/'operation-results.json'))['results'] if r['request_id']==a.parent_request_id)
        selected=next(i for i in parent['inputs'] if i['input_id']==a.input_id)
        request,operation=child_identity(handle.workspace_id,a.parent_request_id,a.input_id)
        mode=Path('mode.txt').read_text()
        def action(transaction, retained):
            if mode=='failed':raise InputProcessingError(a.input_id,'仍需确认布局')
            if mode=='cancel':Path('cancel-started').write_text('ready');time.sleep(30)
            transaction.write_json('review/repaired-recording.json', {'projected':selected['sha256']})
            return {'pending_video_sources':[]}
        result,status=execute_workspace(a.workspace,a.expected_pointer_json,operation,request,a.result_file if mode=='failed' else None,action,
            [{'path':str(handle.path(selected['source_path'])),'input_id':a.input_id,'sha256':selected['sha256'],'kind':'video','retained_source_path':selected['source_path']}],
            inherited_fd=a.inherited_fd,stage_parent_request=a.parent_request_id,algorithm_version='pending-video-projection-v1')
        if status:raise SystemExit(status)
        os._exit(7)
        """
        try Data(repairScript.utf8).write(to: code.appendingPathComponent("scripts/workspace_cli.py"))
        let source = code.appendingPathComponent("recording.mov")
        try Data("retained-video-fixture".utf8).write(to: source)
        let runtime = try ProcessorRuntime(project: code, python: python())
        let edited = FinancialStore(); await edited.loadWorkspace(paths)
        edited.report?.fire_parameters.currentFireAssets += 1
        await edited.persistParameters()
        XCTAssertNil(edited.error)
        // A freshly committed Native handle can carry directory URL slash
        // metadata differently from stateRoot; it must still admit import.
        let importer = try ProcessorExecution(runtime: runtime, workspace: paths, state: XCTUnwrap(edited.workspaceState))
        let parent = try await importer.run(operation: .import, input: JSONEncoder().encode([source.path]))
        XCTAssertEqual(parent.outcome, .partial)
        try FileManager.default.removeItem(at: source) // Retry cannot reopen original selection.
        let store = FinancialStore(); await store.loadWorkspace(paths)
        XCTAssertNil(store.error); XCTAssertEqual(store.pendingVideoCount, 1)
        let pending = try XCTUnwrap(store.pendingVideos.first)
        let original = try paths.readState()
        for mode in ["failed", "cancel", "success"] {
            try Data(mode.utf8).write(to: code.appendingPathComponent("mode.txt"))
            let executor = try ProcessorExecution(runtime: runtime, workspace: paths, state: paths.readState())
            let encoded = try JSONEncoder().encode(pending)
            if mode == "cancel" {
                let task = Task.detached { try await executor.run(operation: .repair, input: encoded, terminationGrace: 0.05) }
                defer { task.cancel() }
                let started = code.appendingPathComponent("cancel-started")
                let deadline = Date().addingTimeInterval(10)
                while !FileManager.default.fileExists(atPath: started.path), Date() < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: started.path), "Cancel after the child enters repair, rather than during preflight.")
                task.cancel()
                do { _ = try await task.value; XCTFail("cancelled repair must not commit") }
                catch is CancellationError {
                    // Swift can cancel a coordinator validation after the child
                    // has been reaped. Pointer and lease assertions below still
                    // prove cancellation did not commit or leave a writer alive.
                }
                catch let failure as ProcessorExecutionError { XCTAssertEqual(failure.reason, .cancelled) }
            } else if mode == "failed" {
                do { _ = try await executor.run(operation: .repair, input: encoded); XCTFail("failed projection must remain pending") }
                catch let failure as ProcessorExecutionError { XCTAssertEqual(failure.reason, .failed, failure.detail) }
            } else {
                let result = try await executor.run(operation: .repair, input: encoded)
                XCTAssertTrue(result.isFullySuccessful)
                XCTAssertEqual(result.requestID, try pending.childIdentity.requestID)
                XCTAssertEqual(result.operationID, try pending.childIdentity.operationID)
            }
            let reopened = FinancialStore(); await reopened.loadWorkspace(paths)
            XCTAssertNil(reopened.error)
            XCTAssertEqual(reopened.pendingVideoCount, mode == "success" ? 0 : 1)
            XCTAssertEqual(try paths.readPointer().localRevision, original.pointer.localRevision + (mode == "success" ? 1 : 0))
            let gate = try WorkspaceCoordinator(paths: paths).acquireWriteToken(); withExtendedLifetime(gate) {}
        }
        let final = try paths.readState(), ledger = try WorkspaceIO.object(WorkspaceIO.read(final.operationResults))
        let results = try XCTUnwrap(ledger["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 3)
        let effects = try XCTUnwrap(results.last?["membership"] as? [[String: Any]])
        XCTAssertEqual(effects.filter { $0["kind"] as? String == "input-stage" }.count, 1)
        var database: OpaquePointer?, statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(final.database.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT count(*) FROM facts", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

}
#endif
