#if os(macOS)
import SwiftUI
import AppKit
import PaymentImageCore

/// An existing native family Host resumes with the selected container. This owner
/// only polls/publishes through the real local grant; it cannot create a binding.
@MainActor final class MacFamilyHostSyncController {
    let paths: WorkspacePaths
    let driver: ReviewFamilySyncDriver
    private let connection: ReviewFamilyConnection
    private let selectionGeneration: UUID
    weak var store: FinancialStore?
    weak var evidence: BrowserStore?
    private var loop: Task<Void, Never>?
    private var operation: Task<String, Error>?
    private(set) var pollingGeneration: UUID?
    private var refreshing = false
    private let pause = "正在同步家庭快照"
    /// Deterministic suspension after core synchronization, before UI activation.
    enum RefreshPhase { case synchronized, activated }
    var refreshBarrier: ((RefreshPhase) async -> Void)?
    init(paths: WorkspacePaths, connection: ReviewFamilyConnection, store: FinancialStore,
         evidence: BrowserStore?, selectionGeneration: UUID) throws {
        self.paths = paths; self.connection = connection; self.store = store
        self.evidence = evidence; self.selectionGeneration = selectionGeneration
        driver = try ReviewFamilySyncDriver(paths: paths, connection: connection)
    }
    func isCurrent(_ store: FinancialStore) -> Bool {
        store.familyHostSyncController === self && store.isWorkspaceSelectionCurrent(paths: paths, generation: selectionGeneration)
    }
    func stop() {
        loop?.cancel(); loop = nil; pollingGeneration = nil; operation?.cancel()
    }
    #if DEBUG
    func stopAndWait() async {
        let activeLoop = loop, activeOperation = operation
        stop()
        await activeLoop?.value
        _ = try? await activeOperation?.value
    }
    #endif
    func start() {
        guard loop == nil, !Task.isCancelled, let store, isCurrent(store) else { return }
        let generation = UUID(); pollingGeneration = generation
        loop = Task { [weak self] in
            defer { if self?.pollingGeneration == generation { self?.loop = nil; self?.pollingGeneration = nil } }
            while !Task.isCancelled {
                guard let self, let store = self.store, self.isCurrent(store) else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    func refresh() async {
        guard !refreshing, !Task.isCancelled, let store, isCurrent(store), store.workspaceWritable,
              !store.loading, !store.categorySaving, !store.completionSaving, !store.completion.persisting,
              !store.importing, !store.discoveryBusy, evidence?.loading != true, store.editorPauseReason == nil,
              store.completion.drafts.isEmpty, !store.hasUnsavedParameters else { return }
        refreshing = true; store.editorPauseReason = pause
        defer {
            operation = nil; refreshing = false
            if isCurrent(store), store.editorPauseReason == pause { store.editorPauseReason = nil }
        }
        let paths = paths, connection = connection, driver = driver
        do {
            let work = Task.detached {
                try Task.checkCancellation()
                guard let saved = try ReviewFamilyHost.readConnection(paths: paths), saved.selection == connection.selection,
                      saved.remote.path == connection.remote.path else { throw WorkspaceError.stalePointer }
                if let bookmark = saved.bookmark {
                    var stale = false
                    let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                    guard !stale, resolved.path == saved.remote.path else { throw WorkspaceError.invalid("请重新选择原家庭同步目录。") }
                }
                let access = saved.remote.startAccessingSecurityScopedResource()
                defer { if access { saved.remote.stopAccessingSecurityScopedResource() } }
                return try await driver.synchronize()
            }
            operation = work
            var generation = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, isCurrent(store) else { return }
            if store.workspaceProcessorEligible, store.workspaceRuntimeReady, store.workspaceRuntimeFailure == nil,
               try await driver.hasPendingRequests() {
                let runtime = try await store.resolveWorkspaceProcessorRuntime()
                try await driver.processRequests(runtime: runtime)
                generation = try await driver.synchronize()
            }
            if let refreshBarrier { await refreshBarrier(.synchronized) }
            guard !Task.isCancelled, isCurrent(store) else { return }
            store.editorPauseReason = nil
            await store.reloadWorkspaceIfChanged(paths, evidence: evidence)
            guard !Task.isCancelled, isCurrent(store) else { return }
            store.syncStatus = "家庭同步已核对（" + String(generation.prefix(8)) + "）。"
            if let refreshBarrier { await refreshBarrier(.activated) }
        } catch is CancellationError {
            // A retired selection must not replace the new family's UI/status.
        } catch {
            if isCurrent(store), !Task.isCancelled { store.syncStatus = "等待家庭同步：" + error.localizedDescription }
        }
    }
}

/// Owns the selected current client only. Durable edits already live in its
/// outbox; network preparation cannot change the displayed reader until CAS.
@MainActor final class MacFamilyClientSyncController {
    let paths: WorkspacePaths
    weak var store: FinancialStore?
    weak var evidence: BrowserStore?
    private let selectionGeneration: UUID
    private var loop: Task<Void, Never>?
    private var operation: Task<ReviewFamilyClientRefreshPreparation, Error>?
    private var refreshing = false
    private(set) var pollingGeneration: UUID?
    enum ClientActivationPhase { case captured, prepared, committed }
    var clientActivationBarrier: ((ClientActivationPhase) async -> Void)?
    init(paths: WorkspacePaths, store: FinancialStore, evidence: BrowserStore?, selectionGeneration: UUID) {
        self.paths = paths; self.store = store; self.evidence = evidence; self.selectionGeneration = selectionGeneration
    }
    func isCurrent(_ store: FinancialStore) -> Bool {
        store.familyClientSyncController === self && store.isWorkspaceSelectionCurrent(paths: paths, generation: selectionGeneration)
    }
    func stop() { loop?.cancel(); loop = nil; pollingGeneration = nil; operation?.cancel() }
    #if DEBUG
    func stopAndWait() async {
        let activeLoop = loop, activeOperation = operation
        stop(); await activeLoop?.value; _ = try? await activeOperation?.value
    }
    #endif
    func start() {
        guard loop == nil, !Task.isCancelled, let store, isCurrent(store) else { return }
        let generation = UUID(); pollingGeneration = generation
        loop = Task { [weak self] in
            defer { if self?.pollingGeneration == generation { self?.loop = nil; self?.pollingGeneration = nil } }
            while !Task.isCancelled {
                guard let self, let store = self.store, self.isCurrent(store) else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    private func idle(_ store: FinancialStore) -> Bool {
        !store.loading && !store.categorySaving && !store.completionSaving && !store.completion.persisting &&
        !store.importing && !store.discoveryBusy && evidence?.loading != true && store.editorPauseReason == nil
    }
    func refresh() async {
        guard !refreshing, !Task.isCancelled, let store, isCurrent(store), idle(store) else { return }
        refreshing = true
        defer { operation = nil; refreshing = false }
        let paths = paths
        do {
            if let clientActivationBarrier { await clientActivationBarrier(.captured) }
            guard !Task.isCancelled, isCurrent(store) else { return }
            let work = Task.detached { () async throws -> ReviewFamilyClientRefreshPreparation in
                guard let connection = try ReviewFamilyClientSession.readConnection(paths: paths) else { throw WorkspaceError.invalid("家庭连接缺失。") }
                var remote = connection.remote
                if let bookmark = connection.bookmark {
                    var stale = false
                    remote = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                    guard !stale, remote.path == connection.remote.path else { throw WorkspaceError.invalid("请重新选择原家庭同步目录。") }
                }
                let scope = remote.startAccessingSecurityScopedResource()
                defer { if scope { remote.stopAccessingSecurityScopedResource() } }
                if try ReviewFamilyClientSession.read(paths: paths) != nil { try await ReviewFamilyClientSession.transfer(paths: paths) }
                return try ReviewFamilyClientSession.prepareRefresh(paths: paths)
            }
            operation = work
            let prepared = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            if let clientActivationBarrier { await clientActivationBarrier(.prepared) }
            guard !Task.isCancelled, isCurrent(store), idle(store), store.completion.drafts.isEmpty else { return }
            let sameClient = store.familyClientPaths == paths
            guard sameClient || !store.hasUnsavedParameters else { return }
            let original = sameClient ? store.parameterDocument : nil
            let draft = sameClient ? try store.report.map { try JSONEncoder().encode($0.fire_parameters) } : nil
            store.editorPauseReason = "正在更新家庭副本"
            defer { if isCurrent(store) { store.editorPauseReason = nil } }
            let handle: ReviewFamilyClientHandle?
            switch prepared {
            case .waiting: store.syncStatus = "等待完整家庭快照；本机修改仍保留。"; return
            case .current: handle = try await ReviewSyncDetached.run { try ReviewFamilyClientSession.read(paths: paths) }
            case .ready(let value): handle = try await ReviewSyncDetached.run { try ReviewFamilyClientSession.commitRefresh(paths: paths, prepared: value) }
            }
            if let clientActivationBarrier { await clientActivationBarrier(.committed) }
            guard !Task.isCancelled, isCurrent(store), let handle else { return }
            try await store.loadFamilyClient(paths: paths, handle: handle, selectionIsCurrent: { self.isCurrent(store) })
            guard !Task.isCancelled, isCurrent(store) else { return }
            if let original, let draft, let updated = store.parameterDocument {
                let rebased = try ParameterDocument.rebasing(original: original, draft: draft, onto: updated)
                store.report?.fire_parameters = try JSONDecoder().decode(FireParameters.self, from: rebased)
                store.parameterDocument = rebased
            }
            if let evidence { await evidence.load(handle.review, finance: store.report) }
            guard !Task.isCancelled, isCurrent(store) else { return }
            store.syncStatus = handle.conflicts.isEmpty ? "已核对家庭快照；本机修改会保留至真实纳入。" : "并发修改已保留，请核对字段版本。"
        } catch is CancellationError {
        } catch {
            if isCurrent(store), !Task.isCancelled { store.syncStatus = "等待同步：" + error.localizedDescription }
        }
    }
}

extension FinancialStore {
    /// Revoke an old container before any provider access for its replacement.
    /// Committed bytes in the old container remain valid; late UI activation does not.
    @discardableResult func expectWorkspace(_ paths: WorkspacePaths) -> UUID {
        guard expectedWorkspacePath != paths.workspace.path else { return workspaceSelectionGeneration }
        expectedWorkspacePath = paths.workspace.path; workspaceSelectionGeneration = UUID()
        workspaceOpenGeneration = UUID()
        familyHostSyncController?.stop(); familyHostSyncController = nil
        familyClientSyncController?.stop(); familyClientSyncController = nil
        workspaceRuntimeTask?.cancel()
        invalidatePendingLoad()
        editorPauseReason = nil
        if root == nil {
            workspacePaths = nil; workspaceState = nil; clientWorkspacePaths = nil; pinnedClientReview = nil
        familyClientPaths = nil; familyClientHandle = nil
            workspaceWritable = false; workspaceProcessorEligible = false; workspaceRuntimeReady = false
            workspaceRequestStatuses = [:]; workspaceRequestStatusesVerified = false
        }
        return workspaceSelectionGeneration
    }
    func isWorkspaceSelectionCurrent(paths: WorkspacePaths, generation: UUID) -> Bool {
        expectedWorkspacePath == paths.workspace.path && workspaceSelectionGeneration == generation
    }
    /// Shared by Welcome and recovery tests: persist the validated local choice,
    /// then immediately revoke the former reader without consulting a provider.
    func selectPendingWorkspace(paths: WorkspacePaths, connectionSaved: () throws -> Void) throws -> UUID {
        guard !FileManager.default.fileExists(atPath: paths.metadata.path),
              try ReviewFamilyClientSession.readConnection(paths: paths) != nil else {
            throw WorkspaceError.invalid("未找到可恢复的本机 client 连接。")
        }
        try validatePendingWorkspaceSelection(paths)
        try connectionSaved()
        workspaceOpenGeneration = UUID()
        let generation = expectWorkspace(paths)
        displayPendingWorkspaceIfNeeded(paths)
        return generation
    }
    func validatePendingWorkspaceSelection(_ paths: WorkspacePaths) throws {
        guard root != nil, clientWorkspacePaths?.workspace.path != paths.workspace.path,
              workspacePaths?.workspace.path != paths.workspace.path else { return }
        guard completion.drafts.isEmpty, !hasUnsavedParameters,
              !categorySaving, !completionSaving, !completion.persisting, !importing, !discoveryBusy else {
            throw WorkspaceError.invalid("请先保存或还原当前草稿，并等待保存完成，再切换家庭资料。")
        }
    }
    private func displayPendingWorkspaceIfNeeded(_ paths: WorkspacePaths) {
        guard root == nil || (clientWorkspacePaths?.workspace.path != paths.workspace.path &&
                              workspacePaths?.workspace.path != paths.workspace.path) else { return }
        invalidatePendingLoad()
        root = nil; report = nil; baseReport = nil
        parameterDocument = nil; savedParameterDocument = nil; overrides = [:]
        preparedCompletionQueues = [:]; sourceVersions = [:]; categoryCatalog = nil
        completion.resetContext(folder: nil, datasetID: "")
        workspacePaths = nil; workspaceState = nil; clientWorkspacePaths = nil; pinnedClientReview = nil
        familyClientPaths = nil; familyClientHandle = nil
        workspaceWritable = false; workspaceProcessorEligible = false; workspaceRuntimeReady = false
        workspaceRuntimeFailure = nil; workspaceRuntimeNotice = ""
        workspaceRequestStatuses = [:]; workspaceRequestStatusesVerified = false
        pendingVideos = []; pendingVideoCount = 0
        error = nil
    }
    func enqueueClientProcessingRequest(kind: String, payload: Data, files: [URL]) async throws -> ReviewFamilyRequest {
        guard let paths = familyClientPaths, let handle = familyClientHandle else { throw WorkspaceError.invalid("请打开当前家庭同步副本。") }
        let transport = try ReviewFamilyClientSession.requestTransport(paths: paths, expected: handle)
        let author = try ReviewFamilyClientSession.requestDeviceID(paths: paths)
        let request: ReviewFamilyRequest
        switch kind {
        case "review": request = try await transport.enqueueReview(payload: payload, authorDeviceID: author)
        case "import": request = try await transport.enqueueImport(files: files, authorDeviceID: author)
        default: throw WorkspaceError.invalid("processing request kind")
        }
        let statuses = try await transport.localStatuses()
        guard familyClientPaths == paths, familyClientHandle?.version == handle.version else { throw WorkspaceError.stalePointer }
        workspaceRequestStatuses = statuses; workspaceRequestStatusesVerified = true
        return request
    }
    func updateWorkspaceRequest(_ id: String, cancel: Bool) async {
        guard !categoryBusy, let paths = clientWorkspacePaths else { return }
        importing = true; defer { importing = false }
        do {
            guard let handle = familyClientHandle, familyClientPaths == paths else { throw WorkspaceError.stalePointer }
            let transport = try ReviewFamilyClientSession.requestTransport(paths: paths, expected: handle)
            if cancel { try await transport.cancel(requestID: id) }
            else { try await transport.retry(requestID: id) }
            let statuses = try await transport.localStatuses()
            guard familyClientPaths == paths, familyClientHandle?.version == handle.version else { return }
            workspaceRequestStatuses = statuses; workspaceRequestStatusesVerified = true
            if statuses[id] == "included" {
                importState = "处理结果已进入验证完成的快照；不会重复发送此请求。"
            } else if statuses[id] == "needsReview" {
                importState = "原请求需要核对处理结果；请求已保留，不会创建重复任务。"
            } else {
                importState = cancel ? "已停止等待此请求；已提交的处理结果仍以验证快照为准。" : "已恢复原请求发送；不会创建重复任务。"
            }
        } catch { self.error = "请求状态未更新：" + error.localizedDescription }
    }
    func enqueueWorkspaceMaterials(_ urls: [URL]) async {
        guard !urls.isEmpty, !categoryBusy, clientWorkspacePaths != nil, pinnedClientReview != nil else {
            error = "请先打开已验证的家庭 client 副本，再保存处理请求。"; return
        }
        importing = true; importState = "正在保存素材并排队到指定家庭 Mac…"; error = nil
        let scopes = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() }; importing = false }
        do {
            let request = try await enqueueClientProcessingRequest(kind: "import", payload: Data("{}".utf8), files: urls)
            importState = "素材已保存在本机，等待指定家庭 Mac 处理。请求 " + String(request.id.prefix(8))
        } catch { self.error = "素材排队未确认：" + error.localizedDescription }
    }
    func reloadWorkspaceIfChanged(_ paths: WorkspacePaths, evidence: BrowserStore? = nil) async {
        guard workspacePaths?.workspace.path == paths.workspace.path,
              expectedWorkspacePath == nil || expectedWorkspacePath == paths.workspace.path,
              !loading, !categorySaving, !completionSaving, !completion.persisting, !importing,
              !discoveryBusy, editorPauseReason == nil, evidence?.loading != true else { return }
        let generation = expectWorkspace(paths)
        let pointer = try? await Task.detached(priority: .utility) { try paths.readPointer() }.value
        guard !Task.isCancelled, isWorkspaceSelectionCurrent(paths: paths, generation: generation),
              workspacePaths?.workspace.path == paths.workspace.path,
              pointer != nil, pointer != workspaceState?.pointer,
              !loading, !categorySaving, !completionSaving, !completion.persisting, !importing,
              !discoveryBusy, editorPauseReason == nil, evidence?.loading != true else { return }
        guard completion.drafts.isEmpty else {
            syncStatus = "本机资料已更新，请先保存或还原补全草稿后刷新。"; return
        }
        let original = parameterDocument
        let draft = try? report.map { try JSONEncoder().encode($0.fire_parameters) }
        await loadWorkspace(paths, selectionGeneration: generation)
        guard isWorkspaceSelectionCurrent(paths: paths, generation: generation), error == nil else { return }
        if let original, let draft, let updated = parameterDocument {
            do {
                let rebased = try ParameterDocument.rebasing(original: original, draft: draft, onto: updated)
                report?.fire_parameters = try JSONDecoder().decode(FireParameters.self, from: rebased)
                parameterDocument = rebased
            } catch { self.error = "资料已更新，但参数草稿需重新核对：" + error.localizedDescription }
        }
        if let evidence, let root { await evidence.load(root, finance: report) }
    }

    /// Called by the stable main TabView lifecycle after Welcome publishes a reader.
    /// A retired view task cannot reselect its old household or replace a live loop.
    func resumeDisplayedWorkspace(_ displayedRoot: URL, evidence: BrowserStore) async {
        guard !Task.isCancelled, root == displayedRoot else { return }
        let paths: WorkspacePaths
        if let clientWorkspacePaths, pinnedClientReview == displayedRoot { paths = clientWorkspacePaths }
        else if let workspacePaths, workspaceState?.review == displayedRoot { paths = workspacePaths }
        else { return }
        let generation = workspaceSelectionGeneration
        guard isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
        await resumeWorkspaceSync(paths: paths, evidence: evidence, selectionGeneration: generation)
    }
    func resumeWorkspaceSync(paths: WorkspacePaths, evidence: BrowserStore? = nil,
                             selectionGeneration: UUID? = nil) async {
        let generation = selectionGeneration ?? expectWorkspace(paths)
        guard !Task.isCancelled, isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
        if let controller = familyHostSyncController, controller.isCurrent(self) {
            if let evidence { controller.evidence = evidence }
            controller.start(); return
        }
        do {
            if !FileManager.default.fileExists(atPath: paths.metadata.path), try ReviewFamilyClientSession.readConnection(paths: paths) != nil {
                guard !Task.isCancelled, isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
                if let controller = familyClientSyncController, controller.isCurrent(self) {
                    if let evidence { controller.evidence = evidence }
                    controller.start(); return
                }
                let controller = MacFamilyClientSyncController(paths: paths, store: self, evidence: evidence, selectionGeneration: generation)
                familyClientSyncController?.stop(); familyClientSyncController = controller
                syncStatus = "家庭副本可离线使用；刷新会发送已保存修改并核对新快照。"
                controller.start()
                return
            }
            if let connection = try await Task.detached(priority: .utility, operation: { try ReviewFamilyHost.readConnection(paths: paths) }).value {
                guard !Task.isCancelled, isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
                let controller = try MacFamilyHostSyncController(paths: paths, connection: connection, store: self, evidence: evidence, selectionGeneration: generation)
                        familyHostSyncController?.stop(); familyHostSyncController = controller
                syncStatus = "本机家庭同步已建立，自动核对已保存修改。"
                controller.start()
                return
            }
        } catch {
            guard !Task.isCancelled, isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
            syncStatus = "本机资料仍可使用；请重新选择原家庭同步目录：" + error.localizedDescription
        }
    }
    func connectWorkspaceClient(paths: WorkspacePaths, remote: URL, evidence: BrowserStore?,
                                connectionSaved: () throws -> Void) async throws {
        let previousGeneration = workspaceSelectionGeneration
        guard completion.drafts.isEmpty, !hasUnsavedParameters, !categorySaving, !completionSaving, !importing else {
            throw WorkspaceError.invalid("请先保存或还原当前草稿，再重新连接家庭资料。")
        }
        let bookmark = try remote.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        _ = try await Task.detached { try ReviewFamilyClientSession.connect(paths: paths, remote: remote, bookmark: bookmark) }.value
        guard workspaceSelectionGeneration == previousGeneration else { throw CancellationError() }
        let generation = try selectPendingWorkspace(paths: paths, connectionSaved: connectionSaved)
        let controller = MacFamilyClientSyncController(paths: paths, store: self, evidence: evidence, selectionGeneration: generation)
        familyClientSyncController?.stop(); familyClientSyncController = controller
        await controller.refresh()
        guard controller.isCurrent(self) else { throw CancellationError() }
        try Task.checkCancellation()
        controller.start()
    }
    func reconnectWorkspaceSync(paths: WorkspacePaths, remote: URL, evidence: BrowserStore?,
                                connectionSaved: () throws -> Void) async throws {
        if !FileManager.default.fileExists(atPath: paths.metadata.path) {
            try await connectWorkspaceClient(paths: paths, remote: remote, evidence: evidence, connectionSaved: connectionSaved)
            return
        }
        let generation = expectWorkspace(paths)
        let bookmark = try remote.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        _ = try await ReviewSyncDetached.run { try ReviewFamilyHost.reconnect(paths: paths, remote: remote, bookmark: bookmark) }
        guard isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { throw CancellationError() }
        try connectionSaved()
        familyHostSyncController?.stop(); familyHostSyncController = nil
        await resumeWorkspaceSync(paths: paths, evidence: evidence, selectionGeneration: generation)
    }

}

struct WorkspaceRequestStatusView: View {
    @Bindable var store: FinancialStore
    var body: some View {
        if store.clientWorkspacePaths != nil {
            ReviewCard(title: "发送到家庭 Mac 的处理请求（\(store.workspaceRequestStatuses.count)）") {
                Text("素材先保存在本机，再发送给此家庭指定的 Mac。只有处理结果进入验证完成的快照，才显示已更新。").font(.caption).foregroundStyle(.secondary)
                if !store.workspaceRequestStatusesVerified {
                    Text("正在核对本机已保存的请求。").foregroundStyle(.secondary)
                } else if store.workspaceRequestStatuses.isEmpty {
                    Text("当前没有已保存的处理请求。").foregroundStyle(.secondary)
                }
                ForEach(Array(store.workspaceRequestStatuses.keys.sorted().prefix(100)), id: \.self) { id in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            Text("请求 " + String(id.prefix(8))).textSelection(.enabled)
                            Spacer()
                            Text(statusText(store.workspaceRequestStatuses[id] ?? "")).foregroundStyle(.secondary)
                        }
                        if !["included", "needsReview"].contains(store.workspaceRequestStatuses[id] ?? "") {
                            HStack {
                                Button("重试发送") { Task { await store.updateWorkspaceRequest(id, cancel: false) } }
                                if store.workspaceRequestStatuses[id] != "cancelled" {
                                    Button("取消等待") { Task { await store.updateWorkspaceRequest(id, cancel: true) } }
                                }
                            }.disabled(store.categoryBusy)
                        } else if store.workspaceRequestStatuses[id] == "needsReview" {
                            Button("核对并重试原请求") { Task { await store.updateWorkspaceRequest(id, cancel: false) } }
                                .disabled(store.categoryBusy)
                            Text("只核对和重试原请求；已保存的结果仍以验证快照为准。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if store.workspaceRequestStatuses.count > 100 { Text("仅显示前 100 个请求。").font(.caption).foregroundStyle(.secondary) }
                Button("重新发送等待中的请求") { Task { await store.familyClientSyncController?.refresh() } }
                    .disabled(store.familyClientSyncController == nil || store.categoryBusy)
                if !store.importState.isEmpty { Text(store.importState).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func statusText(_ status: String) -> String {
        switch status {
        case "queued": "已保存，等待指定 Mac"
        case "uploaded": "已发送，等待处理结果"
        case "received": "Mac 已接收，等待处理结果"
        case "cancelled": "已取消等待；已提交的结果仍以快照为准"
        case "included": "处理结果已进入验证完成的快照"
        case "needsReview": "需要核对处理结果；原请求已保留"
        default: "状态待确认（" + status + "）"
        }
    }
}

struct WorkspaceSyncActions: View {
    @Bindable var store: FinancialStore
    let evidence: BrowserStore
    @State private var busy = false
    var body: some View {
        if store.workspacePaths != nil || store.clientWorkspacePaths != nil {
            VStack(alignment: .leading, spacing: 6) {
                if store.familyClientPaths != nil {
                    Button("刷新家庭同步") { refreshFamilyClient() }
                    Button("重新选择原同步目录") { reconnect() }
                } else if hasFamilyConnection {
                    Button("发布家庭同步") { publishFamily() }
                } else {
                    if hasSavedConnection { Button("重新选择原同步目录") { reconnect() } }
                    if store.workspacePaths != nil {
                        Button("建立新的家庭同步") { create() }.disabled(!store.editingAvailable)
                        Button("连接已有家庭同步") { connect() }
                    }
                }
            }.disabled(busy || store.importing || store.loading || store.completionSaving || store.completion.persisting || store.editorPauseReason != nil)
        }
    }
    private func refreshFamilyClient() {
        guard let paths = store.familyClientPaths, store.completion.drafts.isEmpty, !store.hasUnsavedParameters else {
            store.syncStatus = "请先保存或还原当前草稿，再刷新家庭快照。"; return
        }
        busy = true
        Task {
            defer { busy = false }
            await store.resumeWorkspaceSync(paths: paths, evidence: evidence)
            await store.familyClientSyncController?.refresh()
        }
    }
    private var hasFamilyConnection: Bool {
        guard let paths = store.workspacePaths else { return false }
        return FileManager.default.fileExists(atPath: paths.device.appendingPathComponent("family-connection.json").path)
    }
    private func publishFamily() {
        guard let paths = store.workspacePaths else { return }
        guard store.completion.drafts.isEmpty, !store.hasUnsavedParameters else {
            store.syncStatus = "请先保存或还原当前草稿，再发布家庭同步。"; return
        }
        busy = true
        Task {
            let selectionGeneration = store.workspaceSelectionGeneration
            store.editorPauseReason = "正在发布家庭同步"
            defer {
                busy = false
                if store.isWorkspaceSelectionCurrent(paths: paths, generation: selectionGeneration) { store.editorPauseReason = nil }
            }
            do {
                let generation = try await Task.detached {
                    guard let connection = try ReviewFamilyHost.readConnection(paths: paths) else { throw WorkspaceError.invalid("家庭连接缺失。") }
                    var remote = connection.remote
                    if let bookmark = connection.bookmark {
                        var stale = false
                        remote = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                        guard !stale, remote.path == connection.remote.path else { throw WorkspaceError.invalid("请重新定位原同步目录。") }
                    }
                    let scoped = remote.startAccessingSecurityScopedResource()
                    defer { if scoped { remote.stopAccessingSecurityScopedResource() } }
                    return try await ReviewFamilyHost.synchronize(paths: paths)
                }.value
                guard store.isWorkspaceSelectionCurrent(paths: paths, generation: selectionGeneration) else { return }
                await store.loadWorkspace(paths, selectionGeneration: selectionGeneration)
                guard store.isWorkspaceSelectionCurrent(paths: paths, generation: selectionGeneration) else { return }
                store.syncStatus = "完整快照已发布并通过回读验证（" + String(generation.prefix(8)) + "）。"
            } catch {
                if store.isWorkspaceSelectionCurrent(paths: paths, generation: selectionGeneration) { store.syncStatus = "发布尚未完成，可重试原发布：" + error.localizedDescription }
            }
        }
    }
    private var hasSavedConnection: Bool {
        guard let paths = store.workspacePaths ?? store.clientWorkspacePaths else { return false }
        return FileManager.default.fileExists(atPath: paths.device.appendingPathComponent("family-connection.json").path)
    }
    private func reconnect() {
        guard let paths = store.workspacePaths ?? store.clientWorkspacePaths,
              let remote = WorkspaceMaintenance.directory(message: "重新选择此资料原来的家庭同步目录。将核对原 workspace、binding 和 Host 身份，不会更换绑定或角色。") else { return }
        let scoped = remote.startAccessingSecurityScopedResource()
        busy = true
        Task {
            defer { busy = false; if scoped { remote.stopAccessingSecurityScopedResource() } }
            do {
                try await store.reconnectWorkspaceSync(paths: paths, remote: remote, evidence: evidence) {
                    try MacWorkspaceSelection.remember(paths.workspace,
                        shape: store.clientWorkspacePaths != nil ? .snapshotClient : .workspace, repairCorrupt: true)
                }
            } catch { store.syncStatus = "原家庭同步尚未恢复：" + error.localizedDescription }
        }
    }
    private func create() {
        guard store.completion.drafts.isEmpty, !store.hasUnsavedParameters else {
            store.syncStatus = "请先保存或还原当前草稿，再建立家庭同步。"; return
        }
        guard let paths = store.workspacePaths,
              let remote = WorkspaceMaintenance.directory(message: "选择新的空同步目录。此操作将明确建立新家庭绑定并发布首个完整快照。", create: true) else { return }
        let scoped = remote.startAccessingSecurityScopedResource()
        busy = true
        Task {
            let generation = store.workspaceSelectionGeneration
            defer { busy = false; if scoped { remote.stopAccessingSecurityScopedResource() } }
            do {
                let bookmark = try remote.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                store.editorPauseReason = "正在建立家庭同步"
                defer { if store.isWorkspaceSelectionCurrent(paths: paths, generation: generation) { store.editorPauseReason = nil } }
                _ = try await Task.detached { try ReviewFamilyHost.create(paths: paths, remote: remote, bookmark: bookmark) }.value
                guard store.isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
                await store.loadWorkspace(paths, selectionGeneration: generation)
                guard store.error == nil else { throw WorkspaceError.invalid(store.error!) }
                store.syncStatus = "家庭同步已建立，首个完整快照已通过回读验证。"
            } catch {
                if store.isWorkspaceSelectionCurrent(paths: paths, generation: generation) { store.syncStatus = "家庭同步未建立：" + error.localizedDescription }
            }
        }
    }
    private func connect() {
        guard store.completion.drafts.isEmpty, !store.hasUnsavedParameters else {
            store.syncStatus = "请先保存或还原当前草稿，再连接家庭同步。"; return
        }
        guard let remote = WorkspaceMaintenance.directory(message: "明确选择已有家庭同步目录。此操作只连接 client，不会启用 Host 或创建新绑定。") else { return }
        let paths: WorkspacePaths
        do { paths = try store.clientWorkspacePaths ?? MacWorkspaceSelection.newClientContainer() }
        catch { store.syncStatus = error.localizedDescription; return }
        let scoped = remote.startAccessingSecurityScopedResource()
        busy = true
        Task {
            defer { busy = false; if scoped { remote.stopAccessingSecurityScopedResource() } }
            do {
                try await store.connectWorkspaceClient(paths: paths, remote: remote, evidence: evidence) {
                    try MacWorkspaceSelection.remember(paths.workspace, shape: .snapshotClient, repairCorrupt: true)
                }
            }
            catch { store.syncStatus = "连接未完成：" + error.localizedDescription }
        }
    }
}
#endif
