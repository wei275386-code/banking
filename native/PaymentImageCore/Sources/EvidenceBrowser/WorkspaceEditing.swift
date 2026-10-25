#if os(macOS) || os(iOS)
import Foundation
import PaymentImageCore

/// Immutable read handle and the only Native business-write adapter.
struct WorkspaceEditSession: Sendable {
    let paths: WorkspacePaths
    let state: StateHandle
    var writeRestriction: String? = nil
    var familyDriver: ReviewFamilySyncDriver? = nil

    func writeScheduled<T: Sendable>(_ body: @escaping @Sendable (URL, URL) throws -> T) async throws -> (T, StateHandle) {
        if let familyDriver { return try await familyDriver.runWriter(kind: .localEdit) { try self.write(body) } }
        return try write(body)
    }

    func write<T: Sendable>(_ body: (URL, URL) throws -> T) throws -> (T, StateHandle) {
        if let writeRestriction { throw WorkspaceError.invalid(writeRestriction) }
        let coordinator = WorkspaceCoordinator(paths: paths)
        let token = try coordinator.acquireWriteToken()
        let transaction = try coordinator.begin(token: token, expectedPointer: state.pointer)
        var written: T?
        do {
            let value = try body(transaction.root.appendingPathComponent("review"), transaction.root.appendingPathComponent("config"))
            written = value
            guard try NativeWorkspaceEffects.record(transaction: transaction, token: token) else {
                try transaction.abandon(token: token)
                return (value, state)
            }
            _ = try transaction.prepare(token: token, validator: WorkspaceBusinessValidation.validate)
            let committed = try transaction.commit(token: token)
            WorkspaceReclamation.collectWhileHoldingWrite(paths: paths, token: token)
            return (value, committed)
        } catch {
            // Pointer membership wins if the final journal/fsync report failed.
            if let value = written, let active = try? paths.readState(), active.pointer.stateID == transaction.stateID,
               (try? coordinator.recover(operationID: transaction.operationID)) == .committed(active) { return (value, active) }
            try? transaction.abandon(token: token)
            throw error
        }
    }
}

struct FamilyClientEditSession: Sendable {
    let paths: WorkspacePaths, handle: ReviewFamilyClientHandle
    func write<T: Sendable>(_ body: (URL, URL) throws -> T) throws -> (T, ReviewFamilyClientHandle) {
        try ReviewFamilyClientSession.edit(paths: paths, expected: handle, body: body)
    }
}

extension FinancialStore {
    var familyClientEditSession: FamilyClientEditSession? {
        guard editingAvailable, let paths = familyClientPaths, let handle = familyClientHandle, root == handle.review else { return nil }
        return FamilyClientEditSession(paths: paths, handle: handle)
    }
    func adoptFamilyClientEdit(_ handle: ReviewFamilyClientHandle) {
        familyClientHandle = handle; root = handle.review; pinnedClientReview = handle.review
        completion.root = handle.review
        completion.undo = completion.undo?.rebased(to: handle.review)
        // Rendering canonicalizes the scratch transport documents. Subsequent
        // per-field CAS must pin the actually installed bytes, not scratch JSON.
        for name in ["financial-review.json", "category-catalog.json", "fire-parameters-user.json", "completion-workflow.json"] {
            sourceVersions[name] = ReviewFileVersion.of(try? Data(contentsOf: handle.review.appendingPathComponent(name)))
        }
        if let raw = try? Data(contentsOf: handle.review.appendingPathComponent("review-overrides.json")) { overrideDocument = raw }
        preparedCompletionQueues = [:]; invalidateCompletionCaches()
    }
    func loadFamilyClient(paths: WorkspacePaths, handle: ReviewFamilyClientHandle, selectionIsCurrent: () -> Bool = { true }) async throws {
        guard selectionIsCurrent() else { throw CancellationError() }
        let sameClient = familyClientPaths == paths && familyClientHandle?.selection == handle.selection
        let previousReport = sourceVersions["financial-review.json"], previousCatalog = categoryCatalog
        let previousDataset = report?.dataset_id, saved = completion.saved, selected = completion.selected, undo = completion.undo
        workspacePaths = nil; workspaceState = nil; familyClientPaths = paths; familyClientHandle = handle
        #if os(macOS)
        clientWorkspacePaths = paths
        familyHostSyncController?.stop(); familyHostSyncController = nil
        #endif
        pinnedClientReview = handle.review; workspaceWritable = true; workspaceProcessorEligible = false
        workspaceRuntimeReady = false; workspaceRuntimeFailure = nil; workspaceRuntimeNotice = ""
        await load(handle.review, selectionIsCurrent: selectionIsCurrent)
        guard selectionIsCurrent(), root == handle.review else { throw CancellationError() }
        if let error { throw WorkspaceError.invalid(error) }
        if sameClient, previousReport == sourceVersions["financial-review.json"], previousDataset == report?.dataset_id {
            completion.saved = saved; completion.selected = selected
            // Existing field/dependency CAS still checks undo against the newly
            // merged overrides. A catalog change explicitly invalidates undo.
            if previousCatalog == categoryCatalog { completion.undo = undo?.rebased(to: handle.review) }
        }
        #if os(macOS)
        let transport = try ReviewFamilyClientSession.requestTransport(paths: paths, expected: handle)
        let statuses = try await transport.localStatuses()
        guard selectionIsCurrent(), familyClientHandle?.version == handle.version else { throw CancellationError() }
        workspaceRequestStatuses = statuses; workspaceRequestStatusesVerified = true
        #endif
    }
    func adoptWorkspaceState(_ state: StateHandle) {
        workspaceState = state; root = state.review
        completion.root = state.review
        preparedCompletionQueues = [:]
        completion.undo = nil
    }
    var workspaceEditSession: WorkspaceEditSession? {
        guard let workspacePaths, let workspaceState else { return nil }
        let restriction = editingAvailable ? nil : editorPauseReason ?? workspaceRuntimeFailure ?? "当前资料仅支持查看。"
        #if os(macOS)
        return WorkspaceEditSession(paths: workspacePaths, state: workspaceState, writeRestriction: restriction, familyDriver: familyHostSyncController?.driver)
        #else
        return WorkspaceEditSession(paths: workspacePaths, state: workspaceState, writeRestriction: restriction)
        #endif
    }
    func loadWorkspace(_ paths: WorkspacePaths, expectedPointer: WorkspaceStatePointer? = nil,
                       selectionGeneration: UUID? = nil, selectionIsCurrent: () -> Bool = { true }) async {
        guard selectionIsCurrent() else { return }
        #if os(macOS)
        let generation = selectionGeneration ?? expectWorkspace(paths)
        guard isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
        #endif
        do {
            #if os(macOS)
            let ownsPause = editorPauseReason == nil
            if ownsPause { editorPauseReason = "正在读取本机已保存资料" }
            defer { if ownsPause, isWorkspaceSelectionCurrent(paths: paths, generation: generation) { editorPauseReason = nil } }
            if !FileManager.default.fileExists(atPath: paths.metadata.path), let family = try await Task.detached(operation: { try ReviewFamilyClientSession.read(paths: paths) }).value {
                guard selectionIsCurrent(), isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
                try await loadFamilyClient(paths: paths, handle: family, selectionIsCurrent: { selectionIsCurrent() && self.isWorkspaceSelectionCurrent(paths: paths, generation: generation) })
                return
            }
            #endif
            let (state, pending, notice, writable, processorEligible) = try await Task.detached {
                WorkspaceReclamation.collectWhileOpening(paths: paths)
                let health = try WorkspaceHealth.inspect(paths: paths, businessValidator: WorkspaceBusinessValidation.validateRead, runtimeValidator: nil)
                let state = health.state
                if let expectedPointer { guard state.pointer == expectedPointer else { throw WorkspaceError.stalePointer } }
                let viewing = try WorkspaceCompatibility.isViewingCopy(paths: paths)
                let compatibility = try WorkspaceCompatibility.decision(paths: paths, state: state)
                var notice = viewing ? "当前是只读查看副本。可查看和保留资料，不能编辑、导入或重算。" : ""
                if !compatibility.writable && !viewing { notice = "当前版本仅支持查看此资料：" + compatibility.reasons.joined(separator: "、") }
                return (state, try PendingVideoList.load(state: state), notice, health.writable, health.writable && health.processorEligible)
            }.value
            guard selectionIsCurrent() else { return }
            #if os(macOS)
            guard isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
            #endif
            workspacePaths = paths; workspaceState = state
            familyClientPaths = nil; familyClientHandle = nil
            pinnedClientReview = nil
            #if os(macOS)
            clientWorkspacePaths = nil
            workspaceRequestStatuses = [:]; workspaceRequestStatusesVerified = false
            if familyClientSyncController?.paths.workspace.path != paths.workspace.path {
                familyClientSyncController?.stop(); familyClientSyncController = nil
            }
            #endif
            pendingVideos = pending.items; pendingVideoCount = pending.total
            workspaceNotice = notice
            workspaceWritable = writable
            workspaceProcessorEligible = processorEligible
            #if os(macOS)
            scheduleWorkspaceRuntimeQualification(paths: paths, workspaceID: state.pointer.workspaceID)
            await load(state.review, selectionIsCurrent: {
                selectionIsCurrent() && self.isWorkspaceSelectionCurrent(paths: paths, generation: generation)
            })
            guard selectionIsCurrent(), isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
            if let afterWorkspaceReaderPublished { await afterWorkspaceReaderPublished(paths) }
            guard selectionIsCurrent(), isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
            if error == nil { await resumeWorkspaceSync(paths: paths, selectionGeneration: generation) }
            #else
            await load(state.review, selectionIsCurrent: selectionIsCurrent)
            #endif
        } catch {
            guard selectionIsCurrent() else { return }
            #if os(macOS)
            guard isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
            #endif
            self.error = "无法打开资料：" + error.localizedDescription
        }
    }
    func reloadCurrent() async {
        if let workspacePaths { await loadWorkspace(workspacePaths) }
        else if let root { await load(root) }
    }
}
#endif

#if os(macOS) || os(iOS)
enum WorkspaceBusinessValidation {
    static func validate(_ root: URL) throws { try WorkspaceBusinessValidator.validate(root) }
    static func validateRead(_ state: StateHandle) throws { try WorkspaceBusinessValidator.validateRead(state) }
}

#endif

#if os(macOS)
extension FinancialStore {
    func scheduleWorkspaceRuntimeQualification(paths: WorkspacePaths, workspaceID: String) {
        let selectedWorkspace = paths.workspace.path
        let previousPrefix = selectedWorkspace + "|" + workspaceID + "|"
        if workspaceRuntimeKey?.hasPrefix(previousPrefix) != true {
            workspaceRuntimeReady = false
            workspaceRuntimeFailure = nil
            workspaceRuntimeNotice = "正在后台检查本机处理器；完成前可浏览资料，导入与重算暂不可用。"
        }
        workspaceRuntimeTask?.cancel()
        workspaceRuntimeTask = Task { [weak self] in
            let selection = await Task.detached(priority: .utility) { () -> (String, WorkspaceRuntimeQualification.Result) in
                guard Bundle.main.bundleURL.pathExtension == "app" else {
                    #if DEBUG
                    return (previousPrefix + "development", .explicitDevelopment)
                    #else
                    return (previousPrefix + "unbundled", .failure("生产版本缺少完整 App runtime。"))
                    #endif
                }
                do {
                    let hash = try WorkspaceRuntimeQualification.launchedManifestSHA256()
                    let key = previousPrefix + hash
                    return (key, .qualified(manifestSHA256: hash))
                } catch { return (previousPrefix + "invalid", .failure(error.localizedDescription)) }
            }.value
            guard !Task.isCancelled, let self, self.workspacePaths?.workspace.path == selectedWorkspace,
                  self.workspaceState?.pointer.workspaceID == workspaceID else { return }
            // The key is derived from small bounded metadata. A normal edit
            // reload never launches a new functional doctor or hashes runtime.
            if self.workspaceRuntimeKey == selection.0 { return }
            self.workspaceRuntimeReady = false
            self.workspaceRuntimeFailure = nil
            self.workspaceRuntimeNotice = "正在后台检查本机处理器；完成前可浏览资料，导入与重算暂不可用。"
            let result: WorkspaceRuntimeQualification.Result
            switch selection.1 {
            case .qualified:
                result = await Task.detached(priority: .utility) {
                    do {
                        let runtime = try ProcessorRuntime.resolve()
                        return await WorkspaceRuntimeQualification.shared.qualify(paths: paths, runtime: runtime)
                    } catch { return .failure(error.localizedDescription) }
                }.value
            default: result = selection.1
            }
            guard !Task.isCancelled, self.workspacePaths?.workspace.path == selectedWorkspace,
                  self.workspaceState?.pointer.workspaceID == workspaceID else { return }
            if case .qualified(let digest) = result {
                let current = try? await Task.detached(priority: .utility) { try WorkspaceRuntimeQualification.launchedManifestSHA256() }.value
                guard current == digest, selection.0 == previousPrefix + digest else {
                    self.workspaceRuntimeKey = nil
                    self.scheduleWorkspaceRuntimeQualification(paths: paths, workspaceID: workspaceID)
                    return
                }
            }
            self.workspaceRuntimeKey = selection.0
            self.applyWorkspaceRuntimeQualification(result)
        }
    }

    func applyWorkspaceRuntimeQualification(_ result: WorkspaceRuntimeQualification.Result) {
        switch result {
        case .qualified:
            workspaceRuntimeReady = true; workspaceRuntimeFailure = nil
            workspaceRuntimeNotice = "本机处理器检查通过。"
        case .explicitDevelopment:
            workspaceRuntimeReady = true; workspaceRuntimeFailure = nil
            workspaceRuntimeNotice = "开发模式；未授予 packaged runtime 资格。"
        case .failure(let detail):
            workspaceRuntimeReady = false
            workspaceRuntimeFailure = "本机处理器检查未通过：" + detail
            workspaceRuntimeNotice = workspaceRuntimeFailure! + " 资料仍可查看，编辑与处理暂不可用。"
        }
    }

    func retryWorkspaceRuntimeQualification() async {
        guard let paths = workspacePaths, let state = workspaceState else { return }
        await WorkspaceRuntimeQualification.shared.invalidate(workspace: paths.workspace)
        guard workspacePaths?.workspace.path == paths.workspace.path,
              workspaceState?.pointer.workspaceID == state.pointer.workspaceID else { return }
        workspaceRuntimeKey = nil
        scheduleWorkspaceRuntimeQualification(paths: paths, workspaceID: state.pointer.workspaceID)
        await workspaceRuntimeTask?.value
    }

    func requireWorkspaceRuntimeQualification(_ runtime: ProcessorRuntime) async throws {
        guard let paths = workspacePaths, let state = workspaceState else { return }
        let result = await Task.detached(priority: .utility) {
            await WorkspaceRuntimeQualification.shared.qualify(paths: paths, runtime: runtime)
        }.value
        guard workspacePaths?.workspace.path == paths.workspace.path,
              workspaceState?.pointer.workspaceID == state.pointer.workspaceID else { throw WorkspaceError.stalePointer }
        applyWorkspaceRuntimeQualification(result)
        guard workspaceRuntimeReady else { throw WorkspaceError.invalid(workspaceRuntimeFailure ?? "处理器尚未通过检查。") }
    }

    func resolveWorkspaceProcessorRuntime() async throws -> ProcessorRuntime {
        do { return try await Task.detached(priority: .utility) { try ProcessorRuntime.resolve() }.value }
        catch {
            if let paths = workspacePaths {
                await recordWorkspaceRuntimeFailure(error.localizedDescription, paths: paths)
            }
            throw error
        }
    }
    func recordWorkspaceRuntimeFailure(_ detail: String, paths: WorkspacePaths) async {
        guard workspacePaths?.workspace.path == paths.workspace.path else { return }
        // An older successful probe must not overwrite this active failure.
        workspaceRuntimeTask?.cancel()
        applyWorkspaceRuntimeQualification(.failure(detail))
        await WorkspaceRuntimeQualification.shared.invalidate(workspace: paths.workspace)
    }
    func makeProcessorExecution(runtime: ProcessorRuntime) async throws -> ProcessorExecution {
        guard clientWorkspacePaths == nil else { throw WorkspaceError.invalid("client 处理任务必须发送给指定家庭 Mac。") }
        let paths = workspacePaths, state = workspaceState
        do {
            return try await Task.detached(priority: .userInitiated) {
                guard let paths, let state else { throw WorkspaceError.invalid("请先打开可写账本，再处理账单。") }
                return try ProcessorExecution(runtime: runtime, workspace: paths, state: state)
            }.value
        } catch {
            if let failure = error as? ProcessorRuntimeError, failure.code == .runtimeIntegrity, let paths {
                await recordWorkspaceRuntimeFailure(failure.localizedDescription, paths: paths)
            }
            throw error
        }
    }

    func runProcessor(_ executor: ProcessorExecution, operation: ProcessorExecution.Operation, input: Data) async throws -> ProcessorResult {
        let selectedPaths = workspacePaths
        let driver = familyHostSyncController?.paths.workspace.path == workspacePaths?.workspace.path ? familyHostSyncController?.driver : nil
        let task = Task.detached {
            if let driver { return try await driver.runWriter(kind: .processor) { try await executor.run(operation: operation, input: input) } }
            return try await executor.run(operation: operation, input: input)
        }
        processorTask = task
        defer { processorTask = nil }
        do { return try await task.value }
        catch {
            if let failure = error as? ProcessorRuntimeError, failure.code == .runtimeIntegrity, let selectedPaths {
                await recordWorkspaceRuntimeFailure(failure.localizedDescription, paths: selectedPaths)
            }
            throw error
        }
    }
    func retryPendingVideo(_ input: PendingVideoInput) async {
        guard workspacePaths != nil, let workspaceState, processorAvailable, pendingVideos.contains(input), !importing,
              !completionSaving, !discoveryBusy, !loading, !completion.persisting else { return }
        importing = true; importState = "正在重试此录屏的解析阶段，使用已保存原件…"; error = nil
        defer { importing = false }
        do {
            let runtime = try await resolveWorkspaceProcessorRuntime()
            try await requireWorkspaceRuntimeQualification(runtime)
            let executor = try await makeProcessorExecution(runtime: runtime)
            _ = try await runProcessor(executor, operation: .repair, input: JSONEncoder().encode(input))
            await reloadCurrent()
            guard error == nil else { importState = "解析已保存，但复盘刷新失败。请刷新数据。"; return }
            importState = "此录屏解析已保存，复盘已更新。"
        } catch {
            let failure = error
            // Reopen the authoritative state even on cancellation or a failed
            // projection; retained pending input remains visible for later retry.
            await reloadCurrent()
            self.error = "录屏重试未完成：" + failure.localizedDescription
            importState = "原件仍保留在资料中，可稍后重试。"
        }
    }
}

#endif
