import Foundation

/// Explicit local connection pins only. Construction/marker validation gives no
/// host, processor, checkpoint-reader or protocol-upgrade authority.
public struct ReviewFamilyBindingSelection: Equatable, Sendable {
    public let workspaceID: String, bindingID: String, hostID: String
    public let initialSequence: Int64
    public init(workspaceID: String, bindingID: String, hostID: String, initialSequence: Int64 = 1) throws {
        for id in [workspaceID, bindingID, hostID] { try WorkspaceIO.requireUUID(id, field: "family binding identity") }
        guard initialSequence > 0 else { throw WorkspaceError.invalid("family initial sequence") }
        self.workspaceID = workspaceID; self.bindingID = bindingID; self.hostID = hostID; self.initialSequence = initialSequence
    }
    internal var document: [String: Any] { ReviewRevisionTransportContext(self).marker }
    internal func validate(marker: Data) throws { try ReviewRevisionTransportContext(self).validateMarker(marker) }
}

/// Isolated family immutable native queue. It consumes an already selected marker;
/// it cannot create/activate a binding or admit old-origin supplements. The
/// actual cache is scoped below the caller root to keep each binding independent.
public actor ReviewFamilyRevisionTransport {
    public let remote: URL, cache: URL
    public let selection: ReviewFamilyBindingSelection
    private var engine: ReviewRevisionTransportEngine
    public init(remote: URL, cache: URL, selection: ReviewFamilyBindingSelection) throws {
        guard cache.isFileURL else { throw WorkspaceError.invalid("family revision cache URL") }
        let scoped = cache.appendingPathComponent("" + selection.bindingID)
        var engine = try ReviewRevisionTransportEngine(remote: remote, cache: scoped, context: .init(selection))
        let paging = engine.cache.appendingPathComponent("transfer-cursor.json")
        try WorkspaceIO.rejectSymlinks(paging)
        if FileManager.default.fileExists(atPath: paging.path) {
            let raw = try ReviewSyncIO.read(paging, limit: 4096)
            try selection.validate(marker: raw)
            
            let scan = try WorkspaceIO.integer(raw, field: "scan_offset"), upload = try WorkspaceIO.integer(raw, field: "upload_offset")
            guard (0...100_000).contains(scan), (0...100_000).contains(upload) else { throw WorkspaceError.invalid("family paging offset") }
            engine.pagingOffsets = (Int(scan), Int(upload))
        }
        self.remote = engine.remote; self.cache = engine.cache; self.selection = selection; self.engine = engine
    }
    public func poll(outgoing: [ReviewNativeRevision], limit: Int = 128) throws -> ReviewRevisionTransportPoll {
        let result = try engine.poll(outgoing: outgoing, limit: limit)
        // Callers recreate this actor for each transfer/refresh. Commit progress
        // only after a completed bounded poll, retaining retries on interruption.
        var paging = selection.document
        paging["scan_offset"] = engine.pagingOffsets.scan
        paging["upload_offset"] = engine.pagingOffsets.upload
        try WorkspaceIO.rejectSymlinks(cache.appendingPathComponent("transfer-cursor.json"))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(paging), to: cache.appendingPathComponent("transfer-cursor.json"))
        return result
    }
    public func cachedRevisions() throws -> [ReviewNativeRevision] {
        try ReviewRevisionTransportEngine.cachedRevisions(cache: cache, context: .init(selection))
    }
}

internal struct ReviewRevisionTransportContext: Sendable {
    let workspaceID: String, bindingID: String, hostID: String
    let initialSequence: Int64
    init(_ selection: ReviewFamilyBindingSelection) {
        workspaceID = selection.workspaceID; bindingID = selection.bindingID
        hostID = selection.hostID; initialSequence = selection.initialSequence
    }
    var markerName: String { "family.json" }
    var revisionsName: String { "revisions" }
    var objectsName: String { "objects" }
    var marker: [String: Any] {
        ["workspace_id": workspaceID, "binding_id": bindingID,
         "host_id": hostID, "initial_sequence": initialSequence]
    }
    func validateMarker(_ raw: Data) throws {
        let doc = try WorkspaceIO.object(raw)
        guard doc["workspace_id"] as? String == workspaceID, doc["binding_id"] as? String == bindingID,
              doc["host_id"] as? String == hostID,
              try WorkspaceIO.integer(raw, field: "initial_sequence") == initialSequence else {
            throw WorkspaceError.invalid("provider binding differs from local transport selection")
        }
    }
    func envelope(_ revision: ReviewNativeRevision) -> [String: Any] {
        var doc: [String: Any] = ["workspace_id": workspaceID, "binding_id": bindingID,
            "source_binding_id": bindingID, "revision_id": revision.origin.revisionID, "payload_hash": revision.origin.payloadHash]
        doc["host_id"] = hostID; doc["initial_sequence"] = initialSequence
        return doc
    }
    func validateEnvelope(_ raw: Data, revisionID: String?) throws {
        let doc = try WorkspaceIO.object(raw)
        guard doc["workspace_id"] as? String == workspaceID, doc["binding_id"] as? String == bindingID,
              doc["source_binding_id"] as? String == bindingID else { throw WorkspaceError.invalid("revision envelope context") }
        if let revisionID { guard doc["revision_id"] as? String == revisionID else { throw WorkspaceError.invalid("revision envelope filename") } }
        do {
            guard doc["host_id"] as? String == hostID,
                  try WorkspaceIO.integer(raw, field: "initial_sequence") == initialSequence else { throw WorkspaceError.invalid("family revision envelope selection") }
        }
    }
}
