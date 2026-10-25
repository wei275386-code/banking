#if os(macOS)
import SwiftUI
import AppKit
import PaymentImageCore

struct WorkspaceWelcomeView: View {
    @Bindable var finance: FinancialStore
    let evidence: BrowserStore
    @State private var busy = false
    @State private var stopping = false
    @State private var unavailable: String?
    @State private var activeScope: URL?
    @State private var pendingClient: WorkspacePaths?
    @State private var maintenanceTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "house.and.flag").font(.system(size: 42)).foregroundStyle(.teal)
            Text("家庭财务复盘").font(.largeTitle.bold())
            Text("创建家庭资料后即可导入账单。资料自动保存在本机应用目录，与工程源码分开。").foregroundStyle(.secondary)
            HStack {
                Button("创建新的家庭资料") { create() }.buttonStyle(.borderedProminent)
                Button("打开已有本机资料") { chooseExisting() }
            }.disabled(busy)
            HStack {
                Button("从备份恢复") { restore() }
                Button("恢复同步副本") { restoreClient() }
                Button(pendingClient == nil ? "连接已有家庭同步" : "重新选择原同步目录") { connect() }
                if let pendingClient {
                    Button("继续等待家庭快照") { waitForPending(pendingClient) }
                }
            }.disabled(busy)
            if busy { ProgressView("正在准备资料…") }
            if maintenanceTask != nil { Button("取消操作") { maintenanceTask?.cancel(); stopping = true } }
            if stopping { Text("正在停止操作，并核对目标状态…").foregroundStyle(.secondary) }
            if let error = finance.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let unavailable { Text(unavailable).foregroundStyle(.secondary) }
            if !finance.syncStatus.isEmpty { Text(finance.syncStatus).foregroundStyle(.secondary) }
        }.padding(56).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .frame(minWidth: 760, minHeight: 520)
            .task {
                guard finance.root == nil else { return }
                do {
                    let locations = try AppStorageLocations.forCurrentProcess()
                    let index = AppStorageIndex(locations: locations)
                    if let selected = try index.selected() {
                        if selected.url.startAccessingSecurityScopedResource() { activeScope = selected.url }
                        await open(selected.url, remember: false, expectedShape: selected.entry.shape)
                        return
                    }
                } catch { finance.error = "无法恢复已选资料，请恢复或重新选择已有资料：" + error.localizedDescription }
            }
    }
    private func create() {
        do {
            let destination = try AppStorageLocations.forCurrentProcess().newWorkspaceURL()
            begin(.init(command: .create, workspace: destination), sourceScopes: [])
        } catch { finance.error = "无法创建资料：" + error.localizedDescription }
    }
    private func chooseExisting() {
        guard let folder = WorkspaceMaintenance.directory(message: "选择已有家庭资料目录。程序会读取当前结构的用户数据。") else { return }
        if folder.startAccessingSecurityScopedResource() { activeScope = folder }
        busy = true; finance.error = nil
        maintenanceTask = Task {
            defer { busy = false; stopping = false; maintenanceTask = nil }
            await open(folder, remember: true)
        }
    }
    private func restore() {
        guard let package = WorkspaceMaintenance.directory(message: "选择备份包。将在本机应用目录创建新的恢复资料，既有资料不会被覆盖。") else { return }
        let scoped = package.startAccessingSecurityScopedResource()
        do {
            let destination = try AppStorageLocations.forCurrentProcess().newWorkspaceURL()
            busy = true; stopping = false; finance.error = nil; unavailable = nil
            maintenanceTask = Task {
                defer { busy = false; stopping = false; maintenanceTask = nil; if scoped { package.stopAccessingSecurityScopedResource() } }
                do {
                    try await WorkspaceMaintenance.restoreBackup(package: package, destination: destination)
                    try Task.checkCancellation()
                    await open(destination, remember: true)
                } catch { finance.error = "资料未恢复：" + error.localizedDescription }
            }
        } catch { if scoped { package.stopAccessingSecurityScopedResource() }; finance.error = error.localizedDescription }
    }
    private func restoreClient() {
        guard !busy, let package = WorkspaceMaintenance.directory(message: "选择本机家庭副本备份。恢复的副本可离线使用，之后需重新选择原同步目录。") else { return }
        let scoped = package.startAccessingSecurityScopedResource()
        busy = true; stopping = false; finance.error = nil
        maintenanceTask = Task {
            defer { busy = false; stopping = false; maintenanceTask = nil; if scoped { package.stopAccessingSecurityScopedResource() } }
            do {
                let destination = try AppStorageLocations.forCurrentProcess().newWorkspaceURL()
                try await WorkspaceMaintenance.restoreClient(package: package, destination: destination)
                try Task.checkCancellation()
                await open(destination, remember: true, expectedShape: .snapshotClient)
            } catch { finance.error = error.localizedDescription }
        }
    }
    private func waitForPending(_ paths: WorkspacePaths) {
        guard !busy else { return }
        busy = true; finance.error = nil
        maintenanceTask = Task {
            defer { busy = false; stopping = false; maintenanceTask = nil }
            await open(paths.workspace, remember: false, expectedShape: .snapshotClient)
        }
    }
    private func connect() {
        guard let remote = WorkspaceMaintenance.directory(message: "选择 Mac 已发布的家庭同步目录。本机副本自动保存在应用目录，不会启用 Host。") else { return }
        let scoped = remote.startAccessingSecurityScopedResource()
        busy = true; stopping = false; finance.error = nil; unavailable = nil
        maintenanceTask = Task {
            defer { busy = false; stopping = false; maintenanceTask = nil; if scoped { remote.stopAccessingSecurityScopedResource() } }
            do {
                if let paths = pendingClient {
                    try await finance.reconnectWorkspaceSync(paths: paths, remote: remote, evidence: evidence) {
                        try remember(paths.workspace, shape: .snapshotClient)
                    }
                } else {
                    let paths = try MacWorkspaceSelection.newClientContainer()
                    try await finance.connectWorkspaceClient(paths: paths, remote: remote, evidence: evidence) {
                        try remember(paths.workspace, shape: .snapshotClient)
                        pendingClient = paths
                    }
                }
                if finance.clientWorkspacePaths == nil { unavailable = "连接已保存，正在等待完整家庭快照；尚未打开复盘。" }
            } catch { finance.error = "连接未完成：" + error.localizedDescription }
        }
    }
    private func begin(_ request: WorkspaceMaintenanceRequest, sourceScopes: [URL]) {
        busy = true; stopping = false; finance.error = nil; unavailable = nil
        maintenanceTask = Task {
            defer {
                busy = false; stopping = false; maintenanceTask = nil
                for scope in sourceScopes { scope.stopAccessingSecurityScopedResource() }
            }
            do {
                let result = try await WorkspaceMaintenance.run(request)
                await open(request.workspace, remember: true, expectedPointer: result.state?.pointer)
            } catch { finance.error = "资料未打开：" + error.localizedDescription }
        }
    }
    private func remember(_ folder: URL, shape: AppStorageIndex.Shape) throws {
        try MacWorkspaceSelection.remember(folder, shape: shape, repairCorrupt: true)
    }
    private func open(_ folder: URL, remember: Bool, expectedPointer: WorkspaceStatePointer? = nil,
                      expectedShape: AppStorageIndex.Shape? = nil) async {
        guard let result = await finance.openStoredWorkspace(folder, expectedPointer: expectedPointer,
            expectedShape: expectedShape, selectionSaved: { shape in
                if remember { try self.remember(folder, shape: shape) }
            }, pendingSelected: { pendingClient = $0 }), finance.isCurrentWorkspaceOpen(result) else { return }
        if result.pending {
            pendingClient = result.paths
            unavailable = "本机连接已保留，等待完整家庭快照。若授权失效，请重新选择原同步目录。"
        } else {
            pendingClient = nil
            if let review = finance.root { await evidence.load(review, finance: finance.report) }
            guard finance.isCurrentWorkspaceOpen(result) else { return }
            finance.familyClientSyncController?.evidence = evidence
        }
    }
}

/// One opening token covers local validation and reader activation.
struct StoredWorkspaceOpenResult {
    let paths: WorkspacePaths
    let selectionGeneration: UUID
    let openingGeneration: UUID
    let pending: Bool
}

extension FinancialStore {
    func isCurrentWorkspaceOpen(_ result: StoredWorkspaceOpenResult) -> Bool {
        workspaceOpenGeneration == result.openingGeneration &&
        isWorkspaceSelectionCurrent(paths: result.paths, generation: result.selectionGeneration)
    }
    func openStoredWorkspace(_ folder: URL, expectedPointer: WorkspaceStatePointer? = nil,
                             expectedShape: AppStorageIndex.Shape? = nil,
                             selectionSaved: (AppStorageIndex.Shape) throws -> Void,
                             pendingSelected: (WorkspacePaths) -> Void = { _ in }) async -> StoredWorkspaceOpenResult? {
        var openingGeneration = UUID()
        workspaceOpenGeneration = openingGeneration
        var selectionGeneration = workspaceSelectionGeneration
        let isCurrent = {
            self.workspaceOpenGeneration == openingGeneration && self.workspaceSelectionGeneration == selectionGeneration
        }
        do {
            try Task.checkCancellation()
            let paths = try WorkspacePaths(workspace: folder)
            let hasWorkspace = FileManager.default.fileExists(atPath: paths.metadata.path)
            if let expectedShape, (expectedShape == .workspace) != hasWorkspace {
                throw WorkspaceError.invalid("已选资料形态发生变化，请重新选择已有资料。")
            }
            if !hasWorkspace {
                if try ReviewFamilyClientSession.readConnection(paths: paths) != nil {
                    selectionGeneration = try selectPendingWorkspace(paths: paths) { try selectionSaved(.snapshotClient) }
                    openingGeneration = workspaceOpenGeneration; pendingSelected(paths)
                    let handle = try await Task.detached { try ReviewFamilyClientSession.read(paths: paths) }.value
                    guard isCurrent() else { return nil }
                    if let handle { try await loadFamilyClient(paths: paths, handle: handle, selectionIsCurrent: isCurrent) }
                    guard isCurrent() else { return nil }
                    return StoredWorkspaceOpenResult(paths: paths, selectionGeneration: selectionGeneration, openingGeneration: openingGeneration, pending: handle == nil)
                }
                throw WorkspaceError.invalid("未找到当前家庭副本的本机连接。")
            }
            selectionGeneration = expectWorkspace(paths)
            openingGeneration = workspaceOpenGeneration
            await loadWorkspace(paths, expectedPointer: expectedPointer, selectionGeneration: selectionGeneration,
                                selectionIsCurrent: isCurrent)
            guard isCurrent(), error == nil, root != nil else { return nil }
            try Task.checkCancellation()
            try selectionSaved(.workspace)
            return StoredWorkspaceOpenResult(paths: paths, selectionGeneration: selectionGeneration,
                                             openingGeneration: openingGeneration, pending: false)
        } catch is CancellationError { return nil }
        catch {
            guard isCurrent() else { return nil }
            self.error = "无法打开资料：" + error.localizedDescription
            return nil
        }
    }
}

enum WorkspaceCreation {
    static func create(_ destination: URL) async throws {
        _ = try await WorkspaceMaintenance.run(.init(command: .create, workspace: destination))
    }
}
#endif
