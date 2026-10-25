import Foundation

public struct CategorySuggestion: Sendable {
    public let source: FinancialComponent
    public let score: Int
    public let ambiguous: Bool
    public let platform: Bool
}

/// Regex is used for bounded normalization, never to turn a merchant into an executable pattern.
/// Exact propagation preserves punctuation, digits, branches and product descriptions.
public enum CategoryHeuristics {
    public static func exactName(_ title: String) -> String {
        title.precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    /// Remove known order wrappers, retaining the branch. A platform is only unwrapped
    /// when an explicit parenthesized merchant/branch is present, never for a bare platform.
    public static func merchantName(_ title: String) -> String {
        var name = exactName(title)
        let prefix = #"^(?:美团|淘宝闪购|饿了么)\s*·\s*(?=.{2,80}\([^()]+\))"#
        name = name.replacingOccurrences(of: prefix, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s*(?:订单详情|外卖订单)$"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"(?<=\))-(?:美团app-)?[0-9]{12,40}$"#, with: "", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func blocksAutomation(_ title: String) -> Bool {
        let name = merchantName(title)
        let channels = ["淘宝", "天猫", "京东", "美团", "支付宝", "微信", "财付通", "银联", "云闪付", "拼多多", "抖音", "快手", "饿了么", "拉扎斯", "去哪儿", "携程", "飞猪", "转账", "退款", "红包", "收款", "余额宝", "平台", "taobao", "tmall", "meituan", "alipay", "wechat", "weixin", "tencent", "tenpay", "unionpay", "paypal", "amazon", "apple.com/bill", "applepay", "apple pay", "pinduoduo", "jd.com", "ctrip", "trip.com", "shopping", "支付", "财付", "待确认", "未知"]
        return name.count < 4 || name.contains("…") || name.contains("..") || name.contains("*") || channels.contains(where: name.contains)
    }
    private static func fuzzyName(_ title: String) -> String {
        let name = exactName(title)
        return name.replacingOccurrences(of: #"[\p{P}\p{Z}\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?:股份有限公司|有限责任公司|有限公司)$"#, with: "", options: .regularExpression)
    }
    public static func similarity(_ lhs: String, _ rhs: String) -> Int {
        if exactName(lhs) == exactName(rhs), !exactName(lhs).isEmpty { return 100 }
        // Bound work for malformed/imported titles. A fuzzy score can never authorize a write.
        let a = Array(fuzzyName(lhs).prefix(160)), b = Array(fuzzyName(rhs).prefix(160))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for (i, char) in a.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: b.count)
            for j in b.indices { next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (char == b[j] ? 0 : 1)) }
            row = next
        }
        let edit = 1 - Double(row[b.count]) / Double(max(a.count, b.count))
        func grams(_ chars: [Character]) -> Set<String> {
            if chars.count < 2 { return Set(chars.map(String.init)) }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
        }
        let ag = grams(a), bg = grams(b)
        let dice = 2 * Double(ag.intersection(bg).count) / Double(ag.count + bg.count)
        return min(99, Int((100 * (0.6 * edit + 0.4 * dice)).rounded()))
    }
    public static func suggestion(for component: FinancialComponent, records: [FinancialLifecycle], taxonomy: [FinancialCategory]) -> CategorySuggestion? {
        guard component.primary == "待分类" else { return nil }
        let valid = Dictionary(taxonomy.map { ($0.primary, Set($0.secondaries)) }, uniquingKeysWith: { a, _ in a })
        // Score distinct names once; stable ordering makes equal-score results reproducible.
        var scores = [String: Int]()
        var best: FinancialComponent?; var high = -1; var categories = Set<String>()
        for record in records where !record.non_consumption && !record.reviewExcluded {
            for source in record.components where source.id != component.id && source.primary != "待分类" && valid[source.primary]?.contains(source.secondary) == true {
                let score = scores[source.title] ?? similarity(component.title, source.title)
                scores[source.title] = score
                if score > high { high = score; best = source; categories = [] }
                if score == high {
                    categories.insert(source.primary + "/" + source.secondary)
                    if let current = best, source.id < current.id { best = source }
                }
            }
        }
        guard let best else { return nil }
        return CategorySuggestion(source: best, score: high, ambiguous: categories.count > 1, platform: blocksAutomation(component.title))
    }
    public static func linkedTargets(source: FinancialComponent, draft: CompletionDraft, records: [FinancialLifecycle], excluding: Set<String> = []) -> [FinancialComponent] {
        guard draft.primary != "待分类", !blocksAutomation(source.title) else { return [] }
        let name = merchantName(source.title)
        let same = records.filter { !$0.non_consumption && !$0.reviewExcluded }.flatMap(\.components).filter { $0.id != source.id && merchantName($0.title) == name }
        // Mixed-purpose merchants are never generalized, even when one classification is more frequent.
        guard !same.contains(where: { $0.primary != "待分类" && ($0.primary != draft.primary || $0.secondary != draft.secondary) }) else { return [] }
        return same.filter { !$0.completionConfirmed && !excluding.contains($0.id) && ($0.primary == "待分类" || ($0.primary == draft.primary && $0.secondary == draft.secondary)) }
    }
}

public struct CompletionBatchWrite: Sendable {
    public let document: Data
    public let previous: [String: Data?]
    public let saved: [String: Data?]
}
public struct CompletionConfirmationPlan: Sendable {
    fileprivate let changes: [String: Data?]
    fileprivate let expectedDocument: Data
}

extension CompletionOverrideFile {
    /// One coordinated atomic write and one history snapshot for source + propagated categories.
    /// Linked entries retain their own effective tags/nature (including alias overrides) and unknown metadata.
    public static func saveLinked(root: URL, source: FinancialComponent, draft: CompletionDraft, targets: [FinancialComponent], expectedDocument: Data) throws -> CompletionBatchWrite {
        var changes = [String: Data?]()
        let sourceEntry = try entry(source.id, in: expectedDocument) ?? Data("{}".utf8)
        changes.updateValue(try mergingTagEdit(previous: sourceEntry, changes: JSONEncoder().encode(confirmedOverride(draft: draft, origin: "manual", sourceID: source.id, basis: "人工分类")), previousTags: source.tags, tags: draft.tags), forKey: source.id)
        for target in targets {
            let prior = try entry(target.id, in: expectedDocument) ?? Data("{}".utf8)
            var linked = CompletionDraft(target); linked.primary = draft.primary; linked.secondary = draft.secondary
            let category = try JSONEncoder().encode(confirmedOverride(draft: linked, origin: "linked", sourceID: source.id, basis: "同名商家联动"))
            changes.updateValue(try ParameterDocument.merging(base: prior, changes: category), forKey: target.id)
        }
        return try writeBatch(root: root, changes: changes, expected: dependencies(Array(changes.keys), in: expectedDocument), expectedDocument: expectedDocument)
    }
    private static func confirmedOverride(draft: CompletionDraft, origin: String, sourceID: String, basis: String) -> CategoryOverride {
        CategoryOverride(primary: draft.primary, secondary: draft.secondary, recurrence: draft.recurrence, tags: draft.tags, classification_basis: basis,
                         completion_confirmation: CompletionConfirmation(draft: draft, origin: origin, sourceID: sourceID))
    }
    /// Replay existing human confirmations once, using current effective values and conservative exact names.
    /// Automatically confirmed entries never become training sources.
    public static func reconcileConfirmed(root: URL, records: [FinancialLifecycle], expectedDocument: Data, excluding: Set<String> = []) throws -> CompletionBatchWrite? {
        guard let plan = try prepareConfirmed(records: records, expectedDocument: expectedDocument, excluding: excluding) else { return nil }
        return try applyConfirmed(root: root, plan: plan)
    }
    /// Scan without changing files. Editors can remain usable until a nonempty
    /// plan is ready, then validate its document version before committing.
    public static func prepareConfirmed(records: [FinancialLifecycle], expectedDocument: Data, excluding: Set<String> = []) throws -> CompletionConfirmationPlan? {
        let overrides = try JSONDecoder().decode([String: CategoryOverride].self, from: expectedDocument)
        let components = records.filter { !$0.non_consumption && !$0.reviewExcluded }.flatMap(\.components)
        let groups = Dictionary(grouping: components, by: { CategoryHeuristics.merchantName($0.title) })
        var changes = [String: Data?]()
        for group in groups.values {
            let seeds = group.filter { component in
                guard component.primary != "待分类", !excluding.contains(component.id),
                      let value = ([component.id] + (component.classification_keys ?? [])).compactMap({ overrides[$0] }).first,
                      value.primary == component.primary, value.secondary == component.secondary else { return false }
                if let confirmation = value.completion_confirmation { return confirmation.origin == "manual" && confirmation.matches(component) }
                return value.classification_basis == "人工分类"
            }.sorted { $0.id < $1.id }
            guard let seed = seeds.first else { continue }
            let targets = CategoryHeuristics.linkedTargets(source: seed, draft: CompletionDraft(seed), records: recordsForGroup(group), excluding: excluding)
            for target in seeds.filter({ !$0.completionConfirmed }) + targets {
                guard changes[target.id] == nil else { continue }
                let manual = seeds.contains { $0.id == target.id }
                var draft = CompletionDraft(target)
                if !manual { draft.primary = seed.primary; draft.secondary = seed.secondary }
                let prior = try entry(target.id, in: expectedDocument) ?? Data("{}".utf8)
                let value = confirmedOverride(draft: draft, origin: manual ? "manual" : "linked", sourceID: manual ? target.id : seed.id, basis: manual ? "人工分类" : "同名商家联动")
                changes.updateValue(try ParameterDocument.merging(base: prior, changes: JSONEncoder().encode(value)), forKey: target.id)
            }
        }
        guard !changes.isEmpty else { return nil }
        return CompletionConfirmationPlan(changes: changes, expectedDocument: expectedDocument)
    }
    public static func applyConfirmed(root: URL, plan: CompletionConfirmationPlan) throws -> CompletionBatchWrite {
        try writeBatch(root: root, changes: plan.changes, expected: dependencies(Array(plan.changes.keys), in: plan.expectedDocument), expectedDocument: plan.expectedDocument)
    }
    private static func recordsForGroup(_ components: [FinancialComponent]) -> [FinancialLifecycle] {
        [FinancialLifecycle(id: "group", date: "", title: "", status: "", account_views: [], evidence_keys: [], components: components, events: [], user_relation: "", non_consumption: false, unallocated_credit_cents: 0)]
    }
    public static func restoreLinked(root: URL, previous: [String: Data?], expected: [String: Data?], dependencies: [String: Data?]) throws -> CompletionBatchWrite {
        var guards = dependencies
        for (key, value) in expected { guards.updateValue(value, forKey: key) }
        return try writeBatch(root: root, changes: previous, expected: guards, expectedDocument: nil)
    }
    /// Rebind only the explicitly selected components, without merchant propagation.
    public static func rebindCategories(root: URL, components: [FinancialComponent], primary: String, secondary: String, expectedDocument: Data) throws -> CompletionBatchWrite {
        guard !components.isEmpty, Set(components.map(\.id)).count == components.count else { throw CompletionWriteError.invalidFields }
        var changes = [String: Data?]()
        for component in components {
            let previous = try entry(component.id, in: expectedDocument)
            var object = try previous.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? [:]
            object["primary"] = primary; object["secondary"] = secondary
            object["tags"] = component.tags
            object["recurrence"] = component.recurrence
            object["classification_basis"] = "人工批量分类"
            object.removeValue(forKey: "completion_confirmation")
            changes.updateValue(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), forKey: component.id)
        }
        return try writeBatch(root: root, changes: changes, expected: [:], expectedDocument: expectedDocument)
    }
    private static func writeBatch(root: URL, changes: [String: Data?], expected: [String: Data?], expectedDocument: Data?) throws -> CompletionBatchWrite {
        let target = root.appendingPathComponent("review-overrides.json")
        return try ReviewSyncIO.coordinate(target, write: true) { url in
            let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data("{}".utf8)
            if let expectedDocument, current != expectedDocument { throw CompletionWriteError.conflict }
            for (id, value) in expected { guard try entry(id, in: current) == value else { throw CompletionWriteError.conflict } }
            var object = try JSONSerialization.jsonObject(with: current) as! [String: Any]
            let before = try dependencies(Array(changes.keys), in: current)
            for (id, value) in changes { object[id] = try value.map { try JSONSerialization.jsonObject(with: $0) } }
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            _ = try JSONDecoder().decode([String: CategoryOverride].self, from: bytes)
            let history = root.appendingPathComponent("review-history")
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try ReviewSyncIO.immutable(current, at: history.appendingPathComponent("completion-" + UUID().uuidString + ".json"))
            try bytes.write(to: url, options: .atomic)
            return CompletionBatchWrite(document: bytes, previous: before, saved: try dependencies(Array(changes.keys), in: bytes))
        }
    }
}
