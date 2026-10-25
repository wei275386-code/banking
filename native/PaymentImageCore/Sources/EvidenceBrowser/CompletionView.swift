#if os(macOS) || os(iOS)
import SwiftUI
import Observation
import PaymentImageCore

@Observable @MainActor final class CompletionWorkspace {
    var entries = [CompletionEntry]()
    var visible = [CompletionEntry]()
    var selected: String?
    var mode = "优先补全" { didSet { filter() } }
    var query = "" { didSet { filter() } }
    var from = ""; var to = ""
    var allDates = false
    var drafts = [String: CompletionDraft]()
    var saved = Set<String>()
    var deferred = Set<String>()
    var message = ""
    var persisting = false
    var workflowError: String?
    var undo: CompletionUndo?
    var automaticExcluded = Set<String>()
    var refundCandidateRecordIDs = Set<String>()
    @ObservationIgnored weak var owner: FinancialStore?
    @ObservationIgnored var root: URL?
    @ObservationIgnored var sourceVersion = "missing"
    @ObservationIgnored private var key = ""
    @ObservationIgnored var dataset = ""
    @ObservationIgnored var draftBases = [String: CompletionDraft]()
    @ObservationIgnored var evidenceIndex = [String: BrowseRecord]()
    @ObservationIgnored var candidateIndex = [String: [Candidate]]()
    @ObservationIgnored private var candidateOrder = [String: Int]()
    @ObservationIgnored private var evidenceGeneration: UUID?

    var current: CompletionEntry? { entries.first { $0.id == selected } }
    func refresh(_ store: FinancialStore, _ evidence: BrowserStore) {
        guard let report = store.report else { return }
        resetContext(folder: store.root, datasetID: report.dataset_id)
        let newKey = "\(store.revision)|\(from)|\(to)|\(allDates)"
        if newKey != key {
            refundCandidateRecordIDs = Set((store.baseReport?.refund_candidates ?? []).flatMap(\.source_ids))
            let start = DispatchTime.now().uptimeNanoseconds
            let startDate = allDates ? "" : from, endDate = allDates ? "9999" : to
            entries = store.preparedCompletionQueues[CompletionQueue.key(from: startDate, to: endDate)] ?? CompletionQueue.build(report.records, from: startDate, to: endDate, includeIDs: saved, datasetID: report.dataset_id, rootPath: store.root?.path ?? "")
            key = newKey; filter()
            ReviewLatency.record("completion-queue", milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        guard evidence.root == store.root else { evidenceIndex = [:]; candidateIndex = [:]; candidateOrder = [:]; evidenceGeneration = nil; return }
        if evidenceGeneration != evidence.previewGeneration {
            evidenceIndex = Dictionary(evidence.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            candidateIndex = [:]
            candidateOrder = Dictionary(evidence.orderedCandidates.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
            for candidate in evidence.orderedCandidates where candidate.review_required {
                for id in Set(candidate.record_ids + candidate.bank_ids) { candidateIndex[id, default: []].append(candidate) }
            }
            evidenceGeneration = evidence.previewGeneration
        }
    }
    func resetContext(folder: URL?, datasetID: String, reload: Bool = false) {
        let changed = root != folder || dataset != datasetID
        if changed {
            root = folder; dataset = datasetID; key = ""; entries = []; visible = []; evidenceIndex = [:]; candidateIndex = [:]; candidateOrder = [:]; evidenceGeneration = nil; drafts = [:]; draftBases = [:]; saved = []; deferred = []; undo = nil; automaticExcluded = []; message = ""; selected = nil
            workflowError = nil; refundCandidateRecordIDs = []
            sourceVersion = "missing"
        }
        if changed || reload { try? reloadWorkflow() }
    }
    func reloadWorkflow() throws {
        guard let root else { return }
        do {
            let file = root.appendingPathComponent("completion-workflow.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let bytes = try Data(contentsOf: file)
                let value = try CompletionWorkflow.decode(bytes)
                deferred = value.datasetID == dataset ? Set(value.deferred) : []
                sourceVersion = ReviewFileVersion.of(bytes)
            } else { deferred = []; sourceVersion = "missing" }
            workflowError = nil
        } catch {
            workflowError = "暂放文件无法读取，已保留原文件：" + error.localizedDescription
            throw error
        }
    }
    func filter() {
        visible = entries.filter { entry in
            if entry.record.reviewExcluded && mode != "已排除" { return false }
            let allowed: Bool
            switch mode {
            case "已排除": allowed = entry.record.reviewExcluded
            case "待分类": allowed = entry.missingCategory && !deferred.contains(entry.id)
            case "待核事实": allowed = entry.factsPending && !deferred.contains(entry.id)
            case "退款候选": allowed = refundCandidateRecordIDs.contains(entry.record.id) && entry.record.unallocated_credit_cents > 0 && !deferred.contains(entry.id)
            case "暂放": allowed = deferred.contains(entry.id)
            case "本次已保存": allowed = saved.contains(entry.id)
            case "已确认": allowed = entry.component?.completionConfirmed == true || entry.record.factReviewConfirmed
            default: allowed = !deferred.contains(entry.id) && !saved.contains(entry.id) && entry.component?.completionConfirmed != true && !(entry.record.factReviewConfirmed && !entry.factsPending && !entry.missingCategory)
            }
            return allowed && (query.isEmpty || (entry.record.traceSearchText + " " + entry.record.date + " " + entry.record.title + " " + (entry.component?.title ?? "") + " " + entry.record.userDisplayName + " " + (entry.record.user_id ?? "") + " " + money(entry.impact)).localizedCaseInsensitiveContains(query))
        }
        if !visible.contains(where: { $0.id == selected }) { selected = visible.first?.id }
    }
    func draft(_ entry: CompletionEntry) -> CompletionDraft? {
        guard let component = entry.component else { return nil }
        return drafts[entry.id] ?? CompletionDraft(component)
    }
    func edit(_ entry: CompletionEntry, _ value: CompletionDraft) {
        guard owner?.editingAvailable != false else { return }
        guard let component = entry.component else { return }
        if draftBases[entry.id] == nil { draftBases[entry.id] = CompletionDraft(component) }
        drafts[entry.id] = value
    }
    func isDirty(_ entry: CompletionEntry) -> Bool { entry.component.map { draft(entry) != CompletionDraft($0) } ?? false }
    func next(after id: String, previous: [String]) {
        let after = previous.firstIndex(of: id).map { Array(previous.dropFirst($0 + 1)) } ?? previous
        selected = after.first { candidate in visible.contains { $0.id == candidate } } ?? visible.first?.id
    }
    func relevantCandidates(_ entry: CompletionEntry) -> [Candidate] {
        var seen = Set<String>()
        return entry.record.evidence_keys.flatMap { candidateIndex[$0] ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted {
                let left = candidateOrder[$0.id] ?? Int.max, right = candidateOrder[$1.id] ?? Int.max
                return left == right ? $0.id < $1.id : left < right
            }
    }
    func setDeferred(_ id: String, value: Bool, store suppliedStore: FinancialStore? = nil) async {
        guard let root, !persisting, workflowError == nil, !id.isEmpty else { return }
        let expectedDataset = dataset
        let store = suppliedStore ?? owner
        guard store?.editingAvailable != false else {
            message = store?.editorPauseReason ?? store?.workspaceRuntimeFailure ?? "当前资料仅支持查看。"
            return
        }
        let session = store?.workspaceEditSession
        let client = store?.familyClientEditSession
        let verifiedClient = store?.pinnedClientReview != nil
        persisting = true; defer { persisting = false }
        do {
            let updated = try await Task.detached {
                @Sendable func write(_ root: URL) throws -> (Set<String>, String) {
                let file = root.appendingPathComponent("completion-workflow.json")
                return try ReviewSyncIO.coordinate(file, write: true) { target in
                    let previous = FileManager.default.fileExists(atPath: target.path) ? try Data(contentsOf: target) : Data("{}".utf8)
                    var current = Set<String>()
                    if FileManager.default.fileExists(atPath: target.path) {
                        let workflow = try CompletionWorkflow.decode(previous)
                        if workflow.datasetID == expectedDataset { current = Set(workflow.deferred) }
                    }
                    if value { current.insert(id) } else { current.remove(id) }
                    let bytes = try JSONEncoder().encode(CompletionWorkflow(datasetID: expectedDataset, deferred: current.sorted()))
                    let document = try ParameterDocument.merging(base: previous, changes: bytes)
                    try document.write(to: target, options: .atomic)
                    return (current, ReviewFileVersion.of(document))
                }
                }
                if let session {
                    let (value, state) = try await session.writeScheduled { root, _ in try write(root) }
                    return (value.0, value.1, Optional(state), Optional<ReviewFamilyClientHandle>.none)
                }
                if let client {
                    let (value, handle) = try client.write { root, _ in try write(root) }
                    return (value.0, value.1, Optional<StateHandle>.none, Optional(handle))
                }
                let lease = try ReviewProcessLease(root: root)
                defer { withExtendedLifetime(lease) {} }
                let value = try FinancialStore.withLocalReviewMutation(root: root, verifiedClient: verifiedClient) { try write(root) }
                return (value.0, value.1, Optional<StateHandle>.none, Optional<ReviewFamilyClientHandle>.none)
            }.value
            guard self.root == root, dataset == expectedDataset else { return }
            if let state = updated.2 { store?.adoptWorkspaceState(state) }
            if let handle = updated.3 { store?.adoptFamilyClientEdit(handle) }
            deferred = updated.0; sourceVersion = updated.1; filter(); message = value ? "已暂放；统计和已保存字段保持原值。" : "已放回处理队列。"
        } catch { if self.root == root && dataset == expectedDataset { message = "暂放状态未保存：" + error.localizedDescription } }
    }
}
struct CompletionUndo: Sendable {
    let id: String; let previous: [String: Data?]; let expected: [String: Data?]; let root: URL; let datasetID: String; let dependencies: [String: Data?]
    func rebased(to root: URL) -> Self {
        .init(id: id, previous: previous, expected: expected, root: root, datasetID: datasetID, dependencies: dependencies)
    }
}


struct TransactionReviewExclusion: View {
    let record: FinancialLifecycle
    @Bindable var store: FinancialStore
    var body: some View {
        if [.exclude, .duplicate].contains(store.overrides[record.reviewOverrideKey]?.transaction_facts?.disposition ?? .automatic) {
            Text("此排除来自交易事实确认；在「确认交易事实」中恢复原始证据判断即可撤回。").font(.caption).foregroundStyle(.secondary)
        } else if record.canExcludeFromReview || record.reviewExcluded {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("从补全和统计中排除", isOn: Binding(get: { record.reviewExcluded }, set: { value in
                    Task { await store.setReviewExcluded(record, value: value) }
                })).accessibilityIdentifier("transaction-review-exclusion")
                Text("立即保存，作用于整笔交易；原始记录保留，可在「已排除」或明细中关闭开关恢复。").font(.caption).foregroundStyle(.secondary)
            }.disabled(!store.editingAvailable || store.completionSaving || store.importing || store.loading || store.completion.persisting)
        }
    }
}


#if os(macOS)
struct CompletionPage: View {
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    @Bindable var workspace: CompletionWorkspace
    @State private var showingSourceSets = false
    private var busy: Bool { !store.editingAvailable || store.completionSaving || store.importing || store.loading || evidence.loading || workspace.persisting }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    queue.frame(width: 250)
                    Divider()
                    if let entry = workspace.current {
                        if geometry.size.width >= 900 {
                            ScrollView { CompletionEditor(entry: entry, store: store, evidence: evidence, workspace: workspace, busy: busy).id(entry.id).padding(20) }.id(entry.id).frame(width: geometry.size.width * 0.41)
                            Divider()
                            evidencePanel(entry)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 20) {
                                    CompletionEditor(entry: entry, store: store, evidence: evidence, workspace: workspace, busy: busy).id(entry.id)
                                    CompletionEvidence(entry: entry, store: store, evidence: evidence, workspace: workspace, busy: busy, dirty: workspace.isDirty(entry))
                                }.padding(22)
                            }.id(entry.id)
                        }
                    } else {
                        ContentUnavailableView("当前队列已看完", systemImage: "checkmark.circle", description: Text("可切换待核事实、暂放或本次已保存。未核实事实仍留在待核事实队列中；已无缺项的项目可在本次已保存复查。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if workspace.from.isEmpty { workspace.from = store.from; workspace.to = store.to }
            workspace.refresh(store, evidence)
        }
        .task(id: store.revision) { await store.reconcileCompletion(); workspace.refresh(store, evidence) }
        .onChange(of: store.revision) { _, _ in workspace.refresh(store, evidence) }
        .onChange(of: evidence.previewGeneration) { _, _ in workspace.refresh(store, evidence) }
        .onChange(of: workspace.allDates) { _, _ in workspace.refresh(store, evidence) }
        .sheet(isPresented: $showingSourceSets) {
            NavigationStack {
                SourceRecordSetList(store: store, evidence: evidence)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { showingSourceSets = false } } }
            }.frame(minWidth: 600, minHeight: 600)
        }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("补全").font(.title2.bold())
                Text("同名商家自动确认，可在「已确认」复查").foregroundStyle(.secondary)
            }
            Spacer()
            Button("来源归并（\(store.sourceRecordGroups.count)）") { showingSourceSets = true }
                .accessibilityIdentifier("source-set-list").disabled(busy)
            VStack(alignment: .trailing, spacing: 4) {
                Text("本次保存 \(workspace.saved.count) 项 · 暂放 \(workspace.deferred.count) 项").font(.callout)
                Text("\(workspace.visible.count) 项待看 · 按金额从大到小；金额未知排最后").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 22).padding(.vertical, 16)
    }
    private var queue: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("队列", selection: $workspace.mode) {
                    ForEach(["优先补全", "待分类", "待核事实", "退款候选", "暂放", "本次已保存", "已确认", "已排除"], id: \.self) { Text($0).tag($0) }
                }
                TextField("搜索日期、商户、金额或用户", text: $workspace.query).textFieldStyle(.roundedBorder)
                Toggle("包括区间外与日期未知", isOn: $workspace.allDates).font(.caption)
                Text("只扩大补全队列，统计日期范围不变；同名联动始终覆盖全资料库。").font(.caption2).foregroundStyle(.secondary)
                Text(workspace.allDates ? "全部资料日期" : workspace.from + " — " + workspace.to).font(.caption).foregroundStyle(.secondary)
                Text("仅列已生成生命周期的消费项目；独立证据待核保留在交易证据页。").font(.caption2).foregroundStyle(.secondary)
            }.padding(14)
            List(selection: $workspace.selected) {
                ForEach(workspace.visible) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(entry.record.date).font(.caption); Spacer(); Text(entry.amountUnknown ? "金额未知" : money(entry.impact)).monospacedDigit().font(.callout) }
                        Text(entry.component?.title ?? entry.record.title).lineLimit(2)
                        Text(entry.issueSummaries.joined(separator: " · ")).font(.caption).foregroundStyle(entry.factsPending ? Color.orange : Color.secondary).lineLimit(3)
                        if workspace.isDirty(entry) { Text("未保存草稿").font(.caption2).foregroundStyle(.blue) }
                    }.padding(.vertical, 6).tag(entry.id)
                }
            }.listStyle(.inset).disabled(busy)
                .overlay { if workspace.visible.isEmpty { Text("没有匹配项").foregroundStyle(.secondary) } }
        }.disabled(busy)
    }
    private func evidencePanel(_ entry: CompletionEntry) -> some View {
        ScrollView { CompletionEvidence(entry: entry, store: store, evidence: evidence, workspace: workspace, busy: busy, dirty: workspace.isDirty(entry)).padding(18) }.id(entry.id)
            .frame(maxWidth: .infinity)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let failure = workspace.workflowError { Text(failure).font(.caption).foregroundStyle(.red) }
                if !workspace.message.isEmpty { Text(workspace.message).font(.caption).foregroundStyle(.secondary) }
                if let entry = workspace.current, workspace.isDirty(entry) { Text("有未保存选项；切换交易会保留本次草稿。").font(.caption).foregroundStyle(.blue) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if busy { ProgressView().controlSize(.small) }
            Button("撤销上一笔") { Task { await store.undoCompletion(); workspace.refresh(store, evidence) } }.disabled(busy || workspace.undo == nil)
            if let entry = workspace.current {
                Button(workspace.deferred.contains(entry.id) ? "放回队列" : "暂放并下一笔") {
                    let previous = workspace.visible.map(\.id)
                    Task { await workspace.setDeferred(entry.id, value: !workspace.deferred.contains(entry.id), store: store); workspace.next(after: entry.id, previous: previous) }
                }.disabled(busy || workspace.workflowError != nil)
                Button(entry.component == nil ? "下一笔" : "保存并下一笔") {
                    let previous = workspace.visible.map(\.id)
                    Task {
                        let success = entry.component == nil ? true : await store.saveCompletion(entry)
                        if success {
                            workspace.refresh(store, evidence); workspace.next(after: entry.id, previous: previous)
                        }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(busy)
            }
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }
}

#endif
struct CompletionEditor: View {
    let entry: CompletionEntry
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    @Bindable var workspace: CompletionWorkspace
    let busy: Bool
    @State private var newTag = ""
    @State private var choosingPrimary = false
    private var disabled: Bool { busy }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            identity
            TransactionReviewExclusion(record: entry.record, store: store)
            if let component = entry.component, let draft = workspace.draft(entry) {
                fields(component, draft)
            } else if entry.record.reviewExcluded {
                ReviewCard(title: "已排除") {
                    Text("此交易不参与补全和统计；关闭上方开关后按原有事实恢复。")
                }
            } else {
                ReviewCard(title: "这笔需要核实事实") {
                    Text("暂无可编辑的消费项目。请先对照原始记录核实退款或付款链路；本页不会把贷记直接改成消费。")
                }
            }
            if entry.factsPending {
                ReviewCard(title: "事实仍待核") {
                    ForEach(entry.factDescriptions, id: \.self) { Text("• " + $0).textSelection(.enabled) }
                    Text("分类保存只确认分类、支出性质和标签。请核对原始证据，再用「确认交易事实」处理日期、消费人、金额或统计纳入；候选关联也可在原始证据区复核。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.disabled(disabled)
            .onAppear { choosingPrimary = entry.missingCategory }
            .task(id: "\(entry.id)|\(store.revision)") {
            guard let component = entry.component, let report = store.report else { categorySuggestion = nil; return }
            let result = await Task.detached(priority: .userInitiated) {
                CategoryHeuristics.suggestion(for: component, records: report.records, taxonomy: report.taxonomy)
            }.value
            if !Task.isCancelled { categorySuggestion = result }
        }
    }
    private var identity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.component?.title ?? entry.record.title).font(.title2.bold()).lineLimit(3).help(entry.component?.title ?? entry.record.title).textSelection(.enabled)
            Text(entry.record.date + " · " + entry.record.status).foregroundStyle(.secondary)
            if entry.component?.completionConfirmed == true {
                Label(entry.component?.completion_confirmation?.origin == "linked" ? "分类等字段已自动确认 · 同名商家联动" : "分类等字段已确认", systemImage: "checkmark.circle.fill").foregroundStyle(.teal)
            }
            FinanceTransactionIdentity(record: entry.record)
            TransactionFactActions(record: entry.record, store: store, evidence: evidence)
            if entry.record.components.count > 1 { Text("本次编辑此交易中的一个消费项目（共 \(entry.record.components.count) 项）").font(.caption).foregroundStyle(.secondary) }
            if let component = entry.component {
                HStack(spacing: 22) {
                    VStack(alignment: .leading) { Text("原支出").font(.caption).foregroundStyle(.secondary); Text(entry.amountUnknown ? "金额未知" : money(component.gross_cents)).monospacedDigit() }
                    VStack(alignment: .leading) { Text("退款").font(.caption).foregroundStyle(.secondary); Text(money(component.refund_cents)).monospacedDigit() }
                    if let receipt = component.reimbursement_cents { VStack(alignment: .leading) { Text("代购回款").font(.caption).foregroundStyle(.secondary); Text(money(receipt)).monospacedDigit() } }
                    VStack(alignment: .leading) { Text(component.net_cents < 0 ? "净收入" : "净支出").font(.caption).foregroundStyle(.secondary); Text(entry.amountUnknown ? "金额未知" : money(abs(component.net_cents))).font(.title3.bold()).monospacedDigit() }
                }
                Text(component.included ? "已纳入当前统计" : "尚未纳入当前统计").font(.caption).foregroundStyle(component.included ? Color.secondary : Color.orange)
            }
            DisclosureGroup("付款、退款与回款记录（\(entry.record.paymentEvents.count)）") {
                ForEach(entry.record.paymentEvents) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(event.date + " · " + (event.payment_account ?? platformName(event.source)) + " · " + statusName(event.kind)).font(.caption); Spacer(); Text(money(event.amount_cents)).font(.caption).monospacedDigit() }
                        if event.payment_account != nil || event.status.hasPrefix("同一次") { Text(platformName(event.source) + " · " + event.status).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let group = entry.record.bank_settlement_group {
                    Text("已与 \(group.count) 笔银行扣款整组对账，单笔对应关系未指定。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    @State private var categorySuggestion: CategorySuggestion?
    private var suggestionCard: some View {
        Group {
            if entry.missingCategory, let suggestion = categorySuggestion {
                ReviewCard(title: "分类候选 · 相似度 \(suggestion.score)%") {
                    Text(suggestion.source.primary + " / " + suggestion.source.secondary).font(.headline)
                    Text("参考交易：" + suggestion.source.title).font(.caption).textSelection(.enabled)
                    Text(suggestion.platform ? "平台、通道或不完整名称可能对应多种用途，仅供逐笔参考。" : suggestion.ambiguous ? "最高分对应多个分类，请核对原始证据。" : suggestion.score < 60 ? "匹配较弱，请核对用途后决定。" : "分数仅表示名称相似程度，请核对用途。").font(.caption).foregroundStyle(.secondary)
                    if suggestion.score < 60 && (suggestion.platform || suggestion.ambiguous) {
                        Text("匹配较弱，请核对用途后决定。").font(.caption).foregroundStyle(.orange)
                    }
                    Button("采用候选分类") {
                        guard var next = workspace.draft(entry) else { return }
                        next.primary = suggestion.source.primary; next.secondary = suggestion.source.secondary
                        workspace.edit(entry, next); choosingPrimary = false
                    }.buttonStyle(.bordered).accessibilityIdentifier("completion-adopt-suggestion")
                }
            }
        }
    }
    private func fields(_ component: FinancialComponent, _ draft: CompletionDraft) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            suggestionCard
            ReviewCard(title: "分类") {
                let linked = CategoryHeuristics.linkedTargets(source: component, draft: draft, records: store.report?.records ?? [], excluding: Set(workspace.drafts.keys))
                if !linked.isEmpty {
                    Text("保存时将确认 \(linked.count) 项同名商家并移出默认队列（含区间外），可整批撤销。").font(.caption).foregroundStyle(.teal).accessibilityIdentifier("completion-linked-preview")
                } else {
                    Text(CategoryHeuristics.blocksAutomation(component.title) ? "平台、通道或不完整名称：本笔分类不自动联动。" : "保存即确认；同名且分类一致的项目一起确认，已有草稿跳过。").font(.caption).foregroundStyle(.secondary)
                }
                Text("当前依据：" + component.classification_basis).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("一级分类").font(.caption).foregroundStyle(.secondary)
                    Text(draft.primary).fontWeight(.medium)
                    Spacer()
                    Button(choosingPrimary ? "收起" : "更改") { choosingPrimary.toggle() }
                }
                if choosingPrimary {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 115))], alignment: .leading, spacing: 8) {
                        ForEach((store.report?.taxonomy ?? []).filter { !$0.secondaries.isEmpty }) { category in
                            choice(category.primary, selected: draft.primary == category.primary) {
                                var next = workspace.draft(entry) ?? draft; next.primary = category.primary
                                if !category.secondaries.contains(next.secondary) { next.secondary = category.secondaries.count == 1 ? category.secondaries[0] : "" }
                                workspace.edit(entry, next); choosingPrimary = false
                            }
                        }
                    }
                }
                Divider()
                Text(draft.secondary.isEmpty ? "请选择二级分类" : "二级分类").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], alignment: .leading, spacing: 8) {
                    ForEach(store.report?.taxonomy.first { $0.primary == draft.primary }?.secondaries ?? [], id: \.self) { name in
                        choice(name, selected: draft.secondary == name) { var next = workspace.draft(entry) ?? draft; next.secondary = name; workspace.edit(entry, next) }
                    }
                }
            }
            ReviewCard(title: "支出性质") {
                ForEach([("one_time", "一次性购买"), ("recurring", "持续生活支出")], id: \.0) { value, label in
                    choice(label, selected: draft.recurrence == value) { var next = workspace.draft(entry) ?? draft; next.recurrence = value; workspace.edit(entry, next) }
                }
                Text("默认一次性购买；已明确的持续生活支出保留。年度实际消费仍保留；一次性购买不计入持续支出情景。").font(.caption).foregroundStyle(.secondary)
            }
            ReviewCard(title: "标签（可选）") {
                if draft.tags.isEmpty { Text("暂无标签；不强制补标签。").font(.caption).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading, spacing: 8) {
                    ForEach(draft.tags, id: \.self) { tag in
                        Button { var next = workspace.draft(entry) ?? draft; next.tags.removeAll { $0 == tag }; workspace.edit(entry, next) } label: { Label(tag, systemImage: "xmark.circle").lineLimit(1) }.buttonStyle(.bordered).tint(.teal)
                    }
                }
                Menu("选择已有标签") {
                    ForEach(store.tags.filter { !draft.tags.contains($0) }, id: \.self) { tag in
                        Button(tag) { var next = workspace.draft(entry) ?? draft; next.tags.append(tag); workspace.edit(entry, next) }
                    }
                }
                HStack {
                    TextField("需要时新增标签", text: $newTag).textFieldStyle(.roundedBorder)
                    Button("添加") { var next = workspace.draft(entry) ?? draft; next.tags.append(newTag); workspace.edit(entry, next); newTag = "" }.disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            HStack {
                Text(workspace.isDirty(entry) ? "选项仅在草稿中，保存后生效" : "已有字段已填入，按需修改").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("还原草稿") { workspace.drafts.removeValue(forKey: entry.id); workspace.draftBases.removeValue(forKey: entry.id) }.disabled(!workspace.isDirty(entry))
            }
        }
    }
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Image(systemName: selected ? "checkmark.circle.fill" : "circle"); Text(title).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(title); Spacer(minLength: 0) }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
        }.buttonStyle(.bordered).tint(selected ? Color.accentColor : Color.secondary)
    }
}

struct CompletionEvidence: View {
    let entry: CompletionEntry
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    @Bindable var workspace: CompletionWorkspace
    let busy: Bool; let dirty: Bool
    @State private var chosen: String?
    private var sources: [BrowseRecord] { TransactionListOrder.sorted(entry.record.evidence_keys.compactMap { workspace.evidenceIndex[$0] }, amount: \.amount, date: \.date, id: \.id) }
    private var candidates: [Candidate] { workspace.relevantCandidates(entry) }
    private var active: BrowseRecord? {
        if let chosen, let record = workspace.evidenceIndex[chosen] { return record }
        return sources.first { ["card", "taobao_card"].contains($0.platform) } ?? sources.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("原始证据").font(.title3.bold()); Spacer(); Text("\(sources.count) 份").font(.caption).foregroundStyle(.secondary) }
            if !sources.isEmpty {
                Picker("记录", selection: Binding(get: { active?.id ?? "" }, set: { chosen = $0 })) {
                    ForEach(sources) { source in Text(platformName(source.platform) + " · " + source.date + " · " + money(source.amount)).tag(source.id) }
                }
            }
            if let active { RecordPane(record: active, store: evidence) }
            else { Text("暂无可展示的原始记录，请补充来源资料。").foregroundStyle(.secondary) }
            if !candidates.isEmpty {
                Text("现有候选关联").font(.headline)
                Text("对照两侧记录后选择现有关联选项。不会由金额相同自动确认身份或退款。\(dirty ? "请先保存或还原字段草稿。" : "")").font(.caption).foregroundStyle(.secondary)
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("关联状态：" + candidate.association_status).font(.caption)
                        ForEach(TransactionListOrder.sorted(Array(Set(candidate.record_ids + candidate.bank_ids)).compactMap { workspace.evidenceIndex[$0] }, amount: \.amount, date: \.date, id: \.id)) { source in
                            Group {
                                Button { chosen = source.id } label: {
                                    VStack(alignment: .leading) { Text(platformName(source.platform) + " · " + source.date + " · " + money(source.amount)); Text(source.title).font(.caption).lineLimit(2) }
                                }.buttonStyle(.bordered)
                            }
                        }
                        let competing = !(candidate.active_competing_candidate_ids ?? []).isEmpty
                        Button(competing ? "支持此关联并排除竞争关联" : "支持关联") { Task { await evidence.decide(candidate, judgment: "supports", finance: store) } }
                        HStack {
                            Button("排除此关联") { Task { await evidence.decide(candidate, judgment: "rejects", finance: store) } }
                            Button("仍需资料") { Task { await evidence.decide(candidate, judgment: "needs_evidence", finance: store) } }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.background).clipShape(RoundedRectangle(cornerRadius: 12)).disabled(busy || dirty)
                }
            }
            if evidence.loading { ProgressView("关联复核处理中…") }
            if let error = evidence.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !evidence.reviewMessage.isEmpty { Text(evidence.reviewMessage).font(.caption).foregroundStyle(.secondary) }
        }.onChange(of: entry.id) { _, _ in chosen = nil }
    }
}
#endif
