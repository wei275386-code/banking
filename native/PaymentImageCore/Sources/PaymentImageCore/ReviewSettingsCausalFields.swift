import Foundation

internal enum ReviewCausalFieldRules {
    static func validate(key: String, value: String, seed: Bool) throws {
        let raw = Data(value.utf8), canonical = try ReleaseCanonicalJSON.canonicalize(raw: raw)
        if key.hasPrefix("settings/") {
            guard ReviewSettingsFieldDocuments.mappings.contains(where: { $0.fieldKey == key }),
                  canonical == raw else { throw WorkspaceError.invalid("unsupported/noncanonical settings field") }
            try HouseholdSettingsDocumentShape.validate(raw, field: key)
        } else if !seed {
            guard key == "catalog/@tree" || key.hasPrefix("override/") || key.hasPrefix("parameter/") || key.hasPrefix("deferred/") else {
                throw WorkspaceError.invalid("unsupported field key")
            }
        }
    }
}

/// Standalone document shape only. Cross-document/source/history references are
/// qualified against the replayed pair below, never guessed during raw parsing.
private enum HouseholdSettingsDocumentShape {
    static func validate(_ raw: Data, field: String) throws {
        if field == "settings/family-profile" {
            let row = try SettingsJSON(raw, required: ["household_name", "members"])
            _ = try row.string("household_name", allowEmpty: true)
            for raw in try row.array("members", maximum: 1000) {
                let member = try SettingsJSON(raw, required: ["id", "display_name", "status"])
                _ = try member.string("id"); _ = try member.string("display_name"); _ = try member.status()
            }
            return
        }
        let row = try SettingsJSON(raw, required: ["accounts", "routes", "aliases", "source_owners", "unknown_account_policy"])
        for raw in try row.array("accounts", maximum: 10000) {
            let account = try SettingsJSON(raw, required: ["id", "display_name", "owner_member_id", "currency", "status"])
            _ = try account.string("id"); _ = try account.string("display_name", maximum: 4096)
            _ = try account.nullableString("owner_member_id"); _ = try account.status()
            let currency = try account.string("currency")
            guard currency.utf8.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }) else { throw WorkspaceError.invalid("settings currency shape") }
        }
        for (kind, maximum) in [("routes", 10000), ("aliases", 20000)] {
            for raw in try row.array(kind, maximum: maximum) {
                let rule = try SettingsJSON(raw, required: ["id", "source_selector", "target_account_id", "confirmed", "basis"])
                _ = try rule.string("id"); _ = try rule.string("basis", maximum: 4096); _ = try rule.boolean("confirmed")
                let target = try rule.nullableString("target_account_id")
                guard kind == "aliases" || target != nil else { throw WorkspaceError.invalid("settings route target") }
                let selector = try SettingsJSON(rule.raw("source_selector"), required: ["platform"], optional: ["source_id", "source_account_id", "source_account_name", "payment_channel"])
                guard !Set(selector.keys).intersection(["source_account_id", "source_account_name", "payment_channel"]).isEmpty else { throw WorkspaceError.invalid("settings selector condition") }
                for key in selector.keys { _ = try selector.string(key, maximum: ["source_account_name", "payment_channel"].contains(key) ? 4096 : 256) }
            }
        }
        let owners = try ReleaseCanonicalJSON.canonicalObjectEntries(raw: row.raw("source_owners"))
        guard owners.count <= 100000 else { throw WorkspaceError.invalid("settings owners shape budget") }
        for (source, value) in owners { _ = try SettingsJSON.text(source, maximum: 256); _ = try SettingsJSON.fragmentString(value, maximum: 256) }
        let unknown = try SettingsJSON(row.raw("unknown_account_policy"), required: ["mode", "exclusion_member_ids"])
        guard try unknown.string("mode") == "needs_review" else { throw WorkspaceError.invalid("settings unknown-account mode") }
        let exclusions = try unknown.array("exclusion_member_ids", maximum: 1000).map { Data(try SettingsJSON.fragmentString($0, maximum: 256).utf8) }
        guard exclusions.count == Set(exclusions).count else { throw WorkspaceError.invalid("duplicate exclusion member") }
    }
}

/// Only an unconflicted, pair-validated settings view is ready. A conflicted
/// checkpoint retains every head for inspection, never an authorized winner.
public enum ReviewSettingsCausalPreparation: Sendable {
    case ready(ReviewSettingsCausalCheckpoint)
    case conflicted(checkpoint: ReviewCausalFieldCheckpoint, fields: [String])
    case waiting(ancestorIDs: Set<String>)
}
public struct ReviewSettingsCausalCheckpoint: Sendable {
    public let causal: ReviewCausalFieldCheckpoint, settings: HouseholdSettings
    public let bindingID: String
    fileprivate init(causal: ReviewCausalFieldCheckpoint, settings: HouseholdSettings, bindingID: String) {
        self.causal = causal; self.settings = settings; self.bindingID = bindingID
    }
}

/// Pair-validated current settings replay within one explicit family binding.
public enum ReviewSettingsCausalFields {
    internal static func prepareInventory(seedValues: [String: String], origins: [ReviewRevisionOrigin], bindingID: String,
                                          context: HouseholdSettingsContext) throws -> ReviewSettingsCausalPreparation {
        try WorkspaceIO.requireUUID(bindingID, field: "inventory replay target")
        guard origins.allSatisfy({ $0.key.sourceBindingID == bindingID }) else {
            throw WorkspaceError.invalid("inventory source protocol/binding context")
        }
        let baseline = try seedSettings(seedValues, context: context)
        let result = try ReviewCausalFields.replay(seedValues: seedValues, revisions: origins.map { .init(verified: $0) },
            allowedBindings: Set(origins.map { $0.key.sourceBindingID }).union([bindingID]))
        return try qualify(result, baseline: baseline, context: context, bindingID: bindingID)
    }
    public static func prepare(seedValues: [String: String], revisions: [ReviewNativeRevision], bindingID: String,
                               context: HouseholdSettingsContext) throws -> ReviewSettingsCausalPreparation {
        try WorkspaceIO.requireUUID(bindingID, field: "settings replay binding")
        let baseline = try seedSettings(seedValues, context: context)
        let result = try ReviewCausalFields.replay(seedValues: seedValues, revisions: revisions,
            allowedBindings: [bindingID])
        return try qualify(result, baseline: baseline, context: context, bindingID: bindingID)
    }

    /// Append current operations to the verified family baseline.
    public static func append(_ revisions: [ReviewNativeRevision], to baseline: ReviewSettingsCausalCheckpoint,
                              bindingID: String, context: HouseholdSettingsContext) throws -> ReviewSettingsCausalPreparation {
        try WorkspaceIO.requireUUID(bindingID, field: "settings append binding")
        let source = baseline.causal
        guard baseline.bindingID == bindingID,
              revisions.allSatisfy({ $0.origin.sourceBindingID == bindingID }) else {
            throw WorkspaceError.invalid("settings append protocol/binding context")
        }
        let allowed = Set(source.revisions.map { $0.origin.sourceBindingID }).union([bindingID])
        guard case .ready(let verified) = try ReviewCausalFields.replay(seedValues: source.seedValues, revisions: source.revisions,
            allowedBindings: allowed),
              try verified.fieldState() == source.fieldState(), try headBytes(verified) == headBytes(source), verified.inventory == source.inventory else {
            throw WorkspaceError.invalid("settings append baseline replay differs")
        }
        for (key, value) in ReviewSettingsFieldDocuments.values(baseline.settings) {
            guard source.values[key].map({ Data($0.utf8) }) == Data(value.utf8) else { throw WorkspaceError.invalid("settings append baseline pair differs") }
        }
        let result = try ReviewCausalFields.replay(seedValues: source.seedValues, revisions: source.revisions + revisions,
            allowedBindings: allowed)
        return try qualify(result, baseline: baseline.settings, context: context, bindingID: bindingID)
    }

    private static func seedSettings(_ seed: [String: String], context: HouseholdSettingsContext) throws -> HouseholdSettings {
        for (key, value) in seed where key.hasPrefix("settings/") { try ReviewCausalFieldRules.validate(key: key, value: value, seed: true) }
        let mappings = ReviewSettingsFieldDocuments.mappings
        guard let profile = seed[mappings[0].fieldKey], let policies = seed[mappings[1].fieldKey] else { throw WorkspaceError.invalid("settings seed pair missing") }
        // Additional current historical references may be introduced by later
        // real revisions, so they are checked against replay, not the old seed.
        let initial = HouseholdSettingsContext(registeredSourceIDs: context.registeredSourceIDs, currencyCodes: context.currencyCodes,
            referencedMemberIDs: [], referencedAccountIDs: [])
        return try HouseholdSettings(profileData: Data(profile.utf8), policiesData: Data(policies.utf8), context: initial)
    }
    private static func qualify(_ result: ReviewCausalFieldPreparation, baseline: HouseholdSettings,
                                context: HouseholdSettingsContext, bindingID: String) throws -> ReviewSettingsCausalPreparation {
        switch result {
        case .waiting(let missing): return .waiting(ancestorIDs: missing)
        case .ready(let checkpoint):
            let fields = checkpoint.conflicts.filter { $0.hasPrefix("settings/") }
            if !fields.isEmpty { return .conflicted(checkpoint: checkpoint, fields: fields) }
            let mappings = ReviewSettingsFieldDocuments.mappings
            guard let profile = checkpoint.values[mappings[0].fieldKey], let policies = checkpoint.values[mappings[1].fieldKey] else { throw WorkspaceError.invalid("replayed settings pair missing") }
            func union(_ a: [String], _ b: [String]) -> [String] { var seen = Set<Data>(); return (a + b).filter { seen.insert(Data($0.utf8)).inserted } }
            let retained = HouseholdSettingsContext(registeredSourceIDs: context.registeredSourceIDs, currencyCodes: context.currencyCodes,
                referencedMemberIDs: union(context.referencedMemberIDs, baseline.members.map(\.id)),
                referencedAccountIDs: union(context.referencedAccountIDs, baseline.accounts.map(\.id)))
            let settings = try HouseholdSettings(profileData: Data(profile.utf8), policiesData: Data(policies.utf8), context: retained)
            return .ready(ReviewSettingsCausalCheckpoint(causal: checkpoint, settings: settings, bindingID: bindingID))
        }
    }
    private static func headBytes(_ checkpoint: ReviewCausalFieldCheckpoint) throws -> Data {
        try WorkspaceIO.canonical(["fields": checkpoint.heads.keys.sorted(by: SettingsJSON.byteOrder).map { key in
            ["field": key, "heads": checkpoint.heads[key]!.map { ["revision_id": $0.revisionID, "source_binding_id": $0.sourceBindingID,
                "device": $0.device, "clock": $0.clock, "value": $0.value] as [String: Any] }] as [String: Any]
        }])
    }
}
