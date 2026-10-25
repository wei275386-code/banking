import Foundation

/// A user operation keeps one exact payload and one binding identity.
public struct ReviewRevisionOrigin: Sendable {
    public struct Key: Hashable, Sendable {
        public let sourceBindingID: String
        public let revisionID: String
        public let identityHash: String
    }
    public let key: Key
    public let sources: [String: Data]
    public let canonicalPayload: Data
    public let revision: ReviewRevision
    public var primaryHash: String { key.identityHash }
    public var sourceHashes: [String] { [primaryHash] }

    public init(sourceBindingID: String, sources: [Data]) throws {
        try WorkspaceIO.requireUUID(sourceBindingID, field: "origin binding")
        guard let raw = sources.first, raw.count <= 2 * 1024 * 1024,
              sources.count <= 128, sources.allSatisfy({ $0 == raw }) else {
            throw WorkspaceError.invalid("operation must have one exact payload")
        }
        let parsed = try ReviewNativeRevision(sourceBindingID: sourceBindingID, raw: raw)
        self.sources = [WorkspaceIO.digest(raw): raw]; canonicalPayload = raw
        revision = parsed.revision
        key = Key(sourceBindingID: sourceBindingID, revisionID: parsed.revision.id, identityHash: WorkspaceIO.digest(raw))
    }
    public func merged(with other: ReviewRevisionOrigin) throws -> ReviewRevisionOrigin {
        guard key == other.key, canonicalPayload == other.canonicalPayload else { throw WorkspaceError.invalid("origin identity collision") }
        return self
    }
    public func inventoryEntry() -> [String: Any] {
        ["source_binding_id": key.sourceBindingID, "revision_id": key.revisionID,
         "payload_hash": primaryHash, "parents": revision.parents ?? []]
    }
    public static func inventory(_ raw: Data, objects: [String: Data]) throws -> [ReviewRevisionOrigin] {
        try parseInventory(raw, objects: objects, sourceBindings: nil)
    }
    public static func inventory(_ raw: Data, objects: [String: Data], sourceBindings: Set<String>) throws -> [ReviewRevisionOrigin] {
        for binding in sourceBindings {
            try WorkspaceIO.requireUUID(binding, field: "origin binding")
        }
        return try parseInventory(raw, objects: objects, sourceBindings: sourceBindings)
    }
    private static func parseInventory(_ raw: Data, objects: [String: Data], sourceBindings: Set<String>?) throws -> [ReviewRevisionOrigin] {
        guard let entries = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["entries"]), entries.count <= 20_000 else { throw WorkspaceError.invalid("origin inventory resource limit") }
        var result = [ReviewRevisionOrigin](), identities = Set<String>()
        for entryRaw in entries {
            let entry = try WorkspaceIO.object(entryRaw)
            guard Set(entry.keys) == ["source_binding_id", "revision_id", "payload_hash", "parents"] else { throw WorkspaceError.invalid("origin inventory fields") }
            let hash = try WorkspaceIO.string(entry, "payload_hash")
            try WorkspaceIO.requireHash(hash)
            guard let source = objects[hash], WorkspaceIO.digest(source) == hash else { throw WorkspaceError.invalid("missing or corrupt origin payload") }
            let binding = try WorkspaceIO.string(entry, "source_binding_id")
            if let sourceBindings { guard sourceBindings.contains(binding) else { throw WorkspaceError.invalid("foreign origin binding") } }
            let origin = try ReviewRevisionOrigin(sourceBindingID: binding, sources: [source])
            guard entry["revision_id"] as? String == origin.key.revisionID,
                  entry["parents"] as? [String] == (origin.revision.parents ?? []) else { throw WorkspaceError.invalid("origin inventory differs from authenticated payload") }
            let identity = origin.key.sourceBindingID + "/" + origin.key.revisionID
            guard identities.insert(identity).inserted else { throw WorkspaceError.invalid("duplicate origin inventory identity") }
            result.append(origin)
        }
        return result
    }
    public static func inventoryBytes(_ origins: [ReviewRevisionOrigin]) throws -> Data {
        try WorkspaceIO.canonical(["entries": origins.sorted { ($0.key.sourceBindingID, $0.key.revisionID) < ($1.key.sourceBindingID, $1.key.revisionID) }.map { $0.inventoryEntry() }])
    }
}
