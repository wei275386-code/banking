import Foundation
import CryptoKit
import CSQLite

public struct CategoryPrimary: Codable, Equatable, Sendable, Identifiable {
    public var id: String; public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public struct CategorySecondary: Codable, Equatable, Sendable, Identifiable {
    public var id: String; public var primaryID: String; public var name: String
    public init(id: String, primaryID: String, name: String) { self.id = id; self.primaryID = primaryID; self.name = name }
}
public struct CategoryAlias: Codable, Equatable, Sendable {
    public var primary: String; public var secondary: String; public var targetID: String; public var reassigned: Bool
    public init(primary: String, secondary: String, targetID: String, reassigned: Bool = false) {
        self.primary = primary; self.secondary = secondary; self.targetID = targetID; self.reassigned = reassigned
    }
    enum CodingKeys: String, CodingKey { case primary, secondary, targetID, reassigned }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primary = try c.decode(String.self, forKey: .primary); secondary = try c.decode(String.self, forKey: .secondary)
        targetID = try c.decode(String.self, forKey: .targetID); reassigned = try c.decodeIfPresent(Bool.self, forKey: .reassigned) ?? false
    }
}
public struct CategoryPath: Equatable, Sendable {
    public let primary: String; public let secondary: String; public let id: String?; public let wasRedirected: Bool
    public init(primary: String, secondary: String, id: String? = nil, wasRedirected: Bool = false) {
        self.primary = primary; self.secondary = secondary; self.id = id; self.wasRedirected = wasRedirected
    }
}
public enum CategoryCatalogError: LocalizedError {
    case invalid(String), conflict, storage(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): "分类无效：\(detail)"
        case .conflict: "分类已在其他入口更新，请刷新分类后重试。"
        case .storage(let detail): "分类保存失败：\(detail)"
        }
    }
}
public struct CategoryCatalog: Codable, Equatable, Sendable {
    public var primaries: [CategoryPrimary]
    public var secondaries: [CategorySecondary]
    public var aliases: [CategoryAlias]
    public init(primaries: [CategoryPrimary], secondaries: [CategorySecondary], aliases: [CategoryAlias] = []) {
        self.primaries = primaries; self.secondaries = secondaries; self.aliases = aliases
    }
    private static func stable(_ prefix: String, _ name: String) -> String {
        prefix + SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public init(taxonomy: [FinancialCategory], records: [FinancialLifecycle] = []) {
        primaries = []; secondaries = []; aliases = []
        func append(_ p: String, _ s: String?) {
            guard let p = try? Self.clean(p) else { return }
            let pid = Self.stable("p-", p)
            if !primaries.contains(where: { Self.key($0.name) == Self.key(p) }) { primaries.append(.init(id: pid, name: p)) }
            guard let actual = primaries.first(where: { Self.key($0.name) == Self.key(p) }), let s, let name = try? Self.clean(s) else { return }
            if !secondaries.contains(where: { $0.primaryID == actual.id && Self.key($0.name) == Self.key(name) }) {
                secondaries.append(.init(id: Self.stable("s-", actual.name + "\u{1f}" + name), primaryID: actual.id, name: name))
            }
        }
        for row in taxonomy { append(row.primary, nil); for s in row.secondaries { append(row.primary, s) } }
        for record in records { for c in record.components { append(c.primary, c.secondary) } }
        append("待分类", "待分类")
        rememberPaths()
    }
    public var taxonomy: [FinancialCategory] {
        let grouped = Dictionary(grouping: secondaries, by: \.primaryID)
        return primaries.map { p in FinancialCategory(primary: p.name, secondaries: (grouped[p.id] ?? []).map(\.name)) }
    }
    fileprivate static func clean(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.unicodeScalars.count <= 40, name != "全部分类", !name.contains("\u{1f}"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CategoryCatalogError.invalid("名称须为1–40字，不能使用「全部分类」或控制字符。") }
        return name
    }
    fileprivate static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
    fileprivate static func pathKey(_ p: String, _ s: String) -> String { key(p) + "\u{1f}" + key(s) }
    private func path(_ s: CategorySecondary) -> CategoryPath {
        CategoryPath(primary: primaries.first { $0.id == s.primaryID }!.name, secondary: s.name, id: s.id)
    }
    private var pendingID: String? { secondaries.first { s in s.name == "待分类" && primaries.contains { $0.id == s.primaryID && $0.name == "待分类" } }?.id }
    public func validated() throws -> CategoryCatalog {
        guard primaries.count <= 10_000, secondaries.count <= 50_000, aliases.count <= 100_000,
              Set(primaries.map(\.id)).count == primaries.count, Set(secondaries.map(\.id)).count == secondaries.count,
              Set(primaries.map { Self.key($0.name) }).count == primaries.count,
              Set(secondaries.map { $0.primaryID + "\u{1f}" + Self.key($0.name) }).count == secondaries.count,
              pendingID != nil else { throw CategoryCatalogError.invalid("目录版本、重复名称、ID或保留分类不正确。") }
        let parents = Set(primaries.map(\.id)), leaves = Set(secondaries.map(\.id))
        for p in primaries { guard !p.id.isEmpty, try Self.clean(p.name) == p.name else { throw CategoryCatalogError.invalid("一级名称不规范。") } }
        for s in secondaries { guard !s.id.isEmpty, parents.contains(s.primaryID), try Self.clean(s.name) == s.name else { throw CategoryCatalogError.invalid("二级分类无父级或名称不规范。") } }
        var history = [String: String]()
        for a in aliases {
            guard leaves.contains(a.targetID), try Self.clean(a.primary) == a.primary, try Self.clean(a.secondary) == a.secondary else { throw CategoryCatalogError.invalid("历史路径指向不存在的分类。") }
            let k = Self.pathKey(a.primary, a.secondary)
            guard history[k] == nil else { throw CategoryCatalogError.invalid("历史路径重复。") }; history[k] = a.targetID
        }
        let parentNames = Dictionary(primaries.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for s in secondaries { guard history[Self.pathKey(parentNames[s.primaryID]!, s.name)].map({ $0 == s.id }) ?? true else { throw CategoryCatalogError.invalid("名称已被历史分类使用。") } }
        return self
    }
    public func resolve(primary: String, secondary: String) -> CategoryPath { CategoryResolver(catalog: self).resolve(primary: primary, secondary: secondary) }
    public func applying(to report: inout FinancialReport) {
        let resolver = CategoryResolver(catalog: self)
        for r in report.records.indices { for i in report.records[r].components.indices { resolver.applying(to: &report.records[r].components[i]) } }
        report.taxonomy = taxonomy
    }
    private mutating func rememberPaths() {
        let parents = Dictionary(primaries.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var existing = Set(aliases.map { Self.pathKey($0.primary, $0.secondary) })
        for s in secondaries {
            guard let parent = parents[s.primaryID] else { continue }
            if existing.insert(Self.pathKey(parent, s.name)).inserted { aliases.append(.init(primary: parent, secondary: s.name, targetID: s.id)) }
        }
    }
    private mutating func edit(_ body: (inout CategoryCatalog) throws -> Void) throws {
        var next = self; next.rememberPaths(); try body(&next); next.rememberPaths(); self = try next.validated()
    }
    public mutating func addPrimary(name: String) throws -> String {
        let id = UUID().uuidString; try edit { $0.primaries.append(.init(id: id, name: try Self.clean(name))) }; return id
    }
    public mutating func addSecondary(primaryID: String, name: String) throws -> String {
        let id = UUID().uuidString; try edit { $0.secondaries.append(.init(id: id, primaryID: primaryID, name: try Self.clean(name))) }; return id
    }
    public mutating func renamePrimary(id: String, name: String) throws {
        try edit { c in
            guard let i = c.primaries.firstIndex(where: { $0.id == id }), c.primaries[i].name != "待分类" else { throw CategoryCatalogError.invalid("保留分类不可修改，或分类已不存在。") }
            c.primaries[i].name = try Self.clean(name)
        }
    }
    public mutating func renameSecondary(id: String, name: String, primaryID: String) throws {
        try edit { c in
            guard let i = c.secondaries.firstIndex(where: { $0.id == id }), id != c.pendingID else { throw CategoryCatalogError.invalid("待分类不可修改，或分类已不存在。") }
            c.secondaries[i].name = try Self.clean(name); c.secondaries[i].primaryID = primaryID
        }
    }
    public mutating func deleteSecondary(id: String, replacementID: String) throws {
        try edit { c in
            guard id != c.pendingID, id != replacementID, c.secondaries.contains(where: { $0.id == id }), c.secondaries.contains(where: { $0.id == replacementID }) else { throw CategoryCatalogError.invalid("请选择有效的迁移目标；待分类不可删除。") }
            for i in c.aliases.indices where c.aliases[i].targetID == id { c.aliases[i].targetID = replacementID; c.aliases[i].reassigned = true }
            c.secondaries.removeAll { $0.id == id }
        }
    }
    public mutating func deletePrimary(id: String, replacementID: String) throws {
        try edit { c in
            guard let primary = c.primaries.first(where: { $0.id == id }), primary.name != "待分类", c.secondaries.contains(where: { $0.id == replacementID && $0.primaryID != id }) else { throw CategoryCatalogError.invalid("待分类不可删除；迁移目标须在其他一级分类下。") }
            let ids = Set(c.secondaries.filter { $0.primaryID == id }.map(\.id))
            for i in c.aliases.indices where ids.contains(c.aliases[i].targetID) { c.aliases[i].targetID = replacementID; c.aliases[i].reassigned = true }
            c.secondaries.removeAll { $0.primaryID == id }; c.primaries.removeAll { $0.id == id }
        }
    }
}
/// Build once per report; every component lookup is O(1).
public struct CategoryResolver: Sendable {
    private let current: [String: CategoryPath]; private let historical: [String: CategoryPath]; private let pending: CategoryPath
    public init(catalog: CategoryCatalog) {
        let parents = Dictionary(catalog.primaries.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let leaves = Dictionary(catalog.secondaries.compactMap { s -> (String, CategoryPath)? in
            guard let p = parents[s.primaryID] else { return nil }; return (s.id, .init(primary: p, secondary: s.name, id: s.id))
        }, uniquingKeysWith: { a, _ in a })
        current = Dictionary(leaves.values.map { (CategoryCatalog.pathKey($0.primary, $0.secondary), $0) }, uniquingKeysWith: { a, _ in a })
        historical = Dictionary(catalog.aliases.compactMap { a -> (String, CategoryPath)? in
            guard let p = leaves[a.targetID] else { return nil }
            return (CategoryCatalog.pathKey(a.primary, a.secondary), .init(primary: p.primary, secondary: p.secondary, id: p.id, wasRedirected: a.reassigned))
        }, uniquingKeysWith: { a, _ in a })
        pending = leaves.values.first { $0.primary == "待分类" && $0.secondary == "待分类" } ?? .init(primary: "待分类", secondary: "待分类")
    }
    public func resolve(primary: String, secondary: String) -> CategoryPath {
        let key = CategoryCatalog.pathKey(primary.trimmingCharacters(in: .whitespacesAndNewlines), secondary.trimmingCharacters(in: .whitespacesAndNewlines))
        return current[key] ?? historical[key] ?? .init(primary: pending.primary, secondary: pending.secondary, id: pending.id, wasRedirected: true)
    }
    public func applying(to component: inout FinancialComponent) {
        let p = resolve(primary: component.primary, secondary: component.secondary)
        component.primary = p.primary; component.secondary = p.secondary
        if p.wasRedirected { component.completion_confirmation = nil }
        else if let confirmation = component.completion_confirmation {
            let cp = resolve(primary: confirmation.draft.primary, secondary: confirmation.draft.secondary)
            if cp.wasRedirected { component.completion_confirmation = nil }
            else {
                var draft = confirmation.draft; draft.primary = cp.primary; draft.secondary = cp.secondary
                component.completion_confirmation = .init(draft: draft, origin: confirmation.origin, sourceID: confirmation.sourceID)
            }
        }
    }
}

private final class CategoryDatabase {
    private var db: OpaquePointer?
    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"; if let db { sqlite3_close(db) }; db = nil; throw CategoryCatalogError.storage(detail) }
        do {
            sqlite3_busy_timeout(db, 5_000)
            try execute("PRAGMA foreign_keys=ON")
            try execute("CREATE TABLE IF NOT EXISTS category_primaries(id TEXT PRIMARY KEY,name TEXT NOT NULL,position INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS category_secondaries(id TEXT PRIMARY KEY,primary_id TEXT NOT NULL REFERENCES category_primaries(id),name TEXT NOT NULL,position INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS category_aliases(primary_name TEXT NOT NULL,secondary_name TEXT NOT NULL,target_id TEXT NOT NULL REFERENCES category_secondaries(id),reassigned INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(primary_name,secondary_name)); CREATE TABLE IF NOT EXISTS category_catalog_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),payload_json TEXT NOT NULL)")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { if let db { sqlite3_close(db) } }
    func execute(_ sql: String, _ args: [String] = []) throws {
        if args.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CategoryCatalogError.storage(String(cString: sqlite3_errmsg(db))) }; return
        }
        var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CategoryCatalogError.storage(String(cString: sqlite3_errmsg(db))) }; defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() { guard sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, transient) == SQLITE_OK else { throw CategoryCatalogError.storage("参数绑定失败") } }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw CategoryCatalogError.storage(String(cString: sqlite3_errmsg(db))) }
    }
    func catalog() throws -> CategoryCatalog? {
        var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db, "SELECT payload_json FROM category_catalog_state WHERE singleton=1", -1, &stmt, nil) == SQLITE_OK else { throw CategoryCatalogError.storage(String(cString: sqlite3_errmsg(db))) }; defer { sqlite3_finalize(stmt) }
        let status = sqlite3_step(stmt); if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_text(stmt, 0) else { throw CategoryCatalogError.storage("数据库目录读取失败") }
        return try CategoryCatalogFile.decode(Data(String(cString: bytes).utf8))
    }
    func persist(_ c: CategoryCatalog, data: Data) throws {
        try execute("DELETE FROM category_aliases; DELETE FROM category_secondaries; DELETE FROM category_primaries")
        for (i, p) in c.primaries.enumerated() { try execute("INSERT INTO category_primaries VALUES(?,?,?)", [p.id, p.name, String(i)]) }
        for (i, s) in c.secondaries.enumerated() { try execute("INSERT INTO category_secondaries VALUES(?,?,?,?)", [s.id, s.primaryID, s.name, String(i)]) }
        for a in c.aliases { try execute("INSERT INTO category_aliases VALUES(?,?,?,?)", [a.primary, a.secondary, a.targetID, a.reassigned ? "1" : "0"]) }
        try execute("INSERT INTO category_catalog_state VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET payload_json=excluded.payload_json", [String(decoding: data, as: UTF8.self)])
    }
}
public enum CategoryCatalogFile {
    fileprivate static func decode(_ data: Data) throws -> CategoryCatalog {
        guard data.count <= 8_000_000 else { throw CategoryCatalogError.invalid("分类目录过大。") }
        _ = try ReleaseCanonicalJSON.canonicalize(raw: data)
        return try JSONDecoder().decode(CategoryCatalog.self, from: data).validated()
    }
    private static func encode(_ c: CategoryCatalog) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; let data = try e.encode(c)
        guard data.count <= 8_000_000 else { throw CategoryCatalogError.invalid("分类目录过大。") }; return data
    }
    private static func fileData(_ root: URL) throws -> Data? {
        let file = root.appendingPathComponent("category-catalog.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let v = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? 0) <= 8_000_000 else { throw CategoryCatalogError.invalid("分类目录文件不安全或过大。") }
        return try Data(contentsOf: file)
    }
    /// Read an immutable workspace without initializing a database or transport file.
    public static func read(root: URL, taxonomy: [FinancialCategory], records: [FinancialLifecycle] = []) throws -> CategoryCatalog {
        if let transport = try fileData(root) { return try decode(transport) }
        let url = root.appendingPathComponent("financial-review.sqlite3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return try CategoryCatalog(taxonomy: taxonomy, records: records).validated()
        }
        // Immutable reads never create journals/SHM. A live WAL must first be
        // captured through SQLite backup by the workspace transaction.
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw CategoryCatalogError.storage("分类数据库不是普通文件。")
        }
        for suffix in ["-wal", "-journal"] {
            let journal = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: journal.path),
               (try journal.resourceValues(forKeys: [.fileSizeKey])).fileSize != 0 {
                throw CategoryCatalogError.storage("须先取得分类数据库的一致性备份。")
            }
        }
        var db: OpaquePointer?
        var uri = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        uri.queryItems = [URLQueryItem(name: "immutable", value: "1"), URLQueryItem(name: "mode", value: "ro")]
        guard let path = uri.string,
              sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw CategoryCatalogError.storage("分类数据库无法只读打开。")
        }
        defer { sqlite3_close(db) }
        var table: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='category_catalog_state'", -1, &table, nil) == SQLITE_OK else {
            throw CategoryCatalogError.storage("分类数据库结构无法读取。")
        }
        defer { sqlite3_finalize(table) }
        let tableStatus = sqlite3_step(table)
        if tableStatus == SQLITE_DONE { return try CategoryCatalog(taxonomy: taxonomy, records: records).validated() }
        guard tableStatus == SQLITE_ROW else { throw CategoryCatalogError.storage("分类数据库结构已损坏。") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload_json FROM category_catalog_state WHERE singleton=1", -1, &statement, nil) == SQLITE_OK else {
            throw CategoryCatalogError.storage("分类数据库目录无法读取。")
        }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return try CategoryCatalog(taxonomy: taxonomy, records: records).validated() }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else {
            throw CategoryCatalogError.storage("分类数据库目录已损坏。")
        }
        return try decode(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    public static func load(root: URL, taxonomy: [FinancialCategory], records: [FinancialLifecycle] = []) throws -> CategoryCatalog {
        try ReviewSyncIO.coordinate(root, write: true) { root in
            let db = try CategoryDatabase(root.appendingPathComponent("financial-review.sqlite3")); try db.execute("BEGIN IMMEDIATE")
            var wrote = false
            do {
                let previous = try db.catalog(), transport = try fileData(root)
                let selected = try transport.map { try decode($0) } ?? previous ?? CategoryCatalog(taxonomy: taxonomy, records: records).validated()
                if selected != previous { try db.persist(selected, data: encode(selected)) }
                if transport == nil { try encode(selected).write(to: root.appendingPathComponent("category-catalog.json"), options: .atomic); wrote = true }
                try db.execute("COMMIT"); return selected
            } catch {
                try? db.execute("ROLLBACK")
                if wrote { try FileManager.default.removeItem(at: root.appendingPathComponent("category-catalog.json")) }
                throw error
            }
        }
    }
    public static func save(_ catalog: CategoryCatalog, root: URL, expected: CategoryCatalog) throws {
        let catalog = try catalog.validated(), data = try encode(catalog)
        try ReviewSyncIO.coordinate(root, write: true) { root in
            let db = try CategoryDatabase(root.appendingPathComponent("financial-review.sqlite3")); try db.execute("BEGIN IMMEDIATE")
            let target = root.appendingPathComponent("category-catalog.json")
            var original: Data?; var wrote = false
            do {
                original = try fileData(root)
                let disk = try original.map { try decode($0) }, current = try disk ?? db.catalog()
                guard current == expected else { throw CategoryCatalogError.conflict }
                try db.persist(catalog, data: data)
                try data.write(to: target, options: .atomic); wrote = true
                try db.execute("COMMIT")
            } catch {
                try? db.execute("ROLLBACK")
                if wrote {
                    do { if let original { try original.write(to: target, options: .atomic) } else { try FileManager.default.removeItem(at: target) } }
                    catch { throw CategoryCatalogError.storage("数据库提交和同步文件回滚均失败，请重新加载目录恢复。") }
                }
                throw error
            }
        }
    }
}
