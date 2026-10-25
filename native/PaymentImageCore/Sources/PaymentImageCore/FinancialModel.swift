import Foundation

public struct FinancialCategory: Codable, Sendable, Identifiable {
    public var id: String { primary }
    public let primary: String; public let secondaries: [String]
}
public struct FinancialComponent: Codable, Sendable, Identifiable, Equatable {
    public let id: String; public let title: String
    public var gross_cents: Int; public var refund_cents: Int; public var net_cents: Int
    public var reimbursement_cents: Int? = nil
    public var primary: String; public var secondary: String; public var classification_basis: String
    public var included: Bool; public var reason: String
    public var recurrence: String? = nil
    public var effectiveRecurrence: String { recurrence == "recurring" ? "recurring" : "one_time" }
    public var classification_keys: [String]? = nil
    public var tags: [String] = []
    public var tag_basis: [String: String]? = nil
    public var completion_confirmation: CompletionConfirmation? = nil
    public var completionConfirmed: Bool { completion_confirmation?.matches(self) == true }
}
public struct FinancialEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: String; public let date: String; public let kind: String; public let source: String
    public let amount_cents: Int; public let status: String
    public var payment_account: String? = nil
}
extension FinancialComponent {
    enum CodingKeys: String, CodingKey { case id, title, gross_cents, refund_cents, net_cents, reimbursement_cents, primary, secondary, classification_basis, included, reason, recurrence, classification_keys, tags, tag_basis, completion_confirmation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        gross_cents = try c.decode(Int.self, forKey: .gross_cents); refund_cents = try c.decode(Int.self, forKey: .refund_cents); net_cents = try c.decode(Int.self, forKey: .net_cents)
        reimbursement_cents = try c.decodeIfPresent(Int.self, forKey: .reimbursement_cents)
        primary = try c.decode(String.self, forKey: .primary); secondary = try c.decode(String.self, forKey: .secondary)
        classification_basis = try c.decode(String.self, forKey: .classification_basis)
        included = try c.decode(Bool.self, forKey: .included); reason = try c.decode(String.self, forKey: .reason)
        recurrence = try c.decodeIfPresent(String.self, forKey: .recurrence); classification_keys = try c.decodeIfPresent([String].self, forKey: .classification_keys)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        tag_basis = try c.decodeIfPresent([String: String].self, forKey: .tag_basis)
        completion_confirmation = try c.decodeIfPresent(CompletionConfirmation.self, forKey: .completion_confirmation)
    }
}
public struct FinancialLifecycle: Codable, Sendable, Identifiable, Equatable {
    public let id: String; public var date: String; public let title: String; public var status: String
    public var account_views: [String]; public let evidence_keys: [String]
    public var components: [FinancialComponent]; public let events: [FinancialEvent]
    // Raw events remain the fact-review signature input; the display projection
    // groups confirmed observations of the same payment without losing evidence.
    public var payment_events: [FinancialEvent]? = nil
    public var trace_sources: [TransactionTraceSource]? = nil
    public var traceSearchText: String { (trace_sources ?? []).map { [$0.merchant, $0.title, $0.date, $0.provider_reference, $0.merchant_reference].compactMap { $0 }.joined(separator: " ") }.joined(separator: " ") }
    public var paymentEvents: [FinancialEvent] { payment_events ?? events }
    public var bank_settlement_group: BankSettlementGroup? = nil
    public var user_relation: String; public var non_consumption: Bool; public var unallocated_credit_cents: Int
    public var user_id: String? = nil
    public var payment_accounts: [String]? = nil
    public var payment_account_status: String? = nil
    public var payment_channels: [String]? = nil
    public var payment_account_pending_reasons: [String]? = nil
    public var user_display_name: String? = nil
    public var review_exclusion_allowed: Bool? = nil
    public var account_identity_before_consolidation: AccountIdentityBeforeConsolidation? = nil
    public var userDisplayName: String {
        if user_relation == "other_user", user_id == nil { return "其他用户（已确认）" }
        return user_display_name ?? AccountConsolidation.displayName(user_id) ?? "未确认"
    }
    public var excluded_from_completion_and_statistics: Bool? = nil
    public var fact_review_status: String? = nil
    public var factReviewConfirmed: Bool { fact_review_status?.hasPrefix("事实已确认") == true }
    public var reviewExcluded: Bool { excluded_from_completion_and_statistics == true }
    public var canExcludeFromReview: Bool { review_exclusion_allowed == true && user_id != nil && payment_account_status == "unresolved" }
    public var reviewOverrideKey: String { "transaction:" + id }
}
public struct TransactionTraceSource: Codable, Sendable, Equatable, Identifiable {
    public let id: String; public var association: String; public var basis: String
    public let owner_id: String?
    public let platform: String; public let date: String; public let post_date: String?
    public let merchant: String?; public let title: String?; public let amount_cents: Int?
    public let currency: String; public let payment_method: String?; public let event_kind: String; public let status: String
    public let provider_reference: String?; public let merchant_reference: String?
    public let source_name: String?; public let location: String; public let source_evidence: EvidenceReference?
}
public struct BankSettlementGroup: Codable, Sendable, Equatable {
    public let id: String; public let count: Int; public let bank_keys: [String]
    public let basis: String
}
public struct FireBuckets: Codable, Sendable, Equatable {
    @FireInput public var safetyBucket: Double; @FireInput public var parentMedicalBucket: Double
    public var elderCareEnabled: Bool; @FireInput public var elderCareBucket: Double
    @FireInput public var otherBuckets: Double; public var includeBuckets: Bool
}
public struct FireInvesting: Codable, Sendable, Equatable {
    @FireInput public var withdrawalRate: Double; @FireInput public var annualReturn: Double
    @FireInput public var inflation: Double; @FireInput public var maxDrawdown: Double
}
public struct FireHousing: Codable, Sendable, Equatable {
    public var enabled: Bool; @FireInput public var year: Int; @FireInput public var totalPrice: Double
    @FireInput public var downPaymentRatio: Double; @FireInput public var loanRate: Double; @FireInput public var loanYears: Int
    @FireInput public var fees: Double; @FireInput public var renovation: Double; @FireInput public var annualMaintenance: Double
    public var reduceRent: Bool; @FireInput public var minLiquidAssets: Double; public var ownerHomeCountsAsFireAsset: Bool
    public var annualRentReduction: Double? = nil
}
public struct FireChildren: Codable, Sendable, Equatable {
    public var enabled: Bool; @FireInput public var count: Int; @FireInput public var birthYear: Int; @FireInput public var annualCost: Double
    @FireInput public var educationBucket: Double; @FireInput public var incomeImpact: Double
}
public struct FireBranches: Codable, Sendable, Equatable { public var housing: FireHousing; public var children: FireChildren }
public struct FireParameters: Codable, Sendable, Equatable {
    public var needsInput: Bool { needsBaseInput || !missingRequiredInputs.isEmpty || inputValidationMessage != nil }
    @FireInput public var baseYear: Int; @FireInput public var birthYear: Int; @FireInput public var targetAge: Int
    @FireInput public var currentFireAssets: Double; @FireInput public var afterTaxSalary: Double; @FireInput public var annualContribution: Double
    @FireBudgetMap public var expenseModes: [String: Double]; @FireInput public var annualHardCap: Double
    @FireBudgetMap public var expenseBreakdown: [String: Double]; public var buckets: FireBuckets
    public var investing: FireInvesting; public var branches: FireBranches
}
public struct FinancialReport: Codable, Sendable {
    public let dataset_id: String; public let cutoff: String?
    public var source_dataset_id: String? = nil
    public var coverage: WorkspaceCoverage? = nil
    public var records: [FinancialLifecycle]; public var taxonomy: [FinancialCategory]
    public var fire_parameters: FireParameters; public let coverage_note: String; public let coverage_complete: Bool
    public let video_materials: [FinancialVideoMaterial]?
    public let video_summary: VideoExtractionSummary?
    public var account_consolidation: AccountConsolidationPolicy? = nil
    public var refund_candidates: [RefundCandidate]? = nil
    public var source_record_sets: [SourceRecordSet]? = nil
    public var source_record_set_candidates: [SourceRecordSet]? = nil
}
public struct FinancialVideoMaterial: Codable, Sendable, Identifiable {
    public let id: String; public let title: String; public let date: String
    public let platform: String?
    public let amount_cents: Int; public let status: String
    public var payment_account: String? = nil; public let date_basis: String
    public let source_evidence: EvidenceReference
}
public struct VideoExtractionSummary: Codable, Sendable {
    public let raw_complete_crops: Int; public let deduplicated_materials: Int
    public let wallet_links: Int; public let unparsed_crops: Int; public let undated_materials: Int
    public let recall_status: String
}
public struct CategoryOverride: Codable, Sendable { public let primary: String; public let secondary: String
    public let recurrence: String?
    public let tags: [String]?
    public let classification_basis: String?
    public let completion_confirmation: CompletionConfirmation?
    public let excluded_from_completion_and_statistics: Bool?
    public let transaction_facts: TransactionFactReview?
    public let source_record_set_review: SourceRecordSetReview?
    public let suppressed_discovery_tags: [String]?
    public let discovery_tags: [String]?
    public init(primary: String, secondary: String, recurrence: String? = nil, tags: [String]? = nil, classification_basis: String? = nil, completion_confirmation: CompletionConfirmation? = nil, excluded_from_completion_and_statistics: Bool? = nil, transaction_facts: TransactionFactReview? = nil, source_record_set_review: SourceRecordSetReview? = nil, suppressed_discovery_tags: [String]? = nil, discovery_tags: [String]? = nil) { self.suppressed_discovery_tags = suppressed_discovery_tags; self.discovery_tags = discovery_tags; self.source_record_set_review = source_record_set_review; self.transaction_facts = transaction_facts; self.excluded_from_completion_and_statistics = excluded_from_completion_and_statistics; self.completion_confirmation = completion_confirmation; self.primary = primary; self.secondary = secondary; self.recurrence = recurrence; self.tags = tags; self.classification_basis = classification_basis }
}
public struct ReviewStatistics: Sendable {
    public var gross = 0; public var refunds = 0; public var net = 0
    public var pending = 0; public var pendingCount = 0; public var count = 0
    public var unallocatedCredits = 0; public var byPrimary = [String: Int]()
    public var bySecondary = [String: Int](); public var byMonth = [String: Int]()
    public var byTag = [String: Int](); public var countByTag = [String: Int]()
    public var categoriesByTag = [String: [String: Int]]()
}
public struct BranchProjection: Sendable {
    public let estimatedYears: Double?
    public let fundingGap: Double
    public let targetAssets: Double
}
public enum FinancialMath {
    public static func mortgage(principal: Double, annualRate: Double, years: Int) -> Double {
        let principal = max(0, principal), months = Double(max(1, years * 12))
        let rate = max(0, annualRate) / 12
        return rate == 0 ? principal / months : principal * rate / (1 - pow(1 + rate, -months))
    }
    public static func branchProjection(_ p: FireParameters) -> BranchProjection {
        guard !p.needsInput else { return BranchProjection(estimatedYears: nil, fundingGap: .nan, targetAssets: .nan) }
        let h = p.branches.housing, c = p.branches.children
        let housingMonth = max(0, (h.year - p.baseYear) * 12)
        let childMonth = max(0, (c.birthYear - p.baseYear) * 12)
        let cashNeed = h.enabled ? max(0, h.totalPrice * h.downPaymentRatio + h.fees + h.renovation) : 0
        let rentReduction = h.enabled && h.reduceRent ? max(0, h.annualRentReduction ?? 0) : 0
        let childExpense = c.enabled ? max(0, c.annualCost * Double(c.count)) : 0
        let annualExpense = max(0, (p.expenseModes["normal"] ?? 0) + childExpense + (h.enabled ? h.annualMaintenance : 0) - rentReduction)
        let portfolioTarget = target(p, annualExpense: annualExpense) + (c.enabled ? max(0, c.educationBucket) : 0)
        let payment = mortgage(principal: h.totalPrice * (1 - h.downPaymentRatio), annualRate: h.loanRate, years: h.loanYears)
        let monthlyReturn = pow(1 + realReturn(nominal: p.investing.annualReturn, inflation: p.investing.inflation), 1 / 12) - 1
        let inflationFactor = pow(1 + max(-0.99, p.investing.inflation), 1 / 12)
        let minimumLiquidAssets = h.enabled ? max(0, h.minLiquidAssets) : 0
        let loanEndMonth = housingMonth + max(1, h.loanYears) * 12
        func mortgageReserve(at month: Int) -> Double {
            guard h.enabled, payment > 0 else { return 0 }
            let start = max(month, housingMonth), remaining = max(0, loanEndMonth - start)
            var discount = pow(inflationFactor, Double(start)) * pow(1 + monthlyReturn, Double(start - month))
            var reserve = 0.0
            for _ in 0..<remaining {
                discount *= inflationFactor * (1 + monthlyReturn)
                reserve += payment / discount
            }
            return reserve
        }
        var assets = p.currentFireAssets, housePaid = !h.enabled
        var currentTarget = portfolioTarget
        let centTolerance = 0.005
        for month in 0...1200 {
            // A finite loan needs a finite payment reserve at retirement. Keep
            // nominal instalments in the same present-price units as assets.
            let retirementTarget = max(portfolioTarget + mortgageReserve(at: month), minimumLiquidAssets)
            if h.enabled && !housePaid && month >= housingMonth {
                let purchaseFunding = cashNeed + minimumLiquidAssets
                if assets + centTolerance < purchaseFunding { return BranchProjection(estimatedYears: nil, fundingGap: purchaseFunding - assets, targetAssets: retirementTarget) }
                assets = max(0, assets - cashNeed); housePaid = true
            }
            // Future one-off purchase funding stays reserved until paid.
            currentTarget = retirementTarget + (housePaid ? 0 : cashNeed)
            if assets + centTolerance >= currentTarget { return BranchProjection(estimatedYears: Double(month) / 12, fundingGap: 0, targetAssets: currentTarget) }
            var contribution = p.annualContribution / 12
            if h.enabled && month >= housingMonth {
                contribution += (rentReduction - h.annualMaintenance) / 12
                if month < loanEndMonth { contribution -= payment / pow(inflationFactor, Double(month + 1)) }
            }
            if c.enabled && month >= childMonth { contribution -= (childExpense + max(0, c.incomeImpact)) / 12 }
            assets = assets * (1 + monthlyReturn) + contribution
            if assets < 0 { return BranchProjection(estimatedYears: nil, fundingGap: -assets, targetAssets: currentTarget) }
        }
        return BranchProjection(estimatedYears: nil, fundingGap: 0, targetAssets: currentTarget)
    }
    public static func realReturn(nominal: Double, inflation: Double) -> Double {
        (1 + nominal) / (1 + max(-0.99, inflation)) - 1
    }
    public static func statistics(_ records: [FinancialLifecycle]) -> ReviewStatistics {
        var result = ReviewStatistics()
        for record in records where !record.non_consumption && !record.reviewExcluded {
            result.unallocatedCredits += record.unallocated_credit_cents
            for c in record.components {
                if c.included {
                    result.count += 1; result.gross += c.gross_cents; result.refunds += c.refund_cents; result.net += c.net_cents
                    result.byPrimary[c.primary, default: 0] += c.net_cents
                    result.bySecondary[c.primary + " / " + c.secondary, default: 0] += c.net_cents
                    result.byMonth[String(record.date.prefix(7)), default: 0] += c.net_cents
                    for tag in Set(c.tags) {
                        result.byTag[tag, default: 0] += c.net_cents
                        result.countByTag[tag, default: 0] += 1
                        result.categoriesByTag[tag, default: [:]][c.primary + " / " + c.secondary, default: 0] += c.net_cents
                    }
                } else if !c.reason.isEmpty { result.pendingCount += 1; result.pending += c.gross_cents }
            }
        }
        return result
    }
    public static func target(_ p: FireParameters, annualExpense: Double? = nil) -> Double {
        guard !p.needsBaseInput, p.investing.withdrawalRate > 0 else { return .nan }
        let buckets = p.buckets.includeBuckets ? p.buckets.safetyBucket + p.buckets.parentMedicalBucket + p.buckets.otherBuckets + (p.buckets.elderCareEnabled ? p.buckets.elderCareBucket : 0) : 0
        return (annualExpense ?? p.expenseModes["normal"] ?? 0) / p.investing.withdrawalRate + buckets
    }
    public static func project(assets: Double, annualContribution: Double, annualReturn: Double, years: Double) -> Double {
        let months = max(0, Int((years * 12).rounded()))
        let monthlyReturn = pow(1 + max(-0.99, annualReturn), 1 / 12.0) - 1
        var value = assets
        for _ in 0..<months { value = value * (1 + monthlyReturn) + annualContribution / 12 }
        return value
    }
    public static func reachYears(assets: Double, target: Double, annualContribution: Double, annualReturn: Double) -> Double? {
        let monthlyReturn = pow(1 + max(-0.99, annualReturn), 1 / 12.0) - 1
        var value = assets
        for month in 0...1200 {
            if value >= target { return Double(month) / 12 }
            value = value * (1 + monthlyReturn) + annualContribution / 12
        }
        return nil
    }
    public static func requiredMonthly(assets: Double, target: Double, annualReturn: Double, years: Double) -> Double {
        let months = max(1, (years * 12).rounded())
        let rate = pow(1 + max(-0.99, annualReturn), 1 / 12.0) - 1
        if abs(rate) < 0.00000001 { return max(0, (target - assets) / months) }
        return max(0, (target - assets * pow(1 + rate, months)) * rate / (pow(1 + rate, months) - 1))
    }
    public static func capitalReduction(monthlySaving: Double, withdrawalRate: Double) -> Double {
        withdrawalRate > 0 ? max(0, monthlySaving) * 12 / withdrawalRate : 0
    }
}

public struct WorkspaceCoverage: Codable, Sendable, Equatable {
    public struct Basis: Codable, Sendable, Equatable {
        public let kind: String
        public let source_ids: [String]
    }
    public let basis: Basis
    public let mode: String
    public let from: String?
    public let to: String?
    public let observed_from: String?
    public let observed_to: String?
    public let pending_from: String?
    public let pending_to: String?
    public let revision: Int64
    public var label: String {
        guard let from, let to else { return "暂无可靠日期，尚未建立统计范围" }
        return "\(from) 至 \(to) · " + (mode == "explicit" ? "已确认范围" : "按可靠记录自动确定范围")
    }
}
