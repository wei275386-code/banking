import Foundation

public struct HouseholdRegisteredSource: Sendable {
    public let id: String, path: String, platform: String, sha256: String
}
public struct HouseholdSettingsImpact: Sendable {
    public let evidenceCount: Int, changedFundingCount: Int, resolvedCount: Int
    public let needsReviewCount: Int, nonFundingCount: Int, conflictingCount: Int, changedSourceOwnerCount: Int
}

/// A hash- and state-pointer-pinned read. It grants no host/processor role and
/// does not claim to discover every reference in evidence.
public struct HouseholdSettingsState: Sendable {
    /// Local settings editing cannot create a parallel authority for a bound
    /// household. Callers repeat this check under their maintenance lease.
    public static func requireUnbound(paths: WorkspacePaths) throws {
        for name in ["family-connection", "host-authorization", "client-active", "client-identity"] {
            let file = paths.device.appendingPathComponent(name + ".json")
            try WorkspaceIO.rejectSymlinks(file)
            guard !FileManager.default.fileExists(atPath: file.path) else {
                throw WorkspaceError.invalid("请通过当前家庭同步连接编辑家庭设置。")
            }
        }
    }
    public let pointer: WorkspaceStatePointer, settings: HouseholdSettings
    public let dependencies: [String: String]
    public let sources: [HouseholdRegisteredSource]
    private let paths: WorkspacePaths
    internal let context: HouseholdSettingsContext
    private init(paths: WorkspacePaths, pointer: WorkspaceStatePointer, settings: HouseholdSettings,
                 context: HouseholdSettingsContext, dependencies: [String: String], sources: [HouseholdRegisteredSource]) {
        self.paths = paths; self.pointer = pointer; self.settings = settings
        self.context = context; self.dependencies = dependencies
        self.sources = sources
    }
    public static func read(paths: WorkspacePaths, currencyCodes: [String], referencedMemberIDs: [String], referencedAccountIDs: [String]) throws -> Self {
        try read(paths: paths, state: paths.readState(validateFiles: true), currencyCodes: currencyCodes,
            referencedMemberIDs: referencedMemberIDs, referencedAccountIDs: referencedAccountIDs)
    }
    internal static func read(paths: WorkspacePaths, state: StateHandle, currencyCodes: [String],
                              referencedMemberIDs: [String], referencedAccountIDs: [String]) throws -> Self {
        try WorkspaceIO.validateManifest(state, validateFiles: true)
        try ReviewWorkspaceMembership.validate(state: state)
        let manifestRaw = try WorkspaceIO.read(state.manifest)
        guard WorkspaceIO.digest(manifestRaw) == state.pointer.manifestHash else { throw WorkspaceError.stalePointer }
        let manifest = try SettingsJSON(manifestRaw, required: ["files"], allowAdditional: true)
        let fileEntries = try ReleaseCanonicalJSON.canonicalObjectEntries(raw: manifest.raw("files"))
        let files = try Dictionary(uniqueKeysWithValues: fileEntries.map { entry in
            let hash = try SettingsJSON.fragmentString(entry.value, maximum: 64)
            try WorkspaceIO.requireHash(hash); return (Data(entry.key.utf8), hash)
        })
        func pinned(_ path: String) throws -> Data {
            guard let hash = files[Data(path.utf8)] else { throw WorkspaceError.invalid("settings dependency missing: " + path) }
            let raw = try WorkspaceIO.read(state.file(path))
            guard WorkspaceIO.digest(raw) == hash else { throw WorkspaceError.stalePointer }
            return raw
        }
        let profilePath = "config/family-profile.json", policiesPath = "config/account-policies.json", registryPath = "config/review-import-sources.json"
        let profile = try pinned(profilePath), policies = try pinned(policiesPath), registryRaw = try pinned(registryPath)
        let registry = try SettingsJSON(registryRaw, required: ["sources"], allowAdditional: true)
        var sourceIDs = [String](), sources = [HouseholdRegisteredSource](), seenIDs = Set<Data>(), seenPaths = Set<Data>(), dependencies = [String: String]()
        for raw in try registry.array("sources", maximum: 100_000) {
            let row = try SettingsJSON(raw, required: ["id", "path", "platform", "sha256"], allowAdditional: true)
            let id = try row.string("id"), path = try row.string("path", maximum: 4096), hash = try row.string("sha256", maximum: 64)
            let platform = try row.string("platform")
            _ = try state.file(path); try WorkspaceIO.requireHash(hash)
            guard seenIDs.insert(Data(id.utf8)).inserted, seenPaths.insert(Data(path.utf8)).inserted,
                  files[Data(path.utf8)] == hash else { throw WorkspaceError.invalid("duplicate or unretained registry source") }
            sourceIDs.append(id)
            sources.append(HouseholdRegisteredSource(id: id, path: path, platform: platform, sha256: hash))
            guard dependencies.updateValue(hash, forKey: path) == nil else { throw WorkspaceError.invalid("ambiguous source path") }
        }
        let context = HouseholdSettingsContext(registeredSourceIDs: sourceIDs, currencyCodes: currencyCodes,
            referencedMemberIDs: referencedMemberIDs, referencedAccountIDs: referencedAccountIDs)
        let settings = try HouseholdSettings(profileData: profile, policiesData: policies, context: context)
        guard settings.profileData == profile, settings.policiesData == policies else { throw WorkspaceError.invalid("committed settings must be canonical") }
        for path in [profilePath, policiesPath, registryPath] { dependencies[path] = files[Data(path.utf8)]! }
        return Self(paths: paths, pointer: state.pointer, settings: settings, context: context, dependencies: dependencies, sources: sources)
    }
    /// Read-only comparison of funding rules over committed parsed observations.
    /// This is not a financial recompute or a claim about confirmation validity.
    public func previewImpact(candidate: HouseholdSettings) throws -> HouseholdSettingsImpact {
        let candidate = try prepareEdit(profileData: candidate.profileData, policiesData: candidate.policiesData).candidate
        let state = try paths.readState(validateFiles: true)
        guard state.pointer == pointer else { throw WorkspaceError.stalePointer }
        let limit = WorkspaceBusinessValidator.maximumProjectionBytes
        let raw = try ReleaseCanonicalJSON.canonicalize(raw: WorkspaceIO.read(state.file("review/payment-evidence.json"), limit: Int64(limit)), inputLimit: limit)
        let impact = try Self.previewImpact(settings: settings, candidate: candidate, sources: sources, evidenceRaw: raw)
        guard try paths.readPointer() == pointer else { throw WorkspaceError.stalePointer }
        return impact
    }
    internal static func previewImpact(settings: HouseholdSettings, candidate: HouseholdSettings, sources: [HouseholdRegisteredSource], evidenceRaw raw: Data) throws -> HouseholdSettingsImpact {
        guard let evidence = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let clusters = evidence["clusters"] as? [[String: Any]],
              let banks = evidence["bank_records"] as? [[String: Any]],
              clusters.count + banks.count <= 100_000 else { throw WorkspaceError.invalid("funding preview evidence") }
        let wallets = try clusters.map { cluster -> [String: Any] in
            guard let row = cluster["representative"] as? [String: Any] else { throw WorkspaceError.invalid("funding preview cluster") }
            return row
        }
        let byID = Dictionary(uniqueKeysWithValues: sources.map { (Data($0.id.utf8), $0) })
        let byHash = Dictionary(grouping: sources, by: \.sha256)
        let oldCurrencies = Dictionary(uniqueKeysWithValues: settings.accounts.map { (Data($0.id.utf8), $0.currency) })
        let newCurrencies = Dictionary(uniqueKeysWithValues: candidate.accounts.map { (Data($0.id.utf8), $0.currency) })
        let oldOwners = Dictionary(uniqueKeysWithValues: settings.sourceOwners.map { (Data($0.sourceID.utf8), Data($0.memberID.utf8)) })
        let newOwners = Dictionary(uniqueKeysWithValues: candidate.sourceOwners.map { (Data($0.sourceID.utf8), Data($0.memberID.utf8)) })
        var changed = 0, resolved = 0, pending = 0, nonFunding = 0, conflicting = 0, changedOwner = 0
        for (row, isBank) in wallets.map({ ($0, false) }) + banks.map({ ($0, true) }) {
            try Task.checkCancellation()
            let digest = row["file_sha256"] as? String ?? row["statement_sha256"] as? String
            var source = (row["source_id"] as? String).flatMap { byID[Data($0.utf8)] }
            if source?.sha256 != digest {
                let choices = digest.flatMap { byHash[$0] } ?? []
                source = choices.count == 1 ? choices[0] : nil
            }
            let input = HouseholdFundingInput(platform: isBank ? "bank" : row["platform"] as? String,
                sourceID: source?.id, sourceAccountID: row[isBank ? "account_number" : "source_account_id"] as? String,
                sourceAccountName: row["payment_method"] as? String, paymentChannel: row["payment_channel"] as? String)
            func match(_ value: HouseholdSettings, currencies: [Data: String]) throws -> (String, Data?, String) {
                let result = try value.resolveFunding(input)
                let account = result.accountID.map { Data($0.utf8) }
                if result.status == "resolved", let account, currencies[account] != row["currency"] as? String {
                    return ("needs_review", nil, "currency_mismatch")
                }
                return (result.status, account, result.reason)
            }
            let before = try match(settings, currencies: oldCurrencies), after = try match(candidate, currencies: newCurrencies)
            if before.0 != after.0 || before.1 != after.1 || before.2 != after.2 { changed += 1 }
            if after.2 == "conflicting_rules" { conflicting += 1 }
            if after.0 == "resolved" { resolved += 1 }
            else if after.0 == "non_funding" { nonFunding += 1 }
            else { pending += 1 }
            if let source {
                let original = (row["owner_id"] as? String).map { Data($0.utf8) }, key = Data(source.id.utf8)
                if (oldOwners[key] ?? original) != (newOwners[key] ?? original) { changedOwner += 1 }
            }
        }
        return HouseholdSettingsImpact(evidenceCount: wallets.count + banks.count, changedFundingCount: changed,
            resolvedCount: resolved, needsReviewCount: pending, nonFundingCount: nonFunding,
            conflictingCount: conflicting, changedSourceOwnerCount: changedOwner)
    }
    public func prepareEdit(profileData: Data, policiesData: Data) throws -> HouseholdSettingsEditPlan {
        func union(_ left: [String], _ right: [String]) -> [String] {
            var seen = Set<Data>()
            return (left + right).filter { seen.insert(Data($0.utf8)).inserted }
        }
        let retained = HouseholdSettingsContext(registeredSourceIDs: context.registeredSourceIDs, currencyCodes: context.currencyCodes,
            referencedMemberIDs: union(context.referencedMemberIDs, settings.members.map(\.id)),
            referencedAccountIDs: union(context.referencedAccountIDs, settings.accounts.map(\.id)))
        let candidate = try HouseholdSettings(profileData: profileData, policiesData: policiesData, context: retained)
        return HouseholdSettingsEditPlan(baseline: self, candidate: candidate)
    }
    fileprivate func revalidate(paths: WorkspacePaths) throws -> Self {
        guard paths == self.paths else { throw WorkspaceError.stalePointer }
        let current = try Self.read(paths: paths, currencyCodes: context.currencyCodes,
            referencedMemberIDs: context.referencedMemberIDs, referencedAccountIDs: context.referencedAccountIDs)
        guard current.pointer == pointer, current.dependencies == dependencies else { throw WorkspaceError.stalePointer }
        return current
    }
}

/// A validated draft only. No files are written and no capability is created.
/// Future writers must revalidate while holding their gate and keep full-tuple
/// CAS through staging/commit; success here alone is not atomic authorization.
public struct HouseholdSettingsEditPlan: Sendable {
    public let candidate: HouseholdSettings
    private let baseline: HouseholdSettingsState
    fileprivate init(baseline: HouseholdSettingsState, candidate: HouseholdSettings) { self.baseline = baseline; self.candidate = candidate }
    public func revalidate(paths: WorkspacePaths) throws -> HouseholdSettings {
        let current = try baseline.revalidate(paths: paths)
        return try current.prepareEdit(profileData: candidate.profileData, policiesData: candidate.policiesData).candidate
    }
}
