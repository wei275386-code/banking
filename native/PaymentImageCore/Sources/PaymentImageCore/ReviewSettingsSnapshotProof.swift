import Foundation

/// Identity of the independently selected checkpoint. A pin alone grants no role.
public struct ReviewSettingsSnapshotPins: Sendable {
    public let workspaceID: String, bindingID: String, hostID: String, generation: String
    public init(workspaceID: String, bindingID: String, hostID: String, generation: String) throws {
        for value in [workspaceID, bindingID, hostID] { try WorkspaceIO.requireUUID(value, field: "settings proof pin") }
        try WorkspaceIO.requireHash(generation)
        self.workspaceID = workspaceID; self.bindingID = bindingID; self.hostID = hostID; self.generation = generation
    }
}

/// Whole-document causal values; no settings revision, transaction or permission
/// is created by encoding a validated pair.
public enum ReviewSettingsFieldDocuments {
    public struct Mapping: Sendable {
        public let statePath: String, snapshotPath: String, fieldKey: String
    }
    public static let mappings = [
        Mapping(statePath: "config/family-profile.json", snapshotPath: "family-profile.json", fieldKey: "settings/family-profile"),
        Mapping(statePath: "config/account-policies.json", snapshotPath: "account-policies.json", fieldKey: "settings/account-policies")
    ]
    public static func values(_ settings: HouseholdSettings) -> [String: String] {
        [mappings[0].fieldKey: String(decoding: settings.profileData, as: UTF8.self),
         mappings[1].fieldKey: String(decoding: settings.policiesData, as: UTF8.self)]
    }
    public static func proofRows(_ settings: HouseholdSettings) -> [[String: String]] {
        let fields = values(settings)
        return mappings.map { ["state_path": $0.statePath, "snapshot_path": $0.snapshotPath,
                               "field_key": $0.fieldKey, "sha256": WorkspaceIO.digest(Data(fields[$0.fieldKey]!.utf8))] }
    }
}

/// Settings-only baseline proof. Before activation the caller must separately
/// validate checkpoint ancestry, origin closure/replay, ordinary ledger membership,
/// assets and local context authority. This returns settings, never a capability.
/// Queued offline edits require a separate generation/queue-pinned projection.
public enum ReviewSettingsSnapshotProof {
    public static func validate(pins: ReviewSettingsSnapshotPins, checkpointRaw: Data, stateManifestRaw: Data,
                                businessProofRaw: Data, fieldStateRaw: Data, snapshotDocuments: [String: Data],
                                replayedValues: [String: String], replayedConflictKeys: Set<String>,
                                context: HouseholdSettingsContext) throws -> HouseholdSettings {
        let cp = try canonicalObject(checkpointRaw, required: ["workspace_id", "binding_id", "host_id", "sequence",
            "parent_generation", "min_reader_version", "min_writer_version", "files", "revision_frontier",
            "covered_revision_inventory", "included_requests", "request_results", "asset_manifest", "state"])
        let state = try canonicalObject(stateManifestRaw, required: ["workspace_id", "state_id", "local_revision", "files"], optional: ["parent_pointer"])
        let proof = try canonicalObject(businessProofRaw, required: ["purpose", "workspace_id", "binding_id", "host_id",
            "state_id", "local_revision", "state_manifest_hash", "request_results", "asset_manifest", "documents", "databases", "settings_documents"])
        let fields = try canonicalObject(fieldStateRaw, required: ["values", "observed", "frontier", "conflicts", "covered_revision_inventory"], optional: ["seed_values"])
        guard WorkspaceIO.digest(checkpointRaw) == pins.generation,
              try proof.string("purpose") == "client-reader" else { throw invalid("version or generation") }
        for (key, pin) in [("workspace_id", pins.workspaceID), ("binding_id", pins.bindingID), ("host_id", pins.hostID)] {
            guard try Data(cp.string(key).utf8) == Data(pin.utf8), try Data(proof.string(key).utf8) == Data(pin.utf8) else { throw invalid("selection") }
        }
        let sequence = try integer(cp, "sequence", minimum: 1), parent = try cp.raw("parent_generation")
        if sequence == 1 { guard parent == Data("null".utf8) else { throw invalid("initial parent") } }
        else if parent != Data("null".utf8) { try WorkspaceIO.requireHash(SettingsJSON.fragmentString(parent, maximum: 64)) }
        for key in ["min_reader_version", "min_writer_version"] { try minimumVersion(cp.string(key)) }
        let current = try SettingsJSON(cp.raw("state"), required: ["state_id", "local_revision", "state_manifest_hash"], allowAdditional: true)
        let stateID = try current.string("state_id", maximum: 16 * 1024 * 1024), revision = try integer(current, "local_revision")
        let manifestHash = try hash(current, "state_manifest_hash")
        guard try Data(state.string("state_id", maximum: 16 * 1024 * 1024).utf8) == Data(stateID.utf8),
              try Data(proof.string("state_id", maximum: 16 * 1024 * 1024).utf8) == Data(stateID.utf8),
              try integer(state, "local_revision") == revision, try integer(proof, "local_revision") == revision,
              try Data(state.string("workspace_id").utf8) == Data(pins.workspaceID.utf8),
              WorkspaceIO.digest(stateManifestRaw) == manifestHash, try hash(proof, "state_manifest_hash") == manifestHash else { throw invalid("state pin") }
        if state.keys.contains("parent_pointer"), try state.raw("parent_pointer") != Data("null".utf8) {
            let parent = try SettingsJSON(state.raw("parent_pointer"), required: ["workspace_id", "state_id", "local_revision", "state_manifest_hash"], allowAdditional: true)
            let parentRevision = try integer(parent, "local_revision")
            guard try Data(parent.string("workspace_id").utf8) == Data(pins.workspaceID.utf8),
                  try Data(parent.string("state_id", maximum: 16 * 1024 * 1024).utf8) != Data(stateID.utf8),
                  parentRevision < Int64.max, parentRevision + 1 == revision else { throw invalid("state parent pointer") }
            _ = try hash(parent, "state_manifest_hash")
        }
        let cpFiles = try hashMap(cp.raw("files")), stateFiles = try hashMap(state.raw("files"))
        for name in ["banking.sqlite3", "config/review-import-sources.json", "review/financial-review.json", "review/payment-evidence.json", "review/coverage.json", "operation-results.json"] {
            guard stateFiles[name] != nil else { throw invalid("state files") }
        }
        for name in ["financial-review.json", "payment-evidence.json"] { guard cpFiles[name] != nil else { throw invalid("report files") } }
        for (name, raw) in [("state-manifest.json", stateManifestRaw), ("business-proof.json", businessProofRaw), ("field-state.json", fieldStateRaw)] {
            guard cpFiles[name] == WorkspaceIO.digest(raw) else { throw invalid("metadata raw hash") }
        }
        for (key, name) in [("request_results", "request-results.json"), ("asset_manifest", "asset-manifest.json")] {
            let expected = try hash(cp, key)
            guard try hash(proof, key) == expected, cpFiles[name] == expected else { throw invalid("ledger/asset pin") }
        }
        guard try stateFiles["operation-results.json"] == hash(cp, "request_results"),
              try hash(fields, "covered_revision_inventory") == hash(cp, "covered_revision_inventory"),
              try strings(fields, "frontier") == strings(cp, "revision_frontier") else { throw invalid("state/causal pin") }
        _ = try strings(cp, "included_requests")
        let observed = try entries(fields.raw("observed"))
        for (_, raw) in observed { _ = try nonnegative(raw) }
        let conflicts = try entries(fields.raw("conflicts"))
        for (_, raw) in conflicts {
            guard let rows = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: []), rows.count >= 2, rows.count <= 100_000 else { throw invalid("conflict shape") }
            for raw in rows {
                let row = try SettingsJSON(raw, required: ["revision_id", "value", "source_binding_id"], allowAdditional: true)
                _ = try row.string("revision_id", maximum: 16 * 1024 * 1024)
                _ = try row.string("value", maximum: 16 * 1024 * 1024, allowEmpty: true)
                try WorkspaceIO.requireUUID(row.string("source_binding_id"), field: "conflict source")
            }
        }
        let supplied = try entries(fields.raw("values"))
        for (_, raw) in supplied { _ = try SettingsJSON.fragmentString(raw, maximum: 16 * 1024 * 1024, allowEmpty: true) }
        let mappings = ReviewSettingsFieldDocuments.mappings
        guard Set(snapshotDocuments.keys) == Set(mappings.map(\.snapshotPath)) else { throw invalid("exact settings files") }
        for mapping in mappings {
            let raw = snapshotDocuments[mapping.snapshotPath]!
            _ = try canonicalObject(raw, required: [], additional: true)
            guard !replayedConflictKeys.contains(mapping.fieldKey), !conflicts.contains(where: { $0.key == mapping.fieldKey }),
                  let value = replayedValues[mapping.fieldKey], let encoded = supplied.first(where: { $0.key == mapping.fieldKey })?.value,
                  try Data(SettingsJSON.fragmentString(encoded, maximum: 16 * 1024 * 1024, allowEmpty: true).utf8) == Data(value.utf8),
                  Data(value.utf8) == raw, stateFiles[mapping.statePath] == WorkspaceIO.digest(raw),
                  cpFiles[mapping.snapshotPath] == WorkspaceIO.digest(raw) else { throw invalid("missing/conflicting/unequal settings") }
        }
        let settings = try HouseholdSettings(profileData: snapshotDocuments[mappings[0].snapshotPath]!, policiesData: snapshotDocuments[mappings[1].snapshotPath]!, context: context)
        let expected = ReviewSettingsFieldDocuments.proofRows(settings)
        let rows = try proof.array("settings_documents", maximum: 2)
        var seen = Set<String>()
        for raw in rows {
            let row = try SettingsJSON(raw, required: ["state_path", "snapshot_path", "field_key", "sha256"])
            let path = try row.string("state_path")
            guard seen.insert(path).inserted, let expectedRow = expected.first(where: { $0["state_path"] == path }) else { throw invalid("settings document mapping") }
            for (key, value) in expectedRow { guard try Data(row.string(key).utf8) == Data(value.utf8) else { throw invalid("settings mapping value") } }
        }
        guard seen.count == 2 else { throw invalid("settings documents missing") }
        let documents = try proof.array("documents", maximum: 100_000)
        var seenHeads = Set<String>()
        for raw in documents {
            let row = try SettingsJSON(raw, required: [], allowAdditional: true)
            guard row.keys.contains("path") else { continue } // ordinary proof owner validates other rows
            let path = try row.string("path", maximum: 16 * 1024 * 1024)
            guard let expectedRow = expected.first(where: { $0["state_path"] == path }) else { continue }
            guard Set(row.keys) == ["path", "snapshot_path", "sha256"], seenHeads.insert(path).inserted,
                  try row.string("snapshot_path") == expectedRow["snapshot_path"], try row.string("sha256") == expectedRow["sha256"] else { throw invalid("ordinary settings head mapping") }
        }
        _ = try proof.array("databases", maximum: 256)
        return settings
    }
    private static func canonicalObject(_ raw: Data, required: [String], optional: [String] = [], additional: Bool = false) throws -> SettingsJSON {
        guard try ReleaseCanonicalJSON.canonicalize(raw: raw) == raw else { throw invalid("noncanonical bytes") }
        return try SettingsJSON(raw, required: required, optional: optional, allowAdditional: additional)
    }
    private static func entries(_ raw: Data) throws -> [(key: String, value: Data)] {
        let rows = try ReleaseCanonicalJSON.canonicalObjectEntries(raw: raw)
        guard rows.count <= 100_000 else { throw invalid("map budget") }
        return rows
    }
    private struct FileHashes {
        let values: [Data: String]
        subscript(_ path: String) -> String? { values[Data(path.utf8)] }
    }
    private static func hashMap(_ raw: Data) throws -> FileHashes {
        var result = [Data: String]()
        for (key, raw) in try entries(raw) {
            let components = key.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") && !$0.contains(":") }) else { throw invalid("relative file path") }
            let hash = try SettingsJSON.fragmentString(raw, maximum: 64)
            try WorkspaceIO.requireHash(hash)
            result[Data(key.utf8)] = hash
        }
        return FileHashes(values: result)
    }
    private static func hash(_ object: SettingsJSON, _ key: String) throws -> String {
        let value = try object.string(key, maximum: 64); try WorkspaceIO.requireHash(value); return value
    }
    private static func integer(_ object: SettingsJSON, _ key: String, minimum: Int64 = 0) throws -> Int64 {
        let value = try nonnegative(object.raw(key))
        guard value >= minimum else { throw invalid("integer minimum") }; return value
    }
    private static func nonnegative(_ raw: Data) throws -> Int64 {
        guard !raw.isEmpty, raw.allSatisfy({ (48...57).contains($0) }), let value = Int64(String(decoding: raw, as: UTF8.self)) else { throw invalid("integer kind/range") }
        return value
    }
    private static func strings(_ object: SettingsJSON, _ key: String) throws -> [Data] {
        let values = try object.array(key, maximum: 100_000).map { raw in
            Data(try SettingsJSON.fragmentString(raw, maximum: 16 * 1024 * 1024).utf8)
        }
        guard Set(values).count == values.count else { throw invalid("duplicate list value") }; return values
    }
    private static func minimumVersion(_ value: String) throws {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { throw invalid("version") }
        let numbers = try pieces.map { try nonnegative(Data($0.utf8)) }
        guard numbers == [1, 3, 0] || [Int64(1), 3, 0].lexicographicallyPrecedes(numbers) else { throw invalid("family minimum version") }
    }
    private static func invalid(_ reason: String) -> WorkspaceError { .invalid("settings snapshot: " + reason) }
}
