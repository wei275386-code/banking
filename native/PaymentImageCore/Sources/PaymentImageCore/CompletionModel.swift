import Foundation

/// The queue describes existing facts and fields; it does not infer transaction semantics.
public struct CompletionEntry: Identifiable, Sendable {
    public let id: String
    public let datasetID: String
    public let rootPath: String
    public let record: FinancialLifecycle
    public let component: FinancialComponent?
    public let issues: [String]
    public let rank: Int
    public let impact: Int
    public init(id: String, datasetID: String, rootPath: String, record: FinancialLifecycle, component: FinancialComponent?, issues: [String], rank: Int, impact: Int) {
        self.id = id; self.datasetID = datasetID; self.rootPath = rootPath; self.record = record
        self.component = component; self.issues = issues; self.rank = rank; self.impact = impact
    }
    public var amountUnknown: Bool { component?.reason.contains("支付金额待确定") == true }
    public var editable: Bool { component != nil }
    public var missingCategory: Bool { component?.primary == "待分类" }
    public var factsPending: Bool { !record.reviewExcluded && issues.contains { $0 != "分类待补" } }
    /// Display text is separate from the evidence reasons used by review signatures.
    public var issueSummaries: [String] {
        issues.flatMap { issue -> [String] in
            switch issue {
            case "统计纳入待核":
                let reasons = component?.reason.components(separatedBy: "；").filter { !$0.isEmpty } ?? []
                return reasons.isEmpty ? ["是否计入消费尚未确认"] : reasons.map { CompletionReasonText.summary($0) }
            case "支付账户待关联": return ["实际扣款账户不明"]
            case "消费人未确认": return ["尚未确认是谁的消费"]
            case "退款归属待核": return ["退款尚未找到原购买记录"]
            default: return [issue]
            }
        }
    }
    public var factDescriptions: [String] {
        issues.flatMap { issue -> [String] in
            switch issue {
            case "分类待补": return []
            case "统计纳入待核":
                let reasons = component?.reason.components(separatedBy: "；").filter { !$0.isEmpty } ?? []
                return ["这笔消费暂未计入统计，需要核实以下问题。"] + reasons.map { CompletionReasonText.detail($0) }
            case "支付账户待关联":
                let clues = (record.payment_account_pending_reasons ?? []).filter { !$0.isEmpty }
                let context = clues.isEmpty ? "现有材料没有明确实际扣款账户。" : "现有材料记录为「" + clues.joined(separator: "、") + "」，尚未明确实际扣款账户。"
                return [context + "请核对使用的银行卡、余额或代付账户。"]
            case "消费人未确认": return ["现有材料无法确认这笔属于谁的消费，请确认消费人。"]
            case "退款归属待核":
                let amount = String(format: "¥%.2f", Double(record.unallocated_credit_cents) / 100)
                return ["这笔 " + amount + " 的退款或贷记尚未关联原购买记录。请确认是否为消费退款；如是，找到原购买项目并核对退款金额。"]
            default: return [CompletionReasonText.detail(issue)]
            }
        }
    }
}

private enum CompletionReasonText {
    private static let wording: [String: (summary: String, detail: String)] = [
        "录屏记录与已有来源的关联待确定": ("录屏与已有记录可能重复", "录屏中的这笔交易可能已在其他材料中记录。请对照日期、金额和交易编号，确认是否为同一笔，避免重复计入。"),
        "与已覆盖银行账户的关联待确定": ("付款与银行账单可能重复", "这笔付款可能已在银行账单中记录。请核对扣款账户及对应账单交易，确认是否为同一笔，避免重复计入。"),
        "订单与已有支付记录可能重叠": ("订单与付款记录可能重复", "这份订单可能对应已有的付款记录。请对照订单号、日期和金额，确认是否为同一笔购买，避免订单和付款各计一次。"),
        "年份筛选与日期星期不一致": ("记录年份与星期对不上", "录屏选择的年份与交易日期显示的星期不一致，当前年份可能有误。请查看原始账单，确认完整交易日期。"),
        "截止日之后": ("交易日期晚于统计截止日", "当前交易日期晚于统计截止日，因此未计入统计。请核对日期；若日期正确，需在统计截止日覆盖该日期后再计入。"),
        "退款金额待确定": ("实际退款金额不明", "现有材料无法确定实际退款金额。请对照退款到账记录，确认金额后再计算净支出。"),
        "支付金额待确定": ("实际付款金额不明", "现有材料无法确定实际付款金额。请对照支付或银行扣款记录，确认实际支付金额。"),
        "已关联退款事件金额冲突": ("关联退款的金额不一致", "已关联的退款记录显示不同金额。请核对退款编号及实际到账金额，确认哪条记录有效。"),
        "跨来源退款事件关联待确定": ("不同来源的退款可能重复", "不同材料中的退款尚未确认是否为同一笔。请对照退款编号、日期和到账金额，避免重复扣减支出。"),
        "亲情卡多条来源资金事件配对待确定": ("亲情卡付款与退款尚未配对", "亲情卡的多条付款或退款记录尚未确认各自对应关系。请对照交易编号和资金流水，确认每笔付款及退款的归属。"),
        "支付状态先后待确定": ("付款状态的先后顺序不明", "材料中出现多个支付状态，尚未确认最终是否付款成功。请核对状态时间及实际扣款结果。"),
        "交易类型待确定": ("尚未确认是消费还是其他资金流", "现有材料无法判断这是消费、退款还是其他资金流。请核对原记录的收支方向和交易类型。"),
        "退款或贷记待关联原交易": ("退款或贷记尚未找到原交易", "这笔退款或贷记尚未关联原交易。请确认资金性质，并找到对应购买记录，避免将贷记直接算作消费。"),
        "退款超过原支付金额": ("退款金额超过付款金额", "记录中的退款金额超过原支付金额。请核对是否关联了错误的购买项目，或付款、退款金额有误。"),
        "交易用户归属冲突": ("材料中的消费人不一致", "不同材料对这笔交易的消费人归属不一致。请核对来源并确认消费人。"),
        "组合退款分配待确定": ("退款尚未分配到各购买项目", "这笔购买包含多个项目，退款尚未明确退给哪些项目。请核对各项目的退款金额。"),
        "日期待核": ("交易日期尚未确认", "现有材料未能确认交易日期，请对照原始账单核实完整日期。")
    ]
    static func summary(_ reason: String) -> String { wording[reason]?.summary ?? reason }
    static func detail(_ reason: String) -> String {
        if reason.hasPrefix("来源记录字段冲突：") {
            return "不同来源对以下字段的记录不一致：" + reason.dropFirst("来源记录字段冲突：".count) + "。请对照原始材料确认正确值。"
        }
        return wording[reason]?.detail ?? reason
    }
}

public enum CompletionQueue {
    public static func key(from: String, to: String) -> String { from + "|" + to }
    public static func prepared(_ report: FinancialReport, from: String, to: String, includeIDs: Set<String> = [], rootPath: String = "") -> [String: [CompletionEntry]] {
        var result = [String: [CompletionEntry]]()
        let ranges = (report.cutoff.map { [(String($0.prefix(4)) + "-01-01", $0)] } ?? []) + [ ("", "9999")] + (to.isEmpty ? [] : [(from, to)])
        for (start, end) in ranges {
            let key = key(from: start, to: end)
            if result[key] == nil { result[key] = build(report.records, from: start, to: end, includeIDs: includeIDs, datasetID: report.dataset_id, rootPath: rootPath) }
        }
        return result
    }
    public static func build(_ records: [FinancialLifecycle], from: String, to: String, includeIDs: Set<String> = [], datasetID: String = "", rootPath: String = "") -> [CompletionEntry] {
        var entries = [CompletionEntry]()
        for record in records where record.date >= from && record.date <= to && (!record.non_consumption || record.unallocated_credit_cents > 0 || record.reviewExcluded || record.factReviewConfirmed) {
            if record.reviewExcluded {
                entries.append(CompletionEntry(id: record.id + ":excluded", datasetID: datasetID, rootPath: rootPath, record: record, component: nil, issues: ["已从补全和统计中排除"], rank: 4, impact: record.components.reduce(0) { $0 + max(abs($1.net_cents), $1.gross_cents) }))
                continue
            }
            var facts = [String]()
            if let status = record.fact_review_status, !status.hasPrefix("事实已确认") { facts.append(status) }
            if record.payment_account_status == "unresolved" && !(record.non_consumption && record.factReviewConfirmed) { facts.append("支付账户待关联") }
            if record.user_id == nil && !["self", "other_user"].contains(record.user_relation) && !(record.non_consumption && record.factReviewConfirmed) { facts.append("消费人未确认") }
            if record.unallocated_credit_cents > 0 && !(record.non_consumption && record.factReviewConfirmed) { facts.append("退款归属待核") }
            let components = record.non_consumption ? [] : record.components.filter { $0.completionConfirmed || $0.gross_cents > 0 || $0.refund_cents > 0 || $0.net_cents != 0 || (!$0.included && $0.reason.contains("支付金额待确定")) }
            for component in components {
                var issues = [String]()
                let pending = !component.included && !component.reason.isEmpty
                if pending { issues.append("统计纳入待核") }
                if component.primary == "待分类" { issues.append("分类待补") }
                issues += facts
                guard !issues.isEmpty || component.completionConfirmed || record.factReviewConfirmed || includeIDs.contains(component.id) else { continue }
                entries.append(CompletionEntry(id: component.id, datasetID: datasetID, rootPath: rootPath, record: record, component: component, issues: issues,
                    rank: pending ? 0 : component.primary == "待分类" ? 1 : record.unallocated_credit_cents > 0 ? 2 : 3,
                    impact: max(abs(component.net_cents), component.gross_cents)))
            }
            if components.isEmpty && (!facts.isEmpty || record.factReviewConfirmed) {
                entries.append(CompletionEntry(id: record.id + ":facts", datasetID: datasetID, rootPath: rootPath, record: record, component: nil, issues: facts, rank: record.unallocated_credit_cents > 0 ? 2 : 3, impact: record.unallocated_credit_cents))
            }
        }
        return TransactionListOrder.sorted(entries, amount: { $0.amountUnknown ? nil : $0.impact },
                                          date: { $0.record.date }, id: \.id)
    }
}

public struct CompletionDraft: Codable, Sendable, Equatable {
    public var primary: String
    public var secondary: String
    public var recurrence: String
    public var tags: [String]
    public init(_ component: FinancialComponent) {
        primary = component.primary; secondary = component.secondary
        recurrence = component.effectiveRecurrence; tags = component.tags.sorted()
    }
    public var override: CategoryOverride { CategoryOverride(primary: primary, secondary: secondary, recurrence: recurrence, tags: tags, classification_basis: "人工分类", completion_confirmation: CompletionConfirmation(draft: self, origin: "field_edit")) }
    public func validated(taxonomy: [FinancialCategory]) throws -> CompletionDraft {
        guard taxonomy.contains(where: { $0.primary == primary && $0.secondaries.contains(secondary) }),
              ["recurring", "one_time"].contains(recurrence) else { throw CompletionWriteError.invalidFields }
        var clean = self
        clean.tags = Array(Set(tags.map { $0.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }.filter { !$0.isEmpty })).sorted()
        guard clean.tags.count <= 30, clean.tags.allSatisfy({ $0.count <= 40 }) else { throw CompletionWriteError.invalidTags }
        return clean
    }
}

public enum CompletionWriteError: LocalizedError {
    case conflict, invalidFields, invalidTags
    public var errorDescription: String? {
        switch self {
        case .conflict: "该笔记录已在其他入口更新，请刷新数据后重新选择。草稿仍保留。"
        case .invalidFields: "请选择现有分类和支出性质选项。"
        case .invalidTags: "每笔最多30个标签，每个标签最多40字。"
        }
    }
}

public struct CompletionWrite: Sendable {
    public let document: Data
    public let previousEntry: Data?
    public let savedEntry: Data?
}

/// Coordinates a single-entry merge, preserving all other entries and unknown metadata.
/// Undo uses the same compare-and-swap operation, never restores an entire older file.
public enum CompletionOverrideFile {
    public static func entry(_ id: String, in document: Data) throws -> Data? {
        guard let object = try JSONSerialization.jsonObject(with: document) as? [String: Any] else { throw CocoaError(.propertyListReadCorrupt) }
        return try object[id].map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
    }
    public static func dependencies(_ keys: [String], in document: Data) throws -> [String: Data?] {
        guard let object = try JSONSerialization.jsonObject(with: document) as? [String: Any] else { throw CocoaError(.propertyListReadCorrupt) }
        return try Dictionary(keys.map { key in
            (key, try object[key].map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) })
        }, uniquingKeysWith: { first, _ in first })
    }
    public static func save(root: URL, id: String, draft: CompletionDraft, expected: Data?, dependencies: [String: Data?] = [:], previousTags: [String]? = nil) throws -> CompletionWrite {
        try mutate(root: root, id: id, expected: expected, dependencies: dependencies) { previous in
            let changes = try JSONEncoder().encode(draft.override)
            return try mergingTagEdit(previous: previous ?? Data("{}".utf8), changes: changes, previousTags: previousTags, tags: draft.tags)
        }
    }
    public static func setExcluded(root: URL, record: FinancialLifecycle, value: Bool, expected: Data?) throws -> CompletionWrite {
        guard record.canExcludeFromReview || (record.reviewExcluded && !value) else { throw CompletionWriteError.invalidFields }
        return try mutate(root: root, id: record.reviewOverrideKey, expected: expected, dependencies: [:]) { previous in
            // Reserved lifecycle entry; category edits and linked saves cannot copy this flag.
            let bytes = try JSONEncoder().encode(CategoryOverride(primary: "", secondary: "", excluded_from_completion_and_statistics: value))
            return try ParameterDocument.merging(base: previous ?? Data("{}".utf8), changes: bytes)
        }
    }
    public static func saveFacts(root: URL, record: FinancialLifecycle, review: TransactionFactReview?, expected: Data?, dependencies: [String: Data?] = [:]) throws -> CompletionWrite {
        try mutate(root: root, id: record.reviewOverrideKey, expected: expected, dependencies: dependencies) { previous in
            var object = try previous.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? ["primary": "", "secondary": ""]
            if let review { object["transaction_facts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(review)) }
            else { object.removeValue(forKey: "transaction_facts") }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    }
    public static func restore(root: URL, id: String, previous: Data?, expected: Data?, dependencies: [String: Data?] = [:]) throws -> CompletionWrite {
        try mutate(root: root, id: id, expected: expected, dependencies: dependencies) { _ in previous }
    }
    public static func saveSourceSet(root: URL, group: SourceRecordSet, disposition: SourceRecordSetDisposition, expected: Data?, dependencies: [String: Data?] = [:]) throws -> CompletionWrite {
        try mutate(root: root, id: group.reviewOverrideKey, expected: expected, dependencies: dependencies) { previous in
            var object = try previous.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? ["primary": "", "secondary": ""]
            let review = SourceRecordSetReview(fingerprint: group.fingerprint, disposition: disposition)
            object["source_record_set_review"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(review))
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    }
    private static func mutate(root: URL, id: String, expected: Data?, dependencies: [String: Data?], replacement: (Data?) throws -> Data?) throws -> CompletionWrite {
        let target = root.appendingPathComponent("review-overrides.json")
        var result: CompletionWrite?
        var failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forMerging, error: &coordinationError) { url in
            do {
                let document = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data("{}".utf8)
                guard var object = try JSONSerialization.jsonObject(with: document) as? [String: Any] else { throw CocoaError(.propertyListReadCorrupt) }
                func bytes(_ key: String) throws -> Data? { try object[key].map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } }
                let previous = try bytes(id)
                guard previous == expected else { throw CompletionWriteError.conflict }
                for (key, value) in dependencies {
                    guard try bytes(key) == value else { throw CompletionWriteError.conflict }
                }
                let value = try replacement(previous)
                object[id] = try value.map { try JSONSerialization.jsonObject(with: $0) }
                let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
                _ = try JSONDecoder().decode([String: CategoryOverride].self, from: bytes)
                let history = root.appendingPathComponent("review-history")
                try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
                try ReviewSyncIO.immutable(document, at: history.appendingPathComponent("completion-" + UUID().uuidString + ".json"))
                try bytes.write(to: url, options: .atomic)
                result = CompletionWrite(document: bytes, previousEntry: previous, savedEntry: try entry(id, in: bytes))
            } catch { failure = error }
        }
        if let failure { throw failure }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return result
    }
}

/// Confirmation acknowledges the saved field values without inventing a recurrence or resolving evidence facts.
public struct CompletionConfirmation: Codable, Sendable, Equatable {
    public let draft: CompletionDraft
    public let origin: String
    public let sourceID: String?
    public init(draft: CompletionDraft, origin: String, sourceID: String? = nil) {
        self.draft = draft; self.origin = origin; self.sourceID = sourceID
    }
    private var normalizedDraft: CompletionDraft {
        var value = draft
        if value.recurrence == "unconfirmed" { value.recurrence = "one_time" }
        return value
    }
    public func matches(_ component: FinancialComponent) -> Bool {
        ["manual", "linked"].contains(origin) && component.primary != "待分类" && normalizedDraft == CompletionDraft(component)
    }
}
