import Foundation

public struct ReviewRevision: Codable, Sendable {
    public let id: String
    public let device: String
    public let clock: Int
    public let values: [String: String]
    public let bases: [String: String]
    public let observed: [String: Int]?
    public let parents: [String]?
    public init(id: String, device: String, clock: Int, values: [String: String], bases: [String: String], observed: [String: Int]? = nil, parents: [String]? = nil) {
        self.id = id; self.device = device; self.clock = clock; self.values = values; self.bases = bases; self.observed = observed; self.parents = parents
    }
}
public struct ReviewRevisionMembership: Hashable, Sendable {
    public let sourceBindingID: String
    public let revisionID: String
    public let payloadHash: String
    public init(sourceBindingID: String, revisionID: String, payloadHash: String) {
        self.sourceBindingID = sourceBindingID; self.revisionID = revisionID; self.payloadHash = payloadHash
    }
}
public struct ReviewCheckpointBundle: Sendable {
    public let manifest: Data
    public let objects: [String: URL]
    public init(manifest: Data, objects: [String: URL]) { self.manifest = manifest; self.objects = objects }
}
