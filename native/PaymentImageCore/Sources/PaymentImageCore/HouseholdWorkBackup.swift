import Foundation
import Darwin

/// Current committed business data, restored as an independent, writable Mac
/// workspace. Household/record identity and processing results survive; device
/// credentials, old states and synchronization transport never enter the package.
public enum HouseholdWorkBackup {
    private static let purpose = "household-work-backup"
    private static let maximumBytes: Int64 = 100 * 1024 * 1024 * 1024
    private static let maximumFiles = 100_000

    public static func recognizes(_ package: URL) throws -> Bool {
        let row = try WorkspaceIO.object(WorkspaceIO.read(package.appendingPathComponent("manifest.json")))
        return row["purpose"] as? String == purpose
    }

    public static func export(paths: WorkspacePaths, destination: URL,
                              expectedPointer: WorkspaceStatePointer? = nil, readOnly: Bool = false) throws {
        let target = try newDestination(destination, separateFrom: paths.workspace)
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        defer { withExtendedLifetime(token) {} }
        let state = try paths.readState(validateFiles: false)
        if let expectedPointer, state.pointer != expectedPointer { throw WorkspaceError.stalePointer }
        if !readOnly { try WorkspaceCompatibility.requireWriter(paths: paths, state: state) }
        try ReviewFamilyHost.requireWorkBackupSource(paths: paths)
        let manifest = try WorkspaceIO.object(WorkspaceIO.read(state.manifest))
        let files = (manifest["files"] as! [String: String]).filter { retained($0.key) }
        try checkFiles(files)
        let stage = staging(for: target)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let payload = stage.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        try copy(files: files, from: state.root, to: payload)
        try validateBusiness(payload, files: files, workspaceID: state.pointer.workspaceID, stateID: state.pointer.stateID)
        let pending = try HouseholdPendingRequests.export(paths: paths, destination: stage.appendingPathComponent("pending"))
        guard files.count + pending.count <= maximumFiles else { throw WorkspaceError.invalid("完整备份文件数量过多。") }
        let document: [String: Any] = ["purpose": purpose, "access": readOnly ? "viewing" : "writable",
            "backup_id": UUID().uuidString.lowercased(), "created_at": ISO8601DateFormatter().string(from: Date()),
            "min_reader_version": WorkspaceCompatibility.appVersion,
            "workspace": try WorkspaceIO.object(WorkspaceIO.read(paths.metadata)),
            "source_state": state.pointer.document, "files": files, "pending_files": pending]
        let raw = try WorkspaceIO.canonical(document)
        guard raw.count <= 16 * 1024 * 1024 else { throw WorkspaceError.invalid("完整备份文件清单过大。") }
        try WorkspaceIO.atomicWrite(raw, to: stage.appendingPathComponent("manifest.json"))
        try WorkspaceIO.atomicWrite(Data((WorkspaceIO.digest(raw) + "\n").utf8), to: stage.appendingPathComponent("manifest.sha256"))
        try Task.checkCancellation()
        try publish(stage, to: target)
    }

    /// Does not select the workspace, reconnect a provider, or grant an old Host
    /// identity. Only a completely validated new local workspace is published.
    @discardableResult
    public static func restore(package: URL, destination: URL) throws -> WorkspacePaths {
        let source = WorkspaceIO.lexicalURL(package)
        let target = try newDestination(destination, separateFrom: source)
        let raw = try WorkspaceIO.read(source.appendingPathComponent("manifest.json"))
        let row = try WorkspaceIO.object(raw)
        guard Set(row.keys) == ["purpose", "access", "backup_id", "created_at", "min_reader_version", "workspace", "source_state", "files", "pending_files"],
              row["purpose"] as? String == purpose,
              ["viewing", "writable"].contains(row["access"] as? String ?? ""),
              try ReleaseCanonicalJSON.canonicalize(raw: raw) == raw,
              try WorkspaceIO.read(source.appendingPathComponent("manifest.sha256"), limit: 65) == Data((WorkspaceIO.digest(raw) + "\n").utf8),
              let files = row["files"] as? [String: String],
              let pending = row["pending_files"] as? [String: String],
              var metadata = row["workspace"] as? [String: Any],
              let sourceState = row["source_state"] as? [String: Any] else { throw WorkspaceError.invalid("完整备份格式或校验值无效。") }
        let backupID = try WorkspaceIO.string(row, "backup_id")
        try WorkspaceIO.requireUUID(backupID, field: "backup_id")
        guard try WorkspaceCompatibility.supports(minimumVersion: WorkspaceIO.string(row, "min_reader_version")) else {
            throw WorkspaceError.unsupportedVersion("请使用更新的 App 恢复此备份。")
        }
        try checkFiles(files)
        guard try Set(WorkspaceIO.regularFiles(source)) == Set(files.keys.map { "payload/" + $0 } + pending.keys.map { "pending/" + $0 }).union(["manifest.json", "manifest.sha256"]) else {
            throw WorkspaceError.invalid("完整备份文件缺失或包含未列出的文件。")
        }
        let workspaceID = try WorkspaceIO.string(metadata, "workspace_id")
        try WorkspaceIO.requireUUID(workspaceID, field: "workspace_id")
        let sourceStateID = try WorkspaceIO.string(sourceState, "state_id")
        try WorkspaceIO.requireUUID(sourceStateID, field: "state_id")
        guard sourceState["workspace_id"] as? String == workspaceID else { throw WorkspaceError.invalid("备份账本身份不一致。") }
        let stage = staging(for: target)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let paths = try WorkspacePaths(workspace: stage)
        guard files.count + pending.count <= maximumFiles else { throw WorkspaceError.invalid("完整备份文件数量过多。") }
        if !pending.isEmpty {
            try copy(files: pending, from: source.appendingPathComponent("pending"), to: HouseholdPendingRequests.root(paths))
            try HouseholdPendingRequests.validate(HouseholdPendingRequests.root(paths), workspaceID: workspaceID)
        }
        let stateID = UUID().uuidString.lowercased(), root = try paths.stateRoot(stateID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try copy(files: files, from: source.appendingPathComponent("payload"), to: root)
        // Processing-result membership and pending retained inputs keep their
        // original household IDs. Only the enclosing state's pointer changes.
        let ledgerFile = root.appendingPathComponent("operation-results.json")
        let ledger = try WorkspaceIO.read(ledgerFile)
        try WorkspaceIO.validateLedger(ledger, workspaceID: workspaceID, stateID: sourceStateID)
        let stateIDRaw = try JSONSerialization.data(withJSONObject: stateID, options: [.fragmentsAllowed])
        let rebased = try ReleaseCanonicalJSON.replacingObjectMember(raw: ledger, key: "state_id", valueRaw: stateIDRaw)
        try WorkspaceIO.atomicWrite(rebased, to: ledgerFile)
        var restoredFiles = files
        restoredFiles["operation-results.json"] = WorkspaceIO.digest(rebased)
        metadata["access"] = row["access"]
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(metadata), to: paths.metadata)
        let manifest = try WorkspaceIO.canonical(["workspace_id": workspaceID,
            "state_id": stateID, "local_revision": 0, "files": restoredFiles])
        try WorkspaceIO.atomicWrite(manifest, to: root.appendingPathComponent("state-manifest.json"))
        let pointer = WorkspaceStatePointer(workspaceID: workspaceID, stateID: stateID, localRevision: 0, manifestHash: WorkspaceIO.digest(manifest))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pointer.document), to: paths.activeState)
        let state = try paths.readState(validateFiles: false)
        if row["access"] as? String == "writable" { try WorkspaceCompatibility.requireWriter(paths: paths, state: state) }
        try validateBusiness(root, files: restoredFiles, workspaceID: workspaceID, stateID: stateID)
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        let deviceID = try ReviewDeviceIdentity.readOrCreate(paths: paths, token: token)
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["backup_id": backupID,
            "manifest_hash": WorkspaceIO.digest(raw), "device_id": deviceID,
            "sync_reconnection_required": true]), to: paths.device.appendingPathComponent("work-backup-restore.json"))
        withExtendedLifetime(token) {}
        try Task.checkCancellation()
        try publish(stage, to: target)
        return try WorkspacePaths(workspace: target)
    }

    private static func retained(_ path: String) -> Bool {
        !["state-manifest.json", "review/field-state.json", "review/revision-inventory.json"].contains(path) &&
        !["history/edits/"].contains(where: path.hasPrefix)
    }
    private static func checkFiles(_ files: [String: String]) throws {
        guard files.count <= maximumFiles,
              WorkspaceIO.requiredFiles.subtracting(["state-manifest.json"]).isSubset(of: Set(files.keys)),
              files.keys.allSatisfy({ retained($0) && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") && !$0.hasSuffix("-journal") }) else {
            throw WorkspaceError.invalid("完整备份业务文件清单无效。")
        }
        for (path, hash) in files {
            // Files outside a committed state's business namespaces can never
            // become live credentials, executable runtime or transport on restore.
            guard path == "banking.sqlite3" || path == "operation-results.json" || path == "upgrade-schema.json" ||
                  ["config/", "review/", "sources/", "inputs/", "history/"].contains(where: path.hasPrefix) else {
                throw WorkspaceError.invalid("完整备份包含未知业务文件：" + path)
            }
            try WorkspaceIO.requireHash(hash)
        }
    }
    private static func validateBusiness(_ root: URL, files: [String: String], workspaceID: String, stateID: String) throws {
        try autoreleasepool {
            try WorkspaceBusinessValidator.validate(root, verifiedFiles: files)
            try ReviewWorkspaceMembership.validate(root: root, ledgerRaw: WorkspaceIO.read(root.appendingPathComponent("operation-results.json")), workspaceID: workspaceID, stateID: stateID)
        }
    }
    private static func copy(files: [String: String], from source: URL, to destination: URL) throws {
        var total: Int64 = 0
        for (path, hash) in files.sorted(by: { $0.key < $1.key }) {
            try autoreleasepool {
                try Task.checkCancellation()
                let input = try WorkspaceIO.safeChild(source, path), output = try WorkspaceIO.safeChild(destination, path)
                let size = try input.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard size.isRegularFile == true, let bytes = size.fileSize, bytes >= 0, Int64(bytes) <= maximumBytes - total else {
                    throw WorkspaceError.invalid("完整备份超过文件大小限制。")
                }
                total += Int64(bytes)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                if clonefile(input.path, output.path, 0) != 0 {
                    let code = errno
                    guard [EXDEV, ENOTSUP, EINVAL, EPERM].contains(code) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
                    try FileManager.default.copyItem(at: input, to: output)
                }
                guard try WorkspaceIO.hash(output) == hash else { throw WorkspaceError.invalid("完整备份文件内容校验失败：" + path) }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                let handle = try FileHandle(forWritingTo: output)
                defer { try? handle.close() }
                try handle.synchronize()
            }
        }
    }
    private static func newDestination(_ destination: URL, separateFrom source: URL) throws -> URL {
        let target = WorkspaceIO.lexicalURL(destination), source = WorkspaceIO.lexicalURL(source)
        try WorkspaceIO.rejectSymlinks(source); try WorkspaceIO.rejectSymlinks(target)
        guard destination.isFileURL, target != source, !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/"),
              !FileManager.default.fileExists(atPath: target.path),
              FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) else {
            throw WorkspaceError.invalid("请选择独立的新目录；已有资料或备份不会被覆盖。")
        }
        return target
    }
    private static func staging(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(".household-backup-" + UUID().uuidString.lowercased())
    }
    private static func publish(_ stage: URL, to target: URL) throws {
        // File contents are already synchronized. Seal each directory once,
        // including empty ancestors, before publishing the complete tree.
        guard let directories = FileManager.default.enumerator(at: stage, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw WorkspaceError.io("backup directory enumeration")
        }
        var nested = [URL]()
        while let file = directories.nextObject() as? URL {
            try Task.checkCancellation()
            if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { nested.append(file) }
        }
        for directory in nested.reversed() { try WorkspaceIO.syncDirectory(directory) }
        try WorkspaceIO.syncDirectory(stage)
        try FileManager.default.moveItem(at: stage, to: target)
        try WorkspaceIO.syncDirectory(target.deletingLastPathComponent())
    }
}
