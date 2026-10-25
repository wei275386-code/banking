import Foundation

/// Content validation only: no ancestry, lineage/local qualification, provider
/// selection commit or host/processor/backup capability is represented here.
public struct ReviewValidatedFamilyPayload: Sendable {
    public let generation: String, manifest: Data
    public let fields: ReviewSettingsCausalCheckpoint
    public let coveredRevisions: Set<ReviewRevisionMembership>, successfulRequests: Set<String>
    public let requiredObjects: Set<String>, optionalOriginalObjects: Set<String>
    public let resolved: [String: URL]
    fileprivate init(generation: String, manifest: Data, fields: ReviewSettingsCausalCheckpoint,
                     coveredRevisions: Set<ReviewRevisionMembership>, successfulRequests: Set<String>,
                     requiredObjects: Set<String>, optionalOriginalObjects: Set<String>, resolved: [String: URL]) {
        self.generation = generation; self.manifest = manifest; self.fields = fields
        self.coveredRevisions = coveredRevisions; self.successfulRequests = successfulRequests
        self.requiredObjects = requiredObjects; self.optionalOriginalObjects = optionalOriginalObjects; self.resolved = resolved
    }
}
public enum ReviewFamilyPayloadPreparation: Sendable {
    case ready(ReviewValidatedFamilyPayload)
    case waiting(objectHashes: Set<String>, ancestorIDs: Set<String>)
    case conflicted(settingsFields: Set<String>)
}

/// Store-facing pure content boundary. Every consumed object is hash checked;
/// a caller-supplied protocol map/business context still needs independent local
/// qualification. This API never downloads, copies, publishes or activates.
public enum ReviewFamilySnapshotPayload {
    private struct Missing: Error { let hash: String }
    public static func prepare(selection: ReviewFamilyBindingSelection, generation: String, manifest: Data,
                               objects: [String: URL], sourceBindings: Set<String>, context: HouseholdSettingsContext,
                               readerVersion: String = "1.3.0") throws -> ReviewFamilyPayloadPreparation {
        try prepare(selection: selection, generation: generation, manifest: manifest, sourceBindings: sourceBindings, context: context,
            readerVersion: readerVersion, resolver: { hash, _ in
                guard let file = objects[hash] else { throw Missing(hash: hash) }; return file
            })
    }
    /// The Store resolver downloads only objects actually requested by validated
    /// metadata, at the narrow role-specific limit. Public map entry stays pure.
    internal static func prepare(selection: ReviewFamilyBindingSelection, generation: String, manifest: Data,
                                 sourceBindings: Set<String>, context: HouseholdSettingsContext, readerVersion: String,
                                 resolver: (String, Int64) throws -> URL) throws -> ReviewFamilyPayloadPreparation {
        do {
            return try validate(selection: selection, generation: generation, manifest: manifest,
                sourceBindings: sourceBindings, context: context, readerVersion: readerVersion, resolver: resolver)
        } catch let missing as Missing { return .waiting(objectHashes: [missing.hash], ancestorIDs: []) }
    }
    private static func validate(selection: ReviewFamilyBindingSelection, generation: String, manifest: Data,
                                 sourceBindings: Set<String>, context: HouseholdSettingsContext, readerVersion: String,
                                 resolver: (String, Int64) throws -> URL) throws -> ReviewFamilyPayloadPreparation {
        try Task.checkCancellation(); try WorkspaceIO.requireHash(generation)
        guard manifest.count <= ReviewClientBusinessProof.maximumBytes,
              WorkspaceIO.digest(manifest) == generation, try ReleaseCanonicalJSON.canonicalize(raw: manifest) == manifest else { throw WorkspaceError.invalid("family checkpoint canonical generation") }
        let cp = try WorkspaceIO.object(manifest)
        guard Set(cp.keys) == ["workspace_id", "binding_id", "host_id", "sequence", "parent_generation", "min_reader_version", "min_writer_version", "files", "revision_frontier", "covered_revision_inventory", "included_requests", "request_results", "asset_manifest", "state"] else { throw WorkspaceError.invalid("snapshot fields") }
        guard cp["workspace_id"] as? String == selection.workspaceID, cp["binding_id"] as? String == selection.bindingID,
              cp["host_id"] as? String == selection.hostID, sourceBindings.contains(selection.bindingID) else { throw WorkspaceError.invalid("family checkpoint identity/context") }
        let minimum = try version(WorkspaceIO.string(cp, "min_reader_version")), current = try version(readerVersion)
        let writer = try version(WorkspaceIO.string(cp, "min_writer_version")), floor: [Int64] = [1, 3, 0]
        guard !minimum.lexicographicallyPrecedes(floor), !writer.lexicographicallyPrecedes(floor), !current.lexicographicallyPrecedes(minimum) else { throw WorkspaceError.unsupportedVersion("family reader compatibility") }
        let sequence = try WorkspaceIO.integer(manifest, field: "sequence")
        guard sequence >= selection.initialSequence, let parent = cp["parent_generation"], parent is NSNull || parent is String,
              sequence != 1 || parent is NSNull else { throw WorkspaceError.invalid("family checkpoint sequence/parent") }
        if let parent = parent as? String { try WorkspaceIO.requireHash(parent) }
        guard let stateRaw = try ReleaseCanonicalJSON.canonicalFragment(raw: manifest, atObjectKeys: ["state"]) else { throw WorkspaceError.invalid("family state tuple") }
        let state = try WorkspaceIO.object(stateRaw), stateHash = try WorkspaceIO.string(state, "state_manifest_hash")
        try WorkspaceIO.requireUUID(WorkspaceIO.string(state, "state_id"), field: "family state id")
        _ = try WorkspaceIO.integer(stateRaw, field: "local_revision")
        var paths = try fileMap(fragment(manifest, "files"))
        let mandatory: Set<String> = ["financial-review.json", "payment-evidence.json", "field-state.json", "family-profile.json", "account-policies.json", "state-manifest.json", "business-proof.json", "request-results.json", "asset-manifest.json"]
        guard mandatory.isSubset(of: Set(paths.keys)), paths["checkpoint.json"] == nil, paths["revision-inventory.json"] == nil else { throw WorkspaceError.invalid("family snapshot paths") }
        for (path, hash) in [("state-manifest.json", stateHash), ("request-results.json", try WorkspaceIO.string(cp, "request_results")), ("asset-manifest.json", try WorkspaceIO.string(cp, "asset_manifest"))] {
            try WorkspaceIO.requireHash(hash); guard paths[path] == hash else { throw WorkspaceError.invalid("family metadata pin") }
        }
        let inventoryHash = try WorkspaceIO.string(cp, "covered_revision_inventory"); try WorkspaceIO.requireHash(inventoryHash)
        paths["revision-inventory.json"] = inventoryHash
        func object(_ hash: String, maximum: Int64 = Int64(ReviewClientBusinessProof.maximumBytes)) throws -> URL {
            try Task.checkCancellation(); try WorkspaceIO.requireHash(hash)
            do {
                let file = try resolver(hash, maximum)
                try ReviewContentObjectIO.verify(file, hash: hash, maximumBytes: maximum)
                return file
            } catch { if ReviewSyncIO.isMissing(error) { throw Missing(hash: hash) }; throw error }
        }
        var resolved = [String: URL]()
        for path in paths.keys.sorted() { resolved[path] = try object(paths[path]!, maximum: Int64(WorkspaceBusinessValidator.documentLimit(path))) }
        func raw(_ path: String) throws -> Data { try ReviewSyncIO.read(resolved[path]!, limit: WorkspaceBusinessValidator.documentLimit(path)) }
        let stateManifest = try raw("state-manifest.json"), stateDoc = try WorkspaceIO.object(stateManifest)
        
        let stateFiles = try fileMap(fragment(stateManifest, "files"))
        let exactStateFiles = Dictionary(uniqueKeysWithValues: stateFiles.map { (Data($0.key.utf8), $0.value) })
        guard stateDoc["workspace_id"] as? String == selection.workspaceID, stateDoc["state_id"] as? String == state["state_id"] as? String,
              try WorkspaceIO.integer(stateManifest, field: "local_revision") == WorkspaceIO.integer(stateRaw, field: "local_revision"),
              stateFiles["operation-results.json"] == paths["request-results.json"],
              stateFiles["review/field-state.json"] == paths["field-state.json"],
              stateFiles["review/revision-inventory.json"] == inventoryHash,
              stateFiles["review/financial-review.json"] == paths["financial-review.json"],
              stateFiles["review/payment-evidence.json"] == paths["payment-evidence.json"] else { throw WorkspaceError.invalid("family committed state projection") }
        let inventory = try raw("revision-inventory.json")
        guard let entries = try ReleaseCanonicalJSON.canonicalArrayElements(raw: inventory, atObjectKeys: ["entries"]), entries.count <= 20_000 else { throw WorkspaceError.invalid("family origin inventory") }
        var rawOrigins = [String: Data](), originBytes = 0
        for entry in entries {
            let doc = try WorkspaceIO.object(entry), aliases = [try WorkspaceIO.string(doc, "payload_hash")]
            for hash in aliases where rawOrigins[hash] == nil {
                let file = try object(hash, maximum: 2 * 1024 * 1024), bytes = try ReviewSyncIO.read(file, limit: 2 * 1024 * 1024)
                originBytes += bytes.count; guard originBytes <= 64 * 1024 * 1024 else { throw WorkspaceError.invalid("family origin byte budget") }
                rawOrigins[hash] = bytes; resolved["revision-origins/" + hash + ".json"] = file
            }
        }
        let origins = try ReviewRevisionOrigin.inventory(inventory, objects: rawOrigins, sourceBindings: sourceBindings)
        let fieldRaw = try raw("field-state.json"), field = try WorkspaceIO.object(fieldRaw)
        guard let seed = field["seed_values"] as? [String: String] else { throw WorkspaceError.invalid("family reader requires verified replay seed") }
        let qualified: ReviewSettingsCausalCheckpoint
        switch try ReviewSettingsCausalFields.prepareInventory(seedValues: seed, origins: origins, bindingID: selection.bindingID, context: context) {
        case .waiting(let ancestors): return .waiting(objectHashes: [], ancestorIDs: ancestors)
        case .conflicted(_, let fields): return .conflicted(settingsFields: Set(fields))
        case .ready(let ready): qualified = ready
        }
        let replayed = qualified.causal
        guard replayed.inventory == inventory, try replayed.fieldState() == fieldRaw,
              try replayed.frontier == ids(cp["revision_frontier"]) else { throw WorkspaceError.invalid("family complete causal replay differs") }
        let assetsRaw = try raw("asset-manifest.json"); 
        guard let assets = try ReleaseCanonicalJSON.canonicalArrayElements(raw: assetsRaw, atObjectKeys: ["assets"]), assets.count <= 100_000 else { throw WorkspaceError.invalid("family asset inventory") }
        var pathSpellings = Dictionary(uniqueKeysWithValues: resolved.keys.map { ($0, Data($0.utf8)) })
        var assetPaths = [Data: String](), required = Set(paths.values).union(rawOrigins.keys), optional = Set<String>()
        for raw in assets {
            let row = try SettingsJSON(raw, required: ["path", "sha256", "kind", "download", "required_financial"], allowAdditional: true)
            let path = try row.string("path", maximum: 4096), hash = try row.string("sha256", maximum: 64)
            try relative(path); try WorkspaceIO.requireHash(hash)
            if let spelling = pathSpellings[path] { guard spelling == Data(path.utf8) else { throw WorkspaceError.invalid("ambiguous Unicode asset path") } }
            pathSpellings[path] = Data(path.utf8)
            let kind = try row.string("kind"), policy = try row.string("download"), financial = try row.boolean("required_financial")
            guard paths[path] == nil, path != "checkpoint.json", !path.hasPrefix("revision-origins/"), assetPaths.updateValue(hash, forKey: Data(path.utf8)) == nil,
                  (exactStateFiles[Data(path.utf8)] == hash || exactStateFiles[Data(("review/" + path).utf8)] == hash), ["image", "text", "pdf", "csv", "xlsx", "video", "review"].contains(kind) else { throw WorkspaceError.invalid("family asset state/path") }
            if policy == "on-demand" {
                let original = try row.keys.contains("role") && row.string("role") == "original"
                guard (kind == "video" && !financial) || original else { throw WorkspaceError.invalid("family on-demand retention proof") }
                optional.insert(hash)
            } else {
                guard policy == "required" else { throw WorkspaceError.invalid("family asset download policy") }
                resolved[path] = try object(hash, maximum: 32 * 1024 * 1024 * 1024); required.insert(hash)
            }
        }
        for path in ["financial-review.json", "payment-evidence.json"] {
            var pending: [Any] = [try WorkspaceIO.object(raw(path), inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes)], visited = 0
            while let value = pending.popLast() {
                visited += 1; guard visited <= 2_000_000 else { throw WorkspaceError.invalid("family report reference budget") }
                if let doc = value as? [String: Any] {
                    if let path = doc["path"] as? String, let hash = doc["sha256"] as? String { guard assetPaths[Data(path.utf8)] == hash else { throw WorkspaceError.invalid("family undeclared report asset") } }
                    pending.append(contentsOf: doc.values)
                } else if let array = value as? [Any] { pending.append(contentsOf: array) }
            }
        }
        let proof = try ReviewClientBusinessProof.validate(selection: selection, generation: generation, manifest: manifest, resolved: resolved,
            replayedValues: replayed.values, replayedConflictKeys: Set(replayed.conflicts), context: context)
        var success = Set<String>()
        for result in proof.results {
            let doc = try WorkspaceIO.object(result)
            if doc["outcome"] as? String == "success" { success.insert(try WorkspaceIO.string(doc, "request_id")) }
        }
        guard success == Set(try ids(cp["included_requests"])) else { throw WorkspaceError.invalid("family included requests differ from current membership") }
        let membership = Set(origins.flatMap { origin in origin.sourceHashes.map { ReviewRevisionMembership(sourceBindingID: origin.key.sourceBindingID, revisionID: origin.key.revisionID, payloadHash: $0) } })
        return .ready(ReviewValidatedFamilyPayload(generation: generation, manifest: manifest, fields: qualified, coveredRevisions: membership,
            successfulRequests: success, requiredObjects: required, optionalOriginalObjects: optional, resolved: resolved))
    }
    private static func fragment(_ raw: Data, _ key: String) throws -> Data {
        guard let fragment = try ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: [key]) else { throw WorkspaceError.invalid("family missing map") }; return fragment
    }
    private static func fileMap(_ raw: Data) throws -> [String: String] {
        let entries = try ReleaseCanonicalJSON.canonicalObjectEntries(raw: raw)
        guard entries.count <= 100_000 else { throw WorkspaceError.invalid("family file map") }
        var map = [String: String]()
        for (path, rawHash) in entries {
            let hash = try SettingsJSON.fragmentString(rawHash, maximum: 64)
            try relative(path); try WorkspaceIO.requireHash(hash)
            guard map.updateValue(hash, forKey: path) == nil else { throw WorkspaceError.invalid("ambiguous Unicode file paths") }
        }
        return map
    }
    private static func relative(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") && !$0.contains(":") }) else { throw WorkspaceError.invalid("family relative path") }
    }
    private static func ids(_ value: Any?) throws -> [String] {
        guard let ids = value as? [String], ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count, ids.count <= 100_000 else { throw WorkspaceError.invalid("family identity list") }; return ids
    }
    private static func version(_ value: String) throws -> [Int64] {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && Int64($0) != nil }) else { throw WorkspaceError.invalid("family semantic version") }
        return parts.map { Int64($0)! }
    }
}
