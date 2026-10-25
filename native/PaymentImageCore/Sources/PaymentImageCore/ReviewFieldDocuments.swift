import Foundation

/// Lossless JSON fragments are carried as field strings. In particular parameter
/// decimals and unknown override metadata never pass through NSNumber on write.
public enum ReviewFieldDocuments {
    /// Explicit committed config+review capture, not a mutable config fallback.
    /// The caller must separately qualify the binding/host/processor context.
    public static func capture(state: StateHandle, settings: HouseholdSettingsState) throws -> [String: String] {
        guard state.pointer == settings.pointer else { throw WorkspaceError.stalePointer }
        try WorkspaceIO.validateManifest(state, validateFiles: true)
        try ReviewWorkspaceMembership.validate(state: state)
        for (path, raw) in [("config/family-profile.json", settings.settings.profileData), ("config/account-policies.json", settings.settings.policiesData)] {
            guard try WorkspaceIO.read(state.file(path)) == raw else { throw WorkspaceError.stalePointer }
        }
        var values = try capture(review: state.review)
        for (key, value) in ReviewSettingsFieldDocuments.values(settings.settings) { values[key] = value }
        return values
    }
    public static func capture(review: URL) throws -> [String: String] {
        var values = [String: String]()
        func read(_ name: String) throws -> Data {
            let file = try WorkspaceIO.safeChild(review, name)
            return FileManager.default.fileExists(atPath: file.path) ? try WorkspaceIO.read(file) : Data("{}".utf8)
        }
        func text(_ raw: Data) throws -> String { String(decoding: try ReleaseCanonicalJSON.canonicalize(raw: raw), as: UTF8.self) }
        let catalog = try read("category-catalog.json")
        if !(try WorkspaceIO.object(catalog)).isEmpty {
            _ = try JSONDecoder().decode(CategoryCatalog.self, from: catalog).validated()
            values["catalog/@tree"] = try text(catalog)
        }
        let overrides = try read("review-overrides.json")
        // Extract each strict, lossless fragment once. Re-parsing the complete
        // override document for every record makes field capture quadratic.
        for (id, raw) in try ReleaseCanonicalJSON.canonicalObjectEntries(raw: overrides) {
            guard !id.isEmpty, !id.contains("/") else { throw WorkspaceError.invalid("override identity") }
            try component(id)
            var category = Data("{}".utf8), hasCategory = false
            for (field, value) in try ReleaseCanonicalJSON.canonicalObjectEntries(raw: raw) {
                try component(field)
                if value == Data("null".utf8) { continue }
                if ["primary", "secondary"].contains(field) {
                    category = try ReleaseCanonicalJSON.replacingObjectMember(raw: category, key: field, valueRaw: value); hasCategory = true
                } else { values["override/" + id + "/" + field] = String(decoding: value, as: UTF8.self) }
            }
            if hasCategory { values["override/" + id + "/@category"] = try text(category) }
        }
        func flatten(_ raw: Data, path: String) throws {
            for (key, value) in try ReleaseCanonicalJSON.canonicalObjectEntries(raw: raw) {
                try component(key)
                if value.first == 0x7b, !(try WorkspaceIO.object(value)).isEmpty { try flatten(value, path: path + "/" + key) }
                else { values[path + "/" + key] = try text(value) }
            }
        }
        try flatten(read("fire-parameters-user.json"), path: "parameter")
        let workflow = try WorkspaceIO.object(read("completion-workflow.json"))
        if let deferred = workflow["deferred"] {
            guard let ids = deferred as? [String], Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else { throw WorkspaceError.invalid("deferred workflow") }
            for id in ids { values["deferred/" + id] = "true" }
        }
        return values
    }

    internal static func materializeFamilyClient(values: [String: String], settings: HouseholdSettings, review: URL, paths: WorkspacePaths) throws {
        guard WorkspaceIO.lexicalURL(review).path.hasPrefix(paths.device.appendingPathComponent("client-views").path + "/") else { throw WorkspaceError.invalid("family projection destination") }
        try render(values: values.filter { !$0.key.hasPrefix("settings/") }, review: review) { name, bytes in
            try WorkspaceIO.atomicWrite(bytes, to: WorkspaceIO.safeChild(review, name))
        }
        for (path, raw) in [("family-profile.json", settings.profileData), ("account-policies.json", settings.policiesData)] {
            try WorkspaceIO.atomicWrite(raw, to: review.appendingPathComponent(path))
        }
    }
    internal static func writeFamily(values: [String: String], settings: HouseholdSettings, transaction: WorkspaceTransaction, token: WorkspaceWriteToken) throws {
        try render(values: values.filter { !$0.key.hasPrefix("settings/") }, review: transaction.root.appendingPathComponent("review")) { name, bytes in
            try WorkspaceIO.atomicWrite(bytes, to: transaction.file("review/" + name, token: token))
        }
        try WorkspaceIO.atomicWrite(settings.profileData, to: transaction.file("config/family-profile.json", token: token))
        try WorkspaceIO.atomicWrite(settings.policiesData, to: transaction.file("config/account-policies.json", token: token))
    }
    private static func render(values: [String: String], review: URL, write: (String, Data) throws -> Void) throws {
        guard !values.keys.contains(where: { $0.hasPrefix("settings/") }) else { throw WorkspaceError.unsupportedVersion("paired settings must be written together") }
        let reportRaw = try WorkspaceIO.read(WorkspaceIO.safeChild(review, "financial-review.json"), limit: Int64(WorkspaceBusinessValidator.maximumProjectionBytes))
        let report = try JSONDecoder().decode(FinancialReport.self, from: reportRaw)
        let records = SourceRecordSets.baselineRecords(report)
        let overrideTargets = Set(records.map(\.id))
            .union(records.map(\.reviewOverrideKey))
            .union(records.flatMap { $0.components.map(\.id) })
            .union(SourceRecordSets.groups(report).map(\.reviewOverrideKey))
            .union((report.video_materials ?? []).map(\.id))
        var overrides = Data("{}".utf8), parameters = Data("{}".utf8), deferred = [String]()
        var catalog: Data?
        func insert(_ raw: Data, path: ArraySlice<String>, value: Data) throws -> Data {
            guard let key = path.first else { throw WorkspaceError.invalid("empty field path") }
            try component(key)
            if path.count == 1 { return try ReleaseCanonicalJSON.replacingObjectMember(raw: raw, key: key, valueRaw: value) }
            let existing = try ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: [key]) ?? Data("{}".utf8)
            let child = try insert(existing, path: path.dropFirst(), value: value)
            return try ReleaseCanonicalJSON.replacingObjectMember(raw: raw, key: key, valueRaw: child)
        }
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            let raw = try ReleaseCanonicalJSON.canonicalize(raw: Data(value.utf8))
            if raw == Data("null".utf8), !key.hasPrefix("parameter/") { continue }
            if key == "catalog/@tree" {
                _ = try JSONDecoder().decode(CategoryCatalog.self, from: raw).validated(); catalog = raw
            } else if key.hasPrefix("override/") {
                let path = String(key.dropFirst(9)).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard path.count == 2, !path[0].isEmpty, overrideTargets.contains(path[0]) else { throw WorkspaceError.invalid("override target missing; needsReview") }
                var entry = try ReleaseCanonicalJSON.canonicalFragment(raw: overrides, atObjectKeys: [path[0]]) ?? Data("{}".utf8)
                if path[1] == "@category" {
                    let category = try WorkspaceIO.object(raw)
                    guard Set(category.keys).isSubset(of: ["primary", "secondary"]), !category.isEmpty else { throw WorkspaceError.invalid("category field") }
                    for field in category.keys {
                        let value = try ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: [field])!
                        entry = try ReleaseCanonicalJSON.replacingObjectMember(raw: entry, key: field, valueRaw: value)
                    }
                } else {
                    try component(path[1]); entry = try ReleaseCanonicalJSON.replacingObjectMember(raw: entry, key: path[1], valueRaw: raw)
                }
                overrides = try ReleaseCanonicalJSON.replacingObjectMember(raw: overrides, key: path[0], valueRaw: entry)
            } else if key.hasPrefix("parameter/") {
                let path = key.dropFirst(10).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                parameters = try insert(parameters, path: path[...], value: raw)
            } else if key.hasPrefix("deferred/") {
                let id = String(key.dropFirst(9))
                guard !id.isEmpty, raw == Data("true".utf8) || raw == Data("false".utf8) else { throw WorkspaceError.invalid("deferred field") }
                if raw == Data("true".utf8) { deferred.append(id) }
            } else { throw WorkspaceError.invalid("unsupported causal field") }
        }
        let workflowFile = try WorkspaceIO.safeChild(review, "completion-workflow.json")
        var workflow = FileManager.default.fileExists(atPath: workflowFile.path) ? try WorkspaceIO.read(workflowFile) : Data("{}".utf8)
        let financial = try WorkspaceIO.object(WorkspaceIO.read(WorkspaceIO.safeChild(review, "financial-review.json"), limit: Int64(WorkspaceBusinessValidator.maximumProjectionBytes)), inputLimit: WorkspaceBusinessValidator.maximumProjectionBytes)
        workflow = try ReleaseCanonicalJSON.replacingObjectMember(raw: workflow, key: "datasetID", valueRaw: JSONSerialization.data(withJSONObject: WorkspaceIO.string(financial, "dataset_id"), options: [.fragmentsAllowed]))
        workflow = try ReleaseCanonicalJSON.replacingObjectMember(raw: workflow, key: "deferred", valueRaw: JSONSerialization.data(withJSONObject: deferred.sorted()))
        for (path, bytes) in [("review/review-overrides.json", overrides), ("review/fire-parameters-user.json", parameters), ("review/completion-workflow.json", workflow)] {
            try write(String(path.dropFirst(7)), bytes)
        }
        if let catalog { try write("category-catalog.json", catalog) }
    }
    private static func component(_ key: String) throws {
        guard !key.isEmpty, !key.contains("/"), key != "@category", key.utf8.allSatisfy({ $0 < 128 && $0 >= 32 }) else {
            throw WorkspaceError.unsupportedVersion("field component cannot be safely represented by native causal paths")
        }
    }
}
