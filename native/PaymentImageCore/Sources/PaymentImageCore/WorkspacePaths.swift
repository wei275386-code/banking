import Foundation
import CryptoKit
import Darwin

public enum WorkspaceError: Error, LocalizedError {
    case invalid(String), unsupportedVersion(String), busy, stalePointer, invalidToken, io(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "资料状态校验失败：\(detail)"
        case .unsupportedVersion(let detail): return "资料版本不兼容：\(detail)"
        case .busy: return "另一项资料写入正在进行，请稍后重试。"
        case .stalePointer: return "资料状态已改变，请重新读取后重试。"
        case .invalidToken: return "写入必须持有本资料的 maintenance gate。"
        case .io(let detail): return "资料文件操作失败：\(detail)"
        }
    }
}

/// A pointer is compared as a complete tuple; state ID alone is never a CAS key.
public struct WorkspaceStatePointer: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let stateID: String
    public let localRevision: Int64
    public let manifestHash: String
    public init(workspaceID: String, stateID: String, localRevision: Int64, manifestHash: String) {
        self.workspaceID = workspaceID; self.stateID = stateID
        self.localRevision = localRevision; self.manifestHash = manifestHash
    }
    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", stateID = "state_id"
        case localRevision = "local_revision", manifestHash = "state_manifest_hash"
    }
    internal var document: [String: Any] {
        ["workspace_id": workspaceID, "state_id": stateID,
         "local_revision": localRevision, "state_manifest_hash": manifestHash]
    }
}

/// One read operation resolves one pointer. All of its files remain pinned to
/// this state even when another writer activates a newer state.
public struct StateHandle: Sendable {
    public let pointer: WorkspaceStatePointer
    public let root: URL
    private let readLease: WorkspaceReaderLease?
    internal init(pointer: WorkspaceStatePointer, root: URL, readLease: WorkspaceReaderLease? = nil) {
        self.pointer = pointer; self.root = root; self.readLease = readLease
    }
    public var review: URL { root.appendingPathComponent("review", isDirectory: true) }
    public var config: URL { root.appendingPathComponent("config", isDirectory: true) }
    public var database: URL { root.appendingPathComponent("banking.sqlite3") }
    public var operationResults: URL { root.appendingPathComponent("operation-results.json") }
    public var manifest: URL { root.appendingPathComponent("state-manifest.json") }
    public func file(_ relativePath: String) throws -> URL { try WorkspaceIO.safeChild(root, relativePath) }
}

public struct WorkspacePaths: Sendable, Equatable {
    public let workspace: URL
    public init(workspace: URL) throws {
        guard workspace.isFileURL else { throw WorkspaceError.invalid("workspace URL") }
        self.workspace = WorkspaceIO.lexicalURL(workspace)
        try WorkspaceIO.rejectSymlinks(self.workspace)
    }
    public var metadata: URL { workspace.appendingPathComponent("workspace.json") }
    public var data: URL { workspace.appendingPathComponent("data", isDirectory: true) }
    public var activeState: URL { data.appendingPathComponent("active-state.json") }
    public var states: URL { data.appendingPathComponent("states", isDirectory: true) }
    public var sources: URL { data.appendingPathComponent("sources", isDirectory: true) }
    public var processing: URL { data.appendingPathComponent("processing", isDirectory: true) }
    public var staging: URL { processing.appendingPathComponent("staging", isDirectory: true) }
    public var journals: URL { processing.appendingPathComponent("journals", isDirectory: true) }
    public var history: URL { data.appendingPathComponent("history", isDirectory: true) }
    public var device: URL { workspace.appendingPathComponent("device", isDirectory: true) }
    public var maintenanceLock: URL { device.appendingPathComponent("locks/maintenance.lock") }
    public var recovery: URL { workspace.appendingPathComponent("recovery", isDirectory: true) }

    public func stateRoot(_ stateID: String) throws -> URL {
        try WorkspaceIO.requireUUID(stateID, field: "state_id")
        return try WorkspaceIO.safeChild(states, stateID)
    }
    public func readPointer() throws -> WorkspaceStatePointer {
        let metadataBytes = try WorkspaceIO.read(metadata)
        let metadata = try WorkspaceIO.object(metadataBytes)
        
        
        let workspaceID = try WorkspaceIO.string(metadata, "workspace_id")
        try WorkspaceIO.requireUUID(workspaceID, field: "workspace_id")
        let created = try WorkspaceIO.string(metadata, "created_at")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalDate = formatter.date(from: created)
        formatter.formatOptions = [.withInternetDateTime]
        guard fractionalDate != nil || formatter.date(from: created) != nil else { throw WorkspaceError.invalid("created_at") }
        if let metadataValue = metadata["metadata"], !(metadataValue is [String: Any]) { throw WorkspaceError.invalid("workspace metadata") }
        guard Set(metadata.keys).isSubset(of: ["workspace_id", "created_at", "metadata", "access", "min_reader_version", "min_writer_version"]) else { throw WorkspaceError.invalid("workspace fields") }
        let raw = try WorkspaceIO.read(activeState)
        let document = try WorkspaceIO.object(raw)
        
        let pointerWorkspaceID = try WorkspaceIO.string(document, "workspace_id")
        guard pointerWorkspaceID == workspaceID else { throw WorkspaceError.invalid("workspace pointer identity") }
        let stateID = try WorkspaceIO.string(document, "state_id")
        try WorkspaceIO.requireUUID(stateID, field: "state_id")
        guard stateID == stateID.lowercased() else { throw WorkspaceError.invalid("state_id must be normalized") }
        let revision = try WorkspaceIO.integer(raw, field: "local_revision")
        let hash = try WorkspaceIO.string(document, "state_manifest_hash")
        try WorkspaceIO.requireHash(hash)
        return WorkspaceStatePointer(workspaceID: workspaceID, stateID: stateID, localRevision: revision, manifestHash: hash)
    }
    public func readState(validateFiles: Bool = true) throws -> StateHandle {
        let pointer = try readPointer()
        let handle = StateHandle(pointer: pointer, root: try stateRoot(pointer.stateID), readLease: try WorkspaceReaderLease(directory: device.appendingPathComponent("readers/states"), identity: pointer.stateID))
        try WorkspaceIO.validateManifest(handle, validateFiles: validateFiles)
        if validateFiles {
            try ReviewWorkspaceMembership.validate(root: handle.root, ledgerRaw: WorkspaceIO.read(handle.operationResults),
                                                  workspaceID: pointer.workspaceID, stateID: pointer.stateID)
        }
        return handle
    }
    /// Explicit restored viewing-copy policy. This never weakens manifest or
    /// all-file hash validation, and the returned handle is not a write grant.
    public func readViewingState() throws -> StateHandle {
        let pointer = try readPointer()
        let handle = StateHandle(pointer: pointer, root: try stateRoot(pointer.stateID), readLease: try WorkspaceReaderLease(directory: device.appendingPathComponent("readers/states"), identity: pointer.stateID))
        try WorkspaceIO.validateManifest(handle, validateFiles: true)
        let compatibility = try WorkspaceCompatibility.decision(paths: self, state: handle)
        guard compatibility.readable else { throw WorkspaceError.unsupportedVersion(compatibility.reasons.joined(separator: "; ")) }
        try ReviewWorkspaceMembership.validate(root: handle.root, ledgerRaw: WorkspaceIO.read(handle.operationResults),
                                              workspaceID: pointer.workspaceID, stateID: pointer.stateID)
        return handle
    }
}

internal enum WorkspaceIO {
    /// Foundation standardization can turn a physical OS base into its symlink. Keep
    /// lexical normalization separate from symlink checks and filesystem lookup.
    static func lexicalURL(_ url: URL) -> URL {
        var components = [String]()
        for component in url.path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(String(component))
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"))
    }
    static let requiredFiles = Set(["banking.sqlite3", "config/review-import-sources.json", "review/financial-review.json", "review/payment-evidence.json", "review/coverage.json", "operation-results.json"])
    static func requireUUID(_ value: String, field: String) throws {
        guard value.count == 36, UUID(uuidString: value) != nil else { throw WorkspaceError.invalid(field + " UUID") }
    }
    static func requireHash(_ value: String) throws {
        guard value.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw WorkspaceError.invalid("SHA-256") }
    }
    static func safeChild(_ root: URL, _ path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") && !$0.contains(":") }) else { throw WorkspaceError.invalid("relative path") }
        let result = URL(fileURLWithPath: root.path + "/" + path)
        guard result.path.hasPrefix(root.path + "/") else { throw WorkspaceError.invalid("path escape") }
        try rejectSymlinks(result)
        return result
    }
    static func rejectSymlinks(_ url: URL) throws {
        var current = ""
        for component in url.pathComponents.dropFirst() {
            current += "/" + component
            var info = stat()
            if lstat(current, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else { throw WorkspaceError.invalid("symlink: " + current) }
            } else if errno != ENOENT { throw WorkspaceError.io("lstat " + current) }
        }
    }
    private static func regularHandle(_ url: URL) throws -> (FileHandle, Int64) {
        try rejectSymlinks(url)
        // A provider can replace a checked path with a FIFO before open. Open
        // nonblocking, then validate the descriptor itself before any read.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno; close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            close(descriptor); throw WorkspaceError.invalid("regular file required: " + url.lastPathComponent)
        }
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), Int64(info.st_size))
    }
    static func read(_ url: URL, limit: Int64 = 16 * 1024 * 1024) throws -> Data {
        guard limit >= 0, limit < Int64(Int.max) else { throw WorkspaceError.invalid("read limit") }
        let (handle, size) = try regularHandle(url)
        defer { try? handle.close() }
        guard size <= limit else { throw WorkspaceError.invalid("file exceeds read limit: \(url.lastPathComponent) (\(size) > \(limit))") }
        var result = Data()
        while let chunk = try handle.read(upToCount: Int(min(1024 * 1024, limit - Int64(result.count) + 1))), !chunk.isEmpty {
            guard Int64(result.count) + Int64(chunk.count) <= limit else { throw WorkspaceError.invalid("file exceeds read limit: \(url.lastPathComponent)") }
            result.append(chunk)
        }
        return result
    }
    static func object(_ raw: Data) throws -> [String: Any] {
        try object(raw, inputLimit: ReleaseCanonicalJSON.maximumInputBytes)
    }
    static func object(_ raw: Data, inputLimit: Int) throws -> [String: Any] {
        _ = try ReleaseCanonicalJSON.canonicalize(raw: raw, inputLimit: inputLimit)
        guard let result = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw WorkspaceError.invalid("JSON object") }
        return result
    }
    static func string(_ document: [String: Any], _ field: String) throws -> String {
        guard let value = document[field] as? String, !value.isEmpty else { throw WorkspaceError.invalid(field) }
        return value
    }
    static func integer(_ raw: Data, field: String) throws -> Int64 {
        guard let fragment = try ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: [field]),
              let token = String(data: fragment, encoding: .utf8),
              !token.isEmpty, token.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(token), value >= 0 else { throw WorkspaceError.invalid(field + " integer") }
        return value
    }
    static func canonical(_ document: [String: Any]) throws -> Data {
        try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
    static func hash(_ url: URL) throws -> String {
        try autoreleasepool { try streamingHash(url) }
    }
    private static func streamingHash(_ url: URL) throws -> String {
        let (handle, _) = try regularHandle(url)
        defer { try? handle.close() }
        var hash = SHA256()
        // FileHandle bridges through autoreleased NSData on Darwin. A CLI's
        // synchronous maintenance task has no run-loop pool drain between files.
        while try autoreleasepool(invoking: {
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { return false }
            hash.update(data: chunk)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validateManifest(_ handle: StateHandle, validateFiles: Bool) throws {
        let raw = try read(handle.manifest)
        _ = try ReleaseCanonicalJSON.canonicalize(raw: raw)
        guard digest(raw) == handle.pointer.manifestHash else { throw WorkspaceError.invalid("manifest hash") }
        let document = try object(raw)
        
        guard try string(document, "workspace_id") == handle.pointer.workspaceID,
              try string(document, "state_id") == handle.pointer.stateID,
              try integer(raw, field: "local_revision") == handle.pointer.localRevision,
              let files = document["files"] as? [String: String], requiredFiles.isSubset(of: Set(files.keys)) else { throw WorkspaceError.invalid("manifest tuple or closure") }
        let actual = Set(try regularFiles(handle.root))
        guard actual == Set(files.keys).union(["state-manifest.json"]) else {
            throw WorkspaceError.invalid("unlisted or missing state files")
        }
        for (relative, expected) in files {
            try requireHash(expected)
            let url = try handle.file(relative)
            guard relative != "state-manifest.json", !relative.hasSuffix("-wal"), !relative.hasSuffix("-shm") else { throw WorkspaceError.invalid("manifest member") }
            if validateFiles, try hash(url) != expected { throw WorkspaceError.invalid("file hash: " + relative) }
        }
    }
}
