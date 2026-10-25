import Foundation

public struct ReviewRevisionTransportPoll: Sendable {
    public let revisions: [ReviewNativeRevision]
    public let waitingObjectHashes: Set<String>
    public let invalidRevisionIDs: Set<String>
    public let uploadedRevisionIDs: Set<String>
}

internal struct ReviewRevisionTransportEngine {
    let remote: URL, cache: URL
    let context: ReviewRevisionTransportContext
    private var scanOffset = 0
    private var uploadOffset = 0
    // Scheduling hints only; they never stand in for envelope/raw validation.
    var pagingOffsets: (scan: Int, upload: Int) {
        get { (scanOffset, uploadOffset) }
        set { scanOffset = newValue.scan; uploadOffset = newValue.upload }
    }
    init(remote: URL, cache: URL, context: ReviewRevisionTransportContext) throws {
        guard remote.isFileURL, cache.isFileURL else { throw WorkspaceError.invalid("revision transport URL") }
        self.remote = WorkspaceIO.lexicalURL(remote); self.cache = WorkspaceIO.lexicalURL(cache); self.context = context
        try WorkspaceIO.rejectSymlinks(self.remote); try WorkspaceIO.rejectSymlinks(self.cache)
    }
    mutating func poll(outgoing: [ReviewNativeRevision], limit: Int = 128) throws -> ReviewRevisionTransportPoll {
        guard (1...1_024).contains(limit) else { throw WorkspaceError.invalid("revision poll bound") }
        guard outgoing.allSatisfy({ $0.origin.sourceBindingID == context.bindingID }) else { throw WorkspaceError.invalid("foreign revision binding") }
        guard outgoing.allSatisfy({ $0.raw.count <= 2 * 1024 * 1024 }) else { throw WorkspaceError.invalid("revision object resource limit") }
        try Task.checkCancellation()
        try context.validateMarker(ReviewSyncIO.read(remote.appendingPathComponent(context.markerName), limit: 4096))
        let remoteRevisions = remote.appendingPathComponent(context.revisionsName), remoteObjects = remote.appendingPathComponent(context.objectsName)
        try WorkspaceIO.rejectSymlinks(remoteRevisions); try WorkspaceIO.rejectSymlinks(remoteObjects)
        var uploaded = Set<String>(), waiting = Set<String>(), invalid = Set<String>(), received = [ReviewNativeRevision]()
        if !outgoing.isEmpty {
            try FileManager.default.createDirectory(at: remoteRevisions, withIntermediateDirectories: true)
            for revision in Self.window(outgoing.sorted { $0.origin.revisionID < $1.origin.revisionID }, offset: &uploadOffset, limit: limit) {
                try Task.checkCancellation()
                let doc = context.envelope(revision)
                try ReviewSyncIO.coordinate(remote, write: true) { _ in
                    try immutable(WorkspaceIO.canonical(doc), at: remoteRevisions.appendingPathComponent(revision.origin.revisionID + ".json"))
                }
                try immutable(revision.raw, at: remoteObjects.appendingPathComponent(revision.origin.payloadHash))
                uploaded.insert(revision.origin.revisionID)
            }
        }
        let names: [String]
        do { names = try ReviewSyncIO.coordinate(remoteRevisions) { try FileManager.default.contentsOfDirectory(atPath: $0.path).sorted() } }
        catch { if ReviewSyncIO.isMissing(error) { return ReviewRevisionTransportPoll(revisions: [], waitingObjectHashes: [], invalidRevisionIDs: [], uploadedRevisionIDs: uploaded) }; throw error }
        guard names.count <= 100_000 else { throw WorkspaceError.invalid("revision directory resource limit") }
        for name in Self.window(names, offset: &scanOffset, limit: limit) {
            try Task.checkCancellation()
            guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil else { invalid.insert(name); continue }
            do {
                let envelope = try ReviewSyncIO.read(WorkspaceIO.safeChild(remoteRevisions, name), limit: 4096), doc = try WorkspaceIO.object(envelope)
                try context.validateEnvelope(envelope, revisionID: String(name.dropLast(5)))
                let hash = try WorkspaceIO.string(doc, "payload_hash"); try WorkspaceIO.requireHash(hash)
                let localObject = cache.appendingPathComponent("objects/" + hash)
                let raw: Data
                if FileManager.default.fileExists(atPath: localObject.path) { raw = try ReviewSyncIO.read(localObject, limit: 2 * 1024 * 1024) }
                else {
                    do { raw = try ReviewSyncIO.read(remoteObjects.appendingPathComponent(hash), limit: 2 * 1024 * 1024) }
                    catch { if ReviewSyncIO.isMissing(error) { waiting.insert(hash); continue }; throw error }
                }
                guard WorkspaceIO.digest(raw) == hash else { throw WorkspaceError.invalid("revision raw object hash") }
                let revision = try ReviewNativeRevision(sourceBindingID: context.bindingID, raw: raw)
                guard revision.origin.revisionID == doc["revision_id"] as? String else { throw WorkspaceError.invalid("revision envelope payload differs") }
                try immutable(raw, at: localObject)
                try immutable(envelope, at: cache.appendingPathComponent("envelopes/" + name))
                received.append(revision)
            } catch {
                if error is CancellationError { throw error }
                invalid.insert(name)
            }
        }
        return ReviewRevisionTransportPoll(revisions: received, waitingObjectHashes: waiting, invalidRevisionIDs: invalid, uploadedRevisionIDs: uploaded)
    }
    static func cachedRevisions(cache: URL, context: ReviewRevisionTransportContext) throws -> [ReviewNativeRevision] {
        let directory = cache.appendingPathComponent("envelopes")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try WorkspaceIO.rejectSymlinks(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        guard names.count <= 20_000 else { throw WorkspaceError.invalid("cached revision resource limit") }
        var result = [ReviewNativeRevision](), totalBytes = 0
        for name in names {
            try Task.checkCancellation()
            let envelope = try ReviewSyncIO.read(WorkspaceIO.safeChild(directory, name), limit: 4096), doc = try WorkspaceIO.object(envelope)
            try context.validateEnvelope(envelope, revisionID: nil)
            let hash = try WorkspaceIO.string(doc, "payload_hash"); try WorkspaceIO.requireHash(hash)
            let raw = try ReviewSyncIO.read(cache.appendingPathComponent("objects/" + hash), limit: 2 * 1024 * 1024)
            totalBytes += raw.count
            guard totalBytes <= 64 * 1024 * 1024, WorkspaceIO.digest(raw) == hash else { throw WorkspaceError.invalid("cached revision bytes") }
            let revision = try ReviewNativeRevision(sourceBindingID: context.bindingID, raw: raw)
            guard doc["revision_id"] as? String == revision.origin.revisionID, name == revision.origin.revisionID + ".json" else { throw WorkspaceError.invalid("cached envelope ID") }
            result.append(revision)
        }
        return result
    }
    private static func window<T>(_ values: [T], offset: inout Int, limit: Int) -> [T] {
        guard !values.isEmpty else { offset = 0; return [] }
        let count = min(limit, values.count), start = offset % values.count
        let selected = (0..<count).map { values[(start + $0) % values.count] }
        offset = (start + count) % values.count
        return selected
    }
    private func immutable(_ bytes: Data, at file: URL) throws {
        guard bytes.count <= 2 * 1024 * 1024 else { throw WorkspaceError.invalid("revision object resource limit") }
        try WorkspaceIO.rejectSymlinks(file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ReviewSyncIO.coordinate(file.deletingLastPathComponent(), write: true) { parent in
            let target = parent.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                guard try ReviewSyncIO.read(target, limit: 2 * 1024 * 1024) == bytes else { throw WorkspaceError.invalid("immutable revision collision") }
            } else { try WorkspaceIO.atomicWrite(bytes, to: target) }
        }
    }
}
