import Foundation
import Darwin
import CSQLite

/// The lifetime of this token owns the fixed-inode flock. Nested write helpers
/// receive this token instead of attempting to acquire a second lock.
public final class WorkspaceWriteToken: @unchecked Sendable {
    fileprivate let paths: WorkspacePaths
    fileprivate let descriptor: Int32
    fileprivate init(paths: WorkspacePaths, descriptor: Int32) { self.paths = paths; self.descriptor = descriptor }
    deinit { close(descriptor) } // Never LOCK_UN: a child may share this lease.
    public func validate(for paths: WorkspacePaths) throws {
        guard self.paths == paths else { throw WorkspaceError.invalidToken }
        try WorkspaceIO.rejectSymlinks(paths.maintenanceLock)
        var held = stat(), current = stat()
        guard fstat(descriptor, &held) == 0, lstat(paths.maintenanceLock.path, &current) == 0,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino,
              (current.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceError.invalidToken }
    }
    #if os(macOS)
    /// Set Process.standardInput to this handle and
    /// PAYMENT_WORKSPACE_LEASE_FD=0. Python adopts the same open description.
    public func childGuardHandle() throws -> FileHandle {
        try validate(for: paths)
        let child = dup(descriptor)
        guard child >= 0 else { throw WorkspaceError.io("dup maintenance lease") }
        return FileHandle(fileDescriptor: child, closeOnDealloc: true)
    }
    #endif
}

public enum WorkspaceCommitPoint: String, Sendable {
    case snapshotCreated, manifestPrepared, stateInstalled, pointerCommitted, journalCommitted
}
public enum WorkspaceRecoveryDisposition: Equatable, Sendable {
    case committed(StateHandle), uncommitted, needsReview
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.committed(let a), .committed(let b)): return a.pointer == b.pointer
        case (.uncommitted, .uncommitted), (.needsReview, .needsReview): return true
        default: return false
        }
    }
}

public final class WorkspaceCoordinator: Sendable {
    public let paths: WorkspacePaths
    public init(paths: WorkspacePaths) { self.paths = paths }
    public func acquireWriteToken(nonBlocking: Bool = true) throws -> WorkspaceWriteToken {
        try WorkspaceIO.rejectSymlinks(paths.maintenanceLock)
        try FileManager.default.createDirectory(at: paths.maintenanceLock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceIO.rejectSymlinks(paths.maintenanceLock)
        let descriptor = open(paths.maintenanceLock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WorkspaceError.io("maintenance gate open") }
        guard flock(descriptor, LOCK_EX | (nonBlocking ? LOCK_NB : 0)) == 0 else {
            close(descriptor); throw WorkspaceError.busy
        }
        let token = WorkspaceWriteToken(paths: paths, descriptor: descriptor)
        try token.validate(for: paths)
        return token
    }
    /// Adoption is explicit. Verify a live exclusive lease against both the
    /// path inode and an independent flock probe, then retain a duplicate.
    public func adoptWriteToken(descriptor inherited: Int32) throws -> WorkspaceWriteToken {
        try WorkspaceIO.rejectSymlinks(paths.maintenanceLock)
        var held = stat(), current = stat()
        guard fstat(inherited, &held) == 0, lstat(paths.maintenanceLock.path, &current) == 0,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino,
              (held.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceError.invalidToken }
        let probe = open(paths.maintenanceLock.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard probe >= 0 else { throw WorkspaceError.invalidToken }
        defer { close(probe) }
        guard flock(probe, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK,
              flock(inherited, LOCK_EX | LOCK_NB) == 0 else { throw WorkspaceError.invalidToken }
        let copy = dup(inherited)
        guard copy >= 0 else { throw WorkspaceError.io("adopt maintenance lease") }
        return WorkspaceWriteToken(paths: paths, descriptor: copy)
    }
    public func begin(token: WorkspaceWriteToken, expectedPointer: WorkspaceStatePointer,
                      operationID: String = UUID().uuidString.lowercased(),
                      failureInjector: ((WorkspaceCommitPoint) throws -> Void)? = nil) throws -> WorkspaceTransaction {
        try ReviewFamilyHost.requireNoPendingWrite(paths: paths)
        return try beginFamilyHostMetadata(token: token, expectedPointer: expectedPointer, operationID: operationID, failureInjector: failureInjector)
    }
    /// Internal metadata capture only; its owner first validates local family authority.
    internal func beginFamilyHostMetadata(token: WorkspaceWriteToken, expectedPointer: WorkspaceStatePointer,
                      operationID: String = UUID().uuidString.lowercased(),
                      reservedStateID: String? = nil,
                      failureInjector: ((WorkspaceCommitPoint) throws -> Void)? = nil) throws -> WorkspaceTransaction {
        try token.validate(for: paths)
        let active = try paths.readState()
        try WorkspaceCompatibility.requireWriter(paths: paths, state: active)
        guard active.pointer == expectedPointer else { throw WorkspaceError.stalePointer }
        guard active.pointer.localRevision < Int64.max else { throw WorkspaceError.invalid("revision overflow") }
        guard !operationID.isEmpty else { throw WorkspaceError.invalid("operation_id") }
        let stateID = reservedStateID ?? UUID().uuidString.lowercased()
        try WorkspaceIO.requireUUID(stateID, field: "reserved state")
        guard stateID == stateID.lowercased(), stateID != active.pointer.stateID,
              !FileManager.default.fileExists(atPath: try paths.stateRoot(stateID).path) else { throw WorkspaceError.invalid("state already exists") }
        try FileManager.default.createDirectory(at: paths.staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.journals, withIntermediateDirectories: true)
        try WorkspaceIO.syncDirectory(paths.processing)
        try WorkspaceIO.syncDirectory(paths.data)
        let stagingRoot = try WorkspaceIO.safeChild(paths.staging, stateID)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        let transaction = WorkspaceTransaction(paths: paths, previous: active, stateID: stateID, operationID: operationID, root: stagingRoot)
        do {
            try WorkspaceIO.snapshot(from: active.root, to: stagingRoot)
            try transaction.writeJournal(phase: "processing")
            try failureInjector?(.snapshotCreated)
            return transaction
        } catch {
            // Incomplete staging remains an explicitly uncommitted recovery artifact.
            throw error
        }
    }
    /// A journal is diagnostic. Only membership in the currently pointed state
    /// can prove commit; an old journal saying committed never authorizes replay.
    public func recover(operationID: String, membershipValidator: ((Data, StateHandle) throws -> Bool)? = nil) throws -> WorkspaceRecoveryDisposition {
        guard !operationID.isEmpty else { throw WorkspaceError.invalid("operation_id") }
        let active = try paths.readState()
        let raw = try WorkspaceIO.read(active.operationResults)
        try WorkspaceIO.validateLedger(raw, workspaceID: active.pointer.workspaceID, stateID: active.pointer.stateID)
        let ledger = try WorkspaceIO.object(raw)
        
        guard try WorkspaceIO.string(ledger, "state_id") == active.pointer.stateID,
              let results = ledger["results"] as? [[String: Any]] else { throw WorkspaceError.invalid("operation membership ledger") }
        let matching = results.filter { $0["operation_id"] as? String == operationID }
        guard !matching.isEmpty else { return .uncommitted }
        guard matching.count == 1, let result = matching.first,
              result["workspace_id"] as? String == active.pointer.workspaceID,
              result["phase"] as? String == "committed",
              let outcome = result["outcome"] as? String, ["success", "partial"].contains(outcome),
              let digest = result["result_digest"] as? String else { return .needsReview }
        try WorkspaceIO.requireHash(digest)
        // Result state_id records the introducing state, so descendant states
        // retain it unchanged instead of re-identifying historical operations.
        if let validator = membershipValidator, try !validator(raw, active) { return .needsReview }
        return .committed(active)
    }
}

/// The processor's root and output are exactly root and root/review here.
/// Calls are serialized by the owner, and every mutation requires its token.
public final class WorkspaceTransaction {
    public let paths: WorkspacePaths
    public let previous: StateHandle
    public let stateID: String
    public let operationID: String
    public let root: URL
    public var review: URL { root.appendingPathComponent("review", isDirectory: true) }
    public var database: URL { root.appendingPathComponent("banking.sqlite3") }
    private var preparedPointer: WorkspaceStatePointer?
    private var committed = false
    private var abandoned = false
    fileprivate init(paths: WorkspacePaths, previous: StateHandle, stateID: String, operationID: String, root: URL) {
        self.paths = paths; self.previous = previous; self.stateID = stateID; self.operationID = operationID; self.root = root
    }
    public func file(_ relativePath: String, token: WorkspaceWriteToken) throws -> URL {
        try token.validate(for: paths)
        guard preparedPointer == nil, !committed, !abandoned else { throw WorkspaceError.invalid("prepared state cannot be edited") }
        return try WorkspaceIO.safeChild(root, relativePath)
    }
    /// The caller closes all DB/file writers before prepare. Business validators
    /// inspect staging and must throw for missing references or incompatible schemas.
    public func prepare(token: WorkspaceWriteToken, validator: ((URL) throws -> Void)? = nil,
                        failureInjector: ((WorkspaceCommitPoint) throws -> Void)? = nil) throws -> WorkspaceStatePointer {
        try token.validate(for: paths)
        guard preparedPointer == nil, !committed, !abandoned else { throw WorkspaceError.invalid("already prepared") }
        guard try paths.readPointer() == previous.pointer else { throw WorkspaceError.stalePointer }
        try WorkspaceCompatibility.requireWriter(paths: paths, state: previous)
        for relative in try WorkspaceIO.regularFiles(root) {
            if relative.hasSuffix("-wal") || relative.hasSuffix("-shm") || relative.hasSuffix("-journal") { continue }
            let file = try WorkspaceIO.safeChild(root, relative)
            if try WorkspaceIO.isSQLite(file) {
                try WorkspaceIO.sqliteSeal(file)
                try WorkspaceIO.sqliteIntegrity(file)
            }
        }
        try autoreleasepool { try validator?(root) }
        try WorkspaceCompatibility.requireWriter(paths: paths, state: StateHandle(pointer: previous.pointer, root: root))
        let ledgerURL = try WorkspaceIO.safeChild(root, "operation-results.json")
        let sourceLedger = try WorkspaceIO.read(ledgerURL)
        let stateIDBytes = try JSONSerialization.data(withJSONObject: stateID, options: [.fragmentsAllowed])
        let normalizedLedger = try ReleaseCanonicalJSON.replacingObjectMember(raw: sourceLedger, key: "state_id", valueRaw: stateIDBytes)
        try WorkspaceIO.validateLedger(normalizedLedger, workspaceID: previous.pointer.workspaceID, stateID: stateID)
        try ReviewWorkspaceMembership.validate(root: root, ledgerRaw: normalizedLedger,
                                              workspaceID: previous.pointer.workspaceID, stateID: stateID)
        try WorkspaceIO.atomicWrite(normalizedLedger, to: ledgerURL)
        let members = try WorkspaceIO.regularFiles(root)
        guard WorkspaceIO.requiredFiles.isSubset(of: Set(members)), !members.contains(where: { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") }) else { throw WorkspaceError.invalid("staging required closure or open SQLite WAL") }
        let hashes = try WorkspaceIO.validatedMemberHashes(root, members: members)
        let ledgerRaw = try WorkspaceIO.read(try WorkspaceIO.safeChild(root, "operation-results.json"))
        let ledger = try WorkspaceIO.object(ledgerRaw)
        
        guard try WorkspaceIO.string(ledger, "state_id") == stateID, ledger["results"] is [[String: Any]] else { throw WorkspaceError.invalid("staged membership state_id") }
        let revision = previous.pointer.localRevision + 1
        let manifest = try WorkspaceIO.canonical(["workspace_id": previous.pointer.workspaceID,
                                                "state_id": stateID, "local_revision": revision, "files": hashes,
                                                "parent_pointer": previous.pointer.document])
        try WorkspaceIO.atomicWrite(manifest, to: try WorkspaceIO.safeChild(root, "state-manifest.json"))
        let pointer = WorkspaceStatePointer(workspaceID: previous.pointer.workspaceID, stateID: stateID, localRevision: revision, manifestHash: WorkspaceIO.digest(manifest))
        try WorkspaceIO.validateManifest(StateHandle(pointer: pointer, root: root), validateFiles: true)
        try WorkspaceCompatibility.requireWriter(paths: paths, state: previous)
        try WorkspaceCompatibility.requireWriter(paths: paths, state: StateHandle(pointer: pointer, root: root))
        try WorkspaceIO.syncTree(root)
        preparedPointer = pointer
        try writeJournal(phase: "prepared")
        try failureInjector?(.manifestPrepared)
        return pointer
    }
    public func commit(token: WorkspaceWriteToken, failureInjector: ((WorkspaceCommitPoint) throws -> Void)? = nil) throws -> StateHandle {
        try token.validate(for: paths)
        guard let pointer = preparedPointer, !committed, !abandoned else { throw WorkspaceError.invalid("commit requires prepared state") }
        guard try paths.readPointer() == previous.pointer else { throw WorkspaceError.stalePointer }
        try WorkspaceCompatibility.requireWriter(paths: paths, state: previous)
        try WorkspaceCompatibility.requireWriter(paths: paths, state: StateHandle(pointer: pointer, root: root))
        // Catch a writer bypassing the gate even if it failed to advance revision.
        try WorkspaceIO.validateManifest(previous, validateFiles: true)
        try WorkspaceIO.validateManifest(StateHandle(pointer: pointer, root: root), validateFiles: true)
        try FileManager.default.createDirectory(at: paths.states, withIntermediateDirectories: true)
        let destination = try paths.stateRoot(stateID)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw WorkspaceError.invalid("state already exists") }
        guard rename(root.path, destination.path) == 0 else { throw WorkspaceError.io("install state") }
        try WorkspaceIO.syncDirectory(paths.staging)
        try WorkspaceIO.syncDirectory(paths.states)
        try failureInjector?(.stateInstalled)
        try token.validate(for: paths)
        guard try paths.readPointer() == previous.pointer else { throw WorkspaceError.stalePointer }
        try WorkspaceCompatibility.requireWriter(paths: paths, state: StateHandle(pointer: pointer, root: destination))
        do {
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pointer.document), to: paths.activeState)
            committed = true
        } catch {
            // A directory fsync error can occur after rename. Once pointer
            // membership is visible, cancellation must never erase that result.
            if (try? paths.readPointer()) == pointer { committed = true }
            throw error
        }
        try failureInjector?(.pointerCommitted)
        try writeJournal(phase: "committed")
        try failureInjector?(.journalCommitted)
        return StateHandle(pointer: pointer, root: destination, readLease: try WorkspaceReaderLease(directory: paths.device.appendingPathComponent("readers/states"), identity: pointer.stateID))
    }
    public func abandon(token: WorkspaceWriteToken) throws {
        try token.validate(for: paths)
        guard !committed else { throw WorkspaceError.invalid("committed result cannot be cancelled") }
        try writeJournal(phase: "cancelled")
        abandoned = true
    }
    fileprivate func writeJournal(phase: String) throws {
        var document: [String: Any] = ["workspace_id": previous.pointer.workspaceID,
                                      "state_id": stateID, "operation_id": operationID,
                                      "expected_pointer": previous.pointer.document, "phase": phase, "result": NSNull()]
        if let preparedPointer { document["target_pointer"] = preparedPointer.document }
        else { document["target_pointer"] = NSNull() }
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(document), to: WorkspaceIO.safeChild(paths.journals, stateID + ".json"))
    }
}

internal extension WorkspaceIO {
    static func validatedMemberHashes(_ root: URL, members: [String]) throws -> [String: String] {
        var hashes = [String: String]()
        for relative in members where relative != "state-manifest.json" {
            hashes[relative] = try autoreleasepool {
                let member = try safeChild(root, relative)
                if relative.hasSuffix(".json") {
                    let limit = WorkspaceBusinessValidator.documentLimit(relative)
                    _ = try ReleaseCanonicalJSON.canonicalize(raw: read(member, limit: Int64(limit)), inputLimit: limit)
                }
                return try hash(member)
            }
        }
        return hashes
    }
    static func atomicWrite(_ bytes: Data, to destination: URL) throws {
        try rejectSymlinks(destination)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = try safeChild(parent, "." + destination.lastPathComponent + "." + UUID().uuidString + ".tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WorkspaceError.io("atomic temporary file") }
        defer { close(descriptor); unlink(temporary.path) }
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WorkspaceError.io("atomic write") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw WorkspaceError.io("file fsync") }
        guard rename(temporary.path, destination.path) == 0 else { throw WorkspaceError.io("atomic rename") }
        try syncDirectory(parent)
    }
    static func syncDirectory(_ url: URL) throws {
        try rejectSymlinks(url)
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkspaceError.io("directory open") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw WorkspaceError.io("directory fsync") }
    }
    static func regularFiles(_ root: URL) throws -> [String] {
        try rejectSymlinks(root)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else { throw WorkspaceError.io("state enumeration") }
        var files = [String]()
        while let url = enumerator.nextObject() as? URL {
            try rejectSymlinks(url)
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw WorkspaceError.invalid("state symlink") }
            if info.isRegularFile == true { files.append(String(url.path.dropFirst(root.path.count + 1))) }
            else if info.isDirectory != true { throw WorkspaceError.invalid("unsupported state file") }
        }
        return files.sorted()
    }
    static func snapshot(from source: URL, to destination: URL) throws {
        let members = try regularFiles(source)
        var databases = Set<String>()
        for relative in members where try isSQLite(safeChild(source, relative)) { databases.insert(relative) }
        for relative in members {
            guard relative != "state-manifest.json", !databases.contains(where: { relative == $0 + "-wal" || relative == $0 + "-shm" || relative == $0 + "-journal" }) else { continue }
            let input = try safeChild(source, relative), output = try safeChild(destination, relative)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            if databases.contains(relative) {
                try sqliteBackup(from: input, to: output)
                // A backup can inherit WAL mode even though its pages are all
                // in the new main file. Seal before any staging reader opens it.
                try sqliteSeal(output)
            }
            else {
                // clonefile gives an independent inode with copy-on-write blocks.
                // Never hardlink mutable DB/JSON or unknown files. This also avoids
                // duplicating large immutable material blocks on APFS.
                if clonefile(input.path, output.path, 0) != 0 {
                    let readFD = open(input.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard readFD >= 0 else { throw WorkspaceError.io("snapshot input") }
                    defer { close(readFD) }
                    let writeFD = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
                    guard writeFD >= 0 else { throw WorkspaceError.io("snapshot output") }
                    defer { close(writeFD) }
                    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                    while true {
                        let count = Darwin.read(readFD, &buffer, buffer.count)
                        if count < 0 && errno == EINTR { continue }
                        guard count >= 0 else { throw WorkspaceError.io("snapshot read") }
                        if count == 0 { break }
                        try buffer.withUnsafeBytes { bytes in
                            var offset = 0
                            while offset < count {
                                let written = write(writeFD, bytes.baseAddress!.advanced(by: offset), count - offset)
                                if written < 0 && errno == EINTR { continue }
                                guard written > 0 else { throw WorkspaceError.io("snapshot write") }
                                offset += written
                            }
                        }
                    }
                }
                // clonefile can retain a read-only source mode; staging is mutable.
                guard chmod(output.path, S_IRUSR | S_IWUSR) == 0 else { throw WorkspaceError.io("staging permissions") }
            }
        }
    }
    static func isSQLite(_ url: URL) throws -> Bool {
        try rejectSymlinks(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkspaceError.io("SQLite header open") }
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 16)
        let count = Darwin.read(descriptor, &bytes, 16)
        guard count >= 0 else { throw WorkspaceError.io("SQLite header read") }
        return count == 16 && bytes == Array("SQLite format 3\0".utf8)
    }
    static func sqliteBackup(from source: URL, to destination: URL) throws {
        try rejectSymlinks(source); try rejectSymlinks(destination)
        var input: OpaquePointer?, output: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { if let input { sqlite3_close(input) }; throw WorkspaceError.invalid("SQLite source") }
        defer { sqlite3_close(input) }
        guard sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { if let output { sqlite3_close(output) }; throw WorkspaceError.io("SQLite snapshot") }
        defer { sqlite3_close(output) }
        sqlite3_busy_timeout(input, 5_000); sqlite3_busy_timeout(output, 5_000)
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw WorkspaceError.io("SQLite backup init") }
        let status = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finished == SQLITE_OK else { throw WorkspaceError.io("SQLite backup incomplete") }
    }
    static func sqliteSeal(_ url: URL) throws {
        try rejectSymlinks(url)
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { if let database { sqlite3_close(database) }; throw WorkspaceError.invalid("SQLite sealing open") }
        defer { if let database { sqlite3_close(database) } }
        sqlite3_busy_timeout(database, 5_000)
        guard sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK,
              sqlite3_exec(database, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw WorkspaceError.invalid("SQLite writers must close before prepare") }
        var mode: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA journal_mode", -1, &mode, nil) == SQLITE_OK else { throw WorkspaceError.io("SQLite journal mode") }
        let deleted = sqlite3_step(mode) == SQLITE_ROW && sqlite3_column_text(mode, 0).map { String(cString: $0) == "delete" } == true
        sqlite3_finalize(mode)
        guard deleted, sqlite3_close(database) == SQLITE_OK else { throw WorkspaceError.invalid("SQLite writers must close before prepare") }
        database = nil
        // A successful switch away from WAL and a closed connection can leave
        // an orphan SHM file from a read-only snapshot. It carries no rows.
        let wal = URL(fileURLWithPath: url.path + "-wal"), shm = URL(fileURLWithPath: url.path + "-shm")
        if FileManager.default.fileExists(atPath: wal.path) {
            try rejectSymlinks(wal)
            let info = try wal.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, info.fileSize == 0 else { throw WorkspaceError.invalid("SQLite has unsealed WAL pages") }
            try FileManager.default.removeItem(at: wal)
        }
        if FileManager.default.fileExists(atPath: shm.path) {
            try rejectSymlinks(shm)
            guard try shm.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw WorkspaceError.invalid("SQLite SHM type") }
            try FileManager.default.removeItem(at: shm)
        }
    }
    static func sqliteIntegrity(_ url: URL) throws {
        try rejectSymlinks(url)
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { if let database { sqlite3_close(database) }; throw WorkspaceError.invalid("SQLite open") }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else { throw WorkspaceError.invalid("SQLite integrity statement") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0), String(cString: value) == "ok", sqlite3_step(statement) == SQLITE_DONE else { throw WorkspaceError.invalid("SQLite integrity") }
    }
    static func syncTree(_ root: URL) throws {
        var directories = Set([root])
        for relative in try regularFiles(root) {
            let url = try safeChild(root, relative)
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw WorkspaceError.io("state flush open") }
            let result = fsync(descriptor); close(descriptor)
            guard result == 0 else { throw WorkspaceError.io("state file fsync") }
            var parent = url.deletingLastPathComponent()
            while parent.path.hasPrefix(root.path) { directories.insert(parent); if parent == root { break }; parent.deleteLastPathComponent() }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) { try syncDirectory(directory) }
    }
}

internal extension WorkspaceIO {
    static func validateLedger(_ raw: Data, workspaceID: String, stateID: String) throws {
        let ledger = try object(raw)
        
        guard try string(ledger, "state_id") == stateID,
              let results = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["results"]) else { throw WorkspaceError.invalid("operation ledger") }
        var operations = Set<String>(), requests = Set<String>()
        for resultRaw in results {
            let result = try object(resultRaw)
            
            let operationID = try string(result, "operation_id"), requestID = try string(result, "request_id")
            guard operations.insert(operationID).inserted, requests.insert(requestID).inserted,
                  try string(result, "workspace_id") == workspaceID,
                  try string(result, "phase") == "committed",
                  result["result_generation"] is NSNull else { throw WorkspaceError.invalid("result identity or phase") }
            _ = try string(result, "state_id")
            _ = try string(result, "algorithm_version")
            try requireHash(try string(result, "input_hash"))
            let digest = try string(result, "result_digest")
            try requireHash(digest)
            let digestBytes = try ReleaseCanonicalJSON.removingObjectMembers(raw: resultRaw, keys: ["result_digest", "result_generation", "phase"])
            guard self.digest(digestBytes) == digest else { throw WorkspaceError.invalid("business result digest") }
            if let recoveryID = result["recovery_attempt_id"], !(recoveryID is NSNull) { try requireUUID(try string(result, "recovery_attempt_id"), field: "recovery_attempt_id") }
            let outcome = try string(result, "outcome")
            guard ["success", "partial"].contains(outcome),
                  let inputs = try ReleaseCanonicalJSON.canonicalArrayElements(raw: resultRaw, atObjectKeys: ["inputs"]),
                  let effects = result["membership"] as? [[String: Any]], !effects.isEmpty else { throw WorkspaceError.invalid("committed result closure") }
            var inputIDs = Set<String>(), pendingCount = 0
            for inputRaw in inputs {
                let input = try object(inputRaw)
                guard inputIDs.insert(try string(input, "input_id")).inserted,
                      let retained = try ReleaseCanonicalJSON.canonicalFragment(raw: inputRaw, atObjectKeys: ["retained"]), retained == Data("true".utf8),
                      let required = try ReleaseCanonicalJSON.canonicalFragment(raw: inputRaw, atObjectKeys: ["required_financial"]),
                      required == Data("true".utf8) || required == Data("false".utf8),
                      let stages = input["completed_stages"] as? [String], Set(stages).count == stages.count, stages.allSatisfy({ !$0.isEmpty }) else { throw WorkspaceError.invalid("result input") }
                try requireHash(try string(input, "sha256"))
                let kind = try string(input, "kind"), inputOutcome = try string(input, "outcome")
                guard ["pdf", "csv", "xlsx", "video", "review"].contains(kind),
                      ["unknown", "success", "pending", "failed"].contains(inputOutcome) else { throw WorkspaceError.invalid("input kind or outcome") }
                if inputOutcome != "success" {
                    pendingCount += 1
                    guard outcome == "partial", kind == "video", required == Data("false".utf8), inputOutcome == "pending",
                          let reason = input["reason"] as? String, ["unsupported_video_layout", "unconfirmed_video_fields"].contains(reason) else { throw WorkspaceError.invalid("partial input scope") }
                }
            }
            guard outcome == "success" ? pendingCount == 0 : pendingCount > 0 else { throw WorkspaceError.invalid("result outcome inputs") }
            var keys = Set<String>()
            for effect in effects {
                let key = try string(effect, "key"), kind = try string(effect, "kind")
                guard keys.insert(key).inserted, ["record", "revision", "input-stage", "supersedes", "tombstone"].contains(kind) else { throw WorkspaceError.invalid("effect identity") }
                try requireHash(try string(effect, "digest"))
                if let supersedes = effect["supersedes"] {
                    guard let values = supersedes as? [String], Set(values).count == values.count, values.allSatisfy({ !$0.isEmpty }) else { throw WorkspaceError.invalid("effect supersedes") }
                }
            }
        }
    }
}
