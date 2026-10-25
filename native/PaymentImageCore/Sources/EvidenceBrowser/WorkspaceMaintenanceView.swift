#if os(macOS)
import SwiftUI
import AppKit
import PaymentImageCore

enum WorkspaceMaintenance {
    /// Runtime hashing, receipt checks and business decoding stay off the UI thread.
    static func run(_ request: WorkspaceMaintenanceRequest) async throws -> WorkspaceMaintenanceResult {
        let operation = Task.detached(priority: .userInitiated) {
            let runtime = try ProcessorRuntime.resolve()
            let result = try await WorkspaceMaintenanceExecutor(runtime: runtime).run(request)
            if let state = result.state { try WorkspaceBusinessValidation.validateRead(state) }
            return result
        }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
    static func clientBackup(paths: WorkspacePaths, destination: URL, publishedHost: Bool = false) async throws {
        let operation = Task.detached(priority: .userInitiated) {
            if publishedHost { try ReviewFamilyHost.exportPublishedBackup(paths: paths, destination: destination) }
            else { try ReviewFamilyClientSession.exportSelectedBackup(paths: paths, destination: destination) }
        }
        try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
    static func workBackup(paths: WorkspacePaths, destination: URL, expectedPointer: WorkspaceStatePointer, readOnly: Bool = false) async throws {
        let operation = Task.detached(priority: .userInitiated) {
            try HouseholdWorkBackup.export(paths: paths, destination: destination, expectedPointer: expectedPointer, readOnly: readOnly)
        }
        try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
    static func restoreBackup(package: URL, destination: URL) async throws {
        let isWorkBackup = try await Task.detached { try HouseholdWorkBackup.recognizes(package) }.value
        if isWorkBackup {
            let operation = Task.detached(priority: .userInitiated) {
                try HouseholdWorkBackup.restore(package: package, destination: destination)
            }
            _ = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        } else {
            try await restoreClient(package: package, destination: destination)
        }
    }
    static func restoreClient(package: URL, destination: URL) async throws {
        let operation = Task.detached(priority: .userInitiated) {
            _ = try ReviewFamilyClientSession.restoreSelectedBackup(package: package, destination: destination)
        }
        try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
    @MainActor static func directory(message: String, create: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = create; panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func destination(in parent: URL) -> URL {
        URL(fileURLWithPath: parent.path + "/家庭财务资料-" + UUID().uuidString.lowercased(), isDirectory: true)
    }

}

@MainActor enum MacWorkspaceSelection {
    static func newClientContainer() throws -> WorkspacePaths {
        try WorkspacePaths(workspace: AppStorageLocations.forCurrentProcess().newWorkspaceURL())
    }
    /// Call only after data/descriptor validation. The index owns the complete
    /// selection and its bookmark in one atomic record.
    static func remember(_ folder: URL, shape: AppStorageIndex.Shape, repairCorrupt: Bool) throws {
        let locations = try AppStorageLocations.forCurrentProcess()
        let index = AppStorageIndex(locations: locations)
        if let id = try locations.managedContainerID(for: folder) {
            try index.select(containerID: id, shape: shape, repairCorrupt: repairCorrupt)
        } else {
            let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            try index.selectExternal(url: folder, bookmark: bookmark, shape: shape, repairCorrupt: repairCorrupt)
        }
    }
}

/// Current-workspace maintenance uses the pinned tuple supplied by the Store.
/// The backend owns the fixed gate; this View never creates a Native lease.
struct WorkspaceMaintenanceActions: View {
    @Bindable var store: FinancialStore
    @State private var task: Task<Void, Never>?
    @State private var status = ""
    @State private var failed = false
    @State private var familyHost = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.familyClientPaths != nil {
                Button("备份本机家庭副本") { backupClient(publishedHost: false) }
            } else if familyHost {
                Menu("备份家庭资料") {
                    Button("创建完整备份") { backupWork() }
                    Button("备份已发布的家庭副本") { backupClient(publishedHost: true) }
                }
            } else {
            Button("检查家庭资料") { inspect() }
            Menu("备份家庭资料") {
                Button("创建完整备份") { backupWork() }
                Button("创建只读查看副本") { backupWork(readOnly: true) }
            }
            }
            if task != nil {
                ProgressView().controlSize(.small)
                Button("取消资料维护") { task?.cancel(); status = "正在停止操作，并核对目标状态…" }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(failed ? .red : .secondary).textSelection(.enabled) }
        }
        .disabled(task == nil && (store.importing || store.loading || store.completionSaving || store.completion.persisting))
        .task(id: store.workspaceState?.pointer) {
            guard let paths = store.workspacePaths else { familyHost = false; return }
            familyHost = (try? await Task.detached(priority: .utility) { try ReviewFamilyHost.readConnection(paths: paths) != nil }.value) ?? false
        }
    }
    private func backupWork(readOnly: Bool = false) {
        guard task == nil, let paths = store.workspacePaths, let state = store.workspaceState else { return }
        guard store.completion.drafts.isEmpty, !store.hasUnsavedParameters else {
            failed = true; status = "请先保存或还原当前草稿，再创建完整备份。"; return
        }
        guard let parent = WorkspaceMaintenance.directory(message: "备份当前已保存的账本、原始资料和家庭设置。恢复后可继续导入账单，并重新建立同步。", create: true) else { return }
        let scoped = parent.startAccessingSecurityScopedResource()
        let destination = parent.appendingPathComponent("家庭完整备份-" + UUID().uuidString.lowercased())
        store.importing = true; failed = false; status = "正在创建完整备份…"
        task = Task {
            defer { store.importing = false; task = nil; if scoped { parent.stopAccessingSecurityScopedResource() } }
            do {
                try await WorkspaceMaintenance.workBackup(paths: paths, destination: destination, expectedPointer: state.pointer, readOnly: readOnly)
                status = "备份已保存：" + destination.path
            } catch { failed = true; status = error.localizedDescription }
        }
    }
    private func backupClient(publishedHost: Bool) {
        guard task == nil, let paths = publishedHost ? store.workspacePaths : store.familyClientPaths else { return }
        guard store.completion.drafts.isEmpty, !store.hasUnsavedParameters else {
            failed = true; status = "请先保存或还原当前草稿，再备份本机副本。"; return
        }
        guard let parent = WorkspaceMaintenance.directory(message: publishedHost ? "保存当前已完整发布的家庭副本。恢复后需重新选择同步目录。" : "保存本机家庭副本，包括尚未同步的修改。恢复后需重新选择同步目录。", create: true) else { return }
        let scoped = parent.startAccessingSecurityScopedResource()
        let destination = parent.appendingPathComponent("家庭副本备份-" + UUID().uuidString.lowercased())
        store.importing = true; failed = false; status = "正在备份本机家庭副本…"
        task = Task {
            defer { store.importing = false; task = nil; if scoped { parent.stopAccessingSecurityScopedResource() } }
            do {
                try await WorkspaceMaintenance.clientBackup(paths: paths, destination: destination, publishedHost: publishedHost)
                status = "本机副本已备份：" + destination.path
            } catch { failed = true; status = error.localizedDescription }
        }
    }
    private func inspect() {
        guard task == nil, let paths = store.workspacePaths, let state = store.workspaceState else { return }
        store.importing = true; failed = false; status = "正在检查当前资料…"
        task = Task {
            defer { store.importing = false; task = nil }
            do {
                _ = try await WorkspaceMaintenance.run(.init(command: .doctor, workspace: paths.workspace, expectedPointer: state.pointer))
                status = "资料检查已完成。"
            } catch { failed = true; status = error.localizedDescription }
        }
    }

}
#endif
