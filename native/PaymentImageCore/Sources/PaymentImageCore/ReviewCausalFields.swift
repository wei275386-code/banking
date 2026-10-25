import Foundation

public struct ReviewNativeRevision: Sendable {
    public let origin: ReviewRevisionMembership
    public let raw: Data
    public let revision: ReviewRevision
    /// Local verified interpretation context, not a rewritten envelope field.
    internal let verifiedOrigin: ReviewRevisionOrigin?
    public init(sourceBindingID: String, raw: Data) throws {
        try WorkspaceIO.requireUUID(sourceBindingID, field: "source binding")
        let doc = try WorkspaceIO.object(raw)
        guard Set(doc.keys).isSubset(of: ["id", "device", "clock", "values", "bases", "observed", "parents", "metadata"]),
              doc["metadata"] == nil || doc["metadata"] is [String: Any] else { throw WorkspaceError.invalid("operation fields") }
        let id = try WorkspaceIO.string(doc, "id"); try WorkspaceIO.requireUUID(id, field: "revision_id")
        let clock = try WorkspaceIO.integer(raw, field: "clock")
        guard clock > 0, clock <= Int64(Int.max), doc["values"] is [String: String], doc["bases"] is [String: String] else { throw WorkspaceError.invalid("native revision fields") }
        let revision = try JSONDecoder().decode(ReviewRevision.self, from: raw)
        guard !revision.device.isEmpty, Set(revision.parents ?? []).count == (revision.parents ?? []).count,
              !(revision.parents ?? []).contains(id) else { throw WorkspaceError.invalid("revision identity/parents") }
        for parent in revision.parents ?? [] { try WorkspaceIO.requireUUID(parent, field: "revision parent") }
        if let observed = try ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: ["observed"]), observed != Data("null".utf8) {
            for key in try WorkspaceIO.object(observed).keys { _ = try WorkspaceIO.integer(observed, field: key) }
        }
        for (key, value) in revision.values {
            try ReviewCausalFieldRules.validate(key: key, value: value, seed: false)
            if key == "catalog/@tree" {
                guard value != "null" else { throw WorkspaceError.invalid("catalog cannot be removed") }
                _ = try JSONDecoder().decode(CategoryCatalog.self, from: Data(value.utf8)).validated()
            }
        }
        for key in revision.bases.keys where key.hasPrefix("settings/") {
            guard ReviewSettingsFieldDocuments.mappings.contains(where: { $0.fieldKey == key }) else { throw WorkspaceError.invalid("unsupported settings base") }
        }
        self.raw = raw; self.revision = revision; self.verifiedOrigin = nil
        origin = ReviewRevisionMembership(sourceBindingID: sourceBindingID, revisionID: id, payloadHash: WorkspaceIO.digest(raw))
    }
    internal init(verified origin: ReviewRevisionOrigin) {
        self.origin = ReviewRevisionMembership(sourceBindingID: origin.key.sourceBindingID, revisionID: origin.key.revisionID, payloadHash: origin.primaryHash)
        self.raw = origin.sources[origin.primaryHash]!; self.revision = origin.revision; self.verifiedOrigin = origin
    }
    internal var rawSources: [String: Data] { verifiedOrigin?.sources ?? [origin.payloadHash: raw] }
}

public struct ReviewCausalFieldCheckpoint: Sendable {
    public struct Head: Sendable {
        public let revisionID: String; public let sourceBindingID: String
        public let device: String; public let clock: Int; public let value: String
    }
    public let values: [String: String]
    public let seedValues: [String: String]
    public let heads: [String: [Head]]
    public let observed: [String: Int]
    public let frontier: [String]
    public let revisions: [ReviewNativeRevision]
    public let inventory: Data
    public var inventoryHash: String { WorkspaceIO.digest(inventory) }
    public var conflicts: [String] { heads.filter { Set($0.value.map { Data($0.value.utf8) }).count > 1 }.keys.sorted() }
    public func fieldState() throws -> Data {
        let conflicts = heads.filter { Set($0.value.map { Data($0.value.utf8) }).count > 1 }.mapValues { heads in
            heads.map { ["revision_id": $0.revisionID, "value": $0.value, "source_binding_id": $0.sourceBindingID] }
        }
        // A baseline is not a synthetic user edit. Keep the operation closure for conflicts and deduplication.
        return try WorkspaceIO.canonical(["values": values, "seed_values": seedValues,
                                          "observed": observed, "frontier": frontier, "conflicts": conflicts,
                                          "covered_revision_inventory": inventoryHash])
    }
}

public enum ReviewCausalFieldPreparation: Sendable {
    case ready(ReviewCausalFieldCheckpoint)
    case waiting(ancestorIDs: Set<String>)
}

/// Pure local prepare; does not capture edits, rewrite source bytes, or acquire a
/// maintenance gate. All operations belong to the selected binding.
public enum ReviewCausalFields {
    public static func prepare(seedValues: [String: String], revisions: [ReviewNativeRevision],
                               selection: ReviewFamilyBindingSelection) throws -> ReviewCausalFieldPreparation {
        try replay(seedValues: seedValues, revisions: revisions, allowedBindings: [selection.bindingID])
    }
    internal static func replay(seedValues: [String: String], revisions: [ReviewNativeRevision],
                               allowedBindings: Set<String>) throws -> ReviewCausalFieldPreparation {
        guard revisions.count <= 20_000 else { throw WorkspaceError.invalid("causal replay resource limit") }
        guard revisions.reduce(0, { $0 + $1.raw.count }) <= 64 * 1024 * 1024,
              revisions.reduce(0, { $0 + $1.revision.values.count + ($1.revision.parents?.count ?? 0) }) <= 100_000 else {
            throw WorkspaceError.invalid("causal payload/edge resource limit")
        }
        for (key, value) in seedValues { try ReviewCausalFieldRules.validate(key: key, value: value, seed: true) }
        var byID = [String: ReviewNativeRevision](), deviceClocks = [String: String]()
        for revision in revisions {
            guard allowedBindings.contains(revision.origin.sourceBindingID) else { throw WorkspaceError.invalid("cross-binding operation") }
            let id = revision.revision.id
            if let prior = byID[id] {
                guard prior.origin == revision.origin else { throw WorkspaceError.invalid("same revision ID has different native bytes") }
                continue
            }
            let key = revision.revision.device + "/" + String(revision.revision.clock)
            guard deviceClocks.updateValue(id, forKey: key) == nil else { throw WorkspaceError.invalid("device clock identity collision") }
            byID[id] = revision
        }
        let missing = Set(byID.values.flatMap { $0.revision.parents ?? [] }).subtracting(byID.keys)
        guard missing.isEmpty else { return .waiting(ancestorIDs: missing) }
        let ordered = byID.values.sorted { ($0.revision.clock, $0.revision.device, $0.revision.id) < ($1.revision.clock, $1.revision.device, $1.revision.id) }
        var heads = [String: [ReviewCausalFieldCheckpoint.Head]](), observed = [String: Int]()
        var referenced = Set<String>()
        var ancestryWork = 0
        func isAncestor(_ target: String, parents: [String]) throws -> Bool {
            var pending = parents, seen = Set<String>()
            while let id = pending.popLast() {
                if id == target { return true }
                if seen.insert(id).inserted {
                    ancestryWork += 1
                    guard ancestryWork <= 1_000_000 else { throw WorkspaceError.invalid("causal ancestry work resource limit") }
                    pending.append(contentsOf: byID[id]?.revision.parents ?? [])
                }
            }
            return false
        }
        for origin in ordered {
            let revision = origin.revision
            for parent in revision.parents ?? [] {
                guard let prior = byID[parent], prior.revision.clock < revision.clock else { throw WorkspaceError.invalid("cyclic/nonmonotonic revision ancestry") }
                referenced.insert(parent)
            }
            observed[revision.device] = max(observed[revision.device] ?? 0, revision.clock)
            for (device, clock) in revision.observed ?? [:] { observed[device] = max(observed[device] ?? 0, clock) }
            for (key, rawValue) in revision.values {
                let value = String(decoding: try ReleaseCanonicalJSON.canonicalize(raw: Data(rawValue.utf8)), as: UTF8.self)
                var candidates = heads[key] ?? []
                try candidates.removeAll { head in
                    ancestryWork += 1
                    guard ancestryWork <= 1_000_000 else { throw WorkspaceError.invalid("causal candidate work resource limit") }
                    return try (revision.observed?[head.device] ?? 0) >= head.clock ||
                        (revision.device == head.device && revision.clock > head.clock) ||
                        isAncestor(head.revisionID, parents: revision.parents ?? [])
                }
                candidates.append(ReviewCausalFieldCheckpoint.Head(revisionID: revision.id, sourceBindingID: origin.origin.sourceBindingID,
                                                                  device: revision.device, clock: revision.clock, value: value))
                heads[key] = candidates
            }
        }
        var values = seedValues
        for (key, candidates) in heads {
            let sorted = candidates.sorted { ($0.clock, $0.device, $0.revisionID) < ($1.clock, $1.device, $1.revisionID) }
            heads[key] = sorted
            if let winner = sorted.last {
                // Parameter null means explicitly unset.
                let explicitUnset = key.hasPrefix("parameter/")
                if winner.value == "null" && !explicitUnset { values.removeValue(forKey: key) }
                else { values[key] = winner.value }
            }
        }
        let frontier = byID.keys.filter { !referenced.contains($0) }.sorted()
        let entries: [[String: Any]] = ordered.map { origin in
            origin.verifiedOrigin?.inventoryEntry() ?? ["source_binding_id": origin.origin.sourceBindingID, "revision_id": origin.origin.revisionID, "payload_hash": origin.origin.payloadHash,
             "parents": origin.revision.parents ?? []]
        }
        let inventory = try WorkspaceIO.canonical(["entries": entries])
        return .ready(ReviewCausalFieldCheckpoint(values: values, seedValues: seedValues, heads: heads, observed: observed,
                                                  frontier: frontier, revisions: ordered, inventory: inventory))
    }
}
