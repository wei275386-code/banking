import Foundation
import Darwin

/// Per-generation interpretation inputs supplied by the local qualification
/// owner. Constructing this value does not authenticate its provenance.
public struct ReviewFamilySnapshotContext: Sendable {
    public let sourceBindings: Set<String>, settings: HouseholdSettingsContext
    public init(sourceBindings: Set<String>, settings: HouseholdSettingsContext) {
        self.sourceBindings = sourceBindings; self.settings = settings
    }
}
/// One validated generation's logical files, addressed by immutable raw hashes.
/// This cache handle is not a selected client view or activation capability.
public struct ReviewCachedFamilySnapshot: Sendable {
    private let readLease: WorkspaceReaderLease
    public let payload: ReviewValidatedFamilyPayload, sequence: Int64
    public var generation: String { payload.generation }
    public func file(_ path: String) throws -> URL {
        guard let file = payload.resolved[path] else { throw WorkspaceError.invalid("file is not in required checkpoint closure") }; return file
    }
    fileprivate init(payload: ReviewValidatedFamilyPayload, sequence: Int64, readLease: WorkspaceReaderLease) {
        self.readLease = readLease; self.payload = payload; self.sequence = sequence
    }
}
public enum ReviewFamilySnapshotPreparation: Sendable {
    case ready(ReviewCachedFamilySnapshot)
    case unchanged(ReviewCachedFamilySnapshot)
    case waiting(objectHashes: Set<String>, ancestorIDs: Set<String>)
    case conflicted(settingsFields: Set<String>)
}

/// Family reader transport/cache only. No host publication, workspace gate, active
/// client pointer or local upgrade authority. Provider and offline paths both
/// validate the selected complete snapshot and its referenced objects.
public final class ReviewFamilySnapshotStore: Sendable {
    public let remote: URL, local: URL, selection: ReviewFamilyBindingSelection, readerVersion: String
    private var cacheHead: URL { local.appendingPathComponent("cached-snapshot.json") }
    private var objectRoot: URL { local.appendingPathComponent("objects") }
    public init(remote: URL, local: URL, selection: ReviewFamilyBindingSelection, readerVersion: String = "1.3.0") throws {
        guard remote.isFileURL, local.isFileURL else { throw WorkspaceError.invalid("family Store URLs") }
        self.remote = WorkspaceIO.lexicalURL(remote)
        self.local = WorkspaceIO.lexicalURL(local.appendingPathComponent("" + selection.bindingID))
        self.selection = selection; self.readerVersion = readerVersion
        try WorkspaceIO.rejectSymlinks(self.remote); try WorkspaceIO.rejectSymlinks(self.local)
    }
    /// Cache high-water commits are serialized on local disk only; this lock
    /// grants no provider writer/host role. Missing data never replaces the head.
    public func prepare(contextForGeneration: (String, Data) throws -> ReviewFamilySnapshotContext) throws -> ReviewFamilySnapshotPreparation {
        try withCacheLock {
            try validateMarker()
            let pointer: Head
            do { pointer = try readHead(remote.appendingPathComponent("current.json")) }
            catch { if ReviewSyncIO.isMissing(error) { return .waiting(objectHashes: [], ancestorIDs: []) }; throw error }
            let previous = try cachedHead()
            let resolver = objectResolver(online: true)
            let result: ReviewFamilySnapshotPreparation
            do {
                result = try validateSnapshot(head: pointer, known: previous, contextForGeneration: contextForGeneration,
                    manifest: { hash in try self.fetchManifest(hash) }, resolver: resolver)
            } catch let missing as Missing { return .waiting(objectHashes: [missing.hash], ancestorIDs: []) }
            guard case .ready(let checkpoint) = result else { return result }
            try immutable(checkpoint.payload.manifest, at: generationFile(pointer.generation))
            try validateMarker()
            let latest = try readHead(remote.appendingPathComponent("current.json"))
            guard latest == pointer, try cachedHead() == previous else { throw WorkspaceError.stalePointer }
            var document = selection.document
            document["purpose"] = "validated-checkpoint-cache"
            document["generation"] = pointer.generation; document["sequence"] = pointer.sequence
            try Task.checkCancellation()
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(document), to: cacheHead)
            return previous == pointer ? .unchanged(checkpoint) : .ready(checkpoint)
        }
    }
    /// Offline reads need only the current snapshot and its referenced objects.
    public func readCached(contextForGeneration: (String, Data) throws -> ReviewFamilySnapshotContext) throws -> ReviewCachedFamilySnapshot? {
        guard let head = try cachedHead() else { return nil }
        let result: ReviewFamilySnapshotPreparation
        do {
            result = try validateSnapshot(head: head, known: nil, contextForGeneration: contextForGeneration,
            manifest: { hash in
                try self.manifestBytes(self.generationFile(hash), hash: hash)
            }, resolver: objectResolver(online: false))
        } catch let missing as Missing { throw WorkspaceError.invalid("retained family ancestor missing: " + missing.hash) }
        guard case .ready(let cached) = result else { throw WorkspaceError.invalid("retained family cache is incomplete or conflicted") }; return cached
    }
    /// New-binding reader context is derived from hash-pinned state/registry
    /// objects, never from local host state or a provider qualification report.
    /// Upgrade lineage is deliberately rejected by this native-only entrance.
    public func prepareNewFamily() throws -> ReviewFamilySnapshotPreparation {
        try prepare { _, raw in try self.newFamilyContext(raw, online: true) }
    }
    public func readNewFamily(generation: String, sequence: Int64) throws -> ReviewCachedFamilySnapshot {
        try WorkspaceIO.requireHash(generation)
        let result = try validateSnapshot(head: Head(generation: generation, sequence: sequence), known: nil,
            contextForGeneration: { _, raw in try self.newFamilyContext(raw, online: false) },
            manifest: { hash in try self.manifestBytes(self.generationFile(hash), hash: hash) }, resolver: objectResolver(online: false))
        guard case .ready(let value) = result else { throw WorkspaceError.invalid("selected native family checkpoint incomplete") }
        return value
    }
    /// Exact offline ancestry/object closure for a selected native client backup.
    /// Full copies require on-demand originals too; a cache miss is not an omission.
    internal func selectedBackupFiles(generation: String, sequence: Int64) throws -> [String: URL] {
        var files = [String: URL]()
        let result = try validateSnapshot(head: Head(generation: generation, sequence: sequence), known: nil,
            contextForGeneration: { _, raw in try self.newFamilyContext(raw, online: false) },
            manifest: { hash in
                let file = self.generationFile(hash)
                let raw = try self.manifestBytes(file, hash: hash)
                files["snapshots/" + hash] = file; return raw
            }, resolver: objectResolver(online: false), validated: { payload in
                for hash in payload.requiredObjects.union(payload.optionalOriginalObjects) {
                    let file = self.objectRoot.appendingPathComponent(hash)
                    try ReviewContentObjectIO.verify(file, hash: hash, maximumBytes: 32 * 1024 * 1024 * 1024)
                    files["objects/" + hash] = file
                }
            })
        guard case .ready = result else { throw WorkspaceError.invalid("selected backup checkpoint is incomplete") }
        return files
    }
    private func newFamilyContext(_ raw: Data, online: Bool) throws -> ReviewFamilySnapshotContext {
        let cp = try WorkspaceIO.object(raw)
        guard let tuple = cp["state"] as? [String: Any] else { throw WorkspaceError.invalid("family snapshot state") }
        let resolve = objectResolver(online: online)
        func object(_ hash: String) throws -> Data {
            try WorkspaceIO.requireHash(hash)
            return try ReviewSyncIO.read(resolve(hash, 16 * 1024 * 1024), limit: 16 * 1024 * 1024)
        }
        let stateRaw = try object(WorkspaceIO.string(tuple, "state_manifest_hash")), state = try WorkspaceIO.object(stateRaw)
        guard state["workspace_id"] as? String == selection.workspaceID,
              state["state_id"] as? String == tuple["state_id"] as? String,
              let files = state["files"] as? [String: String], let registryHash = files["config/review-import-sources.json"] else { throw WorkspaceError.invalid("native family context state") }
        let registry = try SettingsJSON(object(registryHash), required: ["sources"], allowAdditional: true)
        var ids = [String](), seenIDs = Set<Data>(), seenPaths = Set<Data>()
        let exactFiles = Dictionary(uniqueKeysWithValues: files.map { (Data($0.key.utf8), $0.value) })
        for raw in try registry.array("sources", maximum: 100_000) {
            let row = try SettingsJSON(raw, required: ["id", "path", "platform", "sha256"], allowAdditional: true)
            let id = try row.string("id"), path = try row.string("path", maximum: 4096), hash = try row.string("sha256", maximum: 64)
            _ = try WorkspaceIO.safeChild(local, path); _ = try row.string("platform"); try WorkspaceIO.requireHash(hash)
            guard seenIDs.insert(Data(id.utf8)).inserted, seenPaths.insert(Data(path.utf8)).inserted,
                  exactFiles[Data(path.utf8)] == hash else { throw WorkspaceError.invalid("native family source registry closure") }
            ids.append(id)
        }
        return .init(sourceBindings: [selection.bindingID], settings: .init(registeredSourceIDs: ids,
            currencyCodes: ["CNY"], referencedMemberIDs: [], referencedAccountIDs: []))
    }
    private struct Head: Equatable { let generation: String, sequence: Int64 }
    private struct Node {
        let head: Head, raw: Data, parent: String?, stateID: String, stateHash: String, localRevision: Int64
    }
    private struct Missing: Error { let hash: String }
    private func validateSnapshot(head: Head, known: Head?, contextForGeneration: (String, Data) throws -> ReviewFamilySnapshotContext,
                               manifest: (String) throws -> Data, resolver: (String, Int64) throws -> URL,
                               validated: ((ReviewValidatedFamilyPayload) throws -> Void)? = nil) throws -> ReviewFamilySnapshotPreparation {
        let readLease = try WorkspaceReaderLease(directory: local.appendingPathComponent("reader-locks"), identity: head.generation)
        if let known { guard head == known || head.sequence > known.sequence else { throw WorkspaceError.invalid("family provider rollback/equal-sequence fork") } }
        let raw: Data
        do { raw = try manifest(head.generation) }
        catch { if ReviewSyncIO.isMissing(error) { throw Missing(hash: head.generation) }; throw error }
        let node = try parse(raw, generation: head.generation)
        guard node.head == head else { throw WorkspaceError.invalid("checkpoint pointer differs from manifest") }
        if let known, known != head {
            let previous = try parse(manifestBytes(generationFile(known.generation), hash: known.generation), generation: known.generation)
            guard node.localRevision >= previous.localRevision,
                  node.localRevision != previous.localRevision || (node.stateID == previous.stateID && node.stateHash == previous.stateHash) else {
                throw WorkspaceError.invalid("checkpoint committed-state rollback")
            }
        }
        let context = try contextForGeneration(head.generation, raw)
        switch try ReviewFamilySnapshotPayload.prepare(selection: selection, generation: head.generation, manifest: raw,
            sourceBindings: context.sourceBindings, context: context.settings, readerVersion: readerVersion, resolver: resolver) {
        case .waiting(let hashes, let ancestors): return .waiting(objectHashes: hashes, ancestorIDs: ancestors)
        case .conflicted(let fields): return .conflicted(settingsFields: fields)
        case .ready(let payload):
            try validated?(payload)
            return .ready(ReviewCachedFamilySnapshot(payload: payload, sequence: head.sequence, readLease: readLease))
        }
    }
    private func parse(_ raw: Data, generation: String) throws -> Node {
        guard WorkspaceIO.digest(raw) == generation, try ReleaseCanonicalJSON.canonicalize(raw: raw) == raw else { throw WorkspaceError.invalid("family generation hash/canonical bytes") }
        let doc = try WorkspaceIO.object(raw)
        guard doc["workspace_id"] as? String == selection.workspaceID, doc["binding_id"] as? String == selection.bindingID,
              doc["host_id"] as? String == selection.hostID, let parent = doc["parent_generation"], parent is NSNull || parent is String,
              let stateRaw = try ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: ["state"]) else { throw WorkspaceError.invalid("family ancestry identity") }
        let sequence = try WorkspaceIO.integer(raw, field: "sequence"), state = try WorkspaceIO.object(stateRaw)
        guard sequence >= selection.initialSequence, sequence != 1 || parent is NSNull else { throw WorkspaceError.invalid("family initial sequence") }
        if let parent = parent as? String { try WorkspaceIO.requireHash(parent) }
        let stateID = try WorkspaceIO.string(state, "state_id"), stateHash = try WorkspaceIO.string(state, "state_manifest_hash")
        try WorkspaceIO.requireUUID(stateID, field: "family state"); try WorkspaceIO.requireHash(stateHash)
        return Node(head: Head(generation: generation, sequence: sequence), raw: raw, parent: parent as? String,
            stateID: stateID, stateHash: stateHash, localRevision: try WorkspaceIO.integer(stateRaw, field: "local_revision"))
    }
    private func objectResolver(online: Bool) -> (String, Int64) throws -> URL {
        var fetched = Set<String>(), fetchedBytes: Int64 = 0
        return { hash, maximum in
            let remaining = 100 * 1024 * 1024 * 1024 - fetchedBytes
            let bound = fetched.contains(hash) ? maximum : min(maximum, remaining)
            guard bound >= 0, fetched.contains(hash) || fetched.count < 100_000 else { throw WorkspaceError.invalid("family Store object budget") }
            let target = self.objectRoot.appendingPathComponent(hash)
            if !online || FileManager.default.fileExists(atPath: target.path) { try ReviewContentObjectIO.verify(target, hash: hash, maximumBytes: bound) }
            else { try ReviewContentObjectIO.copy(self.remote.appendingPathComponent("objects/" + hash), to: target, hash: hash, maximumBytes: bound) }
            if fetched.insert(hash).inserted {
                let size = try ReviewVerifiedFilePin.read(target).size
                guard size <= remaining else { throw WorkspaceError.invalid("family Store total byte budget") }; fetchedBytes += size
            }
            return target
        }
    }
    private func validateMarker() throws { try selection.validate(marker: readJSON(remote.appendingPathComponent("family.json"), maximum: 4096)) }
    private func readHead(_ file: URL, cached: Bool = false) throws -> Head {
        let raw = try readJSON(file, maximum: 4096); try selection.validate(marker: raw)
        let doc = try WorkspaceIO.object(raw)
        if cached { guard doc["purpose"] as? String == "validated-checkpoint-cache" else { throw WorkspaceError.invalid("family cache-head purpose/version") } }
        let generation = try WorkspaceIO.string(doc, "generation"), sequence = try WorkspaceIO.integer(raw, field: "sequence")
        try WorkspaceIO.requireHash(generation); guard sequence >= selection.initialSequence else { throw WorkspaceError.invalid("family pointer sequence") }
        return Head(generation: generation, sequence: sequence)
    }
    private func cachedHead() throws -> Head? {
        do { return try readHead(cacheHead, cached: true) }
        catch { if ReviewSyncIO.isMissing(error) { return nil }; throw error }
    }
    private func generationFile(_ hash: String) -> URL { local.appendingPathComponent("snapshots/" + hash) }
    private func manifestBytes(_ file: URL, hash: String) throws -> Data {
        let raw = try readJSON(file)
        guard WorkspaceIO.digest(raw) == hash, try ReleaseCanonicalJSON.canonicalize(raw: raw) == raw else { throw WorkspaceError.invalid("family retained manifest differs") }; return raw
    }
    private func fetchManifest(_ hash: String) throws -> Data {
        try WorkspaceIO.requireHash(hash)
        let file = generationFile(hash)
        if FileManager.default.fileExists(atPath: file.path) { return try manifestBytes(file, hash: hash) }
        let raw = try manifestBytes(remote.appendingPathComponent("snapshots/" + hash), hash: hash)
        try immutable(raw, at: file); return raw
    }
    private func readJSON(_ file: URL, maximum: Int = ReviewClientBusinessProof.maximumBytes) throws -> Data { try ReviewSyncIO.read(file, limit: maximum) }
    private func immutable(_ raw: Data, at file: URL) throws {
        try WorkspaceIO.rejectSymlinks(file)
        if FileManager.default.fileExists(atPath: file.path) { guard try readJSON(file) == raw else { throw WorkspaceError.invalid("family immutable cache collision") } }
        else { try WorkspaceIO.atomicWrite(raw, to: file) }
    }
    /// Selected and live reader handles pin their generation. No ancestor chain
    /// or fixed count of full snapshots is retained.
    @discardableResult internal func collectCache(selectedGeneration: String) throws -> Int {
        try withCacheLock {
            var generations: Set<String> = [selectedGeneration]
            if let head = try cachedHead() { generations.insert(head.generation) }
            var removed = 0
            for name in try WorkspaceReclamation.children(local.appendingPathComponent("snapshots")) where !generations.contains(name) {
                try WorkspaceIO.requireHash(name)
                if try WorkspaceReaderLease.removeIfUnleased(tree: generationFile(name), directory: local.appendingPathComponent("reader-locks"), identity: name) {
                    removed += 1
                } else { generations.insert(name) }
            }
            var objects = Set<String>()
            func metadata(_ hash: String) throws -> [String: Any] {
                try WorkspaceIO.requireHash(hash)
                let raw = try ReviewSyncIO.read(objectRoot.appendingPathComponent(hash), limit: ReviewClientBusinessProof.maximumBytes)
                guard WorkspaceIO.digest(raw) == hash else { throw WorkspaceError.invalid("cache reclamation object pin") }
                return try WorkspaceIO.object(raw)
            }
            for generation in generations {
                let raw = try manifestBytes(generationFile(generation), hash: generation), cp = try WorkspaceIO.object(raw)
                guard let files = cp["files"] as? [String: String] else { throw WorkspaceError.invalid("cache reclamation files") }
                objects.formUnion(files.values)
                let inventory = try WorkspaceIO.string(cp, "covered_revision_inventory"); objects.insert(inventory)
                guard let tuple = cp["state"] as? [String: Any],
                      let stateFiles = try metadata(WorkspaceIO.string(tuple, "state_manifest_hash"))["files"] as? [String: String] else { throw WorkspaceError.invalid("cache reclamation state closure") }
                objects.formUnion(stateFiles.values)
                let assets = try metadata(WorkspaceIO.string(cp, "asset_manifest")), origins = try metadata(inventory)
                guard let entries = assets["assets"] as? [[String: Any]], let revisions = origins["entries"] as? [[String: Any]] else { throw WorkspaceError.invalid("cache reclamation inventory") }
                for entry in entries { objects.insert(try WorkspaceIO.string(entry, "sha256")) }
                for revision in revisions { objects.insert(try WorkspaceIO.string(revision, "payload_hash")) }
            }
            for hash in try WorkspaceReclamation.children(objectRoot) where !objects.contains(hash) && !hash.hasPrefix(".") {
                try WorkspaceIO.requireHash(hash); try WorkspaceIO.rejectSymlinks(objectRoot.appendingPathComponent(hash))
                try FileManager.default.removeItem(at: objectRoot.appendingPathComponent(hash))
            }
            return removed
        }
    }

    private func withCacheLock<T>(_ work: () throws -> T) throws -> T {
        try WorkspaceIO.rejectSymlinks(local); try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let file = local.appendingPathComponent("reader-cache-family.lock"); try WorkspaceIO.rejectSymlinks(file)
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw WorkspaceError.io("family reader cache lock") }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WorkspaceError.busy }; defer { flock(fd, LOCK_UN) }
        return try work()
    }
}
