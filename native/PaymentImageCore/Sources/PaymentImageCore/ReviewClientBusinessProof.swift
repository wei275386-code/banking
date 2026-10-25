import Foundation

/// Reader-only evidence issued by a locally authorized host after validation of
/// actual committed data. This compact proof cannot qualify a backup, restore or
/// processor role: input retention is attested, not downloaded by the reader.
public enum ReviewClientBusinessProof {
    public static let maximumBytes = 16 * 1024 * 1024
    internal static func build(state: StateHandle, selection: ReviewFamilyBindingSelection, settings: HouseholdSettingsState, assetManifestHash: String) throws -> Data {
        _ = try ReviewFieldDocuments.capture(state: state, settings: settings)
        return try build(state: state, identity: Identity(selection), assetManifestHash: assetManifestHash, settings: settings.settings)
    }
    private static func build(state: StateHandle, identity: Identity, assetManifestHash: String, settings: HouseholdSettings?) throws -> Data {
        guard state.pointer.workspaceID == identity.workspaceID else { throw WorkspaceError.invalid("reader build workspace") }
        try WorkspaceIO.requireHash(assetManifestHash)
        try ReviewWorkspaceMembership.validate(state: state)
        let ledger = try WorkspaceIO.read(state.operationResults), heads = try currentHeads(ledger)
        let files = try fileMap(WorkspaceIO.read(state.manifest)), needed = Set(heads.filter { $0.value["kind"] as? String != "tombstone" }.keys)
        var documents = [[String: Any]](), databases = [[String: Any]](), proofCost = 0
        for path in files.keys.sorted() {
            let file = try state.file(path)
            if try WorkspaceIO.isSQLite(file) {
                let database: [String: Any] = ["path": path, "sha256": files[path]!, "tables": try ReviewSQLiteReaderProof.build(file, relative: path, neededEntities: needed)]
                proofCost += try WorkspaceIO.canonical(database).count
                guard proofCost <= maximumBytes else { throw WorkspaceError.unsupportedVersion("reader database proof budget") }
                databases.append(database)
            } else if needed.contains("document:" + path) {
                guard path.hasSuffix(".json") else { throw WorkspaceError.invalid("reader document kind") }
                if let snapshot = snapshotPath(path) {
                    documents.append(["path": path, "sha256": files[path]!, "snapshot_path": snapshot])
                } else {
                    let encoded = try bounded(file).base64EncodedString(); proofCost += encoded.utf8.count
                    guard proofCost <= maximumBytes else { throw WorkspaceError.unsupportedVersion("reader document proof budget") }
                    documents.append(["path": path, "sha256": files[path]!, "raw_base64": encoded])
                }
            }
        }
        var document: [String: Any] = ["purpose": "client-reader", "workspace_id": identity.workspaceID,
            "binding_id": identity.bindingID, "host_id": identity.hostID, "state_id": state.pointer.stateID,
            "local_revision": state.pointer.localRevision, "state_manifest_hash": state.pointer.manifestHash,
            "request_results": WorkspaceIO.digest(ledger), "asset_manifest": assetManifestHash,
            "documents": documents, "databases": databases]
        if let settings { document["settings_documents"] = ReviewSettingsFieldDocuments.proofRows(settings) }
        let raw = try WorkspaceIO.canonical(document)
        guard raw.count <= maximumBytes else { throw WorkspaceError.unsupportedVersion("reader proof exceeds 16 MiB budget; source remains a host workspace") }
        // Recompute every compact entity and the whole ledger before publication.
        var resolved: [String: URL] = ["business-proof.json": state.root, "request-results.json": state.operationResults,
                                       "state-manifest.json": state.manifest, "financial-review.json": state.review.appendingPathComponent("financial-review.json")]
        resolved["payment-evidence.json"] = state.review.appendingPathComponent("payment-evidence.json")
        if settings != nil {
            for mapping in ReviewSettingsFieldDocuments.mappings { resolved[mapping.snapshotPath] = try state.file(mapping.statePath) }
        }
        let actual = try ReviewWorkspaceMembership.currentEntities(root: state.root)
        let proofEntities = try entities(raw: raw, stateFiles: files, resolved: resolved, heads: heads)
        for entity in heads.keys { guard proofEntities[entity] == actual[entity] else { throw WorkspaceError.invalid("reader proof differs from actual state: " + entity) } }
        return raw
    }
    /// Whole-ledger validation once per generation, not a per-result opaque Bool.
    /// Required metadata paths have already been raw-hash checked by the Store.
    /// Requires independently replayed fields. Payload owner verifies raw object
    /// closure, full replay, ancestry and protocol-map qualification separately.
    internal static func validate(selection: ReviewFamilyBindingSelection, generation: String, manifest: Data, resolved: [String: URL],
                                  replayedValues: [String: String], replayedConflictKeys: Set<String>, context: HouseholdSettingsContext) throws -> (results: Set<Data>, settings: HouseholdSettings) {
        let results = try validate(identity: Identity(selection), manifest: manifest, resolved: resolved)
        guard let state = resolved["state-manifest.json"], let proof = resolved["business-proof.json"], let fields = resolved["field-state.json"] else { throw WorkspaceError.invalid("reader settings metadata") }
        var documents = [String: Data]()
        for mapping in ReviewSettingsFieldDocuments.mappings {
            guard let file = resolved[mapping.snapshotPath] else { throw WorkspaceError.invalid("reader settings file") }
            documents[mapping.snapshotPath] = try bounded(file)
        }
        let settings = try ReviewSettingsSnapshotProof.validate(pins: .init(workspaceID: selection.workspaceID, bindingID: selection.bindingID, hostID: selection.hostID, generation: generation),
            checkpointRaw: manifest, stateManifestRaw: bounded(state), businessProofRaw: bounded(proof), fieldStateRaw: bounded(fields), snapshotDocuments: documents,
            replayedValues: replayedValues, replayedConflictKeys: replayedConflictKeys, context: context)
        return (results, settings)
    }
    private static func validate(identity: Identity, manifest: Data, resolved: [String: URL]) throws -> Set<Data> {
        guard let proofFile = resolved["business-proof.json"], let stateFile = resolved["state-manifest.json"],
              let resultsFile = resolved["request-results.json"], let assetsFile = resolved["asset-manifest.json"] else { throw WorkspaceError.invalid("checkpoint has no client business proof") }
        let raw = try bounded(proofFile), proof = try WorkspaceIO.object(raw), checkpoint = try WorkspaceIO.object(manifest)
        var expectedKeys: Set<String> = ["purpose", "workspace_id", "binding_id", "host_id", "state_id", "local_revision", "state_manifest_hash", "request_results", "asset_manifest", "documents", "databases"]
        expectedKeys.insert("settings_documents")
        guard try ReleaseCanonicalJSON.canonicalize(raw: raw) == raw, Set(proof.keys) == expectedKeys,
              checkpoint["workspace_id"] as? String == identity.workspaceID, checkpoint["binding_id"] as? String == identity.bindingID, checkpoint["host_id"] as? String == identity.hostID,
              proof["purpose"] as? String == "client-reader",
              proof["workspace_id"] as? String == identity.workspaceID, proof["binding_id"] as? String == identity.bindingID,
              proof["host_id"] as? String == identity.hostID,
              let state = checkpoint["state"] as? [String: Any], proof["state_id"] as? String == state["state_id"] as? String,
              proof["state_manifest_hash"] as? String == state["state_manifest_hash"] as? String,
              try WorkspaceIO.integer(raw, field: "local_revision") == WorkspaceIO.integer(WorkspaceIO.canonical(state), field: "local_revision"),
              proof["request_results"] as? String == checkpoint["request_results"] as? String,
              proof["asset_manifest"] as? String == checkpoint["asset_manifest"] as? String else { throw WorkspaceError.invalid("client proof identity") }
        let stateRaw = try bounded(stateFile), files = try fileMap(stateRaw), ledger = try bounded(resultsFile)
        guard let financial = resolved["financial-review.json"], let evidence = resolved["payment-evidence.json"] else { throw WorkspaceError.invalid("reader report pair") }
        try WorkspaceBusinessValidator.validateReportPair(financialRaw: ReviewSyncIO.read(financial, limit: WorkspaceBusinessValidator.maximumProjectionBytes), evidenceRaw: ReviewSyncIO.read(evidence, limit: WorkspaceBusinessValidator.maximumProjectionBytes))
        guard WorkspaceIO.digest(stateRaw) == proof["state_manifest_hash"] as? String, WorkspaceIO.digest(ledger) == proof["request_results"] as? String else { throw WorkspaceError.invalid("client proof raw anchor") }
        let heads = try currentHeads(ledger), values = try entities(raw: raw, stateFiles: files, resolved: resolved, heads: heads)
        let assets = try WorkspaceIO.object(bounded(assetsFile))["assets"] as? [[String: Any]] ?? []
        var assetPaths = [Data: String]()
        for asset in assets {
            let path = try WorkspaceIO.string(asset, "path"), hash = try WorkspaceIO.string(asset, "sha256")
            guard assetPaths.updateValue(hash, forKey: Data(path.utf8)) == nil else { throw WorkspaceError.invalid("duplicate reader asset path") }
        }
        try ReviewWorkspaceMembership.validate(ledgerRaw: ledger, workspaceID: identity.workspaceID,
                                               stateID: WorkspaceIO.string(proof, "state_id"), entities: values) { input in
            let path = try WorkspaceIO.string(input, "source_path"), hash = try WorkspaceIO.string(input, "sha256")
            guard files[path] == hash, assetPaths[Data(path.utf8)] == hash else { throw WorkspaceError.invalid("input-retention attestation not in exact state/asset path") }
        }
        return Set(try ReleaseCanonicalJSON.canonicalArrayElements(raw: ledger, atObjectKeys: ["results"]) ?? [])
    }
    private struct Identity {
            let workspaceID: String, bindingID: String, hostID: String
        init(_ selection: ReviewFamilyBindingSelection) { workspaceID = selection.workspaceID; bindingID = selection.bindingID; hostID = selection.hostID }
    }
    private static func snapshotPath(_ statePath: String) -> String? {
        if ["review/financial-review.json", "review/payment-evidence.json"].contains(statePath) { return String(statePath.dropFirst(7)) }
        return ReviewSettingsFieldDocuments.mappings.first(where: { $0.statePath == statePath })?.snapshotPath
    }
    private static func bounded(_ file: URL) throws -> Data { try ReviewSyncIO.read(file, limit: maximumBytes) }
    private static func fileMap(_ raw: Data) throws -> [String: String] {
        guard let files = try WorkspaceIO.object(raw)["files"] as? [String: String], files.count <= 100_000 else { throw WorkspaceError.invalid("reader state file map") }
        for (path, hash) in files { _ = try WorkspaceIO.safeChild(URL(fileURLWithPath: "/reader-proof"), path); try WorkspaceIO.requireHash(hash) }
        return files
    }
    private static func currentHeads(_ ledger: Data) throws -> [String: [String: Any]] {
        let results = try ReleaseCanonicalJSON.canonicalArrayElements(raw: ledger, atObjectKeys: ["results"]) ?? []
        guard results.count <= 20_000 else { throw WorkspaceError.invalid("reader result budget") }
        var all = [String: [String: Any]](), superseded = Set<String>()
        for raw in results {
            let result = try WorkspaceIO.object(raw)
            guard let membership = result["membership"] as? [[String: Any]] else { throw WorkspaceError.invalid("reader membership") }
            for effect in membership {
                let key = try WorkspaceIO.string(effect, "key")
                guard all.updateValue(effect, forKey: key) == nil else { throw WorkspaceError.invalid("reader duplicate effect") }
                superseded.formUnion(effect["supersedes"] as? [String] ?? [])
            }
            guard all.count <= 100_000 else { throw WorkspaceError.invalid("reader effect budget") }
        }
        var heads = [String: [String: Any]]()
        for (key, value) in all where !superseded.contains(key) && value["kind"] as? String != "input-stage" {
            let entity = try WorkspaceIO.string(value, "entity_key")
            guard heads.updateValue(value, forKey: entity) == nil else { throw WorkspaceError.invalid("reader concurrent business heads") }
        }
        return heads
    }
    private static func digest(_ value: Any) throws -> String {
        WorkspaceIO.digest(try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])))
    }
    private static func entities(raw: Data, stateFiles: [String: String], resolved: [String: URL],
                                 heads: [String: [String: Any]]) throws -> [String: String] {
        let proof = try WorkspaceIO.object(raw)
        guard let documents = proof["documents"] as? [[String: Any]], let databases = proof["databases"] as? [[String: Any]],
              documents.count <= 100_000, databases.count <= 256,
              let financial = resolved["financial-review.json"] else { throw WorkspaceError.invalid("reader entity proof shape") }
        let exactStateFiles = Dictionary(uniqueKeysWithValues: stateFiles.map { (Data($0.key.utf8), $0.value) })
        var values = [String: String]()
        for path in stateFiles.keys where path.hasSuffix(".json") { values["document:" + path] = stateFiles[path]! }
        let records = try ReleaseCanonicalJSON.canonicalArrayElements(raw: ReviewSyncIO.read(financial, limit: WorkspaceBusinessValidator.maximumProjectionBytes), atObjectKeys: ["records"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? []
        guard records.count <= 100_000 else { throw WorkspaceError.invalid("reader record budget") }
        for record in records {
            let entity = "record:" + (try WorkspaceIO.string(WorkspaceIO.object(record, inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes), "id"))
            guard values.updateValue(WorkspaceIO.digest(record), forKey: entity) == nil else { throw WorkspaceError.invalid("reader duplicate record") }
        }
        var seenDocuments = Set<String>(), seenDBs = Set<String>(), rowTotal = 0
        for document in documents {
            let path = try WorkspaceIO.string(document, "path"), hash = try WorkspaceIO.string(document, "sha256")
            guard seenDocuments.insert(path).inserted, exactStateFiles[Data(path.utf8)] == hash,
                  heads["document:" + path]?["kind"] as? String != "tombstone" else { throw WorkspaceError.invalid("reader document inventory") }
            let content: Data
            if let snapshotPath = document["snapshot_path"] as? String {
                guard Set(document.keys) == ["path", "sha256", "snapshot_path"], snapshotPath == self.snapshotPath(path),
                      let file = resolved[snapshotPath] else { throw WorkspaceError.invalid("reader projection proof") }
                content = try ReviewSyncIO.read(file, limit: WorkspaceBusinessValidator.documentLimit(path))
            } else {
                guard !ReviewSettingsFieldDocuments.mappings.contains(where: { $0.statePath == path }) else { throw WorkspaceError.invalid("settings head requires snapshot mapping") }
                guard Set(document.keys) == ["path", "sha256", "raw_base64"], let encoded = document["raw_base64"] as? String,
                      let bytes = Data(base64Encoded: encoded) else { throw WorkspaceError.invalid("reader document bytes") }
                content = bytes
            }
            _ = try ReleaseCanonicalJSON.canonicalize(raw: content, inputLimit: WorkspaceBusinessValidator.documentLimit(path))
            guard WorkspaceIO.digest(content) == hash else { throw WorkspaceError.invalid("reader document digest") }
        }
        let neededDocuments = Set(heads.filter { $0.key.hasPrefix("document:") && $0.value["kind"] as? String != "tombstone" }.keys.map { String($0.dropFirst(9)) })
        guard Set(neededDocuments.map { Data($0.utf8) }) == Set(seenDocuments.map { Data($0.utf8) }) else { throw WorkspaceError.invalid("reader document proof is not exact current membership") }
        var seenRows = Set<String>()
        for database in databases {
            let path = try WorkspaceIO.string(database, "path"), hash = try WorkspaceIO.string(database, "sha256")
            guard Set(database.keys) == ["path", "sha256", "tables"], exactStateFiles[Data(path.utf8)] == hash, seenDBs.insert(path).inserted,
                  let tables = database["tables"] as? [[String: Any]], tables.count <= 10_000 else { throw WorkspaceError.invalid("reader database domain") }
            var seenTables = Set<String>()
            for table in tables {
                let name = try WorkspaceIO.string(table, "name")
                guard Set(table.keys) == ["name", "sql", "columns", "selected_columns", "primary_keys", "key_inventory", "rows", "row_counts"],
                      seenTables.insert(name).inserted, let columns = table["columns"] as? [[Any]],
                      let selected = table["selected_columns"] as? [String], Set(selected).count == selected.count,
                      let primary = table["primary_keys"] as? [String], Set(primary).count == primary.count,
                      let keys = table["key_inventory"] as? [String], Set(keys).count == keys.count,
                      let rows = table["rows"] as? [[String: Any]], let counts = table["row_counts"] as? [String: Any],
                      let sql = table["sql"], sql is String || sql is NSNull else { throw WorkspaceError.invalid("reader table shape") }
                for column in columns { guard column.count == 6 else { throw WorkspaceError.invalid("reader schema columns") } }
                let expectedPrimary = columns.filter { ($0[5] as? NSNumber)?.int64Value ?? 0 > 0 }.sorted { ($0[5] as? NSNumber)?.int64Value ?? 0 < ($1[5] as? NSNumber)?.int64Value ?? 0 }.compactMap { $0[1] as? String }
                guard primary == expectedPrimary, Set(primary).isSubset(of: Set(selected)) else { throw WorkspaceError.invalid("reader primary key schema") }
                let suffix = path + ":" + name
                values["table-schema:" + suffix] = try digest(["sql": sql, "columns": columns])
                rowTotal += keys.count + counts.count; guard rowTotal <= 1_000_000 else { throw WorkspaceError.invalid("reader row budget") }
                if primary.isEmpty {
                    guard keys.isEmpty, rows.isEmpty else { throw WorkspaceError.invalid("unkeyed table cannot provide selected-row proof") }
                    for (rowHash, count) in counts {
                        try WorkspaceIO.requireHash(rowHash)
                        let rawCount = try WorkspaceIO.canonical(["n": count]); guard try WorkspaceIO.integer(rawCount, field: "n") > 0 else { throw WorkspaceError.invalid("reader row multiset count") }
                    }
                    values["table:" + suffix] = try digest(counts)
                } else {
                    guard counts.isEmpty else { throw WorkspaceError.invalid("keyed table multiset") }
                    let keySet = Set(keys)
                    for key in keys { try WorkspaceIO.requireHash(key); values["database:" + suffix + ":" + key] = "present-but-unselected" }
                    for row in rows {
                        let key = try WorkspaceIO.string(row, "key"), entity = "database:" + suffix + ":" + key
                        guard Set(row.keys) == ["key", "document"], keySet.contains(key), seenRows.insert(entity).inserted,
                              let document = row["document"] as? [String: Any], Set(document.keys) == Set(selected),
                              try digest(primary.map { document[$0]! }) == key else { throw WorkspaceError.invalid("reader typed row identity") }
                        values[entity] = try digest(document)
                    }
                }
            }
        }
        let neededRows = Set(heads.filter { $0.key.hasPrefix("database:") && $0.value["kind"] as? String != "tombstone" }.keys)
        guard Set(neededRows.map { Data($0.utf8) }) == Set(seenRows.map { Data($0.utf8) }) else { throw WorkspaceError.invalid("reader row proof is not exact current membership") }
        for entity in heads.keys where entity.hasPrefix("database:") || entity.hasPrefix("table:") || entity.hasPrefix("table-schema:") {
            guard seenDBs.contains(where: { entity.hasPrefix(entity.components(separatedBy: ":").first! + ":" + $0 + ":") }) else { throw WorkspaceError.invalid("reader tombstone database domain absent") }
        }
        return values
    }
}
