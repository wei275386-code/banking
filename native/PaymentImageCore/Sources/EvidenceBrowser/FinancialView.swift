#if os(macOS) || os(iOS)
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Charts
import CoreFoundation
import Observation
import PaymentImageCore
import UniformTypeIdentifiers

@Observable @MainActor final class FinancialStore {
    var workspacePaths: WorkspacePaths?
    var workspaceState: StateHandle?
    var pinnedClientReview: URL?
    var familyClientPaths: WorkspacePaths?
    var familyClientHandle: ReviewFamilyClientHandle?
    var workspaceNotice = ""
    var workspaceWritable = true
    var workspaceProcessorEligible = true
    /// MainActor capture/commit windows pause every human write, including
    /// client-local parameter saves that do not have a workspace transaction.
    var editorPauseReason: String?
    var workspaceRuntimeNotice = ""
    var workspaceRuntimeReady = true
    var workspaceRuntimeFailure: String?
    @ObservationIgnored var workspaceRuntimeTask: Task<Void, Never>?
    @ObservationIgnored var workspaceRuntimeKey: String?
    var editingAvailable: Bool { workspaceWritable && editorPauseReason == nil && workspaceRuntimeFailure == nil }
    var processorAvailable: Bool { workspaceProcessorEligible && workspaceRuntimeReady && editorPauseReason == nil }
    var evidenceReviewAvailable: Bool {
        #if os(macOS)
        return editingAvailable && (clientWorkspacePaths != nil ? materialImportAvailable : processorAvailable)
        #else
        return editingAvailable
        #endif
    }
    var report: FinancialReport?; var root: URL?; var error: String?
    var section = "overview" { didSet { ReviewLatency.begin("navigate") } }
    var query = "" { didSet { directDetailID = nil; ReviewLatency.begin("search") } }
    var primary = "全部分类" { didSet { ReviewLatency.begin("category") } }
    var account = "全部账户" { didSet { ReviewLatency.begin("account") } }
    var selectedTags = [String]()
    var tagMatch = "all"
    var from = "2026-01-01" { didSet { ReviewLatency.begin("date.from") } }
    var to = "2026-09-13" { didSet { ReviewLatency.begin("date.to") } }
    var selected: String? { didSet { if selected != directDetailID { directDetailID = nil }; ReviewLatency.begin("select-record") } }
    var directDetailID: String?
    var overrides = [String: CategoryOverride](); var savingPercent = 20.0 { didSet { ReviewLatency.begin("saving-slider") } }
    var showingPicker = false; var pickerMode = "materials"; var importState = ""; var importing = false
    var pendingVideos = [PendingVideoInput]()
    var pendingVideoCount = 0
    #if os(macOS)
    var processorTask: Task<ProcessorResult, Error>?
    var clientWorkspacePaths: WorkspacePaths?
    var workspaceRequestStatuses = [String: String]()
    var workspaceRequestStatusesVerified = false
    var materialImportAvailable: Bool {
        if familyClientHandle != nil { return editingAvailable && pinnedClientReview != nil }
        if clientWorkspacePaths != nil {
            return editingAvailable && pinnedClientReview != nil
        }
        return processorAvailable
    }
    @ObservationIgnored var familyClientSyncController: MacFamilyClientSyncController?
    @ObservationIgnored var familyHostSyncController: MacFamilyHostSyncController?
    @ObservationIgnored var expectedWorkspacePath: String?
    @ObservationIgnored var workspaceSelectionGeneration = UUID()
    @ObservationIgnored var workspaceOpenGeneration = UUID()
    /// Internal seams for synthetic recovery and cancellation interleavings.
    @ObservationIgnored var afterWorkspaceReaderPublished: ((WorkspacePaths) async -> Void)?
    #endif
    var parameterDocument: Data?
    var savedParameterDocument: Data?
    var hasUnsavedParameters: Bool {
        guard let saved = savedParameterDocument ?? parameterDocument,
              let parameters = try? JSONDecoder().decode(FireParameters.self, from: saved) else { return false }
        return report?.fire_parameters != parameters
    }
    var recordView = "全部消费" { didSet { ReviewLatency.begin("record-mode") } }
    var parameterStatus = ""
    var syncStatus = ""
    let completion = CompletionWorkspace()
    var completionSaving = false
    var loading = false
    @ObservationIgnored private var loadGeneration = UUID()
    /// Internal suspension seam for deterministic asynchronous selection tests.
    @ObservationIgnored var beforeLoadApply: (() async -> Void)?
    var overrideDocument = Data("{}".utf8) {
        didSet { sourceVersions["review-overrides.json"] = ReviewFileVersion.of(overrideDocument) }
    }
    @ObservationIgnored var sourceVersions = [String: String]()
    var baseReport: FinancialReport?
    var categoryCatalog: CategoryCatalog?
    var categorySaving = false
    var categoryMessage = ""
    private(set) var categoryUsage = [String: Int]()
    var preparedCompletionQueues = [String: [CompletionEntry]]()
    var discoveryBusy = false
    var discoveryCandidates = [MerchantTagCandidate]()
    var discoveryRules = [MerchantTagRule]()
    var discoveryMessage = ""
    var discoveryConflicts = 0
    var discoveryConflictSamples = [MerchantTagSample]()
    @ObservationIgnored var discoveryDatabaseURL: URL?

    func importMaterials(_ urls: [URL]) async {
#if os(iOS)
        guard editorPauseReason == nil, !importing, !completionSaving, !discoveryBusy, !loading else { return }
        importing = true; defer { importing = false }
        do {
            try await MobileServices.shared.enqueue(kind: "import", payload: Data("{}".utf8), files: urls)
            importState = "素材已保存，等待 Mac 解析；完成后自动更新复盘。"; error = nil
        } catch { self.error = "导入未完成：" + error.localizedDescription }

#else
        if clientWorkspacePaths != nil {
            await enqueueWorkspaceMaterials(urls)
            return
        }
        guard let root, processorAvailable, !importing, !completionSaving, !discoveryBusy, !loading, !completion.persisting else { return }
        importing = true; importState = "正在保存原始材料、解析和更新复盘…"; error = nil
        let scopes = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() }; importing = false }
        do {
            let runtime = try await resolveWorkspaceProcessorRuntime()
            try await requireWorkspaceRuntimeQualification(runtime)
            let executor = try await makeProcessorExecution(runtime: runtime)
            let result = try await runProcessor(executor, operation: .import, input: JSONEncoder().encode(urls.map(\.path)))
            await reloadCurrent()
            guard error == nil else { importState = "素材处理已结束，但复盘刷新失败。请刷新数据。"; return }
            let failures = result.inputs.compactMap { input -> String? in
                guard let failure = input.error else { return nil }
                return URL(fileURLWithPath: input.inputID).lastPathComponent + "：" + failure.message
            }.joined(separator: "；")
            importState = result.isFullySuccessful ? "导入完成，复盘已更新。" : "部分素材处理未完成；已保存原件。" + failures
        } catch { self.error = "导入未完成：" + error.localizedDescription; importState = "" }

#endif
    }

    var editingGeneration: UUID { loadGeneration }
    func invalidatePendingLoad() { loadGeneration = UUID(); loading = false }
    private var recordRevision = 0
    var revision: Int { recordRevision }
    private var cachedAccounts = [String]()
    private var cachedTags = [String]()
    @ObservationIgnored private var searchText = [String: String]()
    @ObservationIgnored private var snapshotCache: (key: SnapshotKey, value: ReviewSnapshot)?
    @ObservationIgnored private var visibleCache: (key: SnapshotKey, mode: String, value: [FinancialLifecycle])?
    @ObservationIgnored private var allTransactionsCache: (revision: Int, value: [FinancialLifecycle])?
    var allTransactionsByAmount: [FinancialLifecycle] {
        if let cached = allTransactionsCache, cached.revision == recordRevision { return cached.value }
        let value = TransactionListOrder.sorted(report?.records ?? [])
        allTransactionsCache = (recordRevision, value)
        return value
    }
    @ObservationIgnored private var spendingCache: (key: SnapshotKey, values: [CategoryPath: [FinancialLifecycle]])?
    private struct CategoryPath: Hashable { let primary: String; let secondary: String }
    private struct SnapshotKey: Equatable {
        let revision: Int; let from: String; let to: String; let account: String; let primary: String; let query: String
        let tags: [String]; let tagMatch: String
    }
    private var snapshotKey: SnapshotKey {
        SnapshotKey(revision: recordRevision, from: from, to: to, account: account, primary: primary, query: section == "details" ? query : "", tags: selectedTags.sorted(), tagMatch: tagMatch)
    }
    private var snapshot: ReviewSnapshot {
        let key = snapshotKey
        if let cached = snapshotCache, cached.key == key { return cached.value }
        let value = ReviewSnapshot(records: report?.records ?? [], from: from, to: to, account: account, primary: primary,
                                   query: key.query, searchText: searchText, tags: key.tags, tagMatch: key.tagMatch)
        snapshotCache = (key, value)
        return value
    }

    func load(_ folder: URL, selectionIsCurrent: () -> Bool = { true }) async {
        guard selectionIsCurrent() else { return }
        if let handle = familyClientHandle, handle.review != folder {
            familyClientPaths = nil; familyClientHandle = nil
            if pinnedClientReview == handle.review { pinnedClientReview = nil }
        }
        let generation = UUID(); loadGeneration = generation; loading = true
        defer { if loadGeneration == generation { loading = false } }
        ReviewLatency.begin("load-to-overview")
        let start = DispatchTime.now().uptimeNanoseconds
        let completionFrom = completion.from, completionTo = completion.to
        let completionDataset = completion.dataset, completionRoot = completion.root, savedIDs = completion.saved
        let immutable = workspaceState?.review == folder || pinnedClientReview == folder
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let bytes = try Data(contentsOf: ReviewDataSource.url("financial-review.json", root: folder))
                let decoder = JSONDecoder()
                var report = try decoder.decode(FinancialReport.self, from: bytes)
                let rawReport = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                var document = try JSONSerialization.data(withJSONObject: rawReport["fire_parameters"]!)
                let overrideURL = folder.appendingPathComponent("review-overrides.json")
                let persistedOverrides = FileManager.default.fileExists(atPath: overrideURL.path) ? try Data(contentsOf: overrideURL) : nil
                let overrideBytes = persistedOverrides ?? Data("{}".utf8)
                let overrides = try decoder.decode([String: CategoryOverride].self, from: overrideBytes)
                report.records = SourceRecordSets.baselineRecords(report)
                let base = report
                let catalog = try immutable ? CategoryCatalogFile.read(root: folder, taxonomy: report.taxonomy, records: report.records) : CategoryCatalogFile.load(root: folder, taxonomy: report.taxonomy, records: report.records)
                Self.applyCompletion(overrides, to: &report, catalog: catalog)
                let user = try? Data(contentsOf: folder.appendingPathComponent("fire-parameters-user.json"))
                if let user {
                    document = try ParameterDocument.merging(base: document, changes: user)
                    report.fire_parameters = try decoder.decode(FireParameters.self, from: document)
                }
                let accounts = Array(Set(report.records.flatMap(\.account_views))).sorted()
                let search = Self.searchIndex(report.records)
                let ids = completionRoot == folder && completionDataset == report.dataset_id ? savedIDs : []
                let queues = CompletionQueue.prepared(report, from: completionFrom, to: completionTo, includeIDs: ids, rootPath: folder.path)
                let versions = ["financial-review.json": ReviewFileVersion.of(bytes), "review-overrides.json": ReviewFileVersion.of(persistedOverrides), "fire-parameters-user.json": ReviewFileVersion.of(user), "category-catalog.json": ReviewFileVersion.of(try? Data(contentsOf: folder.appendingPathComponent("category-catalog.json")))]
                return (report, document, overrides, accounts, search, base, overrideBytes, queues, versions, catalog)
            }.value
            ReviewLatency.record("financial-load-worker", milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            if let beforeLoadApply { await beforeLoadApply() }
            guard loadGeneration == generation, selectionIsCurrent() else { return }
            let previousCutoff = report?.cutoff
            if let cutoff = loaded.0.cutoff {
                if report == nil || previousCutoff == nil { from = loaded.0.coverage?.from ?? String(cutoff.prefix(4)) + "-01-01" }
                if previousCutoff == nil || to == previousCutoff { to = cutoff } else { to = min(to, cutoff) }
            } else { from = ""; to = "" }
            report = loaded.0; root = folder; parameterDocument = loaded.1; savedParameterDocument = loaded.1; overrides = loaded.2
            baseReport = loaded.5; overrideDocument = loaded.6; preparedCompletionQueues = loaded.7
            sourceVersions = loaded.8
            let previousCatalog = categoryCatalog
            categoryCatalog = loaded.9
            if previousCatalog != loaded.9 { rebaseCategoryDrafts(using: loaded.9, previous: previousCatalog) }
            rebasePrimaryFilter(using: loaded.9, previous: previousCatalog)
            completion.owner = self
            completion.resetContext(folder: folder, datasetID: loaded.0.dataset_id)
            cachedAccounts = loaded.3; searchText = loaded.4; recordRevision += 1
            cachedTags = Array(Set(loaded.0.records.flatMap(\.components).flatMap(\.tags))).sorted()
            updateCategoryUsage(); snapshotCache = nil; visibleCache = nil; error = nil
            #if os(macOS)
            Task { [weak self] in
                guard let self, !immutable, self.root == folder, self.loadGeneration == generation else { return }
                await self.discoverMerchantTags()
            }
            #endif
        } catch { if loadGeneration == generation, selectionIsCurrent() { self.error = "无法读取财务复盘：" + error.localizedDescription } }
    }
    nonisolated static func applyCompletion(_ overrides: [String: CategoryOverride], to report: inout FinancialReport, catalog: CategoryCatalog? = nil) {
        FinancialEffectiveProjection.applyCompletion(overrides, to: &report, catalog: catalog)
    }
    var categoryBusy: Bool { !editingAvailable || categorySaving || completionSaving || loading || importing || completion.persisting || discoveryBusy }

    func categoryTransactions(primaryID: String, secondaryID: String? = nil) -> [CompletionEntry] {
        guard let catalog = categoryCatalog, let report,
              let parent = catalog.primaries.first(where: { $0.id == primaryID }) else { return [] }
        let names = Set(catalog.secondaries.filter { $0.primaryID == primaryID && (secondaryID == nil || $0.id == secondaryID) }.map(\.name))
        var entries = [CompletionEntry]()
        for record in report.records {
            for component in record.components where component.primary == parent.name && names.contains(component.secondary) {
                entries.append(CompletionEntry(id: component.id, datasetID: report.dataset_id, rootPath: root?.path ?? "", record: record, component: component, issues: [], rank: 0, impact: component.net_cents))
            }
        }
        return TransactionListOrder.sorted(entries, amount: { $0.amountUnknown ? nil : $0.impact }, date: { $0.record.date }, id: \.id)
    }

    /// A directory change is one write. Rebuild the projection off the main
    /// thread; amounts, original evidence and the override history stay intact.
    func saveCategoryCatalog(_ next: CategoryCatalog, expected: CategoryCatalog) async -> Bool {
        guard !categoryBusy, let root, let baseReport, let report, categoryCatalog == expected else {
            error = "分类目录已更新或正在保存，请关闭表单后重试。"; return false
        }
        categorySaving = true; completionSaving = true
        defer { categorySaving = false; completionSaving = false }
        let currentOverrides = overrides
        do {
            let context = try editContext()
            let session = workspaceEditSession
            let client = familyClientEditSession
            let verifiedClient = pinnedClientReview != nil
            let result = try await Task.detached(priority: .userInitiated) {
                @Sendable func write(_ root: URL) throws -> (CategoryCatalog, FinancialReport, [String: String], Data) {
                let lease = try session == nil ? ReviewProcessLease(root: root) : nil
                defer { withExtendedLifetime(lease) {} }
                try context.validateOnDisk()
                let validated = try next.validated()
                if session != nil || client != nil { _ = try CategoryCatalogFile.load(root: root, taxonomy: baseReport.taxonomy, records: baseReport.records) }
                try CategoryCatalogFile.save(validated, root: root, expected: expected)
                var effective = baseReport
                Self.applyCompletion(currentOverrides, to: &effective, catalog: validated)
                return (validated, effective, Self.searchIndex(effective.records), try Data(contentsOf: root.appendingPathComponent("category-catalog.json")))
                }
                if let session {
                    let (value, state) = try await session.writeScheduled { root, _ in try write(root) }
                    return (value.0, value.1, value.2, value.3, Optional(state), Optional<ReviewFamilyClientHandle>.none)
                }
                if let client {
                    let (value, handle) = try client.write { root, _ in try write(root) }
                    return (value.0, value.1, value.2, value.3, Optional<StateHandle>.none, Optional(handle))
                }
                let value = try Self.withLocalReviewMutation(root: root, verifiedClient: verifiedClient) { try write(root) }
                return (value.0, value.1, value.2, value.3, Optional<StateHandle>.none, Optional<ReviewFamilyClientHandle>.none)
            }.value
            guard isCurrent(context) else { error = "分类已保存，但资料库已重新加载，请刷新后查看。"; return false }
            categoryCatalog = result.0
            var effective = result.1; effective.fire_parameters = report.fire_parameters
            self.report = effective
            rebaseCategoryDrafts(using: result.0, previous: expected)
            rebasePrimaryFilter(using: result.0, previous: expected)
            sourceVersions["category-catalog.json"] = ReviewFileVersion.of(result.3)
            preparedCompletionQueues = [:]
            invalidateCompletionCaches(search: result.2)
            if let state = result.4 { adoptWorkspaceState(state) }
            if let handle = result.5 { adoptFamilyClientEdit(handle) }
            categoryMessage = "分类已保存；已应用到全部资料库。"; error = nil
            return true
        } catch { self.error = "分类未保存：" + error.localizedDescription; return false }
    }
    private func rebasePrimaryFilter(using catalog: CategoryCatalog, previous: CategoryCatalog?) {
        guard primary != "全部分类" else { return }
        if let id = previous?.primaries.first(where: { $0.name == primary })?.id,
           let renamed = catalog.primaries.first(where: { $0.id == id }) { primary = renamed.name }
        else if !catalog.primaries.contains(where: { $0.name == primary }) { primary = "全部分类" }
    }
    private func rebaseCategoryDrafts(using catalog: CategoryCatalog, previous: CategoryCatalog?) {
        let resolver = CategoryResolver(catalog: catalog)
        func update(_ value: CompletionDraft) -> CompletionDraft {
            var draft = value
            if value.secondary.isEmpty {
                if let id = previous?.primaries.first(where: { $0.name == value.primary })?.id,
                   let renamed = catalog.primaries.first(where: { $0.id == id }) { draft.primary = renamed.name; return draft }
                if catalog.primaries.contains(where: { $0.name == value.primary }) { return draft }
            }
            let path = resolver.resolve(primary: value.primary, secondary: value.secondary)
            draft.primary = path.primary; draft.secondary = path.secondary
            return draft
        }
        completion.drafts = completion.drafts.mapValues(update)
        completion.draftBases = completion.draftBases.mapValues(update)
        // Prior field-write undo cannot reinstate a deleted classification.
        completion.undo = nil
    }

    private func updateCategoryUsage() {
        guard let catalog = categoryCatalog, let report else { categoryUsage = [:]; return }
        let parents = Dictionary(uniqueKeysWithValues: catalog.primaries.map { ($0.id, $0.name) })
        let paths = Dictionary(uniqueKeysWithValues: catalog.secondaries.map { ((parents[$0.primaryID] ?? "") + "\u{1f}" + $0.name, $0.id) })
        var counts = [String: Int]()
        for record in report.records {
            for component in record.components {
                if let id = paths[component.primary + "\u{1f}" + component.secondary] { counts[id, default: 0] += 1 }
            }
        }
        categoryUsage = counts
    }

    func applyOverrides() {
        guard let current = report, var next = baseReport else { return }
        next.fire_parameters = current.fire_parameters
        Self.applyCompletion(overrides, to: &next, catalog: categoryCatalog)
        cachedAccounts = Array(Set(next.records.flatMap(\.account_views))).sorted()
        report = next; recordRevision += 1; snapshotCache = nil; visibleCache = nil; preparedCompletionQueues = [:]
        cachedTags = Array(Set(next.records.flatMap(\.components).flatMap(\.tags))).sorted()
        searchText = Self.searchIndex(next.records); updateCategoryUsage()
        #if os(macOS)
        Task { [weak self] in await self?.discoverMerchantTags() }
        #endif
    }
    func adoptProjection(_ effective: FinancialReport) {
        report?.records = effective.records
        report?.source_record_sets = effective.source_record_sets
        report?.source_record_set_candidates = effective.source_record_set_candidates
    }
    nonisolated static func searchIndex(_ records: [FinancialLifecycle]) -> [String: String] {
        var result = [String: String]()
        for record in records {
            var parts = [record.title, record.date, record.user_id ?? "", record.userDisplayName, record.traceSearchText]
            for c in record.components {
                parts.append(c.title); parts.append(contentsOf: c.tags)
                parts.append(money(c.net_cents)); parts.append(String(format: "%.2f", Double(c.net_cents) / 100))
            }
            result[record.id] = parts.joined(separator: " ")
        }
        return result
    }
    func invalidateCompletionCaches(search: [String: String]? = nil, tags: [String]? = nil) {
        guard let report else { return }
        cachedAccounts = Array(Set(report.records.flatMap(\.account_views))).sorted()
        recordRevision += 1; snapshotCache = nil; visibleCache = nil
        updateCategoryUsage()
        cachedTags = tags ?? Array(Set(report.records.flatMap(\.components).flatMap(\.tags))).sorted()
        searchText = search ?? Self.searchIndex(report.records)
    }
    func resetFireInputs() async {
        if familyClientHandle != nil {
            guard editingAvailable, !categoryBusy, let original = report?.fire_parameters, let document = parameterDocument, let root else { return }
            do {
                let empty = try FireParameters.emptyInputs()
                report?.fire_parameters = empty; parameterDocument = try ParameterDocument.encoding(empty)
                await persistParameters()
                if error != nil, self.root == root { report?.fire_parameters = original; parameterDocument = document }
            } catch { self.error = error.localizedDescription }
            return
        }
        guard editingAvailable, !completionSaving, !discoveryBusy, !categorySaving, !loading, !importing, !completion.persisting,
              let paths = workspacePaths, let original = report?.fire_parameters, let document = parameterDocument else {
            error = "当前资料暂不能清空个人假设。"; return
        }
        let expectedPointer = workspaceState?.pointer
        do {
            try ReviewFamilyHost.requireSettingsWriter(paths: paths)
            let empty = try FireParameters.emptyInputs()
            report?.fire_parameters = empty
            parameterDocument = try ParameterDocument.encoding(empty)
            await persistParameters()
            if error != nil, workspacePaths?.workspace.path == paths.workspace.path, workspaceState?.pointer == expectedPointer {
                report?.fire_parameters = original; parameterDocument = document
            }
        } catch {
            guard workspacePaths?.workspace.path == paths.workspace.path, workspaceState?.pointer == expectedPointer else { return }
            self.error = error.localizedDescription
        }
    }
    func saveParameters() {
        guard editingAvailable else { error = editorPauseReason ?? workspaceRuntimeFailure ?? "当前资料仅支持查看。"; return }
        if workspacePaths == nil && familyClientHandle == nil { saveLocalReviewParameters() }
        else { Task { await persistParameters() } }
    }
    /// Standalone review files share one final-write mutex; family clients use their queue.
    nonisolated static func withLocalReviewMutation<T>(root: URL, verifiedClient: Bool,
                                                       operation: () throws -> T) throws -> T {
        if verifiedClient { return try operation() }
        let lease = try ReviewProcessLease(root: root, name: "local-edit")
        defer { withExtendedLifetime(lease) {} }
        return try operation()
    }
    private func saveLocalReviewParameters() {
        guard editingAvailable, !completionSaving, !discoveryBusy, !categorySaving, !loading, !importing, !completion.persisting, let report, let root else { return }
        let p = report.fire_parameters
        if let message = p.inputValidationMessage { error = message; return }
        do {
            let changes = try ParameterDocument.encoding(report.fire_parameters)
            let original = savedParameterDocument ?? parameterDocument ?? changes
            let draft = try ParameterDocument.merging(base: parameterDocument ?? changes, changes: changes)
            let merged = try Self.withLocalReviewMutation(root: root, verifiedClient: pinnedClientReview != nil) {
                try ReviewSyncIO.coordinate(root.appendingPathComponent("fire-parameters-user.json"), write: true) { file in
                let live = FileManager.default.fileExists(atPath: file.path) ? try ParameterDocument.merging(base: original, changes: Data(contentsOf: file)) : original
                let rebased = try ParameterDocument.rebasing(original: original, draft: draft, onto: live)
                _ = try JSONDecoder().decode(FireParameters.self, from: rebased)
                try rebased.write(to: file, options: .atomic)
                return rebased
                }
            }
            self.report?.fire_parameters = try JSONDecoder().decode(FireParameters.self, from: merged)
            parameterDocument = merged; savedParameterDocument = merged; error = nil; parameterStatus = "参数已保存到本机。"
            sourceVersions["fire-parameters-user.json"] = ReviewFileVersion.of(merged)
        }
        catch { self.error = "参数未保存：" + error.localizedDescription }
    }
    func persistParameters() async {
        guard editingAvailable, !completionSaving, !discoveryBusy, !categorySaving, !loading, !importing, !completion.persisting, let report, let root else { return }
        let p = report.fire_parameters
        let expectedPointer = workspaceState?.pointer
        if let message = p.inputValidationMessage { error = message; return }
        do {
            let changes = try ParameterDocument.encoding(report.fire_parameters)
            let original = savedParameterDocument ?? parameterDocument ?? changes
            let draft = try ParameterDocument.merging(base: parameterDocument ?? changes, changes: changes)
            let session = workspaceEditSession
            let client = familyClientEditSession
            let verifiedClient = pinnedClientReview != nil
            completionSaving = true
            defer { completionSaving = false }
            let result = try await Task.detached {
                @Sendable func write(_ root: URL) throws -> Data {
                return try ReviewSyncIO.coordinate(root.appendingPathComponent("fire-parameters-user.json"), write: true) { file in
                let live = FileManager.default.fileExists(atPath: file.path) ? try ParameterDocument.merging(base: original, changes: Data(contentsOf: file)) : original
                let rebased = try ParameterDocument.rebasing(original: original, draft: draft, onto: live)
                _ = try JSONDecoder().decode(FireParameters.self, from: rebased)
                try rebased.write(to: file, options: .atomic)
                return rebased
            }
                }
                if let session { let (value, state) = try await session.writeScheduled { root, _ in try write(root) }; return (value, Optional(state), Optional<ReviewFamilyClientHandle>.none) }
                if let client { let (value, handle) = try client.write { root, _ in try write(root) }; return (value, Optional<StateHandle>.none, Optional(handle)) }
                let lease = try ReviewProcessLease(root: root)
                defer { withExtendedLifetime(lease) {} }
                return (try Self.withLocalReviewMutation(root: root, verifiedClient: verifiedClient) { try write(root) }, Optional<StateHandle>.none, Optional<ReviewFamilyClientHandle>.none)
            }.value
            if let session {
                guard workspacePaths?.workspace.path == session.paths.workspace.path,
                      workspaceState?.pointer == session.state.pointer else { return }
            } else if self.root?.path != root.path { return }
            let merged = result.0
            if let state = result.1 { adoptWorkspaceState(state) }
            self.report?.fire_parameters = try JSONDecoder().decode(FireParameters.self, from: merged)
            parameterDocument = merged; savedParameterDocument = merged; error = nil; parameterStatus = "参数已保存到本机。"
            sourceVersions["fire-parameters-user.json"] = ReviewFileVersion.of(merged)
            if let handle = result.2 { adoptFamilyClientEdit(handle) }
        }
        catch {
            guard self.root?.path == root.path, workspaceState?.pointer == expectedPointer else { return }
            self.error = "参数未保存：" + error.localizedDescription
        }
    }
#if os(iOS)
    func exportParameters() { saveParameters(); if error == nil { MobileServices.shared.exportDocument = parameterDocument } }
    func importParameters() { MobileServices.shared.parameterPicker = true }
#else
    func exportParameters() {
        Task {
        await persistParameters(); guard error == nil, let bytes = parameterDocument else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "家庭FIRE参数.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { try bytes.write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
        }
    }
        }
    func importParameters() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let original = report?.fire_parameters; let oldDocument = parameterDocument
        do {
            let bytes = try Data(contentsOf: url)
            parameterDocument = try ParameterDocument.merging(base: parameterDocument ?? bytes, changes: bytes)
            report?.fire_parameters = try JSONDecoder().decode(FireParameters.self, from: parameterDocument!)
            Task {
            await persistParameters()
            if error != nil { report?.fire_parameters = original!; parameterDocument = oldDocument }
            }
        } catch { if let original { report?.fire_parameters = original }; parameterDocument = oldDocument; self.error = "参数未导入：" + error.localizedDescription }
    }
#endif
    var records: [FinancialLifecycle] { snapshot.records }
    var classifiedRecords: [FinancialLifecycle] { snapshot.classifiedRecords }
    var stats: ReviewStatistics { snapshot.statistics }
    var accounts: [String] { cachedAccounts }
    var tags: [String] { cachedTags }
    func setTags(_ tags: [String], for component: FinancialComponent) {
        classify(component.id, primary: component.primary, secondary: component.secondary, tags: tags)
    }
    func inspectTag(_ tag: String) {
        selectedTags = [tag]; primary = "全部分类"; query = ""; recordView = "全部消费"; section = "details"
    }
    func spendingTransactions(primary: String, secondary: String) -> [FinancialLifecycle] {
        let key = snapshotKey, path = CategoryPath(primary: primary, secondary: secondary)
        if spendingCache?.key != key { spendingCache = (key, [:]) }
        if let value = spendingCache?.values[path] { return value }
        let value = snapshot.spendingTransactions(primary: primary, secondary: secondary)
        spendingCache?.values[path] = value
        return value
    }
    func inspectTransaction(_ id: String) {
        query = ""; recordView = "全部消费"; selected = id; directDetailID = id; section = "details"
    }
    var fullMonths: [String] { snapshot.fullMonths }
    var monthlyStats: ReviewStatistics { snapshot.monthlyStatistics }
    var recurringStats: ReviewStatistics { snapshot.recurringStatistics }
    var largestUnclassified: [(FinancialLifecycle, FinancialComponent)] { snapshot.largestUnclassified }
    var selectedRecord: FinancialLifecycle? { visibleRecords.first { $0.id == selected } }
    var visibleRecords: [FinancialLifecycle] {
        let key = snapshotKey, mode = recordView
        if let cached = visibleCache, cached.key == key, cached.mode == mode { return cached.value }
        let value = classifiedRecords.filter { r in
            switch mode {
            case "待处理": return !r.reviewExcluded && (r.components.contains { !$0.included && !$0.reason.isEmpty } || (r.fact_review_status != nil && r.fact_review_status?.hasPrefix("事实已确认") != true))
            case "账户待关联": return r.payment_account_status == "unresolved" && !r.non_consumption && r.events.contains { $0.kind == "payment" }
            case "资金流": return r.non_consumption || r.unallocated_credit_cents > 0
            default: return !r.non_consumption
            }
        }
        visibleCache = (key, mode, value)
        return value
    }
    func selectRange(_ name: String) {
        guard let report, let cutoff = report.cutoff else { return }; to = cutoff
        let date = parseDay(to)
        switch name {
        case "全部": from = report.records.map(\.date).min() ?? to
        case "近30天": from = day(Calendar.current.date(byAdding: .day, value: -29, to: date)!)
        case "近90天": from = day(Calendar.current.date(byAdding: .day, value: -89, to: date)!)
        default: from = String(to.prefix(4)) + "-01-01"
        }
    }
}

enum ReviewFileVersion {
    static func of(_ bytes: Data?) -> String { bytes.map(ReviewSyncIO.digest) ?? "missing" }
    static let names = ["financial-review.json", "payment-evidence.json", "review-overrides.json", "fire-parameters-user.json", "completion-workflow.json", "category-catalog.json"]
    nonisolated static func read(_ root: URL) throws -> [String: String] {
        var versions = [String: String]()
        for name in names {
            let file = try ReviewDataSource.url(name, root: root)
            do { versions[name] = of(try Data(contentsOf: file)) }
            catch { if ReviewSyncIO.isMissing(error) { versions[name] = "missing" } else { throw error } }
        }
        return versions
    }
}

#if os(macOS)
extension FinancialStore {
    /// The watcher must acknowledge only files already reflected in the stores.
    /// Local saves update these versions, so their mtime changes do not reload the editor.
    func refreshLocalFilesIfNeeded(_ evidence: BrowserStore) async -> Bool {
        guard let folder = root, !loading, !completionSaving, !discoveryBusy, !categorySaving, !importing, !completion.persisting, !evidence.loading else { return false }
        let expectedRevision = revision
        do {
            let versions = try await Task.detached { try ReviewFileVersion.read(folder) }.value
            guard root == folder, revision == expectedRevision, !loading, !completionSaving, !discoveryBusy, !categorySaving, !importing, !completion.persisting, !evidence.loading else { return false }
            var applied = sourceVersions
            applied["payment-evidence.json"] = evidence.sourceVersion
            applied["completion-workflow.json"] = completion.sourceVersion
            if applied == versions, evidence.root == folder { return true }
            // Only a real external edit reaches the guarded reload, never a mere touch
            // or a save whose values are already displayed by this process.
            let current = report?.fire_parameters
            let persisted = parameterDocument.flatMap { try? JSONDecoder().decode(FireParameters.self, from: $0) }
            do {
                completionSaving = true; completion.persisting = true
                defer { completionSaving = false; completion.persisting = false }
                await load(folder)
                guard error == nil else { return false }
                await evidence.load(folder, finance: report)
                guard evidence.error == nil else { return false }
                let workflowURL = folder.appendingPathComponent("completion-workflow.json")
                if FileManager.default.fileExists(atPath: workflowURL.path) {
                    let bytes = try Data(contentsOf: workflowURL)
                    let workflow = try CompletionWorkflow.decode(bytes)
                    completion.deferred = workflow.datasetID == report?.dataset_id ? Set(workflow.deferred) : []
                    completion.sourceVersion = ReviewFileVersion.of(bytes)
                } else { completion.deferred = []; completion.sourceVersion = "missing" }
                if current != persisted, let current, let persisted, let updated = report?.fire_parameters {
                    let encoder = JSONEncoder()
                    let rebased = try ParameterDocument.rebasing(original: encoder.encode(persisted), draft: encoder.encode(current), onto: encoder.encode(updated))
                    report?.fire_parameters = try JSONDecoder().decode(FireParameters.self, from: rebased)
                }
            }
            await reconcileCompletion()
            completion.refresh(self, evidence); completion.filter()
            return true
        } catch { self.error = "自动更新未完成：" + error.localizedDescription; return false }
    }
}
#endif

@MainActor private enum ReviewDateFormat {
    static let day: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
}
@MainActor func day(_ value: Date) -> String { ReviewDateFormat.day.string(from: value) }
@MainActor func parseDay(_ value: String) -> Date { ReviewDateFormat.day.date(from: value) ?? Date() }
func yuan(_ value: Double) -> String { value.formatted(.currency(code: "CNY").precision(.fractionLength(0))) }
func wan(_ value: Double) -> String { String(format: "%.1f 万", value / 10000) }

struct ReviewMetric: View {
    let title: String; let value: String; let note: String
    var body: some View { VStack(alignment: .leading, spacing: 7) { Text(title).foregroundStyle(.secondary); Text(value).font(.title2.bold()).monospacedDigit(); Text(note).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.quaternary.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 14)) }
}
struct ReviewCard<Content: View>: View {
    let title: String; @ViewBuilder let content: Content
    var body: some View { VStack(alignment: .leading, spacing: 15) { Text(title).font(.title3.bold()); content }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.background).clipShape(RoundedRectangle(cornerRadius: 16)) }
}

#if os(macOS)
struct FinanceRootView: View {
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
            List(selection: $store.section) {
                Section("家庭财务") {
                    Label("复盘总览", systemImage: "chart.bar.xaxis").tag("overview")
                    Label("补全", systemImage: "checklist").tag("completion")
                    Label("支出明细", systemImage: "list.bullet.rectangle").tag("details")
                    Label("分类修改", systemImage: "folder.badge.gearshape").tag("categories")
                    Label("标签与 Patterns", systemImage: "tag").tag("tags")
                    Label("关注与调整", systemImage: "slider.horizontal.3").tag("focus")
                }
                Section("FIRE 规划") {
                    Label("目标与情景", systemImage: "flag.checkered").tag("fire")
                    Label("买房与子女", systemImage: "house").tag("branches")
                    Label("模型参数", systemImage: "gearshape").tag("params")
                }
                Section("资料") { Label("数据与待处理", systemImage: "tray.full").tag("data") }
            }.navigationTitle("家庭财务复盘")
            FinanceSidebarActions(store: store, evidence: evidence)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let error = store.error { Text(error).foregroundStyle(.red).padding() }
                if store.report != nil {
                    if store.report?.cutoff != nil && ["overview", "details", "tags", "focus", "data"].contains(store.section) { FinanceFilters(store: store) }
                    if store.report?.coverage?.mode == "empty" { Text("暂无可靠日期，尚未建立统计范围。可导入账单和素材。").foregroundStyle(.secondary).padding() }
                    if store.section == "completion" { CompletionPage(store: store, evidence: evidence, workspace: store.completion).disabled(!store.editingAvailable) }
                    else if store.section == "details" { FinanceDetailsPage(store: store, evidence: evidence) }
                    else if store.section == "categories" { NavigationStack { CategoryManagementPage(store: store) } }
                    else { ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            switch store.section {
                            case "overview": FinanceOverviewPage(store: store)
                            case "tags": FinanceTagsPage(store: store)
                            case "focus": FinanceFocusPage(store: store)
                            case "fire":
                                if store.report?.fire_parameters.needsBaseInput == true { Text("请先填写必需的模型参数，再查看 FIRE 情景。") }
                                else { FinanceFirePage(store: store) }
                            case "params": FinanceParametersPage(store: store).disabled(!store.editingAvailable)
                            case "branches":
                                if store.report?.fire_parameters.needsBaseInput == true { Text("请先填写基础模型参数，再启用买房与子女情景。") }
                                else { FinanceBranchesPage(store: store).disabled(!store.editingAvailable) }
                            default: FinanceDataPage(store: store, evidence: evidence)
                            }
                        }.padding(28).frame(maxWidth: 1300).frame(maxWidth: .infinity)
                    }.id(store.section).background(Color(nsColor: .windowBackgroundColor)) }
                } else { ContentUnavailableView("正在读取家庭复盘", systemImage: "chart.bar", description: Text("读取已导入资料和生命周期统计。")) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).navigationTitle(["categories":"分类修改", "completion":"补全", "overview":"家庭复盘", "details":"支出明细", "tags":"标签与 Patterns", "focus":"关注与调整", "fire":"FIRE 目标与情景", "params":"模型参数", "branches":"买房与子女", "data":"数据与待处理"][store.section] ?? "家庭复盘")
        }.frame(minWidth: 1180, minHeight: 800)
            .onChange(of: store.section) { _, _ in ReviewLatency.finish("navigate") }
            .onChange(of: store.report?.dataset_id) { _, _ in ReviewLatency.finish("startup-overview") }
            .fileImporter(isPresented: $store.showingPicker,
                          allowedContentTypes: store.pickerMode == "folder" ? [.folder] : [.pdf, .commaSeparatedText, .spreadsheet, .movie, .data],
                          allowsMultipleSelection: store.pickerMode != "folder") { result in
                if case .success(let urls) = result, !store.completionSaving, !store.importing, !store.loading, !evidence.loading, !store.completion.persisting {
                    if store.pickerMode == "folder", let url = urls.first { _ = url.startAccessingSecurityScopedResource(); Task { await store.load(url); await evidence.load(url, finance: store.report) } }
                    else { Task { await store.importMaterials(urls); if let root = store.root { await evidence.load(root, finance: store.report) } } }
                }
            }
            .task(id: store.root) {
                guard let root = store.root else { return }
                if store.clientWorkspacePaths != nil {
                    store.familyClientSyncController?.evidence = evidence
                    if evidence.root != root { await evidence.load(root, finance: store.report) }
                    return
                }
                store.familyClientSyncController?.evidence = evidence
                if let paths = store.workspacePaths {
                    if evidence.root != root { await evidence.load(root, finance: store.report) }
                    while !Task.isCancelled {
                        await store.reloadWorkspaceIfChanged(paths, evidence: evidence)
                        try? await Task.sleep(for: .seconds(5))
                    }
                    return
                }
                var previous = ""
                while !Task.isCancelled {
                    let names = ReviewFileVersion.names
                    let stamp = names.map { name in
                        let value = try? root.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey])
                        return String(value?.contentModificationDate?.timeIntervalSince1970 ?? 0)
                    }.joined(separator: "|")
                    if stamp != previous, await store.refreshLocalFilesIfNeeded(evidence) {
                        previous = stamp
                    }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FinancialDataChanged"))) { _ in Task { _ = await store.refreshLocalFilesIfNeeded(evidence) } }

    }

}

struct FinanceSidebarActions: View {
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if store.workspacePaths != nil || store.familyClientPaths != nil { WorkspaceMaintenanceActions(store: store) }
                WorkspaceSyncActions(store: store, evidence: evidence)
                if !store.workspaceNotice.isEmpty { Text(store.workspaceNotice).font(.caption).foregroundStyle(.secondary) }
                if !store.workspaceRuntimeNotice.isEmpty { Text(store.workspaceRuntimeNotice).font(.caption).foregroundStyle(.secondary) }
                if store.workspaceRuntimeFailure != nil {
                    Button("重新检查处理器") { Task { await store.retryWorkspaceRuntimeQualification() } }
                        .disabled(store.importing || store.loading || store.completionSaving || store.completion.persisting || store.editorPauseReason != nil)
                }
                if let reason = store.editorPauseReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                if !store.syncStatus.isEmpty { Label(store.syncStatus, systemImage: "icloud").font(.caption).foregroundStyle(.secondary) }
                Text("统计单位：交易生命周期").font(.caption)
                Text("账户用于切换 View").font(.caption).foregroundStyle(.secondary)
                Button("刷新数据") { Task { if store.root != nil { await store.reloadCurrent(); if let current = store.root { await evidence.load(current, finance: store.report) } } } }.disabled(store.importing || evidence.loading || store.completionSaving || store.loading || store.completion.persisting)
                Button(store.clientWorkspacePaths == nil ? "导入账单与素材" : "发送素材到家庭 Mac") { store.pickerMode = "materials"; store.showingPicker = true }.disabled(!store.materialImportAvailable || store.importing || store.completionSaving || store.loading || store.completion.persisting)
                if store.importing { ProgressView().controlSize(.small) }
                if store.processorTask != nil { Button("取消处理") { store.processorTask?.cancel(); store.importState = "正在停止处理，并核对已保存状态…" } }
                if !store.importState.isEmpty { Text(store.importState).font(.caption).foregroundStyle(.secondary) }
                Button("选择复盘文件夹") { store.pickerMode = "folder"; store.showingPicker = true }.disabled(store.workspacePaths != nil || store.clientWorkspacePaths != nil || store.importing || evidence.loading || store.completionSaving || store.loading || store.completion.persisting)
            }.padding()
    }
}

struct FinanceFilters: View {
    @Bindable var store: FinancialStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu("统计区间") { ForEach(["今年", "近30天", "近90天", "全部"], id: \.self) { s in Button(s) { store.selectRange(s) } } }
                DatePicker("从", selection: Binding(get: { parseDay(store.from) }, set: { store.from = day($0) }), displayedComponents: .date).labelsHidden().frame(width: 130)
                Text("至").foregroundStyle(.secondary)
                DatePicker("至", selection: Binding(get: { parseDay(store.to) }, set: { store.to = min(day($0), store.report?.cutoff ?? day($0)) }), displayedComponents: .date).labelsHidden().frame(width: 130)
                Picker("账户 View", selection: $store.account) { Text("全部账户").tag("全部账户"); ForEach(store.accounts, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 260)
                Picker("分类", selection: $store.primary) { Text("全部分类").tag("全部分类"); ForEach(store.report?.taxonomy ?? []) { Text($0.primary).tag($0.primary) } }.frame(width: 190)
                Spacer()
            }
            HStack {
                Menu(store.selectedTags.isEmpty ? "筛选标签" : "已选 \(store.selectedTags.count) 个标签") {
                    ForEach(store.tags, id: \.self) { tag in
                        Toggle(tag, isOn: Binding(get: { store.selectedTags.contains(tag) }, set: { checked in
                            if checked { store.selectedTags.append(tag) } else { store.selectedTags.removeAll { $0 == tag } }
                        }))
                    }
                }
                Picker("匹配", selection: $store.tagMatch) { Text("全部所选标签").tag("all"); Text("任一所选标签").tag("any") }.frame(width: 240)
                ScrollView(.horizontal, showsIndicators: false) { HStack {
                    ForEach(store.selectedTags, id: \.self) { tag in Button(tag + " ×") { store.selectedTags.removeAll { $0 == tag } }.buttonStyle(.bordered).controlSize(.small) }
                } }
                if !store.selectedTags.isEmpty { Button("清空标签") { store.selectedTags = [] } }
            }
            Text(store.report?.coverage?.label ?? "截止 \(store.report?.cutoff ?? "未建立范围") · 已提供来源的家庭交易 · 覆盖范围尚未确认完整").font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(.bar)
            .onChange(of: store.account) { _, _ in ReviewLatency.finish("account") }
            .onChange(of: store.primary) { _, _ in ReviewLatency.finish("category") }
            .onChange(of: store.from) { _, _ in ReviewLatency.finish("date.from") }
            .onChange(of: store.to) { _, _ in ReviewLatency.finish("date.to") }
    }
}

#endif
struct FinanceOverviewPage: View {
    @Bindable var store: FinancialStore
    var body: some View {
        if let report = store.report {
            content(report)
                .onAppear { ReviewLatency.finish("startup-overview"); ReviewLatency.finish("load-to-overview") }
                .onChange(of: store.revision) { _, _ in ReviewLatency.finish("load-to-overview") }
        }
    }
    private func content(_ report: FinancialReport) -> some View {
        let s = store.stats
        return VStack(alignment: .leading, spacing: 20) {
            ReviewStack { ReviewMetric(title: "已记录净消费", value: money(s.net), note: "支付减已关联退款，\(s.count) 个购买项目"); ReviewMetric(title: "原支付／退款", value: money(s.gross), note: "已关联退款 " + money(s.refunds)); ReviewMetric(title: "待关联消费", value: money(s.pending), note: "\(s.pendingCount) 个项目，单独保留") }
            ReviewStack { ReviewMetric(title: "完整月份月均", value: store.fullMonths.isEmpty ? "暂无完整月份" : money(store.monthlyStats.net / store.fullMonths.count), note: "\(store.fullMonths.count) 个完整日历月；不是家庭全量结论"); ReviewMetric(title: "待分类净消费", value: money(s.byPrimary["待分类"] ?? 0), note: "未将未知项目归入杂项"); ReviewMetric(title: "未分配贷记", value: money(s.unallocatedCredits), note: "保留资金流，尚未抵扣某笔消费") }
            ReviewCard(title: "月度消费趋势") {
                ReviewMonthlyChart(byMonth: s.byMonth, cutoffMonth: String((report.cutoff ?? "").prefix(7))).equatable()
                Text("橙色为截止日所在的不完整月份。退款修正原交易，不按退款日期另算消费。").font(.caption).foregroundStyle(.secondary)
            }
            ReviewCard(title: "最多两级的支出结构") {
                Text("展开二级分类查看交易；金额为该分类计入统计的净消费，点击交易查看完整详情与证据。").font(.caption).foregroundStyle(.secondary)
                ForEach(report.taxonomy) { category in
                    let amount = s.byPrimary[category.primary] ?? 0
                    if amount > 0 {
                        ReviewCategoryRow(store: store, category: category, amount: amount, bySecondary: s.bySecondary)
                    }
                }
            }
            ReviewCard(title: "标签视角") {
                Text("平台、目的地与消费场景可以重叠；标签金额不可相加作为总消费。").font(.caption).foregroundStyle(.secondary)
                ForEach(s.byTag.keys.sorted { s.byTag[$0, default: 0] > s.byTag[$1, default: 0] }.prefix(6), id: \.self) { tag in
                    HStack { Button(tag) { store.inspectTag(tag) }; Spacer(); Text(money(s.byTag[tag] ?? 0)).monospacedDigit() }
                }
                Button("查看标签与 Patterns") { store.section = "tags" }
            }
        }
    }
}

struct ReviewMonthlyChart: View, Equatable {
    let byMonth: [String: Int]; let cutoffMonth: String
    var body: some View {
        Chart(byMonth.keys.sorted(), id: \.self) { month in
            BarMark(x: .value("月份", month), y: .value("净消费", Double(byMonth[month] ?? 0) / 100))
                .foregroundStyle(month == cutoffMonth ? Color.orange : Color.teal)
        }.frame(height: 240)
    }
}
struct ReviewCategoryRow: View {
    let store: FinancialStore
    let category: FinancialCategory; let amount: Int; let bySecondary: [String: Int]
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { value in
            ReviewLatency.begin("category-disclosure"); expanded = value
        })) {
            ForEach(category.secondaries, id: \.self) { secondary in
                let value = bySecondary[category.primary + " / " + secondary] ?? 0
                if value > 0 { ReviewSecondaryTransactions(store: store, primary: category.primary, secondary: secondary, amount: value) }
            }
        } label: {
            HStack { Text(category.primary).font(.headline); Spacer(); Text(money(amount)).font(.headline).monospacedDigit() }
        }.padding(.vertical, 6)
            .onChange(of: expanded) { _, _ in ReviewLatency.finish("category-disclosure") }
    }
}

struct ReviewSecondaryTransactions: View {
    let store: FinancialStore
    let primary: String; let secondary: String; let amount: Int
    @State private var expanded = false
    @State private var limit = 20
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                let records = store.spendingTransactions(primary: primary, secondary: secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(records.count) 笔交易 · 本分类净消费 " + money(amount)).font(.caption).foregroundStyle(.secondary)
                    ForEach(records.prefix(limit)) { record in
                        Button { store.inspectTransaction(record.id) } label: {
                            HStack(alignment: .center) {
                                FinanceTransactionRow(record: record)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    if records.count > limit { Button("显示更多（剩余 \(records.count - limit) 笔）") { limit += 20 } }
                }
            }
        } label: {
            HStack { Text(secondary); Spacer(); Text(money(amount)).monospacedDigit() }
        }.padding(.vertical, 5)
            .accessibilityIdentifier("category-transactions:\(primary)/\(secondary)")
    }
}

#if os(macOS)
struct FinanceDetailsPage: View {
    let store: FinancialStore; let evidence: BrowserStore
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                FinanceTransactionList(store: store).frame(width: min(360, geometry.size.width * 0.36), height: geometry.size.height)
                Divider()
                FinanceSelectedTransaction(store: store, evidence: evidence, recordID: store.directDetailID)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
}
struct FinanceTransactionList: View {
    @Bindable var store: FinancialStore
    var body: some View {
            VStack(spacing: 0) {
                TextField("搜索日期、商户或商品", text: $store.query).textFieldStyle(.roundedBorder).padding()
                Picker("显示", selection: $store.recordView) { ForEach(["全部消费", "待处理", "账户待关联", "资金流"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).padding(.horizontal)
                ScrollViewReader { proxy in
                List(selection: $store.selected) {
                    ForEach(store.visibleRecords) { r in
                        FinanceTransactionRow(record: r).equatable().tag(r.id).id(r.id)
                    }
                }
                .id(store.recordView)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .overlay { if store.visibleRecords.isEmpty { ContentUnavailableView("没有匹配交易", systemImage: "magnifyingglass", description: Text("清空搜索或调整日期、账户与分类筛选。")) } }
                .onAppear { if let id = store.selectedRecord?.id { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: store.selected) { _, id in if let id, store.selectedRecord != nil { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            .onChange(of: store.query) { _, _ in ReviewLatency.finish("search") }
            .onChange(of: store.recordView) { _, _ in ReviewLatency.finish("record-mode") }
    }
}
#endif
struct FinanceSelectedTransaction: View {
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    var recordID: String? = nil
    var body: some View {
        Group {
            if let r = recordID.flatMap({ id in store.report?.records.first { $0.id == id } }) ?? store.selectedRecord {
                ScrollView { LazyVStack(alignment: .leading, spacing: 20) {
                    Text(r.title).font(.title2.bold()).textSelection(.enabled)
                    Text(r.date + " · " + r.status + (r.user_relation == "other_user" ? " · 已确认其他用户消费" : "")).foregroundStyle(.secondary)
                    Text("账户 View：" + r.account_views.joined(separator: "、")).font(.caption).textSelection(.enabled)
                    FinanceTransactionIdentity(record: r)
                    TransactionFactActions(record: r, store: store, evidence: evidence)
                    TransactionReviewExclusion(record: r, store: store)
                    ForEach(TransactionListOrder.sorted(r.components, amount: { $0.reason.contains("支付金额待确定") ? nil : $0.net_cents }, date: { _ in r.date }, id: \.id)) { c in ComponentEditor(component: c, store: store) }
                    ReviewCard(title: "交易生命周期") {
                        ForEach(r.paymentEvents) { e in HStack(alignment: .top) {
                            Image(systemName: e.kind.contains("refund") || e.kind == "bank_credit" ? "arrow.uturn.backward.circle" : "checkmark.circle").foregroundStyle(.teal)
                            VStack(alignment: .leading) { Text(e.date + " · " + (e.payment_account ?? platformName(e.source))); Text(platformName(e.source) + " · " + e.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            Spacer(); Text(money(e.amount_cents)).monospacedDigit()
                        }.padding(.vertical, 5) }
                        if let group = r.bank_settlement_group {
                            Text("已与 \(group.count) 笔银行扣款整组对账，单笔对应关系未指定。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("原始证据").font(.title3.bold())
                    ForEach(evidence.records.filter { r.evidence_keys.contains($0.id) }) { record in RecordPane(record: record, store: evidence) }
                }.padding(24) }
            } else { ContentUnavailableView("选择一笔交易", systemImage: "list.bullet.rectangle", description: Text("查看购买项目、分类、退款历史和裁剪后的原记录。")).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.onChange(of: store.selected) { _, _ in ReviewLatency.finish("select-record") }
    }
}
struct FinanceTransactionIdentity: View {
    let record: FinancialLifecycle
    private var accountText: String {
        let accounts = record.payment_accounts ?? []
        return accounts.isEmpty ? "待关联" : accounts.joined(separator: "、")
    }
    var body: some View {
        Text("消费人：\(record.userDisplayName) · 支付账户：\(accountText)" + ((record.payment_channels ?? []).isEmpty ? "" : " · 通道：" + (record.payment_channels ?? []).joined(separator: "、")))
            .font(.caption).textSelection(.enabled)
    }
}
struct FinanceTransactionRow: View, Equatable {
    let record: FinancialLifecycle
    var body: some View {
        let r = record
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(r.date).font(.caption); Spacer(); Text(r.unallocated_credit_cents > 0 ? "贷记 " + money(r.unallocated_credit_cents) : r.components.contains(where: { $0.reason.contains("支付金额待确定") }) ? "金额未知" : r.non_consumption ? "资金 " + money(r.events.first?.amount_cents) : money(r.components.reduce(0) { $0 + $1.net_cents })).monospacedDigit().accessibilityIdentifier("transaction-amount:" + r.id) }
            Text(r.title).lineLimit(2)
            if r.user_id != nil { Text("用户：" + r.userDisplayName).font(.caption2).foregroundStyle(.secondary) }
            Text((r.components.contains { !$0.included && !$0.reason.isEmpty } ? "待处理 · " : "") + r.status + " · " + (r.components.first?.primary ?? "")).font(.caption).foregroundStyle(r.components.contains { !$0.included && !$0.reason.isEmpty } ? Color.orange : Color.secondary)
            let tags = Array(Set(r.components.flatMap(\.tags))).sorted()
            if !tags.isEmpty { Text(tags.prefix(4).joined(separator: " · ") + (tags.count > 4 ? " …" : "")).font(.caption2).foregroundStyle(.teal).lineLimit(2) }
        }.padding(.vertical, 6).accessibilityIdentifier("transaction-row:" + r.id)
    }
}

struct FinanceFocusPage: View {
    @Bindable var store: FinancialStore
    var body: some View { if let report = store.report { content(report).onChange(of: store.savingPercent) { _, _ in ReviewLatency.finish("saving-slider") } } }
    private func content(_ report: FinancialReport) -> some View {
        let p = report.fire_parameters
        let months = max(1, store.fullMonths.count)
        let monthly = store.recurringStats.byPrimary
        let ranked = monthly.keys.filter { $0 != "待分类" }.sorted { (monthly[$0] ?? 0) > (monthly[$1] ?? 0) }
        return VStack(alignment: .leading, spacing: 20) {
            ReviewCard(title: "先解释尚未分类的支出") {
                Text("待分类净消费 " + money(store.stats.byPrimary["待分类"] ?? 0)).font(.title2.bold())
                Text("优先处理金额较大的项目，确认商品用途后再评估是否值得调整。支付通道与商品类别分别展示。")
                let largest = store.largestUnclassified
                ForEach(Array(largest.prefix(5)), id: \.1.id) { record, component in
                    HStack { Text(record.date + " · " + component.title).lineLimit(1); Spacer(); Text(money(component.net_cents)).monospacedDigit(); Button("确认用途") { store.query = record.title; store.primary = "待分类"; store.recordView = "全部消费"; store.selected = record.id; store.section = "details" } }
                }
                Button("查看待分类交易") { store.query = ""; store.recordView = "全部消费"; store.primary = "待分类"; store.section = "details" }
            }
            ReviewCard(title: "可调整空间的情景估算") {
                HStack { Text("尝试降低相关支出 \(Int(store.savingPercent))%"); Slider(value: $store.savingPercent, in: 0...40, step: 5).frame(maxWidth: 350) }
                Text("以下以已提供数据的完整月份为参考，排除已标记的一次性购买。尚未确认是否持续的项目仍只作样本比较，年度预算不会自动被替换。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ranked.prefix(4), id: \.self) { name in
                let monthlyYuan = Double(monthly[name] ?? 0) / 100 / Double(months)
                let saving = monthlyYuan * store.savingPercent / 100
                let budget = (p.expenseBreakdown[name] ?? 0) / 12
                ReviewCard(title: name) {
                    ReviewStack { ReviewMetric(title: "样本月均", value: yuan(monthlyYuan), note: "\(store.fullMonths.count) 个完整月份"); ReviewMetric(title: "现有月预算", value: p.expenseBreakdown[name] == nil ? "未填写" : yuan(budget), note: p.expenseBreakdown[name] == nil ? "尚未设置此分类预算" : monthlyYuan > budget ? "已记录支出高于预算" : "样本未超预算，仍可检查价值"); ReviewMetric(title: "调整后年节省", value: yuan(saving * 12), note: "若能持续降低 \(Int(store.savingPercent))%"); ReviewMetric(title: "FIRE 目标资产减少", value: p.investing.$withdrawalRate.map { $0 > 0 ? wan(FinancialMath.capitalReduction(monthlySaving: saving, withdrawalRate: $0)) : "未填写" } ?? "未填写", note: p.investing.$withdrawalRate.map { "提取率 " + String(format: "%.1f", $0 * 100) + "%" } ?? "提取率尚未填写") }
                    Text(name == "生产力工具" ? "重点检查重复订阅、年度续费和知识付费的实际使用。保留高价值工具，停掉低使用项目。" : name == "日常消费" ? "先查看外卖、咖啡茶饮和日用品的频次，比较方便程度与实际价值，再设可持续的上限。" : name == "旅行" ? "拆开一次性行程与长期旅行预算；不能把一次旅行机械地当作每月固定消费。" : "区分必要支出与可选项目，以生活质量和长期预算为依据调整。")
                    Button("查看明细") { store.query = ""; store.recordView = "全部消费"; store.primary = name; store.section = "details" }
                }
            }
            if store.fullMonths.isEmpty { Text("当前区间没有完整月份，切换到今年或全部后再比较月预算。").foregroundStyle(.orange) }
        }
    }
}

struct FinanceFirePage: View {
    @Bindable var store: FinancialStore
    var body: some View { if let report = store.report { content(report) } }
    @ViewBuilder private func content(_ report: FinancialReport) -> some View {
        if report.fire_parameters.needsBaseInput {
            Text("请先填写必需的模型参数；未填写与已确认的零分别保存，当前不展示 FIRE 结论。")
        } else { fireContent(report) }
    }
    private func fireContent(_ report: FinancialReport) -> some View {
        let p = report.fire_parameters; let target = FinancialMath.target(p)
        let age = p.baseYear - p.birthYear; let years = max(0, p.targetAge - age)
        let realReturn = FinancialMath.realReturn(nominal: p.investing.annualReturn, inflation: p.investing.inflation)
        let reach = FinancialMath.reachYears(assets: p.currentFireAssets, target: target, annualContribution: p.annualContribution, annualReturn: realReturn)
        return VStack(alignment: .leading, spacing: 20) {
            ReviewStack { ReviewMetric(title: "FIRE 目标资产", value: wan(target), note: "年度常态支出 " + yuan(p.expenseModes["normal"] ?? 0) + "，含已启用储备桶"); ReviewMetric(title: "当前可投资资产", value: wan(p.currentFireAssets), note: "目标差额 " + wan(max(0, target - p.currentFireAssets))); ReviewMetric(title: "按当前投入预计达到", value: reach.map { String(format: "%.1f 岁", Double(age) + $0) } ?? "100年内未达到", note: "实际收益率 \(String(format: "%.2f", realReturn * 100))%，投入按现价保持") }
            ReviewCard(title: "目标年龄与投入能力") {
                ReviewStack { ReviewMetric(title: "\(p.targetAge)岁目标所需月投入", value: yuan(FinancialMath.requiredMonthly(assets: p.currentFireAssets, target: target, annualReturn: realReturn, years: Double(years))), note: "距离目标 \(years) 年，按现价投入"); ReviewMetric(title: "现有月投入", value: yuan(p.annualContribution / 12), note: "每年 " + yuan(p.annualContribution)); ReviewMetric(title: "税后月收入参考", value: yuan(p.afterTaxSalary / 12), note: "已确认参数，不从账单推算收入") }
                Text("优先检验目标年龄、投入和年度生活成本是否相容。交易收益不纳入主模型；支出调整可同时降低目标资产并增加投入。")
            }
            ReviewCard(title: "收益率情景") {
                Chart([4.0, 6.0, 8.0, 10.0], id: \.self) { rate in
                    ForEach(0...15, id: \.self) { year in
                        LineMark(x: .value("年龄", age + year), y: .value("资产（现价万元）", FinancialMath.project(assets: p.currentFireAssets, annualContribution: p.annualContribution, annualReturn: FinancialMath.realReturn(nominal: rate / 100, inflation: p.investing.inflation), years: Double(year)) / 10000)).foregroundStyle(by: .value("名义收益率", "\(Int(rate))%"))
                    }
                }.chartXScale(domain: age...(age + 15)).frame(height: 300)
                Text("曲线已扣除 \(String(format: "%.1f", p.investing.inflation * 100))% 通胀，资产与年度投入按当前购买力展示。情景不是收益承诺。").font(.caption).foregroundStyle(.secondary)
            }
            ReviewCard(title: "回撤下的生活预算") {
                ForEach([15.0, 20.0, 30.0], id: \.self) { value in HStack { Text("回撤 \(Int(value))%"); Spacer(); Text(wan(p.currentFireAssets * (1 - value / 100))); Text(value >= 30 ? "修复：减少风险与提款，评估收入" : value >= 20 ? "防守：使用压力档预算" : "观察：暂停生活方式上浮").foregroundStyle(.secondary) } }
            }
        }
    }
}

struct FinanceParametersPage: View {
    @Bindable var store: FinancialStore
    @State private var resetConfirmation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(store.report?.fire_parameters.needsInput == true ? "必需参数尚未填写完整；空白保持未填，已确认的零按零保存。" : "已保存的 FIRE 参数；调整会保存到本机。").foregroundStyle(.secondary)
            if store.report != nil {
                let binding = Binding<FireParameters>(get: { store.report!.fire_parameters }, set: { store.report!.fire_parameters = $0 })
                ReviewForm {
                    Section("资产与投入") {
                        OptionalIntegerField(title: "基础年份", value: binding.$baseYear)
                        OptionalIntegerField(title: "出生年份", value: binding.$birthYear)
                        OptionalNumberField(title: "可投资资产（元）", value: binding.$currentFireAssets)
                        OptionalNumberField(title: "税后年收入（元）", value: binding.$afterTaxSalary)
                        OptionalNumberField(title: "每年投入（元）", value: binding.$annualContribution)
                        OptionalIntegerField(title: "目标年龄", value: binding.$targetAge)
                    }
                    Section("生活成本与收益假设") {
                        OptionalNumberField(title: "年度常态支出（元）", value: Binding(get: { binding.wrappedValue.expenseModes["normal"] }, set: { store.report!.fire_parameters.expenseModes["normal"] = $0 }))
                        OptionalNumberField(title: "年度硬上限（元）", value: binding.$annualHardCap)
                        OptionalNumberField(title: "安全提取率", value: binding.investing.$withdrawalRate, percent: true)
                        OptionalNumberField(title: "名义年收益率", value: binding.investing.$annualReturn, percent: true)
                        OptionalNumberField(title: "通胀率", value: binding.investing.$inflation, percent: true)
                    }
                    Section("储备桶") {
                        Toggle("目标包含储备桶", isOn: binding.buckets.includeBuckets)
                        OptionalNumberField(title: "安全储备（元）", value: binding.buckets.$safetyBucket)
                        OptionalNumberField(title: "父母医疗储备（元）", value: binding.buckets.$parentMedicalBucket)
                        OptionalNumberField(title: "其他储备（元）", value: binding.buckets.$otherBuckets)
                        Toggle("启用养老储备", isOn: binding.buckets.elderCareEnabled)
                        OptionalNumberField(title: "养老储备（元）", value: binding.buckets.$elderCareBucket)
                    }
                    Section("一级年度预算") { Text("分类改名或删除后，原年度预算仍保留，可在此按新分类调整。").font(.caption).foregroundStyle(.secondary); ForEach(Array(Set(store.report!.taxonomy.map(\.primary).filter { $0 != "待分类" }).union(store.report!.fire_parameters.expenseBreakdown.keys)).sorted(), id: \.self) { name in OptionalNumberField(title: name, value: Binding(get: { store.report!.fire_parameters.expenseBreakdown[name] }, set: { store.report!.fire_parameters.expenseBreakdown[name] = $0 })) } }
                }.formStyle(.grouped)
                ReviewStack { Button("清空个人假设") { resetConfirmation = true }; Button("保存参数") { store.saveParameters() }; Button("导出参数") { store.exportParameters() }; Button("导入参数") { store.importParameters() }; Button("恢复已确认参数") { Task { if let root = store.root, let bytes = try? Data(contentsOf: ReviewDataSource.url("financial-review.json", root: root)), let report = try? JSONDecoder().decode(FinancialReport.self, from: bytes) { store.report?.fire_parameters = report.fire_parameters; let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]; if let full = object?["fire_parameters"] { store.parameterDocument = try? JSONSerialization.data(withJSONObject: full) }; store.saveParameters() } } } }
                if !store.parameterStatus.isEmpty { Text(store.parameterStatus).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .confirmationDialog("清空个人 FIRE 假设？", isPresented: $resetConfirmation, titleVisibility: .visible) {
            Button("确认清空", role: .destructive) { Task { await store.resetFireInputs() } }
        } message: { Text("资产、收入、预算和情景假设将恢复未填写；账本与历史复核会保留。") }
    }
}

struct FinanceBranchesPage: View {
    @Bindable var store: FinancialStore
    var body: some View { if let report = store.report {
        if report.fire_parameters.needsBaseInput { Text("请先填写必需的基础模型参数。") }
        else { content(report) }
    } }
    private func content(_ report: FinancialReport) -> some View {
        let p = report.fire_parameters; let h = p.branches.housing; let child = p.branches.children
        let principal = h.totalPrice * (1 - h.downPaymentRatio)
                let payment = FinancialMath.mortgage(principal: principal, annualRate: h.loanRate, years: h.loanYears)
        var housingParameters = p; housingParameters.branches.children.enabled = false
        var childParameters = p; childParameters.branches.housing.enabled = false
        let housingProjection = FinancialMath.branchProjection(housingParameters)
        let childProjection = FinancialMath.branchProjection(childParameters)
        let age = p.baseYear - p.birthYear
        return VStack(alignment: .leading, spacing: 20) {
            if store.report != nil {
                let binding = Binding<FireParameters>(get: { store.report!.fire_parameters }, set: { store.report!.fire_parameters = $0 })
                ReviewForm {
                    Section("买房情景") {
                        Toggle("启用买房情景", isOn: binding.branches.housing.enabled)
                        OptionalIntegerField(title: "购房年份", value: binding.branches.housing.$year)
                        OptionalNumberField(title: "总价（元）", value: binding.branches.housing.$totalPrice)
                        OptionalNumberField(title: "首付比例", value: binding.branches.housing.$downPaymentRatio, percent: true)
                        OptionalNumberField(title: "贷款年利率", value: binding.branches.housing.$loanRate, percent: true)
                        OptionalIntegerField(title: "贷款期限（年）", value: binding.branches.housing.$loanYears)
                        OptionalNumberField(title: "税费（元）", value: binding.branches.housing.$fees)
                        OptionalNumberField(title: "装修（元）", value: binding.branches.housing.$renovation)
                        OptionalNumberField(title: "年度维护（元）", value: binding.branches.housing.$annualMaintenance)
                        Toggle("购房后减少原租金", isOn: binding.branches.housing.reduceRent)
                        OptionalNumberField(title: "购房后年度租金减少（元）", value: binding.branches.housing.annualRentReduction)
                        OptionalNumberField(title: "最低流动资产要求（元）", value: binding.branches.housing.$minLiquidAssets)
                    }
                    Section("子女情景") {
                        Toggle("启用子女情景", isOn: binding.branches.children.enabled)
                        OptionalIntegerField(title: "子女数量", value: binding.branches.children.$count)
                        OptionalIntegerField(title: "计划出生年份", value: binding.branches.children.$birthYear)
                        OptionalNumberField(title: "每名子女年度成本（元）", value: binding.branches.children.$annualCost)
                        OptionalNumberField(title: "教育储备总额（元）", value: binding.branches.children.$educationBucket)
                        OptionalNumberField(title: "年度收入减少（元）", value: binding.branches.children.$incomeImpact)
                    }
                }.formStyle(.grouped)
                Button("保存情景参数") { store.saveParameters() }
                if !store.parameterStatus.isEmpty { Text(store.parameterStatus).font(.caption).foregroundStyle(.secondary) }
            }
            Text("分支独立比较，不改变基础 FIRE 页。情景按现价、计划年份和有限还贷期限计算；租金减少需填写实际估计，不默认使用全部住房预算。").foregroundStyle(.secondary)
            if p.needsInput { Text("请补齐已启用情景的参数；未填完前不显示情景结论。") }
            else {
            if !h.enabled && !child.enabled { Text("尚未启用买房或子女情景。") }
            if h.enabled {
            ReviewCard(title: "买房分支（启用）") {
                ReviewStack { ReviewMetric(title: "购房一次性资金", value: wan(h.totalPrice * h.downPaymentRatio + h.fees + h.renovation), note: "首付、税费与装修"); ReviewMetric(title: "预计月供", value: yuan(payment), note: "\(h.loanYears)年，利率 \(String(format: "%.1f", h.loanRate * 100))%"); ReviewMetric(title: "最低流动资产要求", value: wan(h.minLiquidAssets), note: "自住房\(h.ownerHomeCountsAsFireAsset ? "计入" : "不计入")FIRE资产") }
                ReviewStack { ReviewMetric(title: "情景预计达成年龄", value: h.enabled ? housingProjection.estimatedYears.map { String(format: "%.1f 岁", Double(age) + $0) } ?? "条件不足" : "尚未启用", note: housingProjection.fundingGap > 0 ? "计划时点资金缺口 " + wan(housingProjection.fundingGap) : "已考虑首付、剩余房贷及流动资产要求"); ReviewMetric(title: "情景 FIRE 目标", value: wan(housingProjection.targetAssets), note: "含剩余房贷资金及流动资产下限") }
                Text("还贷期间每年现金支出 " + yuan(payment * 12 + h.annualMaintenance) + "；达成 FIRE 前预留剩余房贷的偿付资金，购房前另预留首付、税费与装修。")
                Text("计划年份 \(h.year)，总价 " + wan(h.totalPrice) + "。新增月供和维护费用需要与住房预算联动，租金是否减少按实际计划调整。")
            }
            }
            if child.enabled {
            ReviewCard(title: "子女分支（启用）") {
                ReviewStack { ReviewMetric(title: "情景预计达成年龄", value: child.enabled ? childProjection.estimatedYears.map { String(format: "%.1f 岁", Double(age) + $0) } ?? "条件不足" : "尚未启用", note: "成本与收入影响从计划出生年份开始"); ReviewMetric(title: "情景 FIRE 目标", value: wan(childProjection.targetAssets), note: "未来持续成本及教育储备单独计入") }
                ReviewStack { ReviewMetric(title: "预计年度新增成本", value: yuan(child.annualCost * Double(child.count)), note: "\(child.count)个子女，计划 \(child.birthYear)年"); ReviewMetric(title: "教育储备", value: wan(child.educationBucket), note: "单独预留，不混入当前消费"); ReviewMetric(title: "新增目标资产参考", value: wan(child.annualCost * Double(child.count) / max(0.001, p.investing.withdrawalRate) + child.educationBucket), note: "按新增年度成本与储备估算") }
            }
            }
            }
        }
    }
}

struct FinanceDataPage: View {
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    var body: some View { if let report = store.report { content(report) } }
    private func content(_ report: FinancialReport) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            #if os(macOS)
            MacSyncConflicts(store: store, evidence: evidence)
            WorkspaceRequestStatusView(store: store)
            #endif
            ReviewCard(title: "已提供资料与统计边界") {
                Text(report.coverage_note)
                Text("\(report.records.count) 个生命周期；截止 \(report.cutoff ?? "未建立范围")。每条记录保留来源证据，账户只是 View。").textSelection(.enabled)
                Text("关联复核：人工支持 \(evidence.report?.review_summary["human_supported"] ?? 0)，规则支持 \(evidence.report?.review_summary["rule_supported"] ?? 0)，待确认 \(evidence.report?.review_summary["needs_review"] ?? 0)。")
            }
            ReviewCard(title: "本区间需要处理的资料") {
                Text("待关联消费 " + money(store.stats.pending) + "；未分配银行贷记 " + money(store.stats.unallocatedCredits))
                Text("\(store.stats.pendingCount) 个项目保留在明细中。缺少银行关联不等于订单无效；可能与已记录消费重叠的项目暂不重复计入。")
                Button("查看待处理交易") { store.query = ""; store.primary = "全部分类"; store.recordView = "待处理"; store.section = "details" }
            }
            if store.workspaceState != nil {
                ReviewCard(title: "已保存的待处理录屏（\(store.pendingVideoCount)）") {
                    if store.pendingVideos.isEmpty { Text("当前没有等待解析的已保存录屏。").foregroundStyle(.secondary) }
                    ForEach(store.pendingVideos) { input in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(input.displayName).font(.headline).textSelection(.enabled)
                            Text(input.reasonMessage + "；原件已保留。").font(.caption).foregroundStyle(.secondary)
                            #if os(macOS)
                            Button("重试解析此录屏") { Task { await store.retryPendingVideo(input) } }
                                .disabled(!store.processorAvailable || store.importing || store.loading || store.completionSaving || store.discoveryBusy || store.completion.persisting)
                            #else
                            Text("在 Mac 重试解析此录屏。").font(.caption).foregroundStyle(.secondary)
                            #endif
                        }
                    }
                    if store.pendingVideoCount > store.pendingVideos.count { Text("仅显示前 \(store.pendingVideos.count) 项；处理后刷新会显示后续录屏。").font(.caption).foregroundStyle(.secondary) }
                    #if os(macOS)
                    if store.processorTask != nil { Button("取消处理") { store.processorTask?.cancel(); store.importState = "正在停止处理，并核对已保存状态…" } }
                    #endif
                    if !store.importState.isEmpty { Text(store.importState).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            if let summary = report.video_summary {
                ReviewCard(title: "录屏原记录素材") {
                    Text("完整记录裁剪 \(summary.raw_complete_crops) 张；内容去重后 \(summary.deduplicated_materials) 条，\(summary.wallet_links) 条已补充到已有交易。")
                    Text("日期未确定 \(summary.undated_materials) 条；未解析裁剪 \(summary.unparsed_crops) 张。年份矛盾和可能重复的消费保留为待处理。")
                    Text(summary.recall_status).font(.caption).foregroundStyle(.secondary)
                    #if os(iOS)
                    Text("在「资料」打开「交易证据与关联复核」，搜索云闪付或订单卡片，可查看裁剪图与原文。").textSelection(.enabled)
                    #else
                    Text("切换顶部「交易证据」，搜索云闪付或订单卡片，可查看裁剪图与原文。").textSelection(.enabled)
                    #endif
                }
            }
        }
    }
}

struct ComponentEditor: View {
    let component: FinancialComponent; let store: FinancialStore
    var body: some View {
        ReviewCard(title: component.title) {
            ReviewStack { Text(component.reason.contains("支付金额待确定") ? "支付金额未知" : "支付 " + money(component.gross_cents)); Text("退款 " + money(component.refund_cents)); if let receipt = component.reimbursement_cents { Text("代购回款 " + money(receipt)) }; Spacer(); Text(component.included ? (component.net_cents < 0 ? "净收入 " : "净消费 ") + money(abs(component.net_cents)) : "尚未计入消费统计").font(.headline) }
            if !component.included { Text(component.reason.isEmpty ? "非消费记录，不计入消费统计" : "单独保留：" + component.reason).foregroundStyle(.orange) }
            Picker("是否持续发生", selection: Binding(get: { component.effectiveRecurrence }, set: { store.classify(component.id, primary: component.primary, secondary: component.secondary, recurrence: $0) })) {
                Text("持续生活支出").tag("recurring"); Text("一次性购买").tag("one_time")
            }
            ReviewStack {
                Picker("一级分类", selection: Binding(get: { component.primary }, set: { name in if let first = store.report?.taxonomy.first(where: { $0.primary == name })?.secondaries.first { store.classify(component.id, primary: name, secondary: first) } })) {
                    ForEach((store.report?.taxonomy ?? []).filter { !$0.secondaries.isEmpty }) { Text($0.primary).tag($0.primary) }
                }
                Picker("二级分类", selection: Binding(get: { component.secondary }, set: { store.classify(component.id, primary: component.primary, secondary: $0) })) {
                    ForEach(store.report?.taxonomy.first(where: { $0.primary == component.primary })?.secondaries ?? [], id: \.self) { Text($0).tag($0) }
                }
            }
            Text(component.classification_basis + " · 分类修改会保存，后续复用。").font(.caption).foregroundStyle(.secondary)
            ComponentTagEditor(component: component, store: store)
        }
    }
}

struct ComponentTagEditor: View {
    let component: FinancialComponent; let store: FinancialStore
    @State private var newTag = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Divider()
            Text("标签").font(.headline)
            Text("可叠加平台、目的地和消费场景，例如旅行场景＋便利店＋罗森。").font(.caption).foregroundStyle(.secondary)
            TagFlowLayout {
                ForEach(component.tags, id: \.self) { tag in
                    removableTag(tag)
                }
            }
            HStack {
                TextField("新标签名称", text: $newTag).textFieldStyle(.roundedBorder).onSubmit(addTag)
                Button("添加标签", action: addTag).disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Menu("已有标签") {
                    ForEach(store.tags.filter { !component.tags.contains($0) }, id: \.self) { tag in Button(tag) { store.setTags(component.tags + [tag], for: component) } }
                }
            }
            Text("修改后立即保存；移除的自动标签在后续导入时也会保持移除。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func removableTag(_ tag: String) -> some View {
        let label = "移除标签「\(tag)」"
        let help = (component.tag_basis?[tag] ?? "标签") + "；点击移除"
        return Button {
            store.setTags(component.tags.filter { $0 != tag }, for: component)
        } label: { Label(tag, systemImage: "xmark.circle") }
            .buttonStyle(.bordered).controlSize(.small).lineLimit(1)
            .accessibilityLabel(Text(label)).help(help)
    }
    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        store.setTags(component.tags + [tag], for: component)
        if store.error == nil { newTag = "" }
    }
}

struct TagFlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 600).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (index, point) in layout.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(layout.sizes[index]))
        }
    }
    private func arrange(_ views: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint], sizes: [CGSize]) {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, points = [CGPoint](), sizes = [CGSize]()
        for view in views {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += height + 8; height = 0 }
            points.append(CGPoint(x: x, y: y)); sizes.append(size); x += size.width + 8; height = max(height, size.height)
        }
        return (CGSize(width: width, height: views.isEmpty ? 0 : y + height), points, sizes)
    }
}

struct FinanceTagsPage: View {
    @Bindable var store: FinancialStore
    var body: some View {
        let stats = store.stats
        VStack(alignment: .leading, spacing: 20) {
            #if os(macOS)
            MerchantTagDiscoveryCard(store: store)
            #else
            Text("商家标签由 Mac 发现并确认后同步到这里；你可以在交易详情里添加或移除标签。").font(.caption).foregroundStyle(.secondary)
            #endif
            Text("分类回答支出用途，标签回答平台、场景和目的地。同一购买项目可以有多个标签。").foregroundStyle(.secondary)
            HStack {
                ReviewMetric(title: "当前筛选净消费", value: money(stats.net), note: "每个购买项目只计一次")
                ReviewMetric(title: "标签数", value: String(stats.byTag.count), note: "标签金额存在交叉，不能相加")
            }
            ReviewCard(title: "按标签发现 Patterns") {
                Text("选择上方多个标签并用“全部所选标签”查看交集，例如旅行场景＋便利店。").font(.caption).foregroundStyle(.secondary)
                if stats.byTag.isEmpty { Text("当前筛选没有带标签的消费。").foregroundStyle(.secondary) }
                ForEach(stats.byTag.keys.sorted { stats.byTag[$0, default: 0] > stats.byTag[$1, default: 0] }, id: \.self) { tag in
                    DisclosureGroup {
                        ForEach((stats.categoriesByTag[tag] ?? [:]).keys.sorted(), id: \.self) { category in
                            HStack { Text(category); Spacer(); Text(money(stats.categoriesByTag[tag]?[category] ?? 0)).monospacedDigit() }.font(.callout).padding(.vertical, 4)
                        }
                        Button("查看 \(tag) 的交易") { store.inspectTag(tag) }
                    } label: {
                        HStack { Text(tag).font(.headline); Text("\(stats.countByTag[tag] ?? 0) 笔").foregroundStyle(.secondary); Spacer(); Text(money(stats.byTag[tag] ?? 0)).monospacedDigit() }
                    }.padding(.vertical, 7)
                }
            }
        }
    }
}
#if os(macOS)
extension FinancialStore {
    private var merchantTagStorage: (database: URL, seed: URL?)? {
        if let workspaceState { return (workspaceState.config.appendingPathComponent("merchant-tag-discovery.sqlite3"), nil) }
        if let discoveryDatabaseURL { return (discoveryDatabaseURL, nil) }
        if let path = ProcessInfo.processInfo.environment["BANKING_MERCHANT_DB"] { return (URL(fileURLWithPath: path), nil) }
        return nil
    }
    func discoverMerchantTags(force: Bool = false, decision: MerchantTagRule? = nil) async {
        guard !categoryBusy, root != nil, let report, let storage = merchantTagStorage else { return }
        guard completion.drafts.isEmpty else { discoveryMessage = "先保存或撤销补全草稿，再发现商家标签。"; return }
        let expected = overrideDocument
        let context: OverrideEditContext
        do { context = try editContext() } catch { self.error = error.localizedDescription; return }
        let expectedProjection = sourceVersions["financial-review.json"] ?? ""
        let expectedRule = decision.flatMap { value in discoveryRules.first { $0.payee == value.payee } }
        discoveryBusy = true
        defer { discoveryBusy = false }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let prepared = try await performOverrideEdit(context) { root, config in
                let database = config?.appendingPathComponent("merchant-tag-discovery.sqlite3") ?? storage.database
                let db = try MerchantTagDatabase(url: database)
                if let seed = storage.seed, FileManager.default.fileExists(atPath: seed.path) { try db.seed(Data(contentsOf: seed)) }
                if let decision { try db.save(decision, expected: expectedRule) }
                let rules = try db.rules()
                let values = try JSONSerialization.jsonObject(with: expected) as! [String: Any]
                var associations = [String: Any]()
                for (id, entry) in values {
                    guard let entry = entry as? [String: Any] else { continue }
                    let facts = entry.filter { ["source_record_set_review", "transaction_facts", "excluded_from_completion_and_statistics"].contains($0.key) }
                    if !facts.isEmpty { associations[id] = facts }
                }
                let signature = ReviewSyncIO.digest(Data((MerchantTagDiscovery.normalizationID + expectedProjection).utf8) + (try JSONSerialization.data(withJSONObject: associations, options: [.sortedKeys])))
                let cacheKey = context.datasetID
                let cached = try db.identities(root: cacheKey, signature: signature, force: force)
                let scan = try MerchantTagDiscovery.scan(records: report.records, rules: rules, cached: cached, document: expected)
                let document = try CompletionOverrideFile.appendDiscoveryTags(root: root, records: report.records, additions: scan.additions, expectedDocument: expected, expectedProjection: expectedProjection)
                try db.markProcessed(root: cacheKey, signature: signature, identities: scan.newIdentities)
                return (scan, document)
            }
            discoveryCandidates = prepared.candidates; discoveryRules = prepared.rules; discoveryConflicts = prepared.conflicts; discoveryConflictSamples = prepared.conflictSamples
            discoveryMessage = "检查 \(prepared.eligible) 项；新处理 \(prepared.processed) 项，复用 \(prepared.reused) 项；补加 \(prepared.additions.count) 个标签。"
            error = nil
            ReviewLatency.record("merchant-tag-discovery", milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        } catch {
            discoveryMessage = "发现未完成：" + error.localizedDescription
            self.error = discoveryMessage
        }
    }
}

struct MerchantTagDiscoveryCard: View {
    @Bindable var store: FinancialStore
    @State private var showDeferred = false
    @State private var ruleQuery = ""
    @State private var candidateQuery = ""
    @State private var limit = 20
    var body: some View {
        ReviewCard(title: "启发式标签发现") {
            Text("按已关联材料中的商家名聚合。确认一次后，同名交易会自动获得标签。此列表覆盖全部日期。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(store.discoveryBusy ? "正在检查…" : "检查新交易") { Task { await store.discoverMerchantTags() } }
                    .accessibilityIdentifier("merchant-discovery-scan")
                Button("重新检查全部") { Task { await store.discoverMerchantTags(force: true) } }
                    .accessibilityIdentifier("merchant-discovery-rescan")
                Spacer()
                Toggle("显示暂缓", isOn: $showDeferred).toggleStyle(.checkbox)
            }.disabled(store.categoryBusy)
            if !store.discoveryMessage.isEmpty { Text(store.discoveryMessage).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("merchant-discovery-status") }
            if store.discoveryConflicts > 0 {
                DisclosureGroup("\(store.discoveryConflicts) 项有多个收款名，需逐笔核对") {
                    Text("打开交易详情核对证据，再手动添加标签。").font(.caption).foregroundStyle(.secondary)
                    LazyVStack(alignment: .leading) {
                        ForEach(store.discoveryConflictSamples) { sample in
                            Button { store.inspectTransaction(sample.recordID) } label: {
                                HStack { Text(sample.date); Text(sample.title).lineLimit(2); Spacer(); Text(money(sample.amount)) }
                            }.buttonStyle(.plain).font(.caption).padding(.vertical, 4)
                        }
                    }
                }.foregroundStyle(.orange)
            }
            TextField("查找待确认商家", text: $candidateQuery).textFieldStyle(.roundedBorder)
            let candidates = store.discoveryCandidates.filter { (showDeferred || $0.decision != .deferred) && (candidateQuery.isEmpty || $0.payee.localizedCaseInsensitiveContains(candidateQuery)) }
            if candidates.isEmpty && !store.discoveryBusy { Text("没有待确认的商家名。").foregroundStyle(.secondary) }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(candidates.prefix(limit))) { candidate in MerchantTagCandidateRow(candidate: candidate, store: store) }
            }
            if candidates.count > limit { Button("再显示20个（共\(candidates.count)个）") { limit += 20 } }
            DisclosureGroup("已保存规则（\(store.discoveryRules.count)）") {
                TextField("查找商家或标签", text: $ruleQuery).textFieldStyle(.roundedBorder)
                LazyVStack(alignment: .leading) {
                    ForEach(store.discoveryRules.filter { ruleQuery.isEmpty || $0.payee.localizedCaseInsensitiveContains(ruleQuery) || ($0.tag ?? "").localizedCaseInsensitiveContains(ruleQuery) }) { rule in
                        HStack {
                            Text(rule.payee).textSelection(.enabled)
                            Spacer()
                            Text(rule.tag ?? (rule.decision == .deferred ? "暂缓" : "不加标签")).foregroundStyle(.secondary)
                            if rule.decision == .merchant {
                                Button("停用") { Task { await store.discoverMerchantTags(decision: .init(payee: rule.payee, decision: .no_tag)) } }
                            } else {
                                Button("重新确认") { Task { await store.discoverMerchantTags(decision: .init(payee: rule.payee, decision: .deferred)) }; showDeferred = true }
                            }
                        }.font(.callout).padding(.vertical, 4)
                    }
                }
                Text("停用只影响以后自动添加；已有标签保留。删除交易上的标签后，自动发现会保持删除结果。").font(.caption).foregroundStyle(.secondary)
            }.disabled(store.categoryBusy)
        }
    }
}
private struct MerchantTagCandidateRow: View {
    let candidate: MerchantTagCandidate
    let store: FinancialStore
    @State private var tag = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(candidate.payee).font(.headline).textSelection(.enabled)
                Text("\(candidate.count) 项").foregroundStyle(.secondary)
                if candidate.decision == .deferred { Text("已暂缓").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            Text("收款名：" + candidate.rawNames.joined(separator: "；")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(candidate.samples) { sample in
                Button { store.inspectTransaction(sample.recordID) } label: {
                    HStack { Text(sample.date); Text(sample.title).lineLimit(1); Spacer(); Text(money(sample.amount)) }
                }.buttonStyle(.plain).font(.caption).help("查看交易证据")
            }
            HStack {
                TextField("标签名", text: $tag).textFieldStyle(.roundedBorder).frame(maxWidth: 300).accessibilityLabel("\(candidate.payee) 的标签名")
                Button("确认并回填") { decide(.merchant) }.disabled((try? MerchantTagDiscovery.cleanTag(tag)) == nil)
                Button("不加标签") { decide(.no_tag) }
                Button("暂缓") { decide(.deferred) }
            }.disabled(store.categoryBusy)
            Divider()
        }.onAppear { if tag.isEmpty { tag = candidate.suggestedTag } }
    }
    private func decide(_ decision: MerchantTagDecision) {
        let label = decision == .merchant ? try? MerchantTagDiscovery.cleanTag(tag) : nil
        Task { await store.discoverMerchantTags(decision: .init(payee: candidate.payee, decision: decision, tag: label)) }
    }
}
#endif
struct OptionalNumberField: View {
    let title: String
    @Binding var value: Double?
    var percent = false
    var body: some View {
        HStack {
            Text(title)
            TextField("未填写", value: Binding<Double?>(get: { value.map { percent ? $0 * 100 : $0 } }, set: { value = $0.map { percent ? $0 / 100 : $0 } }), format: .number)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
            if percent { Text("%") }
        }
    }
}
struct OptionalIntegerField: View {
    let title: String
    @Binding var value: Int?
    var body: some View {
        HStack { Text(title); TextField("未填写", value: $value, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(maxWidth: 140) }
    }
}

struct NumberField: View {
    let title: String; @Binding var value: Double
    var body: some View { HStack { Text(title); Spacer(); TextField(title, value: $value, format: .number.precision(.fractionLength(0...2)))
        #if os(iOS)
        .keyboardType(.decimalPad)
        #endif
        .multilineTextAlignment(.trailing).frame(width: 160).labelsHidden() } }
}
struct PercentField: View {
    let title: String; @Binding var value: Double
    var body: some View {
        HStack { Text(title); Spacer(); TextField(title, value: Binding(get: { value * 100 }, set: { value = $0 / 100 }), format: .number.precision(.fractionLength(0...2)))
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .multilineTextAlignment(.trailing).frame(width: 130).labelsHidden(); Text("%").foregroundStyle(.secondary) }
    }
}
#endif
