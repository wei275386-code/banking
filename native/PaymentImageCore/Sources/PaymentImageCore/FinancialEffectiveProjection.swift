import Foundation

/// Current saved decisions and user edits share the same effective-view rules.
public enum FinancialEffectiveProjection {
    /// Strict read-only effective document. The source files are never updated.
    public static func read(review: URL) throws -> Data {
        let raw = try WorkspaceIO.read(review.appendingPathComponent("financial-review.json"), limit: Int64(WorkspaceBusinessValidator.maximumProjectionBytes))
        _ = try ReleaseCanonicalJSON.canonicalize(raw: raw, inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes)
        try validateIdentities(raw: raw)
        var report = try JSONDecoder().decode(FinancialReport.self, from: raw)
        let original = report
        let overrideURL = review.appendingPathComponent("review-overrides.json")
        let overrides: [String: CategoryOverride]
        let overrideValues: [String: Any]
        if FileManager.default.fileExists(atPath: overrideURL.path) {
            let bytes = try Data(contentsOf: overrideURL)
            let keys = try ReleaseCanonicalJSON.canonicalObjectKeys(raw: bytes)
            guard keys.allSatisfy({ !$0.isEmpty }), Set(keys).count == keys.count else {
                throw ReleaseCanonicalJSON.ContractError.invalidJSON("duplicate or empty override identity")
            }
            overrideValues = try WorkspaceIO.object(bytes)
            overrides = try JSONDecoder().decode([String: CategoryOverride].self, from: bytes)
        } else { overrides = [:]; overrideValues = [:] }
        let catalog = try CategoryCatalogFile.read(root: review, taxonomy: report.taxonomy,
                                                  records: SourceRecordSets.baselineRecords(report))
        report.records = SourceRecordSets.baselineRecords(report)
        var before = report
        var lossless = try baselineDocument(raw: raw)
        // Groups can move between confirmed and candidate arrays. Use the same
        // original groups as diff bases in both arrays, retaining unknown fields.
        let groups = SourceRecordSets.groups(original)
        if !groups.isEmpty {
            before.source_record_sets = groups
            before.source_record_set_candidates = groups
            let groupRaw = try combinedGroups(raw: raw)
            for key in ["source_record_sets", "source_record_set_candidates"] {
                lossless = try ReleaseCanonicalJSON.replacingObjectMember(raw: lossless, key: key, valueRaw: groupRaw, inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes)
            }
        }
        applyCompletion(overrides, to: &report, catalog: catalog)
        let taxonomy = try effectiveTaxonomy(raw: raw, before: original.taxonomy, catalog: catalog)
        // Taxonomy has name-based model IDs, which change on rename. Patch its
        // raw rows using the catalog's durable IDs instead of replacing them.
        var diffAfter = report
        diffAfter.taxonomy = before.taxonomy
        var result = try ReleaseCanonicalJSON.applyingModelChanges(raw: lossless,
            before: JSONEncoder().encode(before), after: JSONEncoder().encode(diffAfter), inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes)
        result = try ReleaseCanonicalJSON.replacingObjectMember(raw: result, key: "taxonomy", valueRaw: taxonomy, inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes)
        let catalogURL = review.appendingPathComponent("category-catalog.json")
        let catalogSHA256 = FileManager.default.fileExists(atPath: catalogURL.path)
            ? ReviewSyncIO.digest(try Data(contentsOf: catalogURL)) : nil
        result = try preservingConfirmedOutcomes(raw: result, overrideValues: overrideValues, catalogSHA256: catalogSHA256)
        let user = review.appendingPathComponent("fire-parameters-user.json")
        guard FileManager.default.fileExists(atPath: user.path) else { return result }
        guard let base = try ReleaseCanonicalJSON.canonicalFragment(raw: result, atObjectKeys: ["fire_parameters"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let fire = try ReleaseCanonicalJSON.mergingObjects(raw: base, changes: Data(contentsOf: user))
        _ = try JSONDecoder().decode(FireParameters.self, from: fire)
        return try ReleaseCanonicalJSON.replacingObjectMember(raw: result, key: "fire_parameters", valueRaw: fire, inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes)
    }

    /// Preserve saved decisions until a later edit supersedes the affected component.
    static func preservingConfirmedOutcomes(raw: Data, overrideValues: [String: Any], catalogSHA256: String? = nil) throws -> Data {
        let allowed: Set<String> = ["primary", "secondary", "tags", "recurrence", "classification_basis",
            "classification_evidence_basis", "tag_basis", "completion_confirmation", "included", "reason"]
        var records = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["records"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? []
        var changed = false
        for ri in records.indices {
            var components = try ReleaseCanonicalJSON.canonicalArrayElements(raw: records[ri], atObjectKeys: ["components"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? []
            for ci in components.indices {
                guard let markerRaw = try ReleaseCanonicalJSON.canonicalFragment(raw: components[ci], atObjectKeys: ["confirmed_outcome"]),
                      let marker = try JSONSerialization.jsonObject(with: markerRaw) as? [String: Any] else { continue }
                guard let fields = try ReleaseCanonicalJSON.canonicalFragment(raw: markerRaw, atObjectKeys: ["fields"]) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let keys = try ReleaseCanonicalJSON.canonicalObjectKeys(raw: fields)
                guard Set(keys).isSubset(of: allowed) else { throw CocoaError(.fileReadCorruptFile) }
                guard let expected = marker["override_values"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                let unchanged = try expected.allSatisfy { key, value in
                    let current = overrideValues[key] ?? NSNull()
                    return try WorkspaceIO.canonical(["value": current]) == WorkspaceIO.canonical(["value": value])
                }
                guard unchanged else { continue }
                // Fact overlays run after the raw historical statistics and
                // remain authoritative for inclusion/date/refund decisions.
                let sameCatalog = marker["catalog_sha256"] as? String == catalogSHA256
                for key in keys where key != "included" && key != "reason" && (sameCatalog || key == "completion_confirmation") {
                    guard let value = try ReleaseCanonicalJSON.canonicalFragment(raw: fields, atObjectKeys: [key]) else { throw CocoaError(.fileReadCorruptFile) }
                    components[ci] = try ReleaseCanonicalJSON.replacingObjectMember(raw: components[ci], key: key, valueRaw: value)
                }
                changed = true
            }
            records[ri] = try ReleaseCanonicalJSON.replacingObjectMember(raw: records[ri], key: "components", valueRaw: array(components))
        }
        guard changed else { return raw }
        return try ReleaseCanonicalJSON.replacingObjectMember(raw: raw, key: "records", valueRaw: array(records),
            inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes)
    }

    private static func identity(_ raw: Data) throws -> String {
        guard let fragment = try ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: ["id"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes),
              let id = try? JSONDecoder().decode(String.self, from: fragment), !id.isEmpty else {
            throw ReleaseCanonicalJSON.ContractError.invalidJSON("missing stable identity")
        }
        return id
    }
    private static func validateIdentities(raw: Data) throws {
        var recordSpellings: [String: Data] = [:]
        var componentOwners: [String: (String, Data)] = [:]
        func records(_ values: [Data]) throws {
            var ids = Set<String>()
            for value in values {
                let id = try identity(value)
                let spelling = Data(id.utf8)
                guard ids.insert(id).inserted,
                      recordSpellings[id].map({ $0 == spelling }) ?? true else {
                    throw ReleaseCanonicalJSON.ContractError.invalidJSON("duplicate record identity")
                }
                recordSpellings[id] = spelling
                for field in ["components", "events", "payment_events", "trace_sources"] {
                    var childIDs = Set<String>()
                    for child in try ReleaseCanonicalJSON.canonicalArrayElements(raw: value, atObjectKeys: [field], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? [] {
                        let childID = try identity(child)
                        guard childIDs.insert(childID).inserted else {
                            throw ReleaseCanonicalJSON.ContractError.invalidJSON("duplicate nested identity")
                        }
                        if field == "components" {
                            let spelling = Data(childID.utf8)
                            if let (owner, existing) = componentOwners[childID], owner != id || existing != spelling {
                                throw ReleaseCanonicalJSON.ContractError.invalidJSON("ambiguous global component identity")
                            }
                            componentOwners[childID] = (id, spelling)
                        }
                    }
                }
            }
        }
        try records(ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["records"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? [])
        var groupIDs = Set<String>()
        for key in ["source_record_sets", "source_record_set_candidates"] {
            for group in try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: [key], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? [] {
                guard groupIDs.insert(try identity(group)).inserted else {
                    throw ReleaseCanonicalJSON.ContractError.invalidJSON("duplicate source group identity")
                }
                try records(ReleaseCanonicalJSON.canonicalArrayElements(raw: group, atObjectKeys: ["shadow_records"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? [])
                try records(ReleaseCanonicalJSON.canonicalArrayElements(raw: group, atObjectKeys: ["retained_records"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? [])
            }
        }
        let categories = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["taxonomy"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? []
        var names = Set<String>()
        for category in categories {
            guard let bytes = try ReleaseCanonicalJSON.canonicalFragment(raw: category, atObjectKeys: ["primary"]),
                  let name = try? JSONDecoder().decode(String.self, from: bytes), !name.isEmpty,
                  names.insert(name).inserted else {
                throw ReleaseCanonicalJSON.ContractError.invalidJSON("duplicate or empty category identity")
            }
        }
    }

    private static func effectiveTaxonomy(raw: Data, before: [FinancialCategory], catalog: CategoryCatalog) throws -> Data {
        let rows = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["taxonomy"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? []
        guard rows.count == before.count else { throw CocoaError(.fileReadCorruptFile) }
        let encoder = JSONEncoder()
        var originals: [String: (Data, FinancialCategory)] = [:]
        for (category, bytes) in zip(before, rows) {
            var ids = Set(catalog.primaries.filter { $0.name == category.primary }.map(\.id))
            for alias in catalog.aliases where alias.primary == category.primary && !alias.reassigned {
                if let secondary = catalog.secondaries.first(where: { $0.id == alias.targetID }) { ids.insert(secondary.primaryID) }
            }
            if ids.isEmpty {
                guard try ReleaseCanonicalJSON.canonicalize(raw: bytes) == ReleaseCanonicalJSON.canonicalize(raw: encoder.encode(category)) else {
                    throw ReleaseCanonicalJSON.ContractError.invalidJSON("unmapped category has unknown data")
                }
                continue
            }
            guard ids.count == 1, let id = ids.first, originals[id] == nil else {
                throw ReleaseCanonicalJSON.ContractError.invalidJSON("ambiguous category identity")
            }
            originals[id] = (bytes, category)
        }
        return try array(zip(catalog.primaries, catalog.taxonomy).map { primary, category in
            guard let (bytes, previous) = originals[primary.id] else { return try encoder.encode(category) }
            return try ReleaseCanonicalJSON.applyingModelChanges(raw: bytes, before: encoder.encode(previous), after: encoder.encode(category))
        })
    }

    private static func array(_ values: [Data]) throws -> Data {
        guard values.reduce(2, { $0 + $1.count + 1 }) <= ReleaseCanonicalJSON.maximumOutputBytes else {
            throw ReleaseCanonicalJSON.ContractError.resourceLimit("effective projection array")
        }
        var result = Data("[".utf8)
        for (offset, value) in values.enumerated() {
            if offset > 0 { result.append(44) }
            result.append(value)
        }
        result.append(93)
        return result
    }
    private static func combinedGroups(raw: Data) throws -> Data {
        let values = try ["source_record_sets", "source_record_set_candidates"].flatMap {
            try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: [$0], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? []
        }
        var seen = Set<Data>()
        for value in values {
            guard let id = try ReleaseCanonicalJSON.canonicalFragment(raw: value, atObjectKeys: ["id"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes), seen.insert(id).inserted else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return try array(values)
    }
    private static func baselineDocument(raw: Data) throws -> Data {
        var records = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["records"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? []
        var seen = Set<Data>()
        for record in records {
            guard let id = try ReleaseCanonicalJSON.canonicalFragment(raw: record, atObjectKeys: ["id"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes), seen.insert(id).inserted else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        let groups = try ReleaseCanonicalJSON.canonicalArrayElements(raw: combinedGroups(raw: raw), atObjectKeys: [], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? []
        for group in groups {
            for record in try ReleaseCanonicalJSON.canonicalArrayElements(raw: group, atObjectKeys: ["shadow_records"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) ?? [] {
                guard let id = try ReleaseCanonicalJSON.canonicalFragment(raw: record, atObjectKeys: ["id"], inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes) else { throw CocoaError(.fileReadCorruptFile) }
                if seen.insert(id).inserted { records.append(record) }
            }
        }
        return try ReleaseCanonicalJSON.replacingObjectMember(raw: raw, key: "records", valueRaw: array(records), inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes)
    }
    public static func applyCompletion(_ overrides: [String: CategoryOverride], to report: inout FinancialReport, catalog: CategoryCatalog? = nil) {
        SourceRecordSets.apply(overrides, to: &report)
        // Resolve names after applying raw overrides. Old aliases must remain
        // usable after a rename, including when an older peer sends an edit.
        let originals = report.records
        defer {
            catalog?.applying(to: &report); TransactionFacts.apply(overrides, to: &report)
            AccountConsolidation.apply(to: &report, preserving: originals)
        }
        guard !overrides.isEmpty else { return }
        let valid = Dictionary(report.taxonomy.map { ($0.primary, Set($0.secondaries)) }, uniquingKeysWith: { first, _ in first })
        for ri in report.records.indices {
            let key = report.records[ri].reviewOverrideKey
            if let excluded = overrides[key]?.excluded_from_completion_and_statistics {
                report.records[ri].excluded_from_completion_and_statistics = excluded
            }
            for ci in report.records[ri].components.indices {
                let component = report.records[ri].components[ci]
                let keys = [component.id] + (component.classification_keys ?? [])
                if let value = keys.compactMap({ overrides[$0] }).first(where: { catalog != nil || valid[$0.primary]?.contains($0.secondary) == true }) {
                    report.records[ri].components[ci].primary = value.primary
                    report.records[ri].components[ci].secondary = value.secondary
                    report.records[ri].components[ci].classification_basis = value.classification_basis ?? "人工分类"
                    report.records[ri].components[ci].completion_confirmation = value.completion_confirmation
                    report.records[ri].components[ci].recurrence = value.recurrence ?? component.recurrence
                    if let tags = value.tags {
                        report.records[ri].components[ci].tags = Array(Set(tags)).sorted()
                        report.records[ri].components[ci].tag_basis = Dictionary(uniqueKeysWithValues: Set(tags).map { ($0, (value.discovery_tags ?? []).contains($0) ? "已确认商家规则" : component.tag_basis?[$0] ?? "人工标签") })
                    }
                }
            }
        }
    }
}
