import Foundation

/// Shared transport contract for the editor, workspace validation and sync.
/// Unversioned documents remain readable; version 1 adds an explicit marker.
public struct CompletionWorkflow: Codable, Sendable {
    public let datasetID: String
    public let deferred: [String]

    public init(datasetID: String, deferred: [String]) {
        self.datasetID = datasetID
        self.deferred = deferred
    }

    public static func decode(_ raw: Data) throws -> Self {
        let keys = Set(try ReleaseCanonicalJSON.canonicalObjectKeys(raw: raw))
        guard keys.isSuperset(of: ["datasetID", "deferred"]),
              keys.isSubset(of: ["datasetID", "deferred", "schemaVersion", "extra", "metadata"]) else {
            throw WorkspaceError.invalid("completion workflow fields")
        }
        if keys.contains("schemaVersion") {
            guard try WorkspaceIO.integer(raw, field: "schemaVersion") == 1 else {
                throw WorkspaceError.unsupportedVersion("completion workflow schemaVersion")
            }
        }
        let value = try JSONDecoder().decode(Self.self, from: raw)
        guard !value.datasetID.isEmpty, Set(value.deferred).count == value.deferred.count,
              value.deferred.allSatisfy({ !$0.isEmpty }) else {
            throw WorkspaceError.invalid("completion workflow identities")
        }
        return value
    }
}
