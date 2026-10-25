import Foundation
import CryptoKit

/// Verifies current business effects against one pinned, committed workspace.
/// Receipts and lifecycle journals never substitute for this check.
public enum ReviewWorkspaceMembership {
    public static func validate(state: StateHandle) throws {
        try WorkspaceIO.validateManifest(state, validateFiles: true)
        try validate(root: state.root, ledgerRaw: WorkspaceIO.read(state.operationResults),
                     workspaceID: state.pointer.workspaceID, stateID: state.pointer.stateID)
    }

    /// Also used by transaction.prepare's staging business validator. Call after
    /// sealing/closing writers; this function never modifies SQLite or JSON.
    public static func validate(root: URL, ledgerRaw: Data, workspaceID: String, stateID: String) throws {
        try validate(ledgerRaw: ledgerRaw, workspaceID: workspaceID, stateID: stateID, entities: currentEntities(root: root)) { input in
            let path = try WorkspaceIO.string(input, "source_path"), hash = try WorkspaceIO.string(input, "sha256")
            guard try WorkspaceIO.hash(WorkspaceIO.safeChild(root, path)) == hash else { throw WorkspaceError.invalid("retained result source is missing or changed") }
        }
    }
    /// Internal pure ledger verifier reused by the client reader proof. Its
    /// retention attestation must never be used for host or restore validation.
    internal static func validate(ledgerRaw: Data, workspaceID: String, stateID: String, entities: [String: String],
                                  verifyRetainedInput: ([String: Any]) throws -> Void) throws {
        try WorkspaceIO.validateLedger(ledgerRaw, workspaceID: workspaceID, stateID: stateID)
        let results = try ReleaseCanonicalJSON.canonicalArrayElements(raw: ledgerRaw, atObjectKeys: ["results"]) ?? []
        var effects = [String: [String: Any]](), superseded = Set<String>(), requests = [String: [String: Any]]()
        for resultRaw in results {
            let result = try WorkspaceIO.object(resultRaw)
            guard let membership = result["membership"] as? [[String: Any]], !membership.isEmpty else {
                throw WorkspaceError.invalid("result lacks verifiable business membership")
            }
            let requestID = try WorkspaceIO.string(result, "request_id")
            let inputs = result["inputs"] as? [[String: Any]] ?? []
            let parentID = result["parent_request_id"] as? String
            if let parentValue = result["parent_request_id"], !(parentValue is NSNull), parentID?.isEmpty != false { throw WorkspaceError.invalid("repair parent identity") }
            if let parentID {
                guard let parent = requests[parentID], parent["outcome"] as? String == "partial", inputs.count == 1,
                      let parents = parent["inputs"] as? [[String: Any]] else { throw WorkspaceError.invalid("repair requires earlier partial request") }
                let selected = inputs[0], id = try WorkspaceIO.string(selected, "input_id")
                let candidates = parents.filter { $0["input_id"] as? String == id }
                guard candidates.count == 1, candidates[0]["outcome"] as? String == "pending", selected["outcome"] as? String == "success" else { throw WorkspaceError.invalid("repair is not an earlier pending input") }
                for field in ["sha256", "kind", "required_financial", "source_path"] {
                    guard try fragment(selected, field) == fragment(candidates[0], field) else { throw WorkspaceError.invalid("repair source identity changed") }
                }
                let key = try digest([workspaceID, parentID, id, "projected"])
                guard requestID == (try uuidV5(namespace: workspaceID, name: "request:" + key)),
                      result["operation_id"] as? String == (try uuidV5(namespace: workspaceID, name: "operation:" + key)) else { throw WorkspaceError.invalid("repair operation identity is not stable") }
            }
            var expectedStages = [String: String](), identity = [[String: Any]]()
            for input in inputs {
                let path = try WorkspaceIO.string(input, "source_path"), hash = try WorkspaceIO.string(input, "sha256")
                try WorkspaceIO.requireHash(hash)
                let kind = try WorkspaceIO.string(input, "kind")
                guard path.hasPrefix((kind == "review" ? "inputs/" : "sources/") + hash + "/") else { throw WorkspaceError.invalid("retained source namespace") }
                try verifyRetainedInput(input)
                let stages = input["completed_stages"] as? [String] ?? []
                guard stages == (input["outcome"] as? String == "pending" ? ["retained"] : ["retained", "projected"]) else { throw WorkspaceError.invalid("input stages differ from outcome") }
                let id = try WorkspaceIO.string(input, "input_id")
                for stage in stages where parentID == nil || stage != "retained" {
                    let key = "input-stage:" + (try digest([parentID ?? requestID, id, stage]))
                    expectedStages[key] = try digest(["input_id": id, "sha256": hash, "stage": stage])
                }
                identity.append(["input_id": id, "sha256": hash, "kind": kind, "required_financial": input["required_financial"]!])
            }
            guard result["input_hash"] as? String == (try digest(identity)) else { throw WorkspaceError.invalid("result input identity hash") }
            let stageEffects = membership.filter { $0["kind"] as? String == "input-stage" }
            var actualStages = [String: String]()
            for effect in stageEffects {
                let key = try WorkspaceIO.string(effect, "key"), hash = try WorkspaceIO.string(effect, "digest")
                guard actualStages.updateValue(hash, forKey: key) == nil else { throw WorkspaceError.invalid("duplicate input stage") }
            }
            guard actualStages == expectedStages else { throw WorkspaceError.invalid("input-stage membership does not authenticate retained stages") }
            var introduced = [String: [String: Any]](), resultEntities = Set<String>()
            for effect in membership {
                let key = try WorkspaceIO.string(effect, "key")
                guard effects[key] == nil, introduced[key] == nil else { throw WorkspaceError.invalid("duplicate global effect") }
                let kind = try WorkspaceIO.string(effect, "kind"), digest = try WorkspaceIO.string(effect, "digest")
                try WorkspaceIO.requireHash(digest)
                if kind == "input-stage" {
                    guard effect["entity_key"] == nil, (effect["supersedes"] as? [String] ?? []).isEmpty,
                          expectedStages[key] == digest else { throw WorkspaceError.invalid("input-stage cannot invent a business entity or supersession") }
                    introduced[key] = effect; continue
                }
                let entity = try WorkspaceIO.string(effect, "entity_key")
                guard resultEntities.insert(entity).inserted else { throw WorkspaceError.invalid("duplicate result entity") }
                guard entity.hasPrefix("document:") || entity.hasPrefix("record:") || entity.hasPrefix("database:") ||
                        entity.hasPrefix("table:") || entity.hasPrefix("table-schema:") else {
                    throw WorkspaceError.unsupportedVersion("unverifiable effect entity " + entity)
                }
                if kind == "tombstone" {
                    let expected = WorkspaceIO.digest(try WorkspaceIO.canonical(["entity": entity, "deleted": true]))
                    guard digest == expected, let prior = effect["supersedes"] as? [String], !prior.isEmpty else {
                        throw WorkspaceError.invalid("tombstone requires exact digest and prior same-entity effect")
                    }
                } else {
                    guard ["record", "revision"].contains(kind), effect["tombstone"] as? Bool != true else {
                        throw WorkspaceError.invalid("effect kind or tombstone")
                    }
                }
                // The dictionary contains *earlier results only*. Adding this
                // result after its whole membership excludes self/later edges.
                for previousKey in effect["supersedes"] as? [String] ?? [] {
                    guard let previous = effects[previousKey], previous["entity_key"] as? String == entity else {
                        throw WorkspaceError.invalid("supersession requires earlier result with same entity")
                    }
                    superseded.insert(previousKey)
                }
                introduced[key] = effect
            }
            guard !resultEntities.isEmpty else { throw WorkspaceError.invalid("result lacks verifiable business entity membership") }
            effects.merge(introduced) { _, new in new }
            guard requests.updateValue(result, forKey: requestID) == nil else { throw WorkspaceError.invalid("duplicate historical request") }
        }
        var currentEntityHeads = Set<String>()
        for (key, effect) in effects where !superseded.contains(key) {
            if effect["kind"] as? String == "input-stage" { continue }
            let entity = try WorkspaceIO.string(effect, "entity_key")
            guard currentEntityHeads.insert(entity).inserted else { throw WorkspaceError.invalid("multiple effective business heads without supersession") }
            if effect["kind"] as? String == "tombstone" {
                guard entities[entity] == nil else { throw WorkspaceError.invalid("tombstoned entity is present") }
            } else {
                guard entities[entity] == effect["digest"] as? String else { throw WorkspaceError.invalid("current effect missing or changed: " + entity) }
            }
        }
    }

    private static func digest(_ value: Any) throws -> String {
        WorkspaceIO.digest(try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])))
    }
    private static func fragment(_ object: [String: Any], _ key: String) throws -> Data? {
        try ReleaseCanonicalJSON.canonicalFragment(raw: WorkspaceIO.canonical(object), atObjectKeys: [key])
    }
    private static func uuidV5(namespace: String, name: String) throws -> String {
        guard var uuid = UUID(uuidString: namespace)?.uuid else { throw WorkspaceError.invalid("repair namespace") }
        var bytes = withUnsafeBytes(of: &uuid) { Data($0) }; bytes.append(Data(name.utf8))
        var hash = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x50; hash[8] = (hash[8] & 0x3f) | 0x80
        let text = hash.map { String(format: "%02x", $0) }.joined()
        return [String(text.prefix(8)), String(text.dropFirst(8).prefix(4)), String(text.dropFirst(12).prefix(4)), String(text.dropFirst(16).prefix(4)), String(text.dropFirst(20))].joined(separator: "-")
    }

    /// Hash contracts match workspace_effects.py and NativeWorkspaceEffects.
    /// Source assets are verified via retained input references, not DB page hashes.
    public static func currentEntities(root: URL) throws -> [String: String] {
        var entities = [String: String]()
        let members = try WorkspaceIO.regularFiles(root)
        guard members.count <= 100_000 else { throw WorkspaceError.invalid("effect state resource limit") }
        for path in members {
            if ["state-manifest.json", "operation-results.json", "review/field-state.json", "review/revision-inventory.json"].contains(path) ||
                ["sources/", "inputs/", "review/materials/", "review/ocr/", "review/videos/", "history/edits/"].contains(where: path.hasPrefix) { continue }
            try autoreleasepool {
                guard !path.hasSuffix("-wal"), !path.hasSuffix("-shm"), !path.hasSuffix("-journal") else { throw WorkspaceError.invalid("effect state has open SQLite sidecar") }
                let file = try WorkspaceIO.safeChild(root, path)
                if try WorkspaceIO.isSQLite(file) {
                    let database = try NativeWorkspaceEffects.database(file, relative: path)
                    guard Set(entities.keys).isDisjoint(with: Set(database.keys)) else { throw WorkspaceError.invalid("duplicate database effect identity") }
                    entities.merge(database) { _, new in new }
                } else if path.hasSuffix(".json") {
                    let limit = WorkspaceBusinessValidator.documentLimit(path)
                    let raw = try WorkspaceIO.read(file, limit: Int64(limit))
                    _ = try ReleaseCanonicalJSON.canonicalize(raw: raw, inputLimit: limit)
                    entities["document:" + path] = WorkspaceIO.digest(raw)
                    if path == "review/financial-review.json" {
                        guard let records = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["records"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) else { throw WorkspaceError.invalid("financial records") }
                        for recordRaw in records {
                            let id = try WorkspaceIO.string(WorkspaceIO.object(recordRaw, inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes), "id"), entity = "record:" + id
                            guard entities[entity] == nil else { throw WorkspaceError.invalid("duplicate stable record identity") }
                            entities[entity] = WorkspaceIO.digest(recordRaw)
                        }
                    }
                }
            }
        }
        return entities
    }
}
