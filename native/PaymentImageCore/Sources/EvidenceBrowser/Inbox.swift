#if os(macOS) || os(iOS)
import SwiftUI
import Observation
import PaymentImageCore

/// One queue for everything that needs a human decision. Completion entries keep
/// their own workspace (drafts, saving, undo); associations and source-record
/// sets keep their own stores. This model only aggregates and routes.
enum InboxKind: String, CaseIterable, Identifiable {
    case all = "全部", category = "待分类", facts = "待核事实", refund = "退款候选", association = "关联复核", sourceSet = "来源归并"
    var id: String { rawValue }
    /// The CompletionWorkspace mode backing this kind, if any.
    var completionMode: String? {
        switch self {
        case .all: "全部"
        case .category, .facts, .refund: rawValue
        case .association, .sourceSet: nil
        }
    }
}

enum InboxHistory: String, CaseIterable, Identifiable {
    case deferred = "暂放", saved = "本次已保存", confirmed = "已确认", excluded = "已排除", associations = "关联记录", sourceSets = "来源组"
    var id: String { rawValue }
    var completionMode: String? {
        switch self {
        case .deferred, .saved, .confirmed, .excluded: rawValue
        case .associations, .sourceSets: nil
        }
    }
}

enum InboxItem: Identifiable {
    case completion(CompletionEntry)
    case association(Candidate)
    case sourceSet(SourceRecordSet)

    var id: String {
        switch self {
        case .completion(let entry): "c:" + entry.id
        case .association(let candidate): "a:" + candidate.id
        case .sourceSet(let group): "s:" + group.id
        }
    }
    var completionEntry: CompletionEntry? { if case .completion(let entry) = self { entry } else { nil } }
}

struct InboxRowInfo {
    let title: String; let date: String; let amount: Int?; let badges: [(String, BadgeTone)]
}

@Observable @MainActor final class InboxModel {
    var kind: InboxKind = .all { didSet { if kind != oldValue { history = nil; syncWorkspaceMode() } } }
    /// nil shows open work; a value shows already handled or parked items.
    var history: InboxHistory? { didSet { if history != oldValue { syncWorkspaceMode() } } }
    var query = "" { didSet { workspace?.query = query } }
    var selectedID: String? { didSet { if case .completion(let entry)? = selectedItem { workspace?.selected = entry.id } } }
    var includeAllDates: Bool {
        get { workspace?.allDates ?? false }
        set { workspace?.allDates = newValue }
    }
    @ObservationIgnored weak var finance: FinancialStore?
    @ObservationIgnored weak var evidence: BrowserStore?
    @ObservationIgnored private weak var workspace: CompletionWorkspace?

    /// Navigation entry from elsewhere (overview, menus): always shows open work
    /// of the given type, never a leftover history view or search.
    func openPending(_ kind: InboxKind) {
        history = nil; query = ""
        if self.kind != kind { self.kind = kind } else { syncWorkspaceMode() }
    }
    /// Observed so views that rendered before `bind` re-read counts afterwards.
    private var bound = false
    func bind(_ finance: FinancialStore, _ evidence: BrowserStore) {
        self.finance = finance; self.evidence = evidence; workspace = finance.completion
        bound = true
        syncWorkspaceMode()
    }
    private func syncWorkspaceMode() {
        guard let workspace else { return }
        let mode = history?.completionMode ?? (history == nil ? kind.completionMode : nil)
        if let mode, workspace.mode != mode { workspace.mode = mode }
        if workspace.query != query { workspace.query = query }
    }
    var showsCompletion: Bool { history.map { $0.completionMode != nil } ?? (kind.completionMode != nil) }

    // MARK: Items

    var items: [InboxItem] {
        guard bound, let finance, let evidence else { return [] }
        let workspace = finance.completion
        var result = [InboxItem]()
        // The workspace mode mirrors the kind (全部 = open-work union), so this list and
        // the editor's save-and-next walk the same set on both platforms.
        let completions = workspace.visible
        if showsCompletion { result += completions.map(InboxItem.completion) }
        let wantsAssociations = history == .associations || (history == nil && (kind == .all || kind == .association))
        if wantsAssociations {
            let pending = history == nil
            var candidates = evidence.orderedCandidates.filter { (!pending || $0.review_required) && matches($0, evidence) && inRange(candidateDate($0, evidence)) }
            if kind == .all && pending {
                // Associations already reviewable inside a listed completion entry stay there.
                let covered = Set(completions.flatMap(\.record.evidence_keys))
                candidates.removeAll { !Set($0.record_ids + $0.bank_ids).isDisjoint(with: covered) }
            }
            result += candidates.map(InboxItem.association)
        }
        let wantsSets = history == .sourceSets || (history == nil && (kind == .all || kind == .sourceSet))
        if wantsSets {
            let pending = history == nil
            result += finance.sourceRecordGroups.filter { (!pending || Self.sourceSetPending($0)) && matches($0) && inRange($0.date) }.map(InboxItem.sourceSet)
        }
        if kind == .all || history != nil, result.count > 1 {
            return TransactionListOrder.sorted(result, amount: { self.row($0).amount }, date: { self.row($0).date }, id: \.id)
        }
        return result
    }
    /// Associations and source sets follow the same date scope as completion entries.
    private func inRange(_ date: String) -> Bool {
        guard let workspace, !workspace.allDates else { return true }
        let day = String(date.prefix(10))
        return !day.isEmpty && day >= workspace.from && day <= workspace.to
    }
    private func candidateDate(_ candidate: Candidate, _ evidence: BrowserStore) -> String {
        let ids = Set(candidate.record_ids + candidate.bank_ids)
        let records = evidence.records.filter { ids.contains($0.id) }
        return (records.first { !candidate.bank_ids.contains($0.id) } ?? records.first)?.date ?? ""
    }
    static func sourceSetPending(_ group: SourceRecordSet) -> Bool { group.status != "confirmed" && group.status != "rejected" }
    private func matches(_ candidate: Candidate, _ evidence: BrowserStore) -> Bool {
        guard !query.isEmpty else { return true }
        let ids = Set(candidate.record_ids + candidate.bank_ids)
        return evidence.records.contains { ids.contains($0.id) && (platformName($0.platform) + " " + $0.date + " " + $0.title + " " + money($0.amount)).localizedCaseInsensitiveContains(query) }
    }
    private func matches(_ group: SourceRecordSet) -> Bool {
        query.isEmpty || ([group.date, group.basis, money(group.amount_cents)] + group.evidence_keys).joined(separator: " ").localizedCaseInsensitiveContains(query)
    }

    func count(_ kind: InboxKind) -> Int {
        guard bound, let finance, let evidence else { return 0 }
        let workspace = finance.completion
        let candidates = evidence.orderedCandidates.filter { $0.review_required && inRange(candidateDate($0, evidence)) }
        let sets = finance.sourceRecordGroups.filter { Self.sourceSetPending($0) && inRange($0.date) }.count
        switch kind {
        case .all:
            let open = workspace.entries.filter(workspace.isOpen)
            let covered = Set(open.flatMap(\.record.evidence_keys))
            return open.count + candidates.filter { Set($0.record_ids + $0.bank_ids).isDisjoint(with: covered) }.count + sets
        case .category, .facts, .refund: return workspace.count(kind.rawValue)
        case .association: return candidates.count
        case .sourceSet: return sets
        }
    }
    /// Total amount of open work (all types, same items as `count(.all)`), for summary cards.
    var openImpact: Int {
        guard bound, let finance, let evidence else { return 0 }
        let workspace = finance.completion
        let open = workspace.entries.filter(workspace.isOpen)
        let covered = Set(open.flatMap(\.record.evidence_keys))
        var total = open.filter { !$0.amountUnknown }.reduce(0) { $0 + abs($1.impact) }
        for candidate in evidence.orderedCandidates where candidate.review_required && inRange(candidateDate(candidate, evidence))
            && Set(candidate.record_ids + candidate.bank_ids).isDisjoint(with: covered) {
            total += abs(row(.association(candidate)).amount ?? 0)
        }
        for group in finance.sourceRecordGroups where Self.sourceSetPending(group) && inRange(group.date) { total += abs(group.amount_cents) }
        return total
    }

    var selectedItem: InboxItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }
    func ensureSelection(in list: [InboxItem]) {
        if !list.contains(where: { $0.id == selectedID }) { selectedID = list.first?.id }
    }
    func select(after id: String, previous: [String]) {
        let current = items
        let after = previous.firstIndex(of: id).map { Array(previous.dropFirst($0 + 1)) } ?? previous
        selectedID = after.first { candidate in current.contains { $0.id == candidate } } ?? current.first?.id
    }
    func move(_ offset: Int) {
        let list = items
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selectedID } ?? -1
        selectedID = list[max(0, min(list.count - 1, index + offset))].id
    }

    // MARK: Row presentation

    func row(_ item: InboxItem) -> InboxRowInfo {
        switch item {
        case .completion(let entry):
            var badges = [(String, BadgeTone)]()
            if entry.missingCategory { badges.append(("待分类", .pending)) }
            if entry.factsPending { badges.append(("待核事实", .failure)) }
            if finance?.completion.refundCandidateRecordIDs.contains(entry.record.id) == true, entry.record.unallocated_credit_cents > 0 { badges.append(("退款候选", .accent)) }
            if finance?.completion.isDirty(entry) == true { badges.append(("草稿", .draft)) }
            if entry.component?.completionConfirmed == true { badges.append(("已确认", .confirmed)) }
            return InboxRowInfo(title: entry.component?.title ?? entry.record.title, date: entry.record.date,
                                amount: entry.amountUnknown ? nil : entry.impact, badges: badges)
        case .association(let candidate):
            let records = (candidate.record_ids + candidate.bank_ids).compactMap { id in evidence?.records.first { $0.id == id } }
            let lead = records.first { !candidate.bank_ids.contains($0.id) } ?? records.first
            let amount = records.compactMap(\.amount).max { $0.magnitude < $1.magnitude }
            return InboxRowInfo(title: lead?.title ?? associationKindName(candidate.kind), date: lead?.date ?? "",
                                amount: amount, badges: [(candidate.review_required ? "关联复核" : associationStatusName(candidate, deferred: evidence?.deferredCandidates.contains(candidate.id) == true), candidate.review_required ? .accent : .neutral)])
        case .sourceSet(let group):
            return InboxRowInfo(title: (group.kind == "refund" ? "退款来源组" : "付款来源组") + " · 银联 \(group.network_count) 笔 / 银行 \(group.bank_count) 笔",
                                date: group.date, amount: group.amount_cents,
                                badges: [(group.statusTitle == "待确认" ? "来源归并" : group.statusTitle, group.confirmed ? .confirmed : Self.sourceSetPending(group) ? .pending : .neutral)])
        }
    }
}

func associationKindName(_ kind: String) -> String {
    ["wallet_bank": "钱包与银行", "grouped_wallet_bank": "组合支付与银行", "meituan_wechat": "美团与微信", "meituan_bank": "美团 Apple Pay 与银行"][kind] ?? kind
}
func associationStatusName(_ candidate: Candidate, deferred: Bool) -> String {
    if deferred { return "已暂挂 · 设备尾号待确认" }
    switch candidate.association_status {
    case "supported_by_user": return candidate.review_required ? "支持已保存 · 扣款分配待核" : "人工支持"
    case "rule_supported": return "规则通过"
    case "rejected_by_user": return "人工已排除"
    default: return "待核"
    }
}
#endif
