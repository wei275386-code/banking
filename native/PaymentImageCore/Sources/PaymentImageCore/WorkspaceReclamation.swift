import Foundation
import Darwin

/// Readers hold a shared lock for the lifetime of an immutable state or view.
/// Reclamation can remove a tree only while it holds that tree's exclusive lock.
internal final class WorkspaceReaderLease: @unchecked Sendable {
    private let descriptor: Int32
    init(directory: URL, identity: String) throws {
        guard !identity.isEmpty, !identity.contains("/"), identity != ".", identity != ".." else { throw WorkspaceError.invalid("reader identity") }
        try WorkspaceIO.rejectSymlinks(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(identity)
        descriptor = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw WorkspaceError.io("reader lock") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(descriptor); throw WorkspaceError.invalid("reader lock type") }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { close(descriptor); throw WorkspaceError.busy }
    }
    deinit { close(descriptor) }
    static func removeIfUnleased(tree: URL, directory: URL, identity: String) throws -> Bool {
        try WorkspaceIO.rejectSymlinks(tree); try WorkspaceIO.rejectSymlinks(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(identity)
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw WorkspaceError.io("reclamation lock") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceError.invalid("reader lock type") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw WorkspaceError.io("reclamation lock") }
            return false
        }
        try FileManager.default.removeItem(at: tree)
        try FileManager.default.removeItem(at: file)
        return true
    }
}

public enum WorkspaceReclamation {
    public struct Result: Sendable { public let states: Int, sourceObjects: Int, journals: Int, clientViews: Int }
    /// The current ledger retains exact input/result identities for deduplication.
    /// Full completed states and journals are not required to interpret that ledger.
    @discardableResult public static func collect(paths: WorkspacePaths, token: WorkspaceWriteToken) throws -> Result {
        try token.validate(for: paths)
        let active = try paths.readState(validateFiles: false)
        let ledger = try WorkspaceIO.object(WorkspaceIO.read(active.operationResults))
        guard let results = ledger["results"] as? [[String: Any]] else { throw WorkspaceError.invalid("reclamation ledger") }
        let included = Set(results.compactMap { $0["operation_id"] as? String })
        var keepStates: Set<String> = [active.pointer.stateID], keepSources = Set<String>()
        var obsoleteJournals = [URL]()
        let activeManifest = try WorkspaceIO.object(WorkspaceIO.read(active.manifest))
        keepSources.formUnion((activeManifest["files"] as! [String: String]).values)
        for name in try children(paths.journals) {
            guard name.hasSuffix(".json") else { throw WorkspaceError.invalid("task journal name") }
            let file = paths.journals.appendingPathComponent(name), row = try WorkspaceIO.object(WorkspaceIO.read(file))
            let operation = row["operation"] as? [String: Any], result = row["result"] as? [String: Any]
            let id = row["operation_id"] as? String ?? operation?["operation_id"] as? String ?? result?["operation_id"] as? String
            let complete = id.map { included.contains($0) } ?? false
            let phase = row["phase"] as? String
            if complete || phase == "committed" && operation == nil && result == nil {
                if (row["target_pointer"] as? [String: Any])?["state_id"] as? String != active.pointer.stateID { obsoleteJournals.append(file) }
            } else {
                for key in ["expected_pointer", "target_pointer"] {
                    if let pointer = row[key] as? [String: Any], let state = pointer["state_id"] as? String { keepStates.insert(state) }
                }
                for input in operation?["inputs"] as? [[String: Any]] ?? [] {
                    if let hash = input["sha256"] as? String { keepSources.insert(hash) }
                }
            }
        }
        var stateCount = 0
        for name in try children(paths.states) where !keepStates.contains(name) {
            try WorkspaceIO.requireUUID(name, field: "state directory")
            if try WorkspaceReaderLease.removeIfUnleased(tree: paths.states.appendingPathComponent(name), directory: paths.device.appendingPathComponent("readers/states"), identity: name) { stateCount += 1 }
        }
        var sources = 0
        for name in try children(paths.sources) where !name.hasPrefix(".") && !keepSources.contains(name) {
            try WorkspaceIO.requireHash(name)
            try WorkspaceIO.rejectSymlinks(paths.sources.appendingPathComponent(name))
            try FileManager.default.removeItem(at: paths.sources.appendingPathComponent(name)); sources += 1
        }
        for file in obsoleteJournals { try FileManager.default.removeItem(at: file) }
        return .init(states: stateCount, sourceObjects: sources, journals: obsoleteJournals.count, clientViews: 0)
    }
    @discardableResult public static func collectClientViews(paths: WorkspacePaths, token: WorkspaceWriteToken) throws -> Int {
        try token.validate(for: paths)
        let pointer = paths.device.appendingPathComponent("client-active.json")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return 0 }
        let row = try WorkspaceIO.object(WorkspaceIO.read(pointer))
        let selected = URL(fileURLWithPath: try WorkspaceIO.string(row, "view_path")).lastPathComponent
        var count = 0
        let views = paths.device.appendingPathComponent("client-views")
        for name in try children(views) where name != selected {
            try WorkspaceIO.requireUUID(name, field: "client view")
            if try WorkspaceReaderLease.removeIfUnleased(tree: views.appendingPathComponent(name), directory: paths.device.appendingPathComponent("readers/views"), identity: name) { count += 1 }
        }
        return count
    }
    /// Called inside an existing admitted write or during opening, before the
    /// editor becomes available. Cleanup never competes with foreground saves.
    public static func collectWhileHoldingWrite(paths: WorkspacePaths, token: WorkspaceWriteToken) {
        do {
            if FileManager.default.fileExists(atPath: paths.metadata.path) { _ = try collect(paths: paths, token: token) }
            else { _ = try ReviewFamilyClientSession.collect(paths: paths, token: token) }
        } catch WorkspaceError.busy { return }
        catch {
            try? WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["status": "deferred", "message": error.localizedDescription]),
                to: paths.device.appendingPathComponent("reclamation-status.json"))
        }
    }
    public static func collectWhileOpening(paths: WorkspacePaths) {
        do {
            let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
            collectWhileHoldingWrite(paths: paths, token: token)
        } catch WorkspaceError.busy { return }
        catch {
            try? WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["status": "deferred", "message": error.localizedDescription]),
                to: paths.device.appendingPathComponent("reclamation-status.json"))
        }
    }
    internal static func children(_ root: URL) throws -> [String] {
        try WorkspaceIO.rejectSymlinks(root)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let result = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard result.count <= 100_000 else { throw WorkspaceError.invalid("reclamation directory budget") }
        return result
    }
}
