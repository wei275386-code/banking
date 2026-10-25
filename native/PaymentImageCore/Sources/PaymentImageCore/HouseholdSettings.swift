import Foundation

/// Sources, supported currencies and retained historical references must come
/// from the caller's qualified state. There are no inferred household defaults.
public struct HouseholdSettingsContext: Sendable {
    public let registeredSourceIDs: [String], currencyCodes: [String]
    public let referencedMemberIDs: [String], referencedAccountIDs: [String]
    public init(registeredSourceIDs: [String], currencyCodes: [String], referencedMemberIDs: [String], referencedAccountIDs: [String]) {
        self.registeredSourceIDs = registeredSourceIDs; self.currencyCodes = currencyCodes
        self.referencedMemberIDs = referencedMemberIDs; self.referencedAccountIDs = referencedAccountIDs
    }
}
public struct HouseholdMember: Sendable {
    public let id: String, displayName: String, status: String
}
public struct HouseholdFundingAccount: Sendable {
    public let id: String, displayName: String, currency: String, status: String
    public let ownerMemberID: String?
}
public struct HouseholdSourceOwner: Sendable {
    public let sourceID: String, memberID: String
}
public struct HouseholdFundingRule: Sendable {
    public let id: String, basis: String
    public let selector: [String: String]
    public let targetAccountID: String?
    public let confirmed: Bool
}
public struct HouseholdFundingInput: Sendable {
    public let platform: String?, sourceID: String?, sourceAccountID: String?, sourceAccountName: String?, paymentChannel: String?
    public init(platform: String?, sourceID: String? = nil, sourceAccountID: String? = nil,
                sourceAccountName: String? = nil, paymentChannel: String? = nil) {
        self.platform = platform; self.sourceID = sourceID; self.sourceAccountID = sourceAccountID
        self.sourceAccountName = sourceAccountName; self.paymentChannel = paymentChannel
    }
}
public struct HouseholdFundingResolution: Codable, Sendable {
    public let status: String, accountID: String?, matchedRuleIDs: [String], candidateAccountIDs: [String], reason: String
    enum CodingKeys: String, CodingKey {
        case status, reason, accountID = "account_id", matchedRuleIDs = "matched_rule_ids", candidateAccountIDs = "candidate_account_ids"
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(status, forKey: .status); try values.encode(reason, forKey: .reason)
        try values.encode(accountID, forKey: .accountID)
        try values.encode(matchedRuleIDs, forKey: .matchedRuleIDs); try values.encode(candidateAccountIDs, forKey: .candidateAccountIDs)
    }
}

/// Validated immutable settings only. No state writer, report
/// mutation, sync capability or host authority is installed by this foundation.
public struct HouseholdSettings: Sendable {
    public let profileData: Data, policiesData: Data, householdName: String
    public let members: [HouseholdMember], accounts: [HouseholdFundingAccount]
    public let routes: [HouseholdFundingRule], aliases: [HouseholdFundingRule]
    public let sourceOwners: [HouseholdSourceOwner], exclusionMemberIDs: [String]
    // Swift String equality folds canonical Unicode equivalents. Opaque IDs are
    // indexed by exact UTF-8 bytes; only source labels receive NFC normalization.
    private let accountsByID: [Data: HouseholdFundingAccount]

    public init(profileData: Data, policiesData: Data, context: HouseholdSettingsContext) throws {
        func identifiers(_ values: [String], maximum: Int) throws -> Set<Data> {
            guard values.count <= maximum else { throw Self.invalid("context collection limit") }
            for value in values { _ = try SettingsJSON.text(value, maximum: 256) }
            return Set(values.map { Data($0.utf8) })
        }
        let sources = try identifiers(context.registeredSourceIDs, maximum: 100000)
        let currencies = try identifiers(context.currencyCodes, maximum: 1000)
        let requiredMembers = try identifiers(context.referencedMemberIDs, maximum: 100000)
        let requiredAccounts = try identifiers(context.referencedAccountIDs, maximum: 100000)
        guard sources.count == context.registeredSourceIDs.count, currencies.count == context.currencyCodes.count,
              !currencies.isEmpty, context.currencyCodes.allSatisfy({ value in
                  value.utf8.count == 3 && value.utf8.allSatisfy({ (65...90).contains($0) })
              }) else { throw Self.invalid("invalid context sources or currency capabilities") }
        self.profileData = try ReleaseCanonicalJSON.canonicalize(raw: profileData)
        self.policiesData = try ReleaseCanonicalJSON.canonicalize(raw: policiesData)
        let family = try SettingsJSON(self.profileData, required: ["household_name", "members"])
        householdName = try family.string("household_name", maximum: 256, allowEmpty: true)
        members = try family.array("members", maximum: 1000).map { raw in
            let row = try SettingsJSON(raw, required: ["id", "display_name", "status"])
            return try HouseholdMember(id: row.string("id"), displayName: row.string("display_name"), status: row.status())
        }
        let memberIDs = Set(members.map { Data($0.id.utf8) })
        guard memberIDs.count == members.count, requiredMembers.isSubset(of: memberIDs) else {
            throw Self.invalid("duplicate or missing referenced member")
        }
        let policy = try SettingsJSON(self.policiesData, required: ["accounts", "routes", "aliases", "source_owners", "unknown_account_policy"])
        accounts = try policy.array("accounts", maximum: 10000).map { raw in
            let row = try SettingsJSON(raw, required: ["id", "display_name", "owner_member_id", "currency", "status"])
            let owner = try row.nullableString("owner_member_id"), currency = try row.string("currency")
            guard owner.map({ memberIDs.contains(Data($0.utf8)) }) ?? true,
                  currencies.contains(Data(currency.utf8)) else { throw Self.invalid("dangling account owner or unsupported currency") }
            return try HouseholdFundingAccount(id: row.string("id"), displayName: row.string("display_name", maximum: 4096),
                currency: currency, status: row.status(), ownerMemberID: owner)
        }
        let accountIDs = Set(accounts.map { Data($0.id.utf8) })
        guard accountIDs.count == accounts.count, requiredAccounts.isSubset(of: accountIDs) else {
            throw Self.invalid("duplicate or missing referenced account")
        }
        accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { (Data($0.id.utf8), $0) })
        let owners = try policy.raw("source_owners")
        let ownerEntries = try ReleaseCanonicalJSON.canonicalObjectEntries(raw: owners)
        guard ownerEntries.count <= 100000 else { throw Self.invalid("source owners limit") }
        sourceOwners = try ownerEntries.map { source, rawMember in
            _ = try SettingsJSON.text(source, maximum: 256)
            let member = try SettingsJSON.fragmentString(rawMember, maximum: 256)
            guard sources.contains(Data(source.utf8)), memberIDs.contains(Data(member.utf8)) else { throw Self.invalid("dangling source owner") }
            return HouseholdSourceOwner(sourceID: source, memberID: member)
        }
        let unknown = try SettingsJSON(policy.raw("unknown_account_policy"), required: ["mode", "exclusion_member_ids"])
        guard try unknown.string("mode") == "needs_review" else { throw Self.invalid("unknown account policy") }
        exclusionMemberIDs = try unknown.array("exclusion_member_ids", maximum: 1000).map { try SettingsJSON.fragmentString($0, maximum: 256) }
        let exclusions = Set(exclusionMemberIDs.map { Data($0.utf8) })
        guard exclusions.count == exclusionMemberIDs.count, exclusions.isSubset(of: memberIDs) else { throw Self.invalid("dangling exclusion permission") }
        var ruleIDs = Set<Data>()
        func rules(_ kind: String, maximum: Int, nullTarget: Bool) throws -> [HouseholdFundingRule] {
            var seen = [Data: Data]()
            return try policy.array(kind, maximum: maximum).map { raw in
                let row = try SettingsJSON(raw, required: ["id", "source_selector", "target_account_id", "confirmed", "basis"])
                let id = try row.string("id")
                guard ruleIDs.insert(Data(id.utf8)).inserted else { throw Self.invalid("duplicate funding rule ID") }
                let selector = try SettingsJSON(row.raw("source_selector"), required: ["platform"],
                    optional: ["source_id", "source_account_id", "source_account_name", "payment_channel"])
                guard !Set(selector.keys).intersection(["source_account_id", "source_account_name", "payment_channel"]).isEmpty else {
                    throw Self.invalid("funding condition required")
                }
                var values = [String: String]()
                for key in selector.keys {
                    let label = key == "source_account_name" || key == "payment_channel"
                    let value = try selector.string(key, maximum: label ? 4096 : 256)
                    values[key] = label ? SettingsJSON.label(value) : value
                }
                if let source = values["source_id"], !sources.contains(Data(source.utf8)) { throw Self.invalid("dangling rule source") }
                let target = try row.nullableString("target_account_id")
                guard target != nil || nullTarget, target.map({ accountIDs.contains(Data($0.utf8)) }) ?? true else { throw Self.invalid("dangling funding target") }
                let selectorKey = try ReleaseCanonicalJSON.canonicalize(raw: JSONEncoder().encode(values))
                let targetKey = try JSONEncoder().encode(target)
                guard seen[selectorKey].map({ $0 == targetKey }) ?? true else { throw Self.invalid("identical selectors with conflicting targets") }
                seen[selectorKey] = targetKey
                return try HouseholdFundingRule(id: id, basis: row.string("basis", maximum: 4096), selector: values,
                    targetAccountID: target, confirmed: row.boolean("confirmed"))
            }
        }
        routes = try rules("routes", maximum: 10000, nullTarget: false)
        aliases = try rules("aliases", maximum: 20000, nullTarget: true)
    }

    public func resolveFunding(_ input: HouseholdFundingInput) throws -> HouseholdFundingResolution {
        let supplied = ["platform": input.platform, "source_id": input.sourceID, "source_account_id": input.sourceAccountID,
                        "source_account_name": input.sourceAccountName, "payment_channel": input.paymentChannel]
        var values = [String: String]()
        for (key, value) in supplied {
            guard let value else { continue }
            let label = key == "source_account_name" || key == "payment_channel"
            _ = try SettingsJSON.text(value, maximum: label ? 4096 : 256, allowEmpty: true)
            values[key] = label ? SettingsJSON.label(value) : value
        }
        func result(_ status: String, _ reason: String, account: String? = nil, rules: [String] = [], candidates: [String] = []) -> HouseholdFundingResolution {
            HouseholdFundingResolution(status: status, accountID: account, matchedRuleIDs: rules, candidateAccountIDs: candidates, reason: reason)
        }
        guard !(values["platform"] ?? "").isEmpty,
              ["source_account_id", "source_account_name", "payment_channel"].contains(where: { !(values[$0] ?? "").isEmpty }) else {
            return result("needs_review", "missing_funding_input")
        }
        for (tier, rules) in [("route", routes), ("alias", aliases)] {
            let matched = rules.filter { rule in
                rule.confirmed && rule.selector.allSatisfy { key, value in
                    values[key].map({ !$0.isEmpty && Data($0.utf8) == Data(value.utf8) }) ?? false
                }
            }
            guard !matched.isEmpty else { continue }
            let ids = matched.map(\.id).sorted(by: SettingsJSON.byteOrder)
            let targets = Set(matched.map { $0.targetAccountID.map { Data($0.utf8) } })
            let candidates = targets.compactMap { $0.map { String(decoding: $0, as: UTF8.self) } }.sorted(by: SettingsJSON.byteOrder)
            guard targets.count == 1 else { return result("needs_review", "conflicting_rules", rules: ids, candidates: candidates) }
            guard let target = matched[0].targetAccountID else { return result("non_funding", "non_funding_channel", rules: ids) }
            guard accountsByID[Data(target.utf8)]?.status == "active" else { return result("needs_review", "inactive_account", rules: ids, candidates: candidates) }
            return result("resolved", "matched_" + tier, account: target, rules: ids, candidates: candidates)
        }
        return result("needs_review", "unmatched")
    }
    private static func invalid(_ detail: String) -> WorkspaceError { .invalid("household settings: " + detail) }
}

internal struct SettingsJSON {
    let bytes: Data, keys: [String]
    private let values: [Data: Data]
    init(_ bytes: Data, required: [String], optional: [String] = [], allowAdditional: Bool = false) throws {
        let entries = try ReleaseCanonicalJSON.canonicalObjectEntries(raw: bytes)
        self.bytes = bytes; keys = entries.map(\.key)
        values = Dictionary(uniqueKeysWithValues: entries.map { (Data($0.key.utf8), $0.value) })
        let actual = Set(keys.map { Data($0.utf8) }), requiredKeys = Set(required.map { Data($0.utf8) })
        guard requiredKeys.isSubset(of: actual), allowAdditional || actual.isSubset(of: requiredKeys.union(optional.map { Data($0.utf8) })) else {
            throw WorkspaceError.invalid("household settings: unknown or missing key")
        }
    }
    func raw(_ key: String) throws -> Data {
        guard let raw = values[Data(key.utf8)] else { throw WorkspaceError.invalid("missing setting") }
        return raw
    }
    func string(_ key: String, maximum: Int = 256, allowEmpty: Bool = false) throws -> String {
        try Self.fragmentString(raw(key), maximum: maximum, allowEmpty: allowEmpty)
    }
    func nullableString(_ key: String) throws -> String? {
        let bytes = try raw(key)
        return bytes == Data("null".utf8) ? nil : try Self.fragmentString(bytes, maximum: 256)
    }
    func boolean(_ key: String) throws -> Bool {
        let bytes = try raw(key)
        guard bytes == Data("true".utf8) || bytes == Data("false".utf8) else { throw WorkspaceError.invalid("settings boolean") }
        return bytes == Data("true".utf8)
    }
    func status() throws -> String {
        let status = try string("status")
        guard status == "active" || status == "inactive" else { throw WorkspaceError.invalid("settings status") }
        return status
    }
    func array(_ key: String, maximum: Int) throws -> [Data] {
        guard let values = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw(key), atObjectKeys: []), values.count <= maximum else {
            throw WorkspaceError.invalid("settings array limit or type")
        }
        return values
    }
    static func fragmentString(_ raw: Data, maximum: Int, allowEmpty: Bool = false) throws -> String {
        try text(JSONDecoder().decode(String.self, from: raw), maximum: maximum, allowEmpty: allowEmpty)
    }
    static func text(_ value: String, maximum: Int, allowEmpty: Bool = false) throws -> String {
        guard value.unicodeScalars.count <= maximum, allowEmpty || !trim(value).isEmpty else { throw WorkspaceError.invalid("invalid settings text") }
        return value
    }
    static func trim(_ value: String) -> String {
        func white(_ scalar: Unicode.Scalar) -> Bool {
            (9...13).contains(scalar.value) || [32, 133, 160, 5760, 8232, 8233, 8239, 8287, 12288].contains(scalar.value) || (8192...8202).contains(scalar.value)
        }
        let scalars = Array(value.unicodeScalars)
        let trimmed = scalars.drop(while: white).reversed().drop(while: white).reversed()
        return String(String.UnicodeScalarView(trimmed))
    }
    static func label(_ value: String) -> String { trim(value).precomposedStringWithCanonicalMapping }
    static func byteOrder(_ left: String, _ right: String) -> Bool { left.utf8.lexicographicallyPrecedes(right.utf8) }
}
