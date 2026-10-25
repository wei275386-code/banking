import Foundation
import CSQLite

/// SQLite reader proof preserves the existing typed row/schema digest contract.
/// Full PK domains authenticate absence; unkeyed tables retain their complete
/// compact row-hash multiset. It never opens a client processor database.
internal enum ReviewSQLiteReaderProof {
    static func build(_ file: URL, relative: String, neededEntities: Set<String>) throws -> [[String: Any]] {
        var connection: OpaquePointer?
        try WorkspaceIO.rejectSymlinks(file)
        for suffix in ["-wal", "-shm", "-journal"] {
            guard !FileManager.default.fileExists(atPath: file.path + suffix) else { throw WorkspaceError.invalid("sealed reader database has active sidecar") }
        }
        var uri = URLComponents(url: file, resolvingAgainstBaseURL: false)
        uri?.queryItems = [URLQueryItem(name: "immutable", value: "1"), URLQueryItem(name: "mode", value: "ro")]
        guard let name = uri?.string, sqlite3_open_v2(name, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { if let connection { sqlite3_close(connection) }; throw WorkspaceError.invalid("effect database") }
        defer { sqlite3_close(connection) }
        let textLimit = ["review/financial-review.sqlite3", "review/payment-evidence.sqlite3"].contains(relative) ? WorkspaceBusinessValidator.maximumProjectionBytes : 2 * 1024 * 1024
        let rowLimit = textLimit + (textLimit > 2 * 1024 * 1024 ? 1024 * 1024 : 0)
        sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, Int32(rowLimit))
        func query(_ sql: String, visitor: (([String], [Any]) throws -> Void)? = nil) throws -> (names: [String], rows: [[Any]]) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw WorkspaceError.invalid("effect query") }
            defer { sqlite3_finalize(statement) }
            let names = try (0..<sqlite3_column_count(statement)).map { index -> String in
                guard let name = sqlite3_column_name(statement, index) else { throw WorkspaceError.invalid("effect column name") }
                return String(cString: name)
            }
            guard names.count <= 1_024, Set(names).count == names.count else { throw WorkspaceError.invalid("reader column budget or duplicate column") }
            var output = [[Any]](), status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                try Task.checkCancellation()
                var row = [Any](), rowBytes = 0
                for index in 0..<sqlite3_column_count(statement) {
                    // column_bytes converts numeric storage to TEXT; capture the
                    // original storage class before any conversion-capable call.
                    let storageClass = sqlite3_column_type(statement, index)
                    rowBytes += 32
                    switch storageClass {
                    case SQLITE_INTEGER: row.append(sqlite3_column_int64(statement, index))
                    case SQLITE_FLOAT: row.append(["sqlite_float_bits": String(format: "%016llx", sqlite3_column_double(statement, index).bitPattern)])
                    case SQLITE_TEXT:
                        guard let bytes = sqlite3_column_text(statement, index) else { throw WorkspaceError.invalid("SQLite TEXT read") }
                        let count = Int(sqlite3_column_bytes(statement, index))
                        guard count <= textLimit else { throw WorkspaceError.invalid("reader SQLite TEXT byte budget") }
                        rowBytes += count
                        guard rowBytes <= rowLimit else { throw WorkspaceError.unsupportedVersion("reader SQLite row exceeds proof budget") }
                        guard let text = String(data: Data(bytes: bytes, count: count), encoding: .utf8) else {
                            throw WorkspaceError.invalid("SQLite TEXT is not valid UTF-8")
                        }
                        row.append(text)
                    case SQLITE_BLOB:
                        let bytes = sqlite3_column_blob(statement, index)
                        let count = Int(sqlite3_column_bytes(statement, index))
                        guard sqlite3_errcode(connection) != SQLITE_NOMEM, bytes != nil || count == 0 else { throw WorkspaceError.invalid("SQLite BLOB read") }
                        guard count <= 1024 * 1024 else { throw WorkspaceError.invalid("reader SQLite BLOB byte budget") }
                        rowBytes += 2 * count
                        guard rowBytes <= rowLimit else { throw WorkspaceError.unsupportedVersion("reader SQLite row exceeds proof budget") }
                        let data = bytes.map { Data(bytes: $0, count: count) } ?? Data()
                        row.append(["sqlite_blob_hex": data.map { String(format: "%02x", $0) }.joined()])
                    default: row.append(NSNull())
                    }
                    guard rowBytes <= rowLimit else { throw WorkspaceError.unsupportedVersion("reader SQLite row exceeds proof budget") }
                }
                if let visitor { try visitor(names, row) }
                else {
                    guard output.count < 10_000 else { throw WorkspaceError.invalid("reader schema row budget") }
                    output.append(row)
                }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw WorkspaceError.invalid("effect query incomplete") }
            return (names, output)
        }
        func rows(_ sql: String) throws -> [[Any]] { try query(sql).rows }
        func digest(_ value: Any) throws -> String { WorkspaceIO.digest(try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), inputLimit: max(ReleaseCanonicalJSON.maximumInputBytes, textLimit))) }

        var tables = [[String: Any]](), rowTotal = 0, proofCost = 0
        for table in try rows("SELECT name,sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") {
            guard let name = table[0] as? String else { throw WorkspaceError.invalid("proof table name") }
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let columns = try rows("PRAGMA table_info(" + quoted + ")")
            let primary = columns.filter { ($0[5] as? Int64 ?? 0) > 0 }.sorted { ($0[5] as? Int64 ?? 0) < ($1[5] as? Int64 ?? 0) }.compactMap { $0[1] as? String }
            var keys = Set<String>(), counts = [String: Int](), retained = [[String: Any]]()
            let selected = try query("SELECT * FROM " + quoted) { names, row in
                rowTotal += 1; guard rowTotal <= 1_000_000 else { throw WorkspaceError.invalid("reader proof row budget") }
                let document = Dictionary(uniqueKeysWithValues: zip(names, row)), hash = try digest(document)
                if primary.isEmpty {
                    if counts[hash] == nil { proofCost += 80 }
                    counts[hash, default: 0] += 1
                }
                else {
                    let id = try digest(primary.map { document[$0]! })
                    guard keys.insert(id).inserted else { throw WorkspaceError.invalid("proof duplicate PK") }
                    proofCost += 72
                    let entity = "database:" + relative + ":" + name + ":" + id
                    if neededEntities.contains(entity) {
                        proofCost += try WorkspaceIO.canonical(document).count
                        retained.append(["key": id, "document": document])
                    }
                }
                guard proofCost <= ReviewClientBusinessProof.maximumBytes else { throw WorkspaceError.unsupportedVersion("reader SQLite domain exceeds proof budget") }
            }
            proofCost += try WorkspaceIO.canonical(["sql": table[1], "columns": columns]).count
            guard proofCost <= ReviewClientBusinessProof.maximumBytes else { throw WorkspaceError.unsupportedVersion("reader SQLite schema exceeds proof budget") }
            tables.append(["name": name, "sql": table[1], "columns": columns, "selected_columns": selected.names,
                           "primary_keys": primary, "key_inventory": keys.sorted(), "rows": retained.sorted { ($0["key"] as! String) < ($1["key"] as! String) }, "row_counts": counts])
        }
        guard tables.count <= 10_000 else { throw WorkspaceError.invalid("reader proof table budget") }
        return tables
    }
}
