import Foundation

public enum SourceRecordSetDisposition: String, Codable, Sendable {
    case confirm, reject, automatic
}
/// One synchronized field binds the decision to the complete evidence set.
public struct SourceRecordSetReview: Codable, Sendable, Equatable {
    public var fingerprint: String
    public var disposition: SourceRecordSetDisposition
    public init(fingerprint: String, disposition: SourceRecordSetDisposition) {
        self.fingerprint = fingerprint; self.disposition = disposition
    }
}
public struct SourceRecordSet: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: String
    public let retained_ids: [String]
    public let shadow_ids: [String]
    public let signatures: [String: String]
    public let retained_event_keys: [String]?
    public let basis: String
    public var status: String
    public let evidence_keys: [String]
    public let shadow_records: [FinancialLifecycle]
    public let retained_records: [FinancialLifecycle]?
    public let origin: String
    public let default_status: String?
    public let can_confirm: Bool
    public let reasons: [String]
    public let fingerprint: String
    public let date: String
    public let amount_cents: Int
    public let network_count: Int
    public let bank_count: Int
    public var review_reason: String?
    public var reviewOverrideKey: String { "source-set:" + id }
    public var confirmed: Bool { status == "confirmed" }
    public var statusTitle: String {
        switch status {
        case "confirmed": "已归并"
        case "rejected": "已拒绝"
        case "evidence_changed": "证据变化，待复核"
        default: "待确认"
        }
    }
    enum CodingKeys: String, CodingKey {
        case id, kind, retained_ids, shadow_ids, signatures, retained_event_keys, basis, status, evidence_keys, shadow_records, retained_records, origin, default_status, can_confirm, reasons, fingerprint, date, amount_cents, network_count, bank_count, review_reason
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "payment"
        retained_ids = try c.decode([String].self, forKey: .retained_ids)
        shadow_ids = try c.decode([String].self, forKey: .shadow_ids)
        signatures = try c.decodeIfPresent([String: String].self, forKey: .signatures) ?? [:]
        retained_event_keys = try c.decodeIfPresent([String].self, forKey: .retained_event_keys)
        basis = try c.decodeIfPresent(String.self, forKey: .basis) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "candidate"
        evidence_keys = try c.decodeIfPresent([String].self, forKey: .evidence_keys) ?? []
        shadow_records = try c.decodeIfPresent([FinancialLifecycle].self, forKey: .shadow_records) ?? []
        retained_records = try c.decodeIfPresent([FinancialLifecycle].self, forKey: .retained_records)
        origin = try c.decode(String.self, forKey: .origin)
        default_status = try c.decodeIfPresent(String.self, forKey: .default_status)
        can_confirm = try c.decodeIfPresent(Bool.self, forKey: .can_confirm) ?? true
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? shadow_records.first?.date ?? retained_records?.first?.date ?? ""
        let eventKinds = kind == "refund" ? ["refund", "bank_credit"] : ["payment", "bank_debit"]
        amount_cents = try c.decodeIfPresent(Int.self, forKey: .amount_cents) ?? shadow_records.first?.events.first(where: { eventKinds.contains($0.kind) })?.amount_cents ?? 0
        network_count = try c.decodeIfPresent(Int.self, forKey: .network_count) ?? shadow_ids.count
        bank_count = try c.decodeIfPresent(Int.self, forKey: .bank_count) ?? retained_ids.count
        review_reason = try c.decodeIfPresent(String.self, forKey: .review_reason)
    }
}

public enum SourceRecordSets {
    public static func groups(_ report: FinancialReport) -> [SourceRecordSet] {
        (report.source_record_sets ?? []) + (report.source_record_set_candidates ?? [])
    }
    /// Recover archived observations before any facts are applied. Existing records
    /// win so a newer report member is never silently replaced with an old archive.
    public static func baselineRecords(_ report: FinancialReport) -> [FinancialLifecycle] {
        var records = report.records
        var seen = Set(records.map(\.id))
        for group in groups(report) {
            for record in group.shadow_records where seen.insert(record.id).inserted { records.append(record) }
        }
        return records
    }
    public static func apply(_ overrides: [String: CategoryOverride], to report: inout FinancialReport) {
        let sourceGroups = groups(report)
        guard !sourceGroups.isEmpty else { return }
        let records = baselineRecords(report)
        let index = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let participants = Set(sourceGroups.flatMap { $0.retained_ids + $0.shadow_ids })
        let signatureIndex = Dictionary(participants.compactMap { id in index[id].flatMap { record in (try? TransactionFacts.signature(record)).map { (id, $0) } } }, uniquingKeysWith: { first, _ in first })
        let componentOwners = Dictionary(records.flatMap { record in record.components.map { ($0.id, record.id) } }, uniquingKeysWith: { first, _ in first })
        var linkedIDs = Set<String>()
        for value in overrides.values.compactMap(\.transaction_facts) {
            if let id = value.targetID { linkedIDs.insert(componentOwners[id] ?? id) }
            if let association = value.refundAssociation {
                linkedIDs.formUnion(association.sourceSignatures.keys)
                linkedIDs.formUnion(association.targetSignatures.keys)
            }
        }
        var projected = [SourceRecordSet]()
        for var group in sourceGroups {
            let decision = overrides[group.reviewOverrideKey]?.source_record_set_review
            let rejects = decision?.disposition == .reject
            let manual = decision?.disposition == .confirm
            let automatic = decision == nil || (decision?.disposition == .automatic)
            let backendDefault = group.default_status.map { $0 == "confirmed" } ??
                (group.status == "confirmed" && ["automatic", "manual", "confirmed"].contains(group.origin) || ["manual", "confirmed"].contains(group.origin) && group.status == "rejected")
            let requested = manual || (automatic && backendDefault)
            group.review_reason = group.reasons.isEmpty ? nil : group.reasons.joined(separator: "；")
            if rejects {
                group.status = "rejected"; group.review_reason = "已保留两种来源各自的记录。"
            } else if manual && decision?.fingerprint != group.fingerprint {
                group.status = "evidence_changed"; group.review_reason = "整组证据、账户或币种已变化，请重新核对后确认。"
            } else if let reason = blockingReason(group, records: index, signatures: signatureIndex, linkedIDs: linkedIDs, overrides: overrides) {
                if requested || group.status == "confirmed" { group.status = "evidence_changed" }
                group.review_reason = reason
            } else if automatic && group.origin != "confirmed", let reason = automaticConflict(group, records: index, overrides: overrides) {
                group.status = "candidate"; group.review_reason = reason
            } else if requested {
                group.status = "confirmed"
            } else if !automatic {
                group.status = "evidence_changed"; group.review_reason = "确认版本无法使用，请重新核对后保存。"
            } else if group.status != "evidence_changed" {
                group.status = "candidate"
            }
            projected.append(group)
        }
        // Overlapping active sets cannot hide a member on behalf of two groups.
        var memberships = [String: [Int]]()
        for (offset, group) in projected.enumerated() where group.confirmed {
            for id in group.retained_ids + group.shadow_ids { memberships[id, default: []].append(offset) }
        }
        let conflicts = Set(memberships.values.filter { $0.count > 1 }.flatMap { $0 })
        for offset in conflicts {
            projected[offset].status = "evidence_changed"
            projected[offset].review_reason = "此记录同时参与多组归并，须先处理重叠关系。"
        }
        let hidden = Set(projected.filter(\.confirmed).flatMap(\.shadow_ids))
        report.records = records.filter { !hidden.contains($0.id) }
        let indices = Dictionary(report.records.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for group in projected where !group.confirmed {
            let evidence = Set(group.evidence_keys)
            let groupBasis = group.basis + "；整组来源已确认，未指定逐笔配对"
            for id in group.retained_ids {
                guard let offset = indices[id], let traces = report.records[offset].trace_sources else { continue }
                let ownEvidence = Set(report.records[offset].evidence_keys)
                report.records[offset].trace_sources = traces.compactMap { trace in
                    // Remove only display links introduced by this confirmed set.
                    // Independent links and the bank's own evidence remain visible.
                    guard evidence.contains(trace.id), trace.basis == groupBasis else { return trace }
                    guard ownEvidence.contains(trace.id) else { return nil }
                    var own = trace; own.basis = "交易已关联的原始证据"; return own
                }
            }
        }
        report.source_record_sets = projected.filter(\.confirmed)
        report.source_record_set_candidates = projected.filter { !$0.confirmed }
    }
    private static func automaticConflict(_ group: SourceRecordSet, records: [String: FinancialLifecycle], overrides: [String: CategoryOverride]) -> String? {
        for id in group.retained_ids + group.shadow_ids {
            guard let record = records[id] else { continue }
            if group.shadow_ids.contains(id) {
                let keys = [record.reviewOverrideKey] + record.components.flatMap { [$0.id] + ($0.classification_keys ?? []) }
                if keys.contains(where: { key in
                    guard let value = overrides[key] else { return false }
                    return !["", "待分类"].contains(value.primary) || value.completion_confirmation != nil
                }) { return "另一来源已有人工分类或补全确认，请核对后人工归并。" }
            }
        }
        return nil
    }
    private static func blockingReason(_ group: SourceRecordSet, records: [String: FinancialLifecycle], signatures: [String: String], linkedIDs: Set<String>, overrides: [String: CategoryOverride]) -> String? {
        guard group.can_confirm else { return group.reasons.isEmpty ? "来源组尚不满足确认条件，请先核对缺项或冲突。" : group.reasons.joined(separator: "；") }
        let retained = Set(group.retained_ids), shadows = Set(group.shadow_ids)
        guard !retained.isEmpty, !shadows.isEmpty, retained.count == group.retained_ids.count,
              shadows.count == group.shadow_ids.count, retained.isDisjoint(with: shadows),
              (retained.union(shadows)).allSatisfy({ records[$0] != nil }) else { return "整组参与记录不完整或重复，请重新核对。" }
        let archived = (group.retained_records ?? []) + group.shadow_records
        let archiveIndex = Dictionary(archived.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if !(retained.union(shadows)).allSatisfy({ archiveIndex[$0] != nil }) { return "原始事实绑定不完整，暂不归并。" }
        for id in retained.union(shadows) {
            if let bound = archiveIndex[id], (try? TransactionFacts.signature(bound)) != signatures[id] { return "参与记录的原始事实已变化，请重新核对整组。" }
            guard let record = records[id] else { continue }
            let edit = overrides[record.reviewOverrideKey]
            if record.reviewExcluded || edit?.excluded_from_completion_and_statistics == true { return "参与记录已有人工排除，暂不归并。" }
            if let facts = edit?.transaction_facts {
                if facts.signature != signatures[id] { return "参与记录的人工事实确认已过期，请先复核原始事实。" }
                if group.origin != "confirmed",
                   facts.date.map({ $0 != record.date }) == true || facts.userID.map({ $0 != record.user_id }) == true || facts.account.map({ !((record.payment_accounts ?? []).count == 1 && record.payment_accounts?.first == $0) }) == true {
                    return "参与记录的日期、消费人或账户更正与来源组不一致，请先复核事实。"
                }
                let allowed: Set<FactDisposition> = shadows.contains(id) ? [.automatic] : group.kind == "refund" ? [.automatic, .include, .refund] : [.automatic, .include]
                if !facts.amounts.isEmpty || !allowed.contains(facts.disposition) {
                    return "参与记录已有金额更正或事实处理，暂不归并。"
                }
            }
            if shadows.contains(id), linkedIDs.contains(id) { return "待归并来源已被退款或其他事实确认引用，暂不归并。" }
        }
        return nil
    }
}
