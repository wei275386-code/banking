import Foundation
import CSQLite

/// Native field edits introduce verifiable business effects and explicitly
/// supersede earlier entities without rewriting historical results.
public enum NativeWorkspaceEffects {
    @discardableResult public static func record(transaction: WorkspaceTransaction, token: WorkspaceWriteToken) throws -> Bool {
        let beforeRoot = transaction.previous.root, afterRoot = transaction.root
        // Closing a WAL writer does not switch its persistent journal mode.
        // Seal before read-only effect queries can create fresh WAL sidecars.
        for relative in try WorkspaceIO.regularFiles(afterRoot) where !relative.hasSuffix("-wal") && !relative.hasSuffix("-shm") {
            let file = try WorkspaceIO.safeChild(afterRoot, relative)
            if try WorkspaceIO.isSQLite(file) { try WorkspaceIO.sqliteSeal(file) }
        }
        let oldFiles = Set(try WorkspaceIO.regularFiles(beforeRoot)), newFiles = Set(try WorkspaceIO.regularFiles(afterRoot))
        var before = [String: String](), after = [String: String]()
        for path in oldFiles.union(newFiles).sorted() {
            if path.hasSuffix("-wal") || path.hasSuffix("-shm") || ["state-manifest.json", "operation-results.json", "review/field-state.json", "review/revision-inventory.json"].contains(path) ||
                ["sources/", "inputs/", "review/materials/", "review/ocr/", "review/videos/", "history/edits/"].contains(where: path.hasPrefix) { continue }
            let previous = try oldFiles.contains(path) ? WorkspaceIO.safeChild(beforeRoot, path) : nil
            let current = try newFiles.contains(path) ? WorkspaceIO.safeChild(afterRoot, path) : nil
            let oldHash = try previous.map(WorkspaceIO.hash), newHash = try current.map(WorkspaceIO.hash)
            guard oldHash != newHash else { continue }
            if path.hasSuffix(".json") {
                before["document:" + path] = oldHash; after["document:" + path] = newHash
                if path == "review/financial-review.json" {
                    if let previous { before.merge(try records(previous)) { _, value in value } }
                    if let current { after.merge(try records(current)) { _, value in value } }
                }
            } else if try (current ?? previous).map(WorkspaceIO.isSQLite) == true {
                if let previous { before.merge(try database(previous, relative: path)) { _, value in value } }
                if let current { after.merge(try database(current, relative: path)) { _, value in value } }
            }
        }
        let ledgerFile = try transaction.file("operation-results.json", token: token)
        let ledgerRaw = try WorkspaceIO.read(ledgerFile)
        let historical = try ReleaseCanonicalJSON.canonicalArrayElements(raw: ledgerRaw, atObjectKeys: ["results"]) ?? []
        let historicalObjects = try historical.map(WorkspaceIO.object)
        let historicalEffects = historicalObjects.flatMap { $0["membership"] as? [[String: Any]] ?? [] }
        let superseded = Set(historicalEffects.flatMap { $0["supersedes"] as? [String] ?? [] })
        var prior = [String: [String]]()
        var priorLive = Set<String>()
        for effect in historicalEffects {
            if let entity = effect["entity_key"] as? String, let key = effect["key"] as? String, !superseded.contains(key) {
                prior[entity, default: []].append(key)
                if effect["kind"] as? String != "tombstone" { priorLive.insert(entity) }
            }
        }
        var effects = [[String: Any]]()
        for entity in Set(before.keys).union(after.keys).sorted() where before[entity] != after[entity] {
            let deleted = after[entity] == nil
            // A deletion only retires an existing ledger claim. An unledgered
            // entity has no historical business proof for a tombstone to supersede.
            if deleted && !priorLive.contains(entity) { continue }
            let digest = try after[entity] ?? WorkspaceIO.digest(WorkspaceIO.canonical(["entity": entity, "deleted": true]))
            let key = "effect:" + WorkspaceIO.digest(try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: [transaction.operationID, entity, digest])))
            var effect: [String: Any] = ["key": key, "entity_key": entity, "digest": digest,
                "kind": deleted ? "tombstone" : (entity.hasPrefix("record:") || entity.hasPrefix("database:") ? "record" : "revision")]
            if let previous = prior[entity], !previous.isEmpty { effect["supersedes"] = previous.sorted() }
            effects.append(effect)
        }
        guard !effects.isEmpty else { return false }
        var result: [String: Any] = ["workspace_id": transaction.previous.pointer.workspaceID,
            "state_id": transaction.stateID, "operation_id": transaction.operationID, "request_id": transaction.operationID,
            "input_hash": WorkspaceIO.digest(Data("[]".utf8)), "algorithm_version": "native-edit",
            "phase": "committed", "outcome": "success", "inputs": [], "membership": effects,
            "result_generation": NSNull(), "message": "人工修改已保存。"]
        result["result_digest"] = WorkspaceIO.digest(try WorkspaceIO.canonical(result.filter { !["phase", "result_generation", "result_digest"].contains($0.key) }))
        let encoded = try WorkspaceIO.canonical(result)
        let array = Data("[".utf8) + historical.reduce(into: Data()) { bytes, item in if !bytes.isEmpty { bytes.append(Data(",".utf8)) }; bytes.append(item) } + (historical.isEmpty ? Data() : Data(",".utf8)) + encoded + Data("]".utf8)
        let updated = try ReleaseCanonicalJSON.replacingObjectMember(raw: ledgerRaw, key: "results", valueRaw: array)
        try WorkspaceIO.atomicWrite(updated, to: ledgerFile)
        return true
    }
    private static func records(_ file: URL) throws -> [String: String] {
        let raw = try WorkspaceIO.read(file, limit: Int64(WorkspaceBusinessValidator.maximumProjectionBytes))
        let values = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["records"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? []
        var result = [String: String]()
        for value in values {
            let id = try WorkspaceIO.string(WorkspaceIO.object(value, inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes), "id")
            guard result["record:" + id] == nil else { throw WorkspaceError.invalid("duplicate record") }
            result["record:" + id] = WorkspaceIO.digest(value)
        }
        return result
    }
    static func database(_ file: URL, relative: String) throws -> [String: String] {
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: file.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try WorkspaceIO.rejectSymlinks(sidecar)
                let values = try sidecar.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, values.fileSize == 0 else {
                    throw WorkspaceError.invalid("effect database is not sealed")
                }
            }
        }
        var uri = URLComponents(url: file, resolvingAgainstBaseURL: false)!
        uri.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        var connection: OpaquePointer?
        guard let path = uri.string,
              sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { if let connection { sqlite3_close(connection) }; throw WorkspaceError.invalid("effect database") }
        defer { sqlite3_close(connection) }
        // Enforce this in SQLite before sqlite3_step materializes a large row.
        // Per-cell checks below run before Swift Data/String/hex allocations.
        let reportPath = relative.hasSuffix(".sqlite3") ? String(relative.dropLast(8)) + ".json" : relative
        let textLimit = WorkspaceBusinessValidator.documentLimit(reportPath) == WorkspaceBusinessValidator.maximumProjectionBytes
            ? WorkspaceBusinessValidator.maximumProjectionBytes : 2 * 1024 * 1024
        sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, Int32(textLimit + (textLimit > 2 * 1024 * 1024 ? 1024 * 1024 : 0)))
        var rowsRead = 0
        func query(_ sql: String, visit: ([String], [Any]) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw WorkspaceError.invalid("effect query") }
            defer { sqlite3_finalize(statement) }
            let names = try (0..<sqlite3_column_count(statement)).map { index -> String in
                guard let name = sqlite3_column_name(statement, index) else { throw WorkspaceError.invalid("effect column name") }
                return String(cString: name)
            }
            guard Set(names).count == names.count else { throw WorkspaceError.invalid("duplicate effect column name") }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                try Task.checkCancellation()
                rowsRead += 1
                guard rowsRead <= 1_000_000 else { throw WorkspaceError.invalid("SQLite effect row budget") }
                var row = [Any]()
                for index in 0..<sqlite3_column_count(statement) {
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_INTEGER: row.append(sqlite3_column_int64(statement, index))
                    case SQLITE_FLOAT: row.append(["sqlite_float_bits": String(format: "%016llx", sqlite3_column_double(statement, index).bitPattern)])
                    case SQLITE_TEXT:
                        let count = Int(sqlite3_column_bytes(statement, index))
                        guard count <= textLimit else { throw WorkspaceError.invalid("SQLite TEXT byte budget") }
                        guard let bytes = sqlite3_column_text(statement, index) else { throw WorkspaceError.invalid("SQLite TEXT read") }
                        guard let text = String(data: Data(bytes: bytes, count: count), encoding: .utf8) else {
                            throw WorkspaceError.invalid("SQLite TEXT is not valid UTF-8")
                        }
                        row.append(text)
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, index))
                        guard count <= 1024 * 1024 else { throw WorkspaceError.invalid("SQLite BLOB byte budget") }
                        let bytes = sqlite3_column_blob(statement, index)
                        guard bytes != nil || count == 0, sqlite3_errcode(connection) != SQLITE_NOMEM else { throw WorkspaceError.invalid("SQLite BLOB read") }
                        let data = bytes.map { Data(bytes: $0, count: count) } ?? Data()
                        row.append(["sqlite_blob_hex": data.map { String(format: "%02x", $0) }.joined()])
                    default: row.append(NSNull())
                    }
                }
                try autoreleasepool { try visit(names, row) }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else {
                throw WorkspaceError.invalid(status == SQLITE_TOOBIG ? "SQLite effect row byte budget" : "effect query incomplete")
            }
        }
        func rows(_ sql: String) throws -> [[Any]] {
            var output = [[Any]]()
            try query(sql) { _, row in output.append(row) }
            return output
        }
        func digest(_ value: Any) throws -> String { WorkspaceIO.digest(try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), inputLimit: max(ReleaseCanonicalJSON.maximumInputBytes, textLimit))) }
        var entities = [String: String]()
        for table in try rows("SELECT name,sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") {
            guard let name = table[0] as? String else { throw WorkspaceError.invalid("table name") }
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let columns = try rows("PRAGMA table_info(" + quoted + ")")
            // table_info intentionally remains the schema proof, matching Python.
            // SELECT metadata also includes generated columns omitted by table_info.
            let primary = columns.filter { ($0[5] as? Int64 ?? 0) > 0 }.sorted { ($0[5] as? Int64 ?? 0) < ($1[5] as? Int64 ?? 0) }.compactMap { $0[1] as? String }
            var counts = [String: Int]()
            // Keep only canonical effect hashes, not the full table's decoded
            // TEXT/BLOB values. Schema queries above are small metadata reads.
            try query("SELECT * FROM " + quoted) { names, row in
                let document = Dictionary(uniqueKeysWithValues: zip(names, row))
                let hash = try digest(document)
                if primary.isEmpty { counts[hash, default: 0] += 1 }
                else {
                    let id = try digest(primary.map { document[$0]! })
                    let entity = "database:" + relative + ":" + name + ":" + id
                    guard entities[entity] == nil else { throw WorkspaceError.invalid("duplicate SQLite primary-key identity") }
                    entities[entity] = hash
                }
            }
            entities["table-schema:" + relative + ":" + name] = try digest(["sql": table[1], "columns": columns])
            if primary.isEmpty { entities["table:" + relative + ":" + name] = try digest(counts) }
        }
        return entities
    }
}
