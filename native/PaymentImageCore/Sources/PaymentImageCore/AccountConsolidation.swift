import Foundation

/// Original identity fields keep existing fact signatures valid across a rename.
/// Evidence, events, amounts and inclusion still participate in the signature.
public struct AccountIdentityBeforeConsolidation: Codable, Sendable, Equatable {
    public let user_id: String?
    public let user_relation: String
    public let payment_accounts: [String]?
    public let payment_account_status: String?
    public let account_views: [String]
}
public struct AccountConsolidationPolicy: Codable, Sendable {
    public let aliases: [String: String?]
    public let excluded_lifecycle_ids: [String]
    public var display_name_prefixes: [String]? = nil
}
public enum AccountConsolidation {
    public static func displayName(_ id: String?) -> String? {
        id
    }
    public static func canonical(_ name: String, policy: AccountConsolidationPolicy) -> String? {
        if let mapped = policy.aliases[name] { return mapped }
        for prefix in policy.display_name_prefixes ?? [] where !prefix.isEmpty && name.hasPrefix(prefix) {
            let plain = String(name.dropFirst(prefix.count))
            if let mapped = policy.aliases[plain] { return mapped }
        }
        return name
    }
    /// Snapshots already contain canonical funding. Also normalize an older
    /// device's account edit after fact projection, without rewriting its operation.
    public static func apply(to report: inout FinancialReport, preserving originals: [FinancialLifecycle]) {
        guard let policy = report.account_consolidation else { return }
        let excluded = Set(policy.excluded_lifecycle_ids)
        let frozen = Dictionary(uniqueKeysWithValues: originals.filter { excluded.contains($0.id) }.map { ($0.id, $0) })
        for i in report.records.indices {
            if let original = frozen[report.records[i].id] { report.records[i] = original; continue }
            guard report.records[i].account_identity_before_consolidation != nil else { continue }
            let accounts = Array(Set((report.records[i].payment_accounts ?? []).compactMap { canonical($0, policy: policy) })).sorted()
            report.records[i].payment_accounts = accounts
            report.records[i].account_views = accounts
            if accounts.isEmpty, report.records[i].payment_account_status == "identified" { report.records[i].payment_account_status = "unresolved" }
            report.records[i].user_display_name = report.records[i].userDisplayName
        }
    }
}
