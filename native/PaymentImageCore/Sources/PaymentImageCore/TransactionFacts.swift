import Foundation

public enum FactDisposition: String, Codable, CaseIterable, Sendable {
    case automatic, include, exclude, duplicate, nonConsumption, refund
    public var title: String {
        switch self {
        case .automatic: "沿用证据判断"
        case .include: "确认有效消费，纳入统计"
        case .exclude: "从补全和统计中排除"
        case .duplicate: "与另一笔重复，仅保留另一笔"
        case .nonConsumption: "确认非消费资金流"
        case .refund: "确认退款，关联原购买项目"
        }
    }
}
public struct FactAmounts: Codable, Sendable, Equatable {
    public var gross: Int
    public var refund: Int
    public init(gross: Int, refund: Int) { self.gross = gross; self.refund = refund }
}
/// One atomic review field: outcome, corrections and evidence scope must travel together.
public struct TransactionFactReview: Codable, Sendable, Equatable {
    public var signature: String
    public var date: String?
    public var userID: String?
    public var account: String?
    public var amounts = [String: FactAmounts]()
    public var disposition = FactDisposition.automatic
    public var targetID: String?
    public var targetSignature: String?
    public var refundCents: Int?
    public var refundAssociation: RefundAssociationReview?
    public init(record: FinancialLifecycle) throws { signature = try TransactionFacts.signature(record) }
}
public enum FactReviewError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let text): text } }
}
public enum TransactionFacts {
    public static func signature(_ record: FinancialLifecycle) throws -> String {
        // Classification and tags are independent edits, not evidence changes.
        let identity = record.account_identity_before_consolidation
        let object: [String: Any] = ["id": record.id, "date": record.date, "status": record.status,
            "evidence": record.evidence_keys.sorted(), "events": try JSONSerialization.jsonObject(with: JSONEncoder().encode(record.events)),
            "non_consumption": record.non_consumption, "unallocated": record.unallocated_credit_cents,
            "user": identity.map { $0.user_id ?? "" } ?? record.user_id ?? "", "relation": identity?.user_relation ?? record.user_relation,
            "accounts": (identity.map { $0.payment_accounts ?? [] } ?? record.payment_accounts ?? []).sorted(),
            "account_status": identity.map { $0.payment_account_status ?? "" } ?? record.payment_account_status ?? "",
            "account_views": (identity?.account_views ?? record.account_views).sorted(),
            "components": record.components.map { ["id": $0.id, "gross": $0.gross_cents, "refund": $0.refund_cents, "included": $0.included, "reason": $0.reason] as [String: Any] }]
        return ReviewSyncIO.digest(try ReviewSyncIO.json(object))
    }
    public static func validDate(_ text: String) -> Bool {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard text.count == 10, let day = formatter.date(from: text) else { return false }
        return formatter.string(from: day) == text
    }
    public static func validated(_ value: TransactionFactReview, source: FinancialLifecycle, records: [FinancialLifecycle], cutoff: String?) throws -> TransactionFactReview {
        guard let cutoff else { throw FactReviewError.invalid("尚未建立统计范围，不能确认纳入统计的日期。") }
        return try validated(value, source: source, records: records, cutoff: cutoff)
    }
    public static func validated(_ value: TransactionFactReview, source: FinancialLifecycle, records: [FinancialLifecycle], cutoff: String) throws -> TransactionFactReview {
        func fail(_ text: String) throws -> Never { throw FactReviewError.invalid(text) }
        guard value.signature == (try signature(source)) else { try fail("原始证据已更新，请重新核对事实后保存。") }
        var clean = value
        if let date = clean.date, !validDate(date) { try fail("请输入完整且有效的日期，格式为 YYYY-MM-DD。") }
        for text in [clean.userID, clean.account].compactMap({ $0 }) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 80 else { try fail("消费人和支付账户不能为空，最多 80 字。") }
        }
        clean.userID = clean.userID?.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.account = clean.account?.trimmingCharacters(in: .whitespacesAndNewlines)
        for (id, amount) in clean.amounts {
            guard source.components.contains(where: { $0.id == id }), amount.gross >= 0, amount.gross <= 1_000_000_000_000,
                  amount.refund >= 0, amount.refund <= amount.gross else { try fail("购买项目金额无效：退款必须在零与原支付金额之间。") }
        }
        if clean.disposition == .include {
            guard validDate(clean.date ?? source.date), (clean.date ?? source.date) <= cutoff else { try fail("纳入统计前请确认完整日期，日期不能超过统计截止日。") }
            guard source.unallocated_credit_cents == 0 else { try fail("这笔是未归属退款，请选择「确认退款」并关联原购买项目。") }
            guard !source.components.isEmpty, source.components.allSatisfy({ component in
                let amount = clean.amounts[component.id]
                return (amount?.gross ?? component.gross_cents) > 0 && (amount?.refund ?? component.refund_cents) <= (amount?.gross ?? component.gross_cents)
                    && (!component.reason.contains("支付金额待确定") || amount != nil)
            }) else { try fail("纳入统计前请核实所有购买项目的支付与退款金额。") }
        }
        if let association = clean.refundAssociation, clean.disposition == .refund {
            guard clean.amounts.isEmpty else { try fail("整组退款确认不同时更正来源金额，请先恢复金额更正。") }
            try RefundAssociations.validate(association, source: source, records: records, cutoff: cutoff, date: clean.date)
            clean.targetID = nil; clean.targetSignature = nil; clean.refundCents = nil
            return clean
        }
        clean.refundAssociation = nil
        if clean.disposition == .duplicate || clean.disposition == .refund {
            guard let targetID = clean.targetID,
                  let target = records.first(where: { $0.id == targetID || $0.components.contains(where: { $0.id == targetID }) }),
                  target.id != source.id, clean.targetSignature == (try signature(target)) else { try fail("请选择另一笔有效记录；目标证据更新后需要重新核对。") }
            if clean.disposition == .refund {
                guard validDate(clean.date ?? source.date), (clean.date ?? source.date) <= cutoff,
                      !validDate(target.date) || (clean.date ?? source.date) >= target.date else { try fail("请核实退款日期；退款不能早于原购买日期，也不能超过统计截止日。") }
                guard let cents = clean.refundCents, cents > 0,
                      let component = target.components.first(where: { $0.id == targetID }), component.gross_cents > 0,
                      cents <= component.gross_cents - component.refund_cents else { try fail("退款金额必须大于零，且不能超过原购买项目的未退款金额。") }
                guard source.unallocated_credit_cents > 0 || source.events.contains(where: { $0.kind.contains("refund") || $0.kind == "bank_credit" }) else { try fail("这笔没有退款或贷记证据，不能作为退款关联。") }
                guard source.components.allSatisfy({ $0.gross_cents == 0 }) else { try fail("这笔已包含原购买金额，请在购买项目中核实退款，避免重复扣减。") }
                if source.unallocated_credit_cents > 0 && clean.refundCents != source.unallocated_credit_cents { try fail("本笔退款金额须与未归属贷记金额一致；多项目退款请先核对分配。") }
            }
        } else { clean.targetID = nil; clean.targetSignature = nil; clean.refundCents = nil }
        return clean
    }
    public static func relatedRecordIDs(_ value: TransactionFactReview, records: [FinancialLifecycle]) -> Set<String> {
        if let association = value.refundAssociation {
            return Set(association.sourceSignatures.keys).union(association.targetSignatures.keys)
        }
        return Set(records.filter { record in
            record.id == value.targetID || record.components.contains(where: { $0.id == value.targetID })
        }.map(\.id))
    }
    /// Rebuild from the raw report each time. No original amount/date/evidence is rewritten.
    public static func apply(_ overrides: [String: CategoryOverride], to report: inout FinancialReport) {
        let originals = report.records
        let excluded = Set(report.account_consolidation?.excluded_lifecycle_ids ?? [])
        var active = [String: TransactionFactReview]()
        for record in originals {
            if excluded.contains(record.id) { continue }
            guard let value = overrides[record.reviewOverrideKey]?.transaction_facts else { continue }
            if let target = originals.first(where: { $0.id == value.targetID || $0.components.contains(where: { $0.id == value.targetID }) }), excluded.contains(target.id) { continue }
            if let value = try? validated(value, source: record, records: originals, cutoff: report.cutoff ?? "") { active[record.id] = value }
            else if let index = report.records.firstIndex(where: { $0.id == record.id }) { report.records[index].fact_review_status = "原始证据或确认目标已更新，人工事实确认待复核" }
        }
        let indices = Dictionary(uniqueKeysWithValues: originals.enumerated().map { ($0.element.id, $0.offset) })
        // A link must lead to a retained transaction; cycles and links to excluded
        // or already-linked targets stay pending, rather than hiding both records.
        let blocked: Set<FactDisposition> = [.duplicate, .exclude, .nonConsumption, .refund]
        let linkStates = active
        for (id, value) in linkStates where (value.disposition == .duplicate || value.disposition == .refund) && value.refundAssociation == nil {
            let target = originals.first { $0.id == value.targetID || $0.components.contains { $0.id == value.targetID } }
            if let target, target.reviewExcluded || blocked.contains(linkStates[target.id]?.disposition ?? .automatic) {
                active.removeValue(forKey: id)
                if let index = indices[id] { report.records[index].fact_review_status = "关联目标也被排除或关联到其他记录，请重新选择" }
            }
        }
        for (id, value) in active {
            guard let index = indices[id] else { continue }
            report.records[index].fact_review_status = "事实已确认"
            if let date = value.date { report.records[index].date = date }
            if let user = value.userID { report.records[index].user_id = user; report.records[index].user_relation = "confirmed" }
            if let account = value.account {
                report.records[index].payment_accounts = [account]; report.records[index].payment_account_status = "identified"
                report.records[index].account_views = Array(Set(report.records[index].account_views + [account])).sorted()
            }
            for ci in report.records[index].components.indices {
                if let amount = value.amounts[report.records[index].components[ci].id] {
                    report.records[index].components[ci].gross_cents = amount.gross
                    report.records[index].components[ci].refund_cents = amount.refund
                    report.records[index].components[ci].net_cents = amount.gross - amount.refund - (report.records[index].components[ci].reimbursement_cents ?? 0)
                }
                if value.disposition == .include {
                    report.records[index].components[ci].included = true
                    report.records[index].components[ci].reason = ""
                }
            }
            switch value.disposition {
            case .include: report.records[index].non_consumption = false; report.records[index].excluded_from_completion_and_statistics = false; report.records[index].status = "人工确认有效消费"
            case .exclude, .duplicate:
                report.records[index].excluded_from_completion_and_statistics = true
                report.records[index].status = value.disposition == .duplicate ? "重复记录（原证据保留）" : "人工排除"
            case .nonConsumption: report.records[index].non_consumption = true; report.records[index].status = "人工确认非消费资金流"
            default: break
            }
            // Only a date correction changes the cutoff decision. Account or
            // user edits must preserve the existing inclusion and review reasons.
            if value.date != nil && report.records[index].date > (report.cutoff ?? "") {
                for ci in report.records[index].components.indices {
                    report.records[index].components[ci].included = false
                    report.records[index].components[ci].reason = "截止日之后"
                }
            }
        }
        applyRefunds(active, originals: originals, report: &report)
    }
}
