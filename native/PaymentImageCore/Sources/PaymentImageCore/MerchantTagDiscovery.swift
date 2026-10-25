import Foundation
import CSQLite

public enum MerchantTagDecision: String, Codable, Sendable, CaseIterable {
    case merchant, no_tag, not_merchant, deferred
}
public struct MerchantTagRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String { payee }
    public let payee: String
    public let decision: MerchantTagDecision
    public let tag: String?
    public init(payee: String, decision: MerchantTagDecision, tag: String? = nil) {
        self.payee = payee; self.decision = decision; self.tag = tag
    }
}
public struct MerchantTagIdentity: Codable, Sendable, Equatable {
    public let names: [String]
    public let rawNames: [String]
    public var uniqueName: String? { names.count == 1 ? names.first : nil }
}
public struct MerchantTagSample: Sendable, Identifiable {
    public let id: String
    public let recordID: String
    public let date: String
    public let title: String
    public let amount: Int
}
public struct MerchantTagCandidate: Sendable, Identifiable {
    public var id: String { payee }
    public let payee: String
    public let rawNames: [String]
    public let count: Int
    public let samples: [MerchantTagSample]
    public let decision: MerchantTagDecision?
    public let suggestedTag: String
}
public struct MerchantTagScan: Sendable {
    public let candidates: [MerchantTagCandidate]
    public let rules: [MerchantTagRule]
    public let additions: [String: String]
    public let processed: Int
    public let reused: Int
    public let conflicts: Int
    public let eligible: Int
    public let newIdentities: [String: MerchantTagIdentity]
    public let conflictSamples: [MerchantTagSample]
}
public enum MerchantTagError: LocalizedError {
    case storage(String), invalidRule, conflict
    public var errorDescription: String? {
        switch self {
        case .storage(let text): "标签规则读写失败：" + text
        case .invalidRule: "商家名不能为空；标签须为1–40字。"
        case .conflict: "商家规则或交易已更新，请刷新后重试。"
        }
    }
}

/// Exact receiver names only. Product titles and fuzzy aliases never authorize a tag.
public enum MerchantTagDiscovery {
    public static let normalizationID = "merchant-payee"
    private static let wrappers: [(NSRegularExpression, String)] = [
        (#"\s*\|\s*APPLE PAY.*$"#, ""),
        (#"^(?:淘宝闪购|饿了么|美团)\s*·\s*"#, ""),
        (#" · 多点订单[:：].*$"#, ""),
        (#"(?:订单详情|外卖订单)$"#, ""),
        (#"(?<=\))-(?:(?:美团|大众点评)App-)?\d{12,40}$"#, ""),
        (#"(?:_|[ (])(?:财付通|银联云闪付|银联|特约).*$"#, ""),
        (#"\(([^()]*(?:店|门市|广场|新天地|商场|天地))\)"#, ""),
        (#"(?<=[\u4e00-\u9fff])1[3-9]\d{9}$"#, ""),
        (#"(?:-.*)?(?:代金券|套餐券)$"#, "")
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }
    public static func normalizedPayee(_ raw: String) -> String {
        // The data parser already decodes HTML. Preserve case and identity punctuation.
        var name = raw.precomposedStringWithCompatibilityMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for wrapper in wrappers {
            name = wrapper.0.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: wrapper.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: " -·"))
    }
    public static func identity(record: FinancialLifecycle, component: FinancialComponent) -> MerchantTagIdentity {
        let keys = Set([component.id] + (component.classification_keys ?? []))
        let raw = Set((record.trace_sources ?? []).filter {
            $0.association == "linked" && $0.platform != "bank" &&
            !["refund", "bank_credit"].contains($0.event_kind) &&
            (record.components.count == 1 || keys.contains($0.id))
        }.compactMap(\.merchant).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let names = Set(raw.map(normalizedPayee).filter { !$0.isEmpty })
        return .init(names: names.sorted(), rawNames: raw.sorted())
    }
    public static func cleanTag(_ tag: String) throws -> String {
        let tag = tag.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !tag.isEmpty, tag.count <= 40, !tag.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MerchantTagError.invalidRule }
        return tag
    }
    /// Restrict only candidate presentation; explicit rules may describe services as well as merchants.
    private static func suggestible(_ name: String) -> Bool {
        guard (2...65).contains(name.count), !name.contains("*"), !name.contains("…"), !name.contains("..") else { return false }
        let generic = ["支付宝", "微信", "财付通", "银联", "云闪付", "淘宝", "美团", "饿了么", "京东", "拼多多", "转账", "退款", "红包", "亲情卡", "超级吃货卡", "未知", "待确认"]
        return !generic.contains(name) && !name.hasPrefix("发给") && !name.hasPrefix("发出")
    }
    public static func scan(records: [FinancialLifecycle], rules: [MerchantTagRule], cached: [String: MerchantTagIdentity], document: Data) throws -> MerchantTagScan {
        let objects = try JSONSerialization.jsonObject(with: document) as! [String: Any]
        let ruleIndex = Dictionary(rules.map { ($0.payee, $0) }, uniquingKeysWith: { a, _ in a })
        var grouped = [String: [MerchantTagSample]](), raws = [String: Set<String>](), additions = [String: String]()
        var processed = 0, reused = 0, conflicts = 0, eligible = 0
        var newIdentities = [String: MerchantTagIdentity]()
        var conflictSamples = [MerchantTagSample]()
        for record in records where !record.non_consumption && !record.reviewExcluded {
            for component in record.components where component.gross_cents > 0 {
                eligible += 1
                let identity: MerchantTagIdentity
                if let existing = cached[component.id] { identity = existing; reused += 1 }
                else { identity = self.identity(record: record, component: component); processed += 1; newIdentities[component.id] = identity }
                guard let name = identity.uniqueName else {
                    if identity.names.count > 1 {
                        conflicts += 1
                        conflictSamples.append(.init(id: component.id, recordID: record.id, date: record.date, title: identity.names.joined(separator: " / "), amount: component.net_cents))
                    }
                    continue
                }
                let rule = ruleIndex[name]
                let suppressed = Set(([component.id] + (component.classification_keys ?? [])).flatMap { key in
                    (objects[key] as? [String: Any])?["suppressed_discovery_tags"] as? [String] ?? []
                })
                if rule?.decision == .merchant, let tag = rule?.tag,
                   !component.tags.contains(tag), !suppressed.contains(tag), component.tags.count < 30 {
                    additions[component.id] = tag
                }
                if (rule == nil || rule?.decision == .deferred) && suggestible(name) {
                    grouped[name, default: []].append(.init(id: component.id, recordID: record.id, date: record.date, title: component.title, amount: component.net_cents))
                    raws[name, default: []].formUnion(identity.rawNames)
                }
            }
        }
        var candidates = [MerchantTagCandidate]()
        for (name, samples) in grouped {
            let rawNames: [String] = (raws[name] ?? Set<String>()).sorted()
            let examples: [MerchantTagSample] = Array(samples.sorted { $0.date > $1.date }.prefix(2))
            let candidate = MerchantTagCandidate(payee: name, rawNames: rawNames, count: samples.count,
                                                 samples: examples, decision: ruleIndex[name]?.decision,
                                                 suggestedTag: String(name.prefix(40)))
            candidates.append(candidate)
        }
        candidates.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.payee < $1.payee
        }
        return .init(candidates: candidates, rules: rules, additions: additions, processed: processed, reused: reused, conflicts: conflicts, eligible: eligible, newIdentities: newIdentities, conflictSamples: conflictSamples)
    }
}

/// Household rules outlive dataset folders. Processing flags and cached identities are dataset-local.
/// A boolean is invalidated for the whole dataset when projection/association inputs change.
public final class MerchantTagDatabase {
    private var db: OpaquePointer?
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let db { sqlite3_close(db) }; db = nil; throw MerchantTagError.storage(message)
        }
        do {
            sqlite3_busy_timeout(db, 5_000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS merchant_tag_rules(payee TEXT PRIMARY KEY,decision TEXT NOT NULL,tag TEXT); CREATE TABLE IF NOT EXISTS merchant_tag_scan_context(root TEXT PRIMARY KEY,signature TEXT NOT NULL); CREATE TABLE IF NOT EXISTS merchant_tag_components(root TEXT NOT NULL,component_id TEXT NOT NULL,processed INTEGER NOT NULL DEFAULT 0,identity_json TEXT NOT NULL,PRIMARY KEY(root,component_id)); CREATE TABLE IF NOT EXISTS merchant_tag_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        } catch { if let db { sqlite3_close(db) }; db = nil; throw error }
    }
    deinit { if let db { sqlite3_close(db) } }
    private func statement(_ sql: String, _ args: [String]) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw MerchantTagError.storage(String(cString: sqlite3_errmsg(db))) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            guard sqlite3_bind_text(s, Int32(i + 1), arg, -1, transient) == SQLITE_OK else { sqlite3_finalize(s); throw MerchantTagError.storage("参数绑定失败") }
        }
        return s
    }
    private func execute(_ sql: String, _ args: [String] = []) throws {
        if args.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MerchantTagError.storage(String(cString: sqlite3_errmsg(db))) }; return
        }
        let s = try statement(sql, args); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw MerchantTagError.storage(String(cString: sqlite3_errmsg(db))) }
    }
    private func rows(_ sql: String, _ args: [String] = []) throws -> [[String]] {
        let s = try statement(sql, args); defer { sqlite3_finalize(s) }
        var values = [[String]]()
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW else { throw MerchantTagError.storage(String(cString: sqlite3_errmsg(db))) }
            values.append((0..<sqlite3_column_count(s)).map { column in sqlite3_column_text(s, column).map { String(cString: $0) } ?? "" })
        }
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func rules() throws -> [MerchantTagRule] {
        try rows("SELECT payee,decision,tag FROM merchant_tag_rules ORDER BY payee").map {
            guard let decision = MerchantTagDecision(rawValue: $0[1]) else { throw MerchantTagError.storage("规则状态无效") }
            return .init(payee: $0[0], decision: decision, tag: $0[2].isEmpty ? nil : $0[2])
        }
    }
    public func save(_ rule: MerchantTagRule, expected: MerchantTagRule?) throws {
        guard !rule.payee.isEmpty, MerchantTagDiscovery.normalizedPayee(rule.payee) == rule.payee else { throw MerchantTagError.invalidRule }
        if rule.decision == .merchant { guard let tag = rule.tag, try MerchantTagDiscovery.cleanTag(tag) == tag else { throw MerchantTagError.invalidRule } }
        try transaction {
            let current = try rules().first { $0.payee == rule.payee }
            guard current == expected else { throw MerchantTagError.conflict }
            try put(rule)
        }
    }
    private func put(_ rule: MerchantTagRule) throws {
        try execute("INSERT INTO merchant_tag_rules VALUES(?,?,?) ON CONFLICT(payee) DO UPDATE SET decision=excluded.decision,tag=excluded.tag", [rule.payee, rule.decision.rawValue, rule.tag ?? ""])
    }
    public func seed(_ data: Data) throws {
        struct Seed: Decodable { let decisions: [String: Value] }
        struct Value: Decodable { let decision: MerchantTagDecision; let tag: String? }
        let seed = try JSONDecoder().decode(Seed.self, from: data)
        try transaction {
            guard try rows("SELECT value FROM merchant_tag_metadata WHERE key='seed-v1'").isEmpty else { return }
            var existing = Set(try rules().map(\.payee))
            // Only exact decision keys enter the rule store. Canonical alias groups are not expanded.
            for (name, value) in seed.decisions.sorted(by: { $0.key < $1.key }) {
                guard MerchantTagDiscovery.normalizedPayee(name) == name, !name.isEmpty, existing.insert(name).inserted else { continue }
                let tag = value.decision == .merchant ? try value.tag.map(MerchantTagDiscovery.cleanTag) : nil
                guard value.decision != .merchant || tag != nil else { continue }
                try put(.init(payee: name, decision: value.decision, tag: tag))
            }
            try execute("INSERT INTO merchant_tag_metadata VALUES('seed-v1','1')")
        }
    }
    public func identities(root: String, signature: String, force: Bool = false) throws -> [String: MerchantTagIdentity] {
        try transaction {
            let current = try rows("SELECT signature FROM merchant_tag_scan_context WHERE root=?", [root]).first?.first
            if force || current != signature {
                try execute("DELETE FROM merchant_tag_components WHERE root=?", [root])
                try execute("INSERT INTO merchant_tag_scan_context VALUES(?,?) ON CONFLICT(root) DO UPDATE SET signature=excluded.signature", [root, signature])
            }
            return try Dictionary(rows("SELECT component_id,identity_json FROM merchant_tag_components WHERE root=? AND processed=1", [root]).map {
                ($0[0], try JSONDecoder().decode(MerchantTagIdentity.self, from: Data($0[1].utf8)))
            }, uniquingKeysWith: { a, _ in a })
        }
    }
    /// Commit flags only after any tag write succeeds. Empty results are processed too.
    public func markProcessed(root: String, signature: String, identities: [String: MerchantTagIdentity]) throws {
        try transaction {
            guard try rows("SELECT signature FROM merchant_tag_scan_context WHERE root=?", [root]).first?.first == signature else { throw MerchantTagError.conflict }
            for (id, identity) in identities {
                let data = try JSONEncoder().encode(identity)
                try execute("INSERT INTO merchant_tag_components VALUES(?,?,1,?) ON CONFLICT(root,component_id) DO UPDATE SET processed=1,identity_json=excluded.identity_json", [root, id, String(decoding: data, as: UTF8.self)])
            }
        }
    }
}

extension CompletionOverrideFile {
    /// Preserve user removal across discovery scans. Re-adding a tag clears its suppression.
    public static func mergingTagEdit(previous: Data, changes: Data, previousTags: [String]? = nil, tags: [String]) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: ParameterDocument.merging(base: previous, changes: changes)) as! [String: Any]
        let prior = try JSONSerialization.jsonObject(with: previous) as! [String: Any]
        let removed = Set(previousTags ?? prior["tags"] as? [String] ?? []).subtracting(tags)
        var suppressed = Set(prior["suppressed_discovery_tags"] as? [String] ?? [])
        suppressed.formUnion(removed); suppressed.subtract(tags)
        object["suppressed_discovery_tags"] = suppressed.sorted()
        if let discovery = prior["discovery_tags"] as? [String] { object["discovery_tags"] = Set(discovery).intersection(tags).sorted() }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    /// One parse, one atomic file write, one history snapshot for the entire discovery batch.
    public static func appendDiscoveryTags(root: URL, records: [FinancialLifecycle], additions: [String: String], expectedDocument: Data, expectedProjection: String) throws -> Data {
        return try ReviewSyncIO.coordinate(root.appendingPathComponent("review-overrides.json"), write: true) { url in
            let projection = try Data(contentsOf: ReviewDataSource.url("financial-review.json", root: root))
            guard ReviewSyncIO.digest(projection) == expectedProjection else { throw MerchantTagError.conflict }
            let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data("{}".utf8)
            guard current == expectedDocument else { throw CompletionWriteError.conflict }
            guard !additions.isEmpty else { return current }
            var object = try JSONSerialization.jsonObject(with: current) as! [String: Any]
            var changed = false
            for record in records where !record.non_consumption && !record.reviewExcluded {
                for component in record.components {
                    guard let tag = additions[component.id], !component.tags.contains(tag) else { continue }
                    var value = object[component.id] as? [String: Any] ?? [:]
                    guard !(value["suppressed_discovery_tags"] as? [String] ?? []).contains(tag) else { continue }
                    let tags = Set(component.tags).union([tag]).sorted()
                    guard tags.count <= 30 else { continue }
                    // Materialize effective classification; tags are a complete replacement downstream.
                    value["primary"] = component.primary; value["secondary"] = component.secondary
                    value["recurrence"] = component.effectiveRecurrence
                    value["classification_basis"] = component.classification_basis
                    value["tags"] = tags
                    value["discovery_tags"] = Set(value["discovery_tags"] as? [String] ?? []).union([tag]).sorted()
                    if let old = component.completion_confirmation {
                        var draft = old.draft; draft.tags = tags
                        let confirmation = CompletionConfirmation(draft: draft, origin: old.origin, sourceID: old.sourceID)
                        value["completion_confirmation"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(confirmation))
                    }
                    object[component.id] = value; changed = true
                }
            }
            guard changed else { return current }
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            _ = try JSONDecoder().decode([String: CategoryOverride].self, from: bytes)
            let history = root.appendingPathComponent("review-history")
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try current.write(to: history.appendingPathComponent("merchant-tags-" + UUID().uuidString + ".json"), options: .atomic)
            try bytes.write(to: url, options: .atomic)
            return bytes
        }
    }
}
