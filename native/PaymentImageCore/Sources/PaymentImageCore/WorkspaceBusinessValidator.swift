import Foundation
import CryptoKit

/// Shared production validator for transaction staging and pinned host readers.
/// Snapshot identity binds the report pair; dataset IDs need not be equal.
public enum WorkspaceBusinessValidator {
    public static let maximumProjectionBytes = 64 * 1024 * 1024
    internal static func documentLimit(_ path: String) -> Int {
        if ["financial-review.json", "payment-evidence.json", "review/financial-review.json", "review/payment-evidence.json", "review/trace-refresh-before.json"].contains(path) {
            return maximumProjectionBytes
        }
        if ["confirmed-outcomes.json", "review/confirmed-outcomes.json"].contains(path) { return 16 * 1024 * 1024 }
        // Retained before/after reports have the same bounded document shape
        // as the active projection. Ordinary metadata keeps its smaller limit.
        let historical = path.hasPrefix("review/review-history/") || path.hasPrefix("review-history/")
        let reportNames: Set<String> = ["financial-review.json", "financial-before.json", "before-financial-review.json",
                                        "payment-evidence.json", "payment-evidence-before.json", "before-payment-evidence.json"]
        return historical && reportNames.contains(String(path.split(separator: "/").last ?? ""))
            ? maximumProjectionBytes : ReleaseCanonicalJSON.maximumInputBytes
    }
    /// Pure metadata closure used by a snapshot reader; no original download or
    /// processor is needed. Both dataset IDs remain independent identities.
    public static func validateReportPair(financialRaw: Data, evidenceRaw: Data) throws {
        _ = try ReleaseCanonicalJSON.canonicalize(raw: financialRaw, inputLimit: maximumProjectionBytes)
        _ = try ReleaseCanonicalJSON.canonicalize(raw: evidenceRaw, inputLimit: maximumProjectionBytes)
        let financial = try JSONDecoder().decode(FinancialReport.self, from: financialRaw)
        let evidence = try JSONDecoder().decode(EvidenceDocument.self, from: evidenceRaw)
        guard
              financial.source_dataset_id == evidence.dataset_id, !financial.dataset_id.isEmpty, !evidence.dataset_id.isEmpty,
              financial.cutoff == evidence.backfill_cutoff_date,
              let coverage = financial.coverage, evidence.coverage == coverage, coverage.revision >= 0,
              ["empty", "automatic", "explicit"].contains(coverage.mode), coverage.to == financial.cutoff,
              coverage.mode != "empty" || (coverage.from == nil && coverage.to == nil),
              coverage.mode == "empty" || (coverage.from != nil && coverage.to != nil && coverage.from! <= coverage.to!),
              [coverage.from, coverage.to, coverage.observed_from, coverage.observed_to, coverage.pending_from, coverage.pending_to].compactMap({ $0 }).allSatisfy(TransactionFacts.validDate),
              ["no-reliable-dates", "reliable-observations", "user-confirmed"].contains(coverage.basis.kind),
              Set(coverage.basis.source_ids).count == coverage.basis.source_ids.count,
              Set(financial.records.map(\.id)).count == financial.records.count,
              Set(evidence.candidates.map(\.id)).count == evidence.candidates.count,
              Set(evidence.clusters.map(\.cluster_id)).count == evidence.clusters.count,
              Set(evidence.bank_records.map(\.id)).count == evidence.bank_records.count,
              Set((evidence.ocr_probe?.samples ?? []).map(\.card_id)).count == (evidence.ocr_probe?.samples.count ?? 0) else { throw WorkspaceError.invalid("reader financial/evidence/coverage closure") }
        var keys = Set(evidence.clusters.map(\.cluster_id))
        keys.formUnion(evidence.bank_records.map { "bank:\($0.id)" })
        keys.formUnion((evidence.ocr_probe?.samples ?? []).map { "card:" + $0.card_id })
        keys.formUnion((financial.video_materials ?? []).map(\.id))
        for candidate in evidence.candidates {
            guard Set(candidate.record_ids + candidate.bank_ids).isSubset(of: keys) else { throw WorkspaceError.invalid("reader dangling candidate evidence") }
        }
    }
    public static func validate(_ root: URL) throws { try validate(root, verifiedFiles: nil) }
    public static func validateRead(_ state: StateHandle) throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: state.manifest)) as? [String: Any]
        guard let files = manifest?["files"] as? [String: String] else { throw WorkspaceError.invalid("read manifest closure") }
        try validate(state.root, verifiedFiles: files)
    }
    internal static func validate(_ root: URL, verifiedFiles: [String: String]?) throws {
        let review = root.appendingPathComponent("review")
        let decoder = JSONDecoder()
        let financialBytes = try WorkspaceIO.read(review.appendingPathComponent("financial-review.json"), limit: Int64(maximumProjectionBytes))
        let evidenceBytes = try WorkspaceIO.read(review.appendingPathComponent("payment-evidence.json"), limit: Int64(maximumProjectionBytes))
        try validateReportPair(financialRaw: financialBytes, evidenceRaw: evidenceBytes)
        let financial = try decoder.decode(FinancialReport.self, from: financialBytes)
        let evidence = try decoder.decode(EvidenceDocument.self, from: evidenceBytes)
        let coverageBytes = try Data(contentsOf: review.appendingPathComponent("coverage.json")); _ = try ReleaseCanonicalJSON.canonicalize(raw: coverageBytes)
        let coverage = try decoder.decode(WorkspaceCoverage.self, from: coverageBytes)
        guard financial.source_dataset_id == evidence.dataset_id, !evidence.dataset_id.isEmpty,
              financial.cutoff == evidence.backfill_cutoff_date,
              financial.coverage == coverage, evidence.coverage == coverage,
              coverage.revision >= 0,
              ["empty", "automatic", "explicit"].contains(coverage.mode),
              coverage.to == financial.cutoff,
              (coverage.mode != "empty" || (coverage.from == nil && coverage.to == nil)),
              Set(financial.records.map(\.id)).count == financial.records.count,
              Set(evidence.candidates.map(\.id)).count == evidence.candidates.count else {
            throw WorkspaceError.invalid("financial/evidence/coverage closure")
        }
        let dates = [coverage.from, coverage.to, coverage.observed_from, coverage.observed_to, coverage.pending_from, coverage.pending_to].compactMap { $0 }
        guard dates.allSatisfy(TransactionFacts.validDate),
              (coverage.mode == "empty" || (coverage.from != nil && coverage.to != nil && coverage.from! <= coverage.to!)),
              ["no-reliable-dates", "reliable-observations", "user-confirmed"].contains(coverage.basis.kind),
              Set(coverage.basis.source_ids).count == coverage.basis.source_ids.count else { throw WorkspaceError.invalid("coverage dates or basis") }
        var verifiedAssets = [URL: String]()
        func checkAsset(path: String, hash: String, base: URL) throws {
            guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !path.hasPrefix("/"), !path.contains("\\"),
                  path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw WorkspaceError.invalid("asset reference") }
            let file = try EvidencePath.resolve(path, root: base)
            if let verifiedFiles {
                let relative = base == review ? "review/" + path : path
                guard verifiedFiles[relative] == hash else { throw WorkspaceError.invalid("asset manifest reference") }
                return
            }
            if let prior = verifiedAssets[file] {
                guard prior == hash else { throw WorkspaceError.invalid("conflicting asset hash") }
                return
            }
            guard try WorkspaceIO.hash(file) == hash else { throw WorkspaceError.invalid("asset hash") }
            verifiedAssets[file] = hash
        }
        func references(_ value: Any) throws {
            if let object = value as? [String: Any] {
                if let path = object["path"] as? String, let hash = object["sha256"] as? String { try checkAsset(path: path, hash: hash, base: review) }
                for child in object.values { try references(child) }
            } else if let values = value as? [Any] { for child in values { try references(child) } }
        }
        try references(JSONSerialization.jsonObject(with: financialBytes))
        try references(JSONSerialization.jsonObject(with: evidenceBytes))
        let registryBytes = try Data(contentsOf: root.appendingPathComponent("config/review-import-sources.json")); _ = try ReleaseCanonicalJSON.canonicalize(raw: registryBytes)
        let registry = try JSONSerialization.jsonObject(with: registryBytes) as? [String: Any]
        guard let sources = registry?["sources"] as? [[String: Any]] else { throw WorkspaceError.invalid("source registry schema") }
        var registered = Set<String>()
        for source in sources {
            guard let path = source["path"] as? String, let hash = source["sha256"] as? String,
                  let platform = source["platform"] as? String, !platform.isEmpty, registered.insert(path).inserted else { throw WorkspaceError.invalid("source registry entry") }
            try checkAsset(path: path, hash: hash, base: root)
        }
        let overrides = review.appendingPathComponent("review-overrides.json")
        if FileManager.default.fileExists(atPath: overrides.path) {
            let bytes = try WorkspaceIO.read(overrides), keys = try ReleaseCanonicalJSON.canonicalObjectKeys(raw: bytes)
            guard keys.allSatisfy({ !$0.isEmpty }), Set(keys).count == keys.count else { throw WorkspaceError.invalid("override key identity") }
            _ = try decoder.decode([String: CategoryOverride].self, from: bytes)
        }
        let workflow = review.appendingPathComponent("completion-workflow.json")
        if FileManager.default.fileExists(atPath: workflow.path) {
            _ = try CompletionWorkflow.decode(WorkspaceIO.read(workflow))
        }
        let parameters = review.appendingPathComponent("fire-parameters-user.json")
        if FileManager.default.fileExists(atPath: parameters.path) {
            _ = try WorkspaceIO.object(WorkspaceIO.read(parameters))
            _ = try ReleaseCanonicalJSON.canonicalize(raw: WorkspaceIO.read(parameters))
        }
        _ = try CategoryCatalogFile.read(root: review, taxonomy: financial.taxonomy, records: financial.records)
        var evidenceKeys = Set(evidence.clusters.map(\.cluster_id))
        evidenceKeys.formUnion(evidence.bank_records.map { "bank:\($0.id)" })
        evidenceKeys.formUnion((evidence.ocr_probe?.samples ?? []).map { "card:" + $0.card_id })
        evidenceKeys.formUnion((financial.video_materials ?? []).map(\.id))
        for candidate in evidence.candidates {
            guard Set(candidate.record_ids + candidate.bank_ids).isSubset(of: evidenceKeys) else { throw WorkspaceError.invalid("candidate evidence reference") }
        }
    }
}

private struct EvidenceDocument: Decodable {
    struct Observation: Decodable {
        let platform: String; let transaction_time: String; let merchant: String?; let title: String?
        let platform_reported_amount_cents: Int?; let raw_status: String; let source_evidence: EvidenceReference
    }
    struct Cluster: Decodable { let cluster_id: String; let representative: Observation }
    struct Bank: Decodable {
        let id: Int; let date: String; let description: String; let amount_cents: Int
        let is_credit: Int; let source_evidence: EvidenceReference
    }
    struct Candidate: Decodable {
        var id: String { candidate_id }
        let candidate_id: String; let kind: String; let record_ids: [String]; let bank_ids: [String]
        let association_status: String; let review_required: Bool; let active_competing_candidate_ids: [String]?
    }
    struct Fields: Decodable { let amountCents: Int?; let status: String?; let orderedMinute: String? }
    struct Card: Decodable { let card_id: String; let visible_title: String?; let parsed: Fields?; let source_evidence: EvidenceReference }
    struct Probe: Decodable { let samples: [Card] }
    let coverage: WorkspaceCoverage?
    let dataset_id: String; let backfill_cutoff_date: String?; let clusters: [Cluster]
    let bank_records: [Bank]; let candidates: [Candidate]; let ocr_probe: Probe?
    let review_summary: [String: Int]
}
