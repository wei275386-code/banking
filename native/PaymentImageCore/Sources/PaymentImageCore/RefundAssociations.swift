import Foundation

public struct RefundCandidateTarget: Codable, Sendable, Equatable {
    public let record_id: String
    public let component_id: String
    public let refund_cents: Int
}

extension TransactionFacts {
    /// Aggregate all human refund decisions, including grouped candidates and
    /// manual links, before changing any amount. A failing set applies
    /// neither its sources nor any of its target allocations.
    static func applyRefunds(_ active: [String: TransactionFactReview], originals: [FinancialLifecycle], report: inout FinancialReport) {
        struct Decision {
            let owner: String
            let sources: Set<String>
            let allocations: [String: Int]
        }
        var decisions = [Decision]()
        for (id, value) in active where value.disposition == .refund {
            if let association = value.refundAssociation {
                decisions.append(Decision(owner: id, sources: Set(association.sourceSignatures.keys), allocations: association.allocations))
            } else if let target = value.targetID, let amount = value.refundCents {
                decisions.append(Decision(owner: id, sources: [id], allocations: [target: amount]))
            }
        }
        var failures = [String: String]()
        let records = Dictionary(uniqueKeysWithValues: report.records.map { ($0.id, $0) })
        let excluded = Set(report.account_consolidation?.excluded_lifecycle_ids ?? [])
        let blocked: Set<FactDisposition> = [.duplicate, .exclude, .nonConsumption, .refund]
        for decision in decisions {
            if decision.sources.contains(where: { id in
                guard let source = records[id] else { return true }
                return source.reviewExcluded || source.non_consumption || excluded.contains(id) ||
                    (id != decision.owner && active[id] != nil)
            }) { failures[decision.owner] = "组合中的退款已有其他确认或排除，请重新核对" }
            for targetID in decision.allocations.keys {
                guard let target = report.records.first(where: { $0.components.contains { $0.id == targetID } }) else {
                    failures[decision.owner] = "原购买项目已更新，请重新核对"; continue
                }
                if target.reviewExcluded || target.non_consumption || excluded.contains(target.id) || blocked.contains(active[target.id]?.disposition ?? .automatic) {
                    failures[decision.owner] = "关联目标也被排除或关联到其他记录，请重新选择"
                }
                if !validDate(target.date) || decision.sources.contains(where: { id in records[id].map { $0.date < target.date } ?? true }) {
                    failures[decision.owner] = "原购买日期与退款日期冲突，请重新核对"
                }
            }
        }
        let claims = Dictionary(grouping: decisions.flatMap { d in d.sources.map { ($0, d.owner) } }, by: { $0.0 })
        for values in claims.values where Set(values.map { $0.1 }).count > 1 {
            for (_, owner) in values { failures[owner] = "同一退款被多条确认使用，请撤回冲突确认后重选" }
        }
        let contributions = Dictionary(grouping: decisions.filter { failures[$0.owner] == nil }.flatMap { d in
            d.allocations.map { (target: $0.key, amount: $0.value, owner: d.owner) }
        }, by: { $0.target })
        for (targetID, values) in contributions {
            guard let component = report.records.flatMap(\.components).first(where: { $0.id == targetID }) else { continue }
            if values.reduce(0, { $0 + $1.amount }) > component.gross_cents - component.refund_cents {
                for value in values { failures[value.owner] = "多笔退款合计超过原支付金额，请重新核对" }
            }
        }
        for decision in decisions {
            if let failure = failures[decision.owner] {
                for index in report.records.indices where report.records[index].id == decision.owner {
                    report.records[index].fact_review_status = failure
                }
                continue
            }
            for ri in report.records.indices {
                for ci in report.records[ri].components.indices {
                    if let amount = decision.allocations[report.records[ri].components[ci].id] {
                        report.records[ri].components[ci].refund_cents += amount
                        report.records[ri].components[ci].net_cents -= amount
                    }
                }
                if decision.sources.contains(report.records[ri].id) {
                    report.records[ri].unallocated_credit_cents = 0
                    report.records[ri].non_consumption = true
                    report.records[ri].status = "退款已关联原购买项目"
                    report.records[ri].fact_review_status = "事实已确认"
                }
            }
        }
    }
}
public struct RefundCandidate: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let source_ids: [String]
    public let targets: [RefundCandidateTarget]
    public let basis: String
    public let confidence: String
    public let grouped: Bool
    public let competing: Bool
    public var amount: Int { targets.reduce(0) { $0 + $1.refund_cents } }
}
/// One synced atomic decision covers the entire refund set. The allocation is
/// to purchase components, never an invented mapping of individual bank rows.
public struct RefundAssociationReview: Codable, Sendable, Equatable {
    public let candidateID: String
    public let sourceSignatures: [String: String]
    public let targetSignatures: [String: String]
    public let allocations: [String: Int]
}
public enum RefundAssociations {
    public static func review(_ candidate: RefundCandidate, records: [FinancialLifecycle]) throws -> TransactionFactReview {
        guard !candidate.source_ids.isEmpty, Set(candidate.source_ids).count == candidate.source_ids.count,
              !candidate.targets.isEmpty, Set(candidate.targets.map(\.component_id)).count == candidate.targets.count,
              let source = records.first(where: { $0.id == candidate.source_ids.sorted().first }) else {
            throw FactReviewError.invalid("退款候选已更新，请重新打开详情。")
        }
        var sources = [String: String](), targets = [String: String](), allocations = [String: Int]()
        for id in candidate.source_ids {
            guard let record = records.first(where: { $0.id == id }) else { throw FactReviewError.invalid("退款来源已更新。") }
            sources[id] = try TransactionFacts.signature(record)
        }
        for target in candidate.targets {
            guard let record = records.first(where: { $0.id == target.record_id }), record.components.contains(where: { $0.id == target.component_id }) else {
                throw FactReviewError.invalid("原购买项目已更新。")
            }
            targets[record.id] = try TransactionFacts.signature(record)
            allocations[target.component_id] = target.refund_cents
        }
        var review = try TransactionFactReview(record: source)
        review.disposition = .refund
        review.refundAssociation = RefundAssociationReview(candidateID: candidate.id, sourceSignatures: sources,
            targetSignatures: targets, allocations: allocations)
        return review
    }
    public static func validate(_ association: RefundAssociationReview, source: FinancialLifecycle,
                                records: [FinancialLifecycle], cutoff: String, date: String?) throws {
        func fail(_ text: String) throws -> Never { throw FactReviewError.invalid(text) }
        guard association.sourceSignatures[source.id] != nil, !association.allocations.isEmpty,
              !association.sourceSignatures.keys.contains(where: { association.targetSignatures[$0] != nil }) else {
            try fail("退款组合的来源或目标无效。")
        }
        let sources = records.filter { association.sourceSignatures[$0.id] != nil }
        let targets = records.filter { association.targetSignatures[$0.id] != nil }
        guard sources.count == association.sourceSignatures.count, targets.count == association.targetSignatures.count,
              !targets.isEmpty else { try fail("退款组合的证据已更新。") }
        for record in sources {
            let day = record.id == source.id ? date ?? record.date : record.date
            guard try TransactionFacts.signature(record) == association.sourceSignatures[record.id],
                  record.unallocated_credit_cents > 0, !record.reviewExcluded, !record.non_consumption,
                  record.components.allSatisfy({ $0.gross_cents == 0 }),
                  record.events.contains(where: { $0.kind == "bank_credit" || $0.kind == "refund" }),
                  TransactionFacts.validDate(day), day <= cutoff else { try fail("退款来源已确认、排除或证据已更新，请重新核对。") }
            for target in targets where day < target.date { try fail("退款日期不能早于原购买日期。") }
        }
        var located = Set<String>()
        for target in targets {
            guard try TransactionFacts.signature(target) == association.targetSignatures[target.id],
                  !target.reviewExcluded, !target.non_consumption else { try fail("原购买证据已更新或已被排除。") }
            for component in target.components {
                if let amount = association.allocations[component.id] {
                    guard amount > 0, amount <= component.gross_cents - component.refund_cents else {
                        try fail("退款不能超过原购买项目的未退款金额。")
                    }
                    located.insert(component.id)
                }
            }
        }
        guard located == Set(association.allocations.keys),
              association.allocations.values.reduce(0, +) == sources.reduce(0, { $0 + $1.unallocated_credit_cents }) else {
            try fail("退款组合金额与来源或原购买项目不一致。")
        }
    }
}
