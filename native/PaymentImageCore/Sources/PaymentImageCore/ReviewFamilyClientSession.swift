import Foundation
import Darwin

public struct ReviewFamilyClientConnection: Sendable {
    public let selection: ReviewFamilyBindingSelection, remote: URL, bookmark: Data?
    public let requiresReconnection: Bool
    fileprivate init(selection: ReviewFamilyBindingSelection, remote: URL, bookmark: Data?, requiresReconnection: Bool = false) {
        self.selection = selection; self.remote = remote; self.bookmark = bookmark; self.requiresReconnection = requiresReconnection
    }
}
/// A selected reader/projection, never a StateHandle or host/processor grant.
public struct ReviewFamilyClientHandle: Sendable {
    public let selection: ReviewFamilyBindingSelection, checkpoint: ReviewCachedFamilySnapshot, review: URL
    public let settings: HouseholdSettings, sources: [HouseholdRegisteredSource], conflicts: [String: [String]]
    public let version: String
    private let readLease: WorkspaceReaderLease
    internal let queue: [ReviewRevisionOrigin], fields: ReviewSettingsCausalCheckpoint
    fileprivate init(readLease: WorkspaceReaderLease, selection: ReviewFamilyBindingSelection, checkpoint: ReviewCachedFamilySnapshot, review: URL,
                     sources: [HouseholdRegisteredSource], version: String, queue: [ReviewRevisionOrigin], fields: ReviewSettingsCausalCheckpoint) {
        self.selection = selection; self.checkpoint = checkpoint; self.review = review; self.sources = sources
        self.readLease = readLease; self.version = version; self.queue = queue; self.fields = fields; self.settings = fields.settings
        self.conflicts = fields.causal.heads.filter { Set($0.value.map { Data($0.value.utf8) }).count > 1 }.mapValues { $0.map(\.value) }
    }
}

public struct ReviewFamilyPreparedClientRefresh: Sendable {
    fileprivate let paths: WorkspacePaths, connection: ReviewFamilyClientConnection, checkpoint: ReviewCachedFamilySnapshot
    fileprivate let root: URL, queue: [ReviewRevisionOrigin], expected: String?
    fileprivate let readLease: WorkspaceReaderLease
}
public enum ReviewFamilyClientRefreshPreparation: Sendable {
    case current(ReviewFamilyClientHandle)
    case waiting
    case ready(ReviewFamilyPreparedClientRefresh)
}

public struct ReviewFamilyClientSettingsPlan: Sendable {
    public let candidate: HouseholdSettings
    fileprivate let handle: ReviewFamilyClientHandle
    fileprivate init(candidate: HouseholdSettings, handle: ReviewFamilyClientHandle) { self.candidate = candidate; self.handle = handle }
}

/// Native/new-family family client only. The explicit local descriptor selects the
/// household; a verified cache alone never creates an active view or host grant.
/// Queue inventory and immutable derived view commit together in one pointer.
public enum ReviewFamilyClientSession {
    private static let mutable: Set<String> = ["review-overrides.json", "fire-parameters-user.json", "completion-workflow.json", "category-catalog.json", "family-profile.json", "account-policies.json"]
    public static func requestTransport(paths: WorkspacePaths, expected: ReviewFamilyClientHandle) throws -> ReviewFamilyRequestTransport {
        guard let current = try read(paths: paths), current.selection == expected.selection, current.version == expected.version,
              let connection = try readConnection(paths: paths) else { throw WorkspaceError.stalePointer }
        return try ReviewFamilyRequestTransport(remote: connection.requiresReconnection ? nil : connection.remote,
            cache: paths.device.appendingPathComponent("family-requests/" + current.selection.bindingID), selection: current.selection, readerPaths: paths)
    }
    public static func requestDeviceID(paths: WorkspacePaths) throws -> String {
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        return try ReviewDeviceIdentity.readOrCreate(paths: paths, token: token)
    }
    private static func descriptor(_ paths: WorkspacePaths) -> URL { paths.device.appendingPathComponent("family-connection.json") }
    private static func active(_ paths: WorkspacePaths) -> URL { paths.device.appendingPathComponent("client-active.json") }
    private static func store(_ paths: WorkspacePaths, _ connection: ReviewFamilyClientConnection) throws -> ReviewFamilySnapshotStore {
        try .init(remote: connection.remote, local: paths.device.appendingPathComponent("family-sync/client"), selection: connection.selection)
    }
    private static func queueRoot(_ paths: WorkspacePaths, _ selection: ReviewFamilyBindingSelection) -> URL { paths.device.appendingPathComponent("client-edits/" + selection.bindingID) }
    public static func connect(paths: WorkspacePaths, remote: URL, bookmark: Data?) throws -> ReviewFamilyClientConnection {
        guard remote.isFileURL else { throw WorkspaceError.invalid("native family provider must be a file URL") }
        let raw = try ReviewSyncIO.read(remote.appendingPathComponent("family.json"), limit: 4096)
        let selection = try parseSelection(raw)
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        try token.validate(for: paths); try requireClientContainer(paths)
        if let prior = try readConnection(paths: paths) { guard prior.selection == selection else { throw WorkspaceError.invalid("更换旧家庭需完成独立升级/selection 验证。") } }
        let device = try ReviewDeviceIdentity.readOrCreate(paths: paths, token: token)
        let identity = paths.device.appendingPathComponent("client-identity.json")
        if FileManager.default.fileExists(atPath: identity.path) {
            let bytes = try WorkspaceIO.read(identity), row = try WorkspaceIO.object(bytes); try selection.validate(marker: bytes)
            guard row["device_id"] as? String == device, row["role"] as? String == "client" else { throw WorkspaceError.invalid("client installation identity changed") }
        } else {
            var row = selection.document; row["device_id"] = device; row["role"] = "client"
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(row), to: identity)
        }
        var row = selection.document; row["role"] = "client"; row["purpose"] = "native-new-family"
        row["remote_path"] = WorkspaceIO.lexicalURL(remote).path; row["bookmark"] = bookmark?.base64EncodedString() as Any? ?? NSNull()
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(row), to: descriptor(paths))
        return .init(selection: selection, remote: WorkspaceIO.lexicalURL(remote), bookmark: bookmark)
    }
    public static func readConnection(paths: WorkspacePaths) throws -> ReviewFamilyClientConnection? {
        guard FileManager.default.fileExists(atPath: descriptor(paths).path) else { return nil }
        try requireClientContainer(paths)
        let raw = try WorkspaceIO.read(descriptor(paths)), row = try WorkspaceIO.object(raw); 
        guard row["role"] as? String == "client", row["purpose"] as? String == "native-new-family" else { throw WorkspaceError.invalid("not a native family client descriptor") }
        let selection = try parseSelection(raw), path = try WorkspaceIO.string(row, "remote_path")
        guard path.hasPrefix("/"), row["bookmark"] is NSNull || row["bookmark"] is String else { throw WorkspaceError.invalid("client location") }
        let encoded = row["bookmark"] as? String
        guard encoded == nil || Data(base64Encoded: encoded!) != nil else { throw WorkspaceError.invalid("client bookmark") }
        let identity = try WorkspaceIO.read(paths.device.appendingPathComponent("client-identity.json"))
        let deviceRaw = try WorkspaceIO.read(paths.device.appendingPathComponent("device-identity.json")), device = try WorkspaceIO.object(deviceRaw)
        guard Set(device.keys) == ["device_id"] else { throw WorkspaceError.invalid("device identity fields") }
        try selection.validate(marker: identity)
        let local = try WorkspaceIO.object(identity)
        let installation = try WorkspaceIO.string(device, "device_id"); try WorkspaceIO.requireUUID(installation, field: "client installation")
        guard local["role"] as? String == "client", local["device_id"] as? String == installation else { throw WorkspaceError.invalid("client device mismatch") }
        guard row["requires_reconnection"] == nil || row["requires_reconnection"] is Bool else { throw WorkspaceError.invalid("client reconnect state") }
        return .init(selection: selection, remote: WorkspaceIO.lexicalURL(URL(fileURLWithPath: path)), bookmark: encoded.flatMap { Data(base64Encoded: $0) }, requiresReconnection: row["requires_reconnection"] as? Bool ?? false)
    }
    public static func read(paths: WorkspacePaths) throws -> ReviewFamilyClientHandle? {
        guard let connection = try readConnection(paths: paths) else {
            guard !FileManager.default.fileExists(atPath: active(paths).path) else { throw WorkspaceError.invalid("active family view has no local selection") }; return nil
        }
        guard FileManager.default.fileExists(atPath: active(paths).path) else { return nil }
        let raw = try WorkspaceIO.read(active(paths)), row = try WorkspaceIO.object(raw); try connection.selection.validate(marker: raw)
        
        guard row["purpose"] as? String == "native-new-family-client" else { throw WorkspaceError.invalid("client pointer purpose") }
        let generation = try WorkspaceIO.string(row, "generation"), sequence = try WorkspaceIO.integer(raw, field: "sequence")
        let checkpoint = try store(paths, connection).readNewFamily(generation: generation, sequence: sequence)
        let root = try viewPath(paths, WorkspaceIO.string(row, "view_path"))
        let readLease = try WorkspaceReaderLease(directory: paths.device.appendingPathComponent("readers/views"), identity: root.lastPathComponent)
        let metadataHash = try WorkspaceIO.string(row, "view_hash"), metadata = try WorkspaceIO.read(root.appendingPathComponent("client-view.json"))
        try WorkspaceIO.requireHash(metadataHash)
        guard WorkspaceIO.digest(metadata) == metadataHash else { throw WorkspaceError.invalid("client view manifest changed") }
        let meta = try WorkspaceIO.object(metadata); 
        guard meta["purpose"] as? String == "native-family-projection", meta["generation"] as? String == generation,
              let files = meta["files"] as? [String: String], Set(files.keys) == Set(try WorkspaceIO.regularFiles(root)).subtracting(["client-view.json"]) else { throw WorkspaceError.invalid("client view file closure") }
        for (path, hash) in files { guard try WorkspaceIO.hash(WorkspaceIO.safeChild(root, path)) == hash else { throw WorkspaceError.invalid("client view file changed") } }
        let queueHash = try WorkspaceIO.string(row, "queue_hash"), queue = try loadQueue(paths, connection.selection, queueHash)
        let fields = try replay(checkpoint: checkpoint, queue: queue, selection: connection.selection)
        try validateView(root, checkpoint: checkpoint, fields: fields)
        return .init(readLease: readLease, selection: connection.selection, checkpoint: checkpoint, review: root, sources: try sources(checkpoint),
            version: WorkspaceIO.digest(raw), queue: queue, fields: fields)
    }
    /// Network/cache/projection preparation is off the maintenance gate. The CAS
    /// below rejects a save or another selection made during that preparation.
    public static func refresh(paths: WorkspacePaths) throws -> ReviewFamilyClientHandle? {
        switch try prepareRefresh(paths: paths) {
        case .current: return try read(paths: paths)
        case .waiting: return try read(paths: paths)
        case .ready(let prepared): return try commitRefresh(paths: paths, prepared: prepared)
        }
    }
    public static func prepareRefresh(paths: WorkspacePaths) throws -> ReviewFamilyClientRefreshPreparation {
        guard let connection = try readConnection(paths: paths) else { throw WorkspaceError.invalid("请先明确选择家庭同步目录。") }
        guard !connection.requiresReconnection else { throw WorkspaceError.invalid("恢复的家庭副本需先重新选择原同步目录。") }
        let previous = try read(paths: paths), expected = try pointerVersion(paths)
        let checkpoint: ReviewCachedFamilySnapshot
        switch try store(paths, connection).prepareNewFamily() {
        case .ready(let value), .unchanged(let value): checkpoint = value
        case .waiting: return .waiting
        case .conflicted: throw WorkspaceError.invalid("家庭设置存在并发修改，保留原 view 等待核对。")
        }
        if let previous, previous.checkpoint.generation == checkpoint.generation { return .current(previous) }
        let queue = previous?.queue ?? [], fields = try replay(checkpoint: checkpoint, queue: queue, selection: connection.selection)
        let (root, readLease) = try projection(paths: paths, checkpoint: checkpoint, fields: fields)
        return .ready(.init(paths: paths, connection: connection, checkpoint: checkpoint, root: root, queue: queue, expected: expected, readLease: readLease))
    }
    public static func commitRefresh(paths: WorkspacePaths, prepared: ReviewFamilyPreparedClientRefresh) throws -> ReviewFamilyClientHandle {
        guard paths == prepared.paths else { throw WorkspaceError.stalePointer }
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        try validateView(prepared.root, checkpoint: prepared.checkpoint, fields: replay(checkpoint: prepared.checkpoint, queue: prepared.queue, selection: prepared.connection.selection))
        return try commit(paths: paths, connection: prepared.connection, checkpoint: prepared.checkpoint, root: prepared.root, queue: prepared.queue, expected: prepared.expected, token: token)
    }
    /// All local field editors use a private scratch view. Only supported saved
    /// fields become a real revision; original reports/assets are immutable.
    public static func edit<T>(paths: WorkspacePaths, expected: ReviewFamilyClientHandle,
                               body: (URL, URL) throws -> T) throws -> (T, ReviewFamilyClientHandle) {
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        guard let current = try read(paths: paths), current.version == expected.version, current.review == expected.review,
              let connection = try readConnection(paths: paths) else { throw WorkspaceError.stalePointer }
        let scratch = paths.device.appendingPathComponent("client-views/" + UUID().uuidString.lowercased())
        for path in try WorkspaceIO.regularFiles(current.review) {
            let source = try WorkspaceIO.safeChild(current.review, path), target = try WorkspaceIO.safeChild(scratch, path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if clonefile(source.path, target.path, 0) != 0 { try FileManager.default.copyItem(at: source, to: target) }
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let value = try body(scratch, scratch)
        for (path, file) in current.checkpoint.payload.resolved where !mutable.contains(path) && path != "financial-review.sqlite3" {
            guard try WorkspaceIO.hash(WorkspaceIO.safeChild(scratch, path)) == WorkspaceIO.hash(file) else { throw WorkspaceError.invalid("客户端不能修改原始报告或证据。") }
        }
        let context = try context(current.checkpoint, retaining: current.settings)
        let candidate = try HouseholdSettings(profileData: WorkspaceIO.read(scratch.appendingPathComponent("family-profile.json")),
            policiesData: WorkspaceIO.read(scratch.appendingPathComponent("account-policies.json")), context: context)
        var saved = try ReviewFieldDocuments.capture(review: scratch)
        for (key, value) in ReviewSettingsFieldDocuments.values(candidate) { saved[key] = value }
        var values = [String: String]()
        for key in Set(saved.keys).union(current.fields.causal.values.keys) where saved[key] != current.fields.causal.values[key] {
            values[key] = saved[key] ?? "null"
        }
        if values.isEmpty { return (value, current) }
        let updated = try append(paths: paths, current: current, connection: connection, values: values, expectedValues: saved, token: token)
        return (value, updated)
    }
    private static func append(paths: WorkspacePaths, current: ReviewFamilyClientHandle, connection: ReviewFamilyClientConnection,
                               values: [String: String], expectedValues: [String: String]? = nil, token: WorkspaceWriteToken) throws -> ReviewFamilyClientHandle {
        let device = try ReviewDeviceIdentity.readOrCreate(paths: paths, token: token), clockFile = paths.device.appendingPathComponent("revision-clock-family.json")
        var clock = current.fields.causal.revisions.map { $0.revision.clock }.max() ?? 0
        if FileManager.default.fileExists(atPath: clockFile.path) {
            let raw = try WorkspaceIO.read(clockFile), row = try WorkspaceIO.object(raw)
            guard row["device_id"] as? String == device else { throw WorkspaceError.invalid("client author clock device") }
            let reserved = try WorkspaceIO.integer(raw, field: "reserved_clock")
            guard reserved >= 0, reserved < Int64(Int.max) else { throw WorkspaceError.invalid("client author clock exhausted") }; clock = max(clock, Int(reserved))
        }
        guard clock < Int.max else { throw WorkspaceError.invalid("client author clock exhausted") }; clock += 1
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["device_id": device, "reserved_clock": clock]), to: clockFile)
        let raw = try JSONEncoder().encode(ReviewRevision(id: UUID().uuidString.lowercased(), device: device, clock: clock,
            values: values, bases: values.keys.reduce(into: [String: String]()) { $0[$1] = current.fields.causal.values[$1] ?? "null" }, observed: current.fields.causal.observed, parents: current.fields.causal.frontier))
        let origin = try ReviewRevisionOrigin(sourceBindingID: current.selection.bindingID, sources: [raw])
        let queue = current.queue + [origin], fields = try replay(checkpoint: current.checkpoint, queue: queue, selection: current.selection)
        if let expectedValues { guard fields.causal.values == expectedValues else { throw WorkspaceError.invalid("client saved fields differ from full replay") } }
        let (root, readLease) = try projection(paths: paths, checkpoint: current.checkpoint, fields: fields)
        defer { withExtendedLifetime(readLease) {} }
        return try commit(paths: paths, connection: connection, checkpoint: current.checkpoint, root: root, queue: queue, expected: current.version, token: token)
    }
    /// Even choosing the currently displayed winner must create a new origin
    /// observing every shown head; an unchanged-value edit would be a no-op.
    public static func resolveConflicts(paths: WorkspacePaths, expected: ReviewFamilyClientHandle, choices: [String: String]) throws -> ReviewFamilyClientHandle {
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        guard let current = try read(paths: paths), current.version == expected.version, current.review == expected.review,
              let connection = try readConnection(paths: paths), !choices.isEmpty,
              Set(choices.keys).isSubset(of: Set(current.conflicts.keys)),
              choices.allSatisfy({ key, value in current.conflicts[key]?.contains(where: { Data($0.utf8) == Data(value.utf8) }) == true }) else { throw WorkspaceError.stalePointer }
        return try append(paths: paths, current: current, connection: connection, values: choices, token: token)
    }
    public static func prepareSettings(paths: WorkspacePaths, expected: ReviewFamilyClientHandle, profileData: Data, policiesData: Data) throws -> ReviewFamilyClientSettingsPlan {
        guard let current = try read(paths: paths), current.version == expected.version else { throw WorkspaceError.stalePointer }
        return try .init(candidate: HouseholdSettings(profileData: profileData, policiesData: policiesData,
            context: context(current.checkpoint, retaining: current.settings)), handle: current)
    }
    public static func previewSettings(paths: WorkspacePaths, plan: ReviewFamilyClientSettingsPlan) throws -> HouseholdSettingsImpact {
        guard let current = try read(paths: paths), current.version == plan.handle.version else { throw WorkspaceError.stalePointer }
        return try HouseholdSettingsState.previewImpact(settings: current.settings, candidate: plan.candidate, sources: current.sources,
            evidenceRaw: WorkspaceIO.read(current.review.appendingPathComponent("payment-evidence.json"), limit: Int64(WorkspaceBusinessValidator.maximumProjectionBytes)))
    }
    public static func saveSettings(paths: WorkspacePaths, plan: ReviewFamilyClientSettingsPlan) throws -> ReviewFamilyClientHandle {
        let (_, handle) = try edit(paths: paths, expected: plan.handle) { root, _ in
            try WorkspaceIO.atomicWrite(plan.candidate.profileData, to: root.appendingPathComponent("family-profile.json"))
            try WorkspaceIO.atomicWrite(plan.candidate.policiesData, to: root.appendingPathComponent("account-policies.json"))
        }
        return handle
    }
    /// A native client selection backup, separate from standard Host packages.
    /// No credentials, provider path, host grant or installation identity is copied.
    internal static func exportCheckpointBackup(checkpoint: ReviewCachedFamilySnapshot, cache: ReviewFamilySnapshotStore, destination: URL) throws {
        // A disposable client projection gives Host snapshots the same closed,
        // client-only restore format. No provider is consulted or selected here.
        let target = try backupDestination(destination, separateFrom: cache.local)
        let stage = target.deletingLastPathComponent().appendingPathComponent(".host-backup-projection-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: stage) }
        let paths = try WorkspacePaths(workspace: stage)
        let connection = ReviewFamilyClientConnection(selection: cache.selection, remote: stage.appendingPathComponent("offline-provider"), bookmark: nil, requiresReconnection: true)
        let targetCache = try store(paths, connection)
        let files = try cache.selectedBackupFiles(generation: checkpoint.generation, sequence: checkpoint.sequence)
        guard files.count <= 100_000 else { throw WorkspaceError.invalid("checkpoint backup file count") }
        var total: Int64 = 0
        for (name, file) in files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let size = try ReviewVerifiedFilePin.read(file).size
            guard size >= 0, size <= backupByteLimit - total else { throw WorkspaceError.invalid("checkpoint backup byte limit") }; total += size
            try ReviewContentObjectIO.copy(file, to: WorkspaceIO.safeChild(targetCache.local, name), hash: file.lastPathComponent, maximumBytes: size)
        }
        do {
            let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
            let device = try ReviewDeviceIdentity.readOrCreate(paths: paths, token: token)
            var identity = cache.selection.document; identity["device_id"] = device; identity["role"] = "client"
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(identity), to: paths.device.appendingPathComponent("client-identity.json"))
            var row = cache.selection.document; row["role"] = "client"; row["purpose"] = "native-new-family"
            row["remote_path"] = connection.remote.path; row["bookmark"] = NSNull(); row["requires_reconnection"] = true
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(row), to: descriptor(paths))
            let verified = try targetCache.readNewFamily(generation: checkpoint.generation, sequence: checkpoint.sequence)
            let (root, readLease) = try projection(paths: paths, checkpoint: verified, fields: verified.payload.fields)
            defer { withExtendedLifetime(readLease) {} }
            _ = try commit(paths: paths, connection: connection, checkpoint: verified, root: root, queue: [], expected: nil, token: token)
        }
        try exportSelectedBackup(paths: paths, destination: target)
    }
    public static func exportSelectedBackup(paths: WorkspacePaths, destination: URL) throws {
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        try token.validate(for: paths)
        guard let handle = try read(paths: paths), let connection = try readConnection(paths: paths) else { throw WorkspaceError.invalid("no selected client to back up") }
        let target = try backupDestination(destination, separateFrom: paths.workspace)
        try ReviewFamilyRequestTransport.withOutboxLock(paths.device.appendingPathComponent("family-requests/" + handle.selection.bindingID)) {
        let files = try selectedBackupFiles(paths: paths, handle: handle, connection: connection)
        let stage = target.deletingLastPathComponent().appendingPathComponent(".client-backup-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: stage) }
        var hashes = [String: String](), total: Int64 = 0
        for (name, file) in files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let size = try ReviewVerifiedFilePin.read(file).size
            guard size >= 0, size <= backupByteLimit - total else { throw WorkspaceError.invalid("client backup byte limit") }; total += size
            let hash = try ReviewContentObjectIO.hash(file, maximumBytes: size)
            try ReviewContentObjectIO.copy(file, to: WorkspaceIO.safeChild(stage.appendingPathComponent("payload"), name), hash: hash, maximumBytes: size)
            hashes[name] = hash
        }
        guard try read(paths: paths)?.version == handle.version else { throw WorkspaceError.stalePointer }
        var document = handle.selection.document
        document["purpose"] = "native-family-client-backup"
        document["generation"] = handle.checkpoint.generation; document["sequence"] = handle.checkpoint.sequence
        document["active_hash"] = handle.version; document["files"] = hashes
        document["source_device_id"] = try ReviewDeviceIdentity.readOrCreate(paths: paths, token: token)
        let raw = try WorkspaceIO.canonical(document)
        guard raw.count <= 16 * 1024 * 1024 else { throw WorkspaceError.invalid("client backup manifest limit") }
        try WorkspaceIO.atomicWrite(raw, to: stage.appendingPathComponent("manifest.json"))
        try WorkspaceIO.atomicWrite(Data((WorkspaceIO.digest(raw) + "\n").utf8), to: stage.appendingPathComponent("manifest.sha256"))
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: target)
        try WorkspaceIO.syncDirectory(target.deletingLastPathComponent())
        }
    }
    /// Restores into a new, offline client container with a fresh installation.
    /// Reconnection is a separate explicit connect() call; restoring never uploads.
    public static func restoreSelectedBackup(package: URL, destination: URL) throws -> ReviewFamilyClientHandle {
        let source = WorkspaceIO.lexicalURL(package); try WorkspaceIO.rejectSymlinks(source)
        let target = try backupDestination(destination, separateFrom: source)
        let raw = try ReviewSyncIO.read(source.appendingPathComponent("manifest.json"), limit: 16 * 1024 * 1024)
        guard try ReviewSyncIO.read(source.appendingPathComponent("manifest.sha256"), limit: 65) == Data((WorkspaceIO.digest(raw) + "\n").utf8),
              try ReleaseCanonicalJSON.canonicalize(raw: raw) == raw else { throw WorkspaceError.invalid("client backup manifest hash") }
        let row = try WorkspaceIO.object(raw); 
        let selection = try parseSelection(raw)
        guard row["purpose"] as? String == "native-family-client-backup", let files = row["files"] as? [String: String],
              !files.isEmpty, files.count <= 100_000,
              files["device/client-active.json"] == row["active_hash"] as? String else { throw WorkspaceError.invalid("client backup manifest") }
        let sourceDevice = try WorkspaceIO.string(row, "source_device_id"); try WorkspaceIO.requireUUID(sourceDevice, field: "backup source device")
        let actual = Set(try WorkspaceIO.regularFiles(source))
        guard actual == Set(files.keys.map { "payload/" + $0 }).union(["manifest.json", "manifest.sha256"]) else { throw WorkspaceError.invalid("client backup file closure") }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".client-restore-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: stage) }
        let paths = try WorkspacePaths(workspace: stage)
        var total: Int64 = 0
        for (name, hash) in files.sorted(by: { $0.key < $1.key }) {
            guard backupPath(name, selection: selection) else { throw WorkspaceError.invalid("unexpected client backup path") }
            let file = try WorkspaceIO.safeChild(source.appendingPathComponent("payload"), name)
            let size = try ReviewVerifiedFilePin.read(file).size
            guard size >= 0, size <= backupByteLimit - total else { throw WorkspaceError.invalid("client backup byte limit") }; total += size
            try ReviewContentObjectIO.copy(file, to: WorkspaceIO.safeChild(stage, name), hash: hash, maximumBytes: size)
        }
        do {
            let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
            let device = try ReviewDeviceIdentity.readOrCreate(paths: paths, token: token)
            var identity = selection.document; identity["device_id"] = device; identity["role"] = "client"
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(identity), to: paths.device.appendingPathComponent("client-identity.json"))
            var connection = selection.document; connection["role"] = "client"; connection["purpose"] = "native-new-family"
            connection["remote_path"] = target.appendingPathComponent("offline-provider").path; connection["bookmark"] = NSNull(); connection["requires_reconnection"] = true
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(connection), to: descriptor(paths))
            guard let handle = try read(paths: paths), let localConnection = try readConnection(paths: paths),
                  handle.version == row["active_hash"] as? String, handle.checkpoint.generation == row["generation"] as? String,
                  handle.checkpoint.sequence == (try WorkspaceIO.integer(raw, field: "sequence")) else { throw WorkspaceError.invalid("client backup selected proof") }
            let expected = try selectedBackupFiles(paths: paths, handle: handle, connection: localConnection)
            guard Set(expected.keys) == Set(files.keys) else { throw WorkspaceError.invalid("client backup contains unselected data") }
            for (name, file) in expected { guard try WorkspaceIO.hash(file) == files[name] else { throw WorkspaceError.invalid("client backup selected bytes") } }
            // Rebuild the cache high-water from the fully validated selection;
            // the next provider refresh must descend from this restored head.
            let cache = try store(paths, localConnection).local
            var head = selection.document; head["purpose"] = "validated-checkpoint-cache"
            head["generation"] = handle.checkpoint.generation; head["sequence"] = handle.checkpoint.sequence
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(head), to: cache.appendingPathComponent("cached-snapshot.json"))
            // Original package metadata is provenance only, never active authority.
            try WorkspaceIO.atomicWrite(raw, to: paths.device.appendingPathComponent("restored-client-backup-family.json"))
        }
        guard try WorkspaceIO.read(source.appendingPathComponent("manifest.json")) == raw else { throw WorkspaceError.stalePointer }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: target)
        try WorkspaceIO.syncDirectory(target.deletingLastPathComponent())
        guard let result = try read(paths: WorkspacePaths(workspace: target)) else { throw WorkspaceError.invalid("restored client selection missing") }
        return result
    }
    private static let backupByteLimit: Int64 = 100 * 1024 * 1024 * 1024
    private static func backupDestination(_ destination: URL, separateFrom source: URL) throws -> URL {
        guard destination.isFileURL else { throw WorkspaceError.invalid("client backup destination URL") }
        let target = WorkspaceIO.lexicalURL(destination), source = WorkspaceIO.lexicalURL(source)
        try WorkspaceIO.rejectSymlinks(target)
        guard target != source, !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/"),
              !FileManager.default.fileExists(atPath: target.path) else { throw WorkspaceError.invalid("client backup destination must be new and separate") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        return target
    }
    private static func backupPath(_ name: String, selection: ReviewFamilyBindingSelection) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if name == "device/client-active.json" { return true }
        if parts.count == 5, Array(parts.prefix(3)) == ["device", "family-requests", selection.bindingID] {
            if parts[3] == "objects" { return (try? WorkspaceIO.requireHash(parts[4])) != nil }
            if ["envelopes", "outbox-status"].contains(parts[3]), parts[4].hasSuffix(".json") {
                return UUID(uuidString: String(parts[4].dropLast(5))) != nil
            }
        }
        if parts.count >= 4, parts[0] == "device", parts[1] == "client-views", UUID(uuidString: parts[2]) != nil { return true }
        if parts.count == 5, parts[0] == "device", parts[1] == "client-edits", parts[2] == selection.bindingID,
           ["origins", "inventories"].contains(parts[3]) { return (try? WorkspaceIO.requireHash(parts[4])) != nil }
        if parts.count == 6, Array(parts.prefix(4)) == ["device", "family-sync", "client", selection.bindingID],
           ["objects", "snapshots"].contains(parts[4]) { return (try? WorkspaceIO.requireHash(parts[5])) != nil }
        return false
    }
    private static func selectedBackupFiles(paths: WorkspacePaths, handle: ReviewFamilyClientHandle, connection: ReviewFamilyClientConnection) throws -> [String: URL] {
        var files = ["device/client-active.json": active(paths)]
        let view = "device/client-views/" + handle.review.lastPathComponent + "/"
        for path in try WorkspaceIO.regularFiles(handle.review) { files[view + path] = try WorkspaceIO.safeChild(handle.review, path) }
        let pointer = try WorkspaceIO.object(WorkspaceIO.read(active(paths))), queueHash = try WorkspaceIO.string(pointer, "queue_hash")
        let queuePrefix = "device/client-edits/" + handle.selection.bindingID + "/"
        files[queuePrefix + "inventories/" + queueHash] = queueRoot(paths, handle.selection).appendingPathComponent("inventories/" + queueHash)
        for origin in handle.queue { for hash in origin.sources.keys {
            files[queuePrefix + "origins/" + hash] = queueRoot(paths, handle.selection).appendingPathComponent("origins/" + hash)
        } }
        let cachePrefix = "device/family-sync/client/" + handle.selection.bindingID + "/"
        for (name, file) in try store(paths, connection).selectedBackupFiles(generation: handle.checkpoint.generation, sequence: handle.checkpoint.sequence) { files[cachePrefix + name] = file }
        let requestPrefix = "device/family-requests/" + handle.selection.bindingID + "/"
        for (name, file) in try ReviewFamilyRequestTransport.backupFiles(cache: paths.device.appendingPathComponent("family-requests/" + handle.selection.bindingID), selection: handle.selection) {
            files[requestPrefix + name] = file
        }
        guard files.count <= 100_000 else { throw WorkspaceError.invalid("client backup file count") }
        return files
    }
    /// Fetch only a material named by the selected verified asset inventory.
    /// Optional originals enter the shared object cache, never the immutable view.
    public static func material(paths: WorkspacePaths, expected: ReviewFamilyClientHandle, path: String, hash: String) throws -> URL {
        guard let handle = try read(paths: paths), handle.version == expected.version,
              handle.selection == expected.selection, let connection = try readConnection(paths: paths) else { throw WorkspaceError.stalePointer }
        let inventory = try WorkspaceIO.object(WorkspaceIO.read(handle.checkpoint.file("asset-manifest.json")))
        guard let assets = inventory["assets"] as? [[String: Any]],
              assets.contains(where: { $0["path"] as? String == path && $0["sha256"] as? String == hash }) else {
            throw WorkspaceError.invalid("material is not in selected asset inventory")
        }
        try WorkspaceIO.requireHash(hash)
        let file: URL
        if handle.checkpoint.payload.resolved[path] != nil {
            file = try WorkspaceIO.safeChild(handle.review, path)
            try ReviewContentObjectIO.verify(file, hash: hash, maximumBytes: 32 * 1024 * 1024 * 1024)
        } else {
            guard handle.checkpoint.payload.optionalOriginalObjects.contains(hash) else { throw WorkspaceError.invalid("material download policy") }
            file = try store(paths, connection).local.appendingPathComponent("objects/" + hash)
            if FileManager.default.fileExists(atPath: file.path) {
                try ReviewContentObjectIO.verify(file, hash: hash, maximumBytes: 32 * 1024 * 1024 * 1024)
            } else {
                guard !connection.requiresReconnection else { throw WorkspaceError.invalid("请重新选择原同步目录，以下载此原件。") }
                try connection.selection.validate(marker: ReviewSyncIO.read(connection.remote.appendingPathComponent("family.json"), limit: 4096))
                try ReviewContentObjectIO.copy(connection.remote.appendingPathComponent("objects/" + hash), to: file, hash: hash, maximumBytes: 32 * 1024 * 1024 * 1024)
            }
        }
        guard let current = try read(paths: paths), current.version == handle.version else { throw WorkspaceError.stalePointer }
        return file
    }
    public static func transfer(paths: WorkspacePaths) async throws {
        guard let handle = try read(paths: paths), let connection = try readConnection(paths: paths) else { throw WorkspaceError.invalid("没有选中的 family 家庭副本。") }
        guard !connection.requiresReconnection else { throw WorkspaceError.invalid("恢复的家庭副本需先重新选择原同步目录。") }
        let transport = try ReviewFamilyRevisionTransport(remote: connection.remote, cache: paths.device.appendingPathComponent("client-transport"), selection: connection.selection)
        _ = try await transport.poll(outgoing: handle.queue.map { ReviewNativeRevision(verified: $0) })
        let requests = try requestTransport(paths: paths, expected: handle)
        _ = try await requests.poll(uploadOnly: true)
    }
    private static func commit(paths: WorkspacePaths, connection: ReviewFamilyClientConnection, checkpoint: ReviewCachedFamilySnapshot,
                               root: URL, queue: [ReviewRevisionOrigin], expected: String?, token: WorkspaceWriteToken) throws -> ReviewFamilyClientHandle {
        try token.validate(for: paths)
        guard try pointerVersion(paths) == expected, try readConnection(paths: paths)?.selection == connection.selection else { throw WorkspaceError.stalePointer }
        let metadata = try WorkspaceIO.read(root.appendingPathComponent("client-view.json")), meta = try WorkspaceIO.object(metadata)
        guard let files = meta["files"] as? [String: String], Set(files.keys) == Set(try WorkspaceIO.regularFiles(root)).subtracting(["client-view.json"]),
              meta["purpose"] as? String == "native-family-projection", meta["generation"] as? String == checkpoint.generation else { throw WorkspaceError.invalid("prepared client view manifest") }
        for (path, hash) in files { guard try WorkspaceIO.hash(WorkspaceIO.safeChild(root, path)) == hash else { throw WorkspaceError.invalid("prepared client view changed") } }
        let queueHash = try saveQueue(queue, paths, connection.selection)
        var row = connection.selection.document; row["purpose"] = "native-new-family-client"
        row["generation"] = checkpoint.generation; row["sequence"] = checkpoint.sequence; row["queue_hash"] = queueHash
        row["view_path"] = "client-views/" + root.lastPathComponent; row["view_hash"] = try WorkspaceIO.hash(root.appendingPathComponent("client-view.json"))
        let raw = try WorkspaceIO.canonical(row)
        try Task.checkCancellation()
        do { try WorkspaceIO.atomicWrite(raw, to: active(paths)) }
        catch { guard (try? WorkspaceIO.read(active(paths))) == raw else { throw error } }
        guard let handle = try read(paths: paths) else { throw WorkspaceError.invalid("family selection commit missing") }
        WorkspaceReclamation.collectWhileHoldingWrite(paths: paths, token: token)
        return handle
    }
    private static func replay(checkpoint: ReviewCachedFamilySnapshot, queue: [ReviewRevisionOrigin], selection: ReviewFamilyBindingSelection) throws -> ReviewSettingsCausalCheckpoint {
        guard queue.allSatisfy({ $0.key.sourceBindingID == selection.bindingID }) else { throw WorkspaceError.invalid("foreign client queued origin") }
        switch try ReviewSettingsCausalFields.append(queue.map { ReviewNativeRevision(verified: $0) }, to: checkpoint.payload.fields,
            bindingID: selection.bindingID, context: context(checkpoint)) {
        case .ready(let fields): return fields
        case .waiting: throw WorkspaceError.invalid("客户端修改缺少 ancestors，原 selection 保留。")
        case .conflicted: throw WorkspaceError.invalid("家庭设置并发修改需核对，原 selection 和 queue 保留。")
        }
    }
    private static func projection(paths: WorkspacePaths, checkpoint: ReviewCachedFamilySnapshot, fields: ReviewSettingsCausalCheckpoint) throws -> (URL, WorkspaceReaderLease) {
        let root = paths.device.appendingPathComponent("client-views/" + UUID().uuidString.lowercased())
        let readLease = try WorkspaceReaderLease(directory: paths.device.appendingPathComponent("readers/views"), identity: root.lastPathComponent)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, file) in checkpoint.payload.resolved {
            let target = try WorkspaceIO.safeChild(root, path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if clonefile(file.path, target.path, 0) != 0 { try FileManager.default.copyItem(at: file, to: target) }
        }
        try ReviewFieldDocuments.materializeFamilyClient(values: fields.causal.values, settings: fields.settings, review: root, paths: paths)
        try WorkspaceIO.atomicWrite(fields.causal.inventory, to: root.appendingPathComponent("projection-inventory.json"))
        try validateView(root, checkpoint: checkpoint, fields: fields)
        var files = [String: String]()
        for path in try WorkspaceIO.regularFiles(root) { files[path] = try WorkspaceIO.hash(WorkspaceIO.safeChild(root, path)) }
        let metadata = try WorkspaceIO.canonical(["purpose": "native-family-projection", "generation": checkpoint.generation, "files": files])
        try WorkspaceIO.atomicWrite(metadata, to: root.appendingPathComponent("client-view.json"))
        return (root, readLease)
    }
    private static func validateView(_ root: URL, checkpoint: ReviewCachedFamilySnapshot, fields: ReviewSettingsCausalCheckpoint) throws {
        for (path, file) in checkpoint.payload.resolved where !mutable.contains(path) {
            guard try WorkspaceIO.hash(WorkspaceIO.safeChild(root, path)) == WorkspaceIO.hash(file) else { throw WorkspaceError.invalid("projection changed baseline proof/original") }
        }
        var actual = try ReviewFieldDocuments.capture(review: root)
        for (path, field) in [("family-profile.json", "settings/family-profile"), ("account-policies.json", "settings/account-policies")] {
            actual[field] = String(decoding: try WorkspaceIO.read(root.appendingPathComponent(path)), as: UTF8.self)
        }
        guard actual == fields.causal.values, try WorkspaceIO.read(root.appendingPathComponent("projection-inventory.json")) == fields.causal.inventory else { throw WorkspaceError.invalid("projection differs from exact replay") }
    }
    internal static func sources(_ checkpoint: ReviewCachedFamilySnapshot) throws -> [HouseholdRegisteredSource] {
        let row = try SettingsJSON(WorkspaceIO.read(checkpoint.file("config/review-import-sources.json")), required: ["sources"], allowAdditional: true)
        return try row.array("sources", maximum: 100_000).map { raw in
            let entry = try SettingsJSON(raw, required: ["id", "path", "platform", "sha256"], allowAdditional: true)
            return try .init(id: entry.string("id"), path: entry.string("path", maximum: 4096), platform: entry.string("platform"), sha256: entry.string("sha256", maximum: 64))
        }
    }
    internal static func context(_ checkpoint: ReviewCachedFamilySnapshot, retaining settings: HouseholdSettings? = nil) throws -> HouseholdSettingsContext {
        .init(registeredSourceIDs: try sources(checkpoint).map(\.id), currencyCodes: ["CNY"],
            referencedMemberIDs: settings?.members.map(\.id) ?? [], referencedAccountIDs: settings?.accounts.map(\.id) ?? [])
    }
    private static func saveQueue(_ queue: [ReviewRevisionOrigin], _ paths: WorkspacePaths, _ selection: ReviewFamilyBindingSelection) throws -> String {
        let root = queueRoot(paths, selection)
        for origin in queue { for (hash, raw) in origin.sources { try immutable(raw, root.appendingPathComponent("origins/" + hash)) } }
        let raw = try ReviewRevisionOrigin.inventoryBytes(queue), hash = WorkspaceIO.digest(raw)
        try immutable(raw, root.appendingPathComponent("inventories/" + hash)); return hash
    }
    private static func loadQueue(_ paths: WorkspacePaths, _ selection: ReviewFamilyBindingSelection, _ hash: String) throws -> [ReviewRevisionOrigin] {
        try WorkspaceIO.requireHash(hash)
        let root = queueRoot(paths, selection), raw = try WorkspaceIO.read(root.appendingPathComponent("inventories/" + hash))
        guard WorkspaceIO.digest(raw) == hash, let entries = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["entries"]), entries.count <= 20_000 else { throw WorkspaceError.invalid("client queue pin/budget") }
        var objects = [String: Data](), totalBytes = 0
        for entry in entries {
            let row = try WorkspaceIO.object(entry)
            let aliases = [try WorkspaceIO.string(row, "payload_hash")]
            for hash in aliases where objects[hash] == nil {
                try WorkspaceIO.requireHash(hash)
                let bytes = try ReviewSyncIO.read(root.appendingPathComponent("origins/" + hash), limit: min(2 * 1024 * 1024, 64 * 1024 * 1024 - totalBytes))
                totalBytes += bytes.count; guard totalBytes <= 64 * 1024 * 1024 else { throw WorkspaceError.invalid("client queue byte budget") }
                objects[hash] = bytes
            }
        }
        return try ReviewRevisionOrigin.inventory(raw, objects: objects, sourceBindings: [selection.bindingID])
    }
    private static func immutable(_ raw: Data, _ file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) { guard try WorkspaceIO.read(file, limit: 64 * 1024 * 1024) == raw else { throw WorkspaceError.invalid("immutable client queue object changed") } }
        else { try WorkspaceIO.atomicWrite(raw, to: file) }
    }
    @discardableResult public static func collect(paths: WorkspacePaths, token: WorkspaceWriteToken) throws -> Int {
        try token.validate(for: paths)
        guard let handle = try read(paths: paths), let connection = try readConnection(paths: paths) else { return 0 }
        let views = try WorkspaceReclamation.collectClientViews(paths: paths, token: token)
        _ = try store(paths, connection).collectCache(selectedGeneration: handle.checkpoint.generation)
        return views
    }
    private static func pointerVersion(_ paths: WorkspacePaths) throws -> String? {
        if !FileManager.default.fileExists(atPath: active(paths).path) { return nil }; return try WorkspaceIO.hash(active(paths))
    }
    private static func viewPath(_ paths: WorkspacePaths, _ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "client-views", UUID(uuidString: String(parts[1])) != nil else { throw WorkspaceError.invalid("client view namespace") }
        return try WorkspaceIO.safeChild(paths.device, relative)
    }
    private static func requireClientContainer(_ paths: WorkspacePaths) throws {
        for file in [paths.metadata] + ["host-authorization.json", "create-family.json"].map({ paths.device.appendingPathComponent($0) }) {
            try WorkspaceIO.rejectSymlinks(file)
            guard !FileManager.default.fileExists(atPath: file.path) else { throw WorkspaceError.invalid("旧绑定或完整工作区不能自动变成新 family client。") }
        }
    }
    private static func parseSelection(_ raw: Data) throws -> ReviewFamilyBindingSelection {
        let row = try WorkspaceIO.object(raw)
        let selection = try ReviewFamilyBindingSelection(workspaceID: WorkspaceIO.string(row, "workspace_id"), bindingID: WorkspaceIO.string(row, "binding_id"), hostID: WorkspaceIO.string(row, "host_id"), initialSequence: WorkspaceIO.integer(raw, field: "initial_sequence"))
        try selection.validate(marker: raw); return selection
    }
}
