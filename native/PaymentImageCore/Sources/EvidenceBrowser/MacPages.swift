#if os(macOS)
import SwiftUI
import AppKit
import PaymentImageCore

// MARK: 待办

/// Actions published by the inbox so the 复核 menu and shortcuts reach the focused window.
struct InboxActions {
    var save: (() -> Void)?
    var deferItem: (() -> Void)?
    var undo: (() -> Void)?
    var adopt: (() -> Void)?
    var move: (Int) -> Void
    var search: () -> Void
    var shortcuts: () -> Void
}
private struct InboxActionsKey: FocusedValueKey { typealias Value = InboxActions }
extension FocusedValues {
    var inboxActions: InboxActions? { get { self[InboxActionsKey.self] } set { self[InboxActionsKey.self] = newValue } }
}

struct InboxCommands: Commands {
    @FocusedValue(\.inboxActions) private var actions
    var body: some Commands {
        CommandMenu("复核") {
            Button("保存并下一笔") { actions?.save?() }.keyboardShortcut(.return, modifiers: .command).disabled(actions?.save == nil)
            Button("暂放 / 放回队列") { actions?.deferItem?() }.keyboardShortcut("d", modifiers: .command).disabled(actions?.deferItem == nil)
            Button("撤销上一笔保存") { actions?.undo?() }.keyboardShortcut("z", modifiers: [.command, .option]).disabled(actions?.undo == nil)
            Divider()
            Button("采用分类候选") { actions?.adopt?() }.keyboardShortcut("1", modifiers: [.command, .option]).disabled(actions?.adopt == nil)
            Divider()
            Button("上一项") { actions?.move(-1) }.keyboardShortcut("[", modifiers: .command).disabled(actions == nil)
            Button("下一项") { actions?.move(1) }.keyboardShortcut("]", modifiers: .command).disabled(actions == nil)
            Button("搜索待办") { actions?.search() }.keyboardShortcut("f", modifiers: .command).disabled(actions == nil)
            Button("键盘快捷键…") { actions?.shortcuts() }.keyboardShortcut("/", modifiers: .command).disabled(actions == nil)
        }
    }
}

struct MacInboxPage: View {
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    @Bindable var inbox: InboxModel
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var showingShortcuts = false
    private var workspace: CompletionWorkspace { store.completion }
    private var busy: Bool { !store.editingAvailable || store.completionSaving || store.importing || store.loading || evidence.loading || workspace.persisting }

    var body: some View {
        let items = inbox.items
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                queue(items).frame(width: 310)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(DS.pageBackground)
        .onAppear { inbox.ensureSelection(in: items); listFocused = true }
        .onChange(of: items.map(\.id)) { _, ids in if !ids.contains(where: { $0 == inbox.selectedID }) { inbox.selectedID = ids.first } }
        .focusedSceneValue(\.inboxActions, actions)
        .sheet(isPresented: $showingShortcuts) { InboxShortcutSheet() }
    }

    // MARK: Queue column

    private func queue(_ items: [InboxItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.m) {
                Picker("范围", selection: Binding(get: { inbox.history == nil ? 0 : 1 }, set: { inbox.history = $0 == 0 ? nil : (inbox.history ?? .saved) })) {
                    Text("待处理").tag(0); Text("历史").tag(1)
                }.pickerStyle(.segmented).labelsHidden()
                if inbox.history == nil {
                    TagFlowLayout() {
                        ForEach(InboxKind.allCases) { kind in
                            FilterChip(title: kind.rawValue, count: inbox.count(kind), selected: inbox.kind == kind) { inbox.kind = kind }
                        }
                    }
                } else {
                    TagFlowLayout() {
                        ForEach(InboxHistory.allCases) { kind in
                            FilterChip(title: kind.rawValue, selected: inbox.history == kind) { inbox.history = kind }
                        }
                    }
                }
                HStack(spacing: DS.s) {
                    TextField("搜索日期、商户、金额或用户", text: $inbox.query).textFieldStyle(.roundedBorder).focused($searchFocused)
                        .onSubmit { listFocused = true }
                    Menu {
                        Toggle("包括区间外与日期未知", isOn: $inbox.includeAllDates)
                        Divider()
                        Button("键盘快捷键…") { showingShortcuts = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize().help("队列选项")
                }
                Text(queueCaption(items.count)).font(.caption).foregroundStyle(.secondary)
            }.padding(DS.m + 2)
            List(selection: $inbox.selectedID) {
                ForEach(items) { item in InboxRow(info: inbox.row(item)).tag(item.id) }
            }
            .listStyle(.inset)
            .focused($listFocused)
            .onKeyPress(characters: CharacterSet(charactersIn: "jk1/?")) { press in
                switch press.characters {
                case "j": inbox.move(1)
                case "k": inbox.move(-1)
                case "1": actions.adopt?()
                case "/": searchFocused = true
                default: showingShortcuts = true
                }
                return .handled
            }
            .overlay { if items.isEmpty { emptyQueue } }
        }.disabled(busy && inbox.selectedItem?.completionEntry == nil)
    }
    private func queueCaption(_ count: Int) -> String {
        let range = inbox.includeAllDates ? "全部日期" : periodTitle(from: workspace.from, to: workspace.to)
        return "\(count) 项 · \(range) · 金额从大到小"
    }
    @ViewBuilder private var emptyQueue: some View {
        if inbox.history == nil {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: inbox.query.isEmpty ? "checkmark.circle" : "magnifyingglass")
            } description: {
                Text(emptyDetail)
            } actions: {
                if !inbox.query.isEmpty { Button("清空搜索") { inbox.query = "" } }
                else if inbox.kind != .all && inbox.count(.all) > 0 { Button("查看全部待办") { inbox.kind = .all } }
                else if !inbox.includeAllDates { Button("包括区间外与日期未知") { inbox.includeAllDates = true } }
                else { Button("复查本次已保存") { inbox.history = .saved } }
            }
        } else { ContentUnavailableView("暂无记录", systemImage: "clock") }
    }

    private var emptyTitle: String {
        if !inbox.query.isEmpty { return "没有匹配项" }
        return inbox.count(.all) == 0 ? "当前区间已全部处理" : "此类型已处理完"
    }
    private var emptyDetail: String {
        if !inbox.query.isEmpty { return "没有符合「\(inbox.query)」的待办。" }
        let remaining = inbox.count(.all)
        if remaining > 0 { return "其他类型还有 \(remaining) 项待处理。" }
        return inbox.includeAllDates ? "全部日期都没有待处理项目。" : "统计区间外或日期未知的资料可能仍有待办。"
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch inbox.selectedItem {
        case .completion(let entry)?:
            GeometryReader { geometry in
                if geometry.size.width >= 820 {
                    HStack(spacing: 0) {
                        ScrollView { editor(entry).padding(DS.xl - 4) }.frame(width: geometry.size.width * 0.5)
                        Divider()
                        ScrollView { evidencePanel(entry).padding(DS.l + 2) }
                    }
                } else {
                    ScrollView { VStack(alignment: .leading, spacing: DS.xl) { editor(entry); evidencePanel(entry) }.padding(DS.xl - 2) }
                }
            }.id(entry.id)
        case .association(let candidate)?:
            InboxAssociationDetail(candidate: candidate, store: store, evidence: evidence).id(candidate.id)
        case .sourceSet(let group)?:
            NavigationStack { SourceRecordSetDetail(groupID: group.id, store: store, evidence: evidence) }.id(group.id)
        case nil:
            ContentUnavailableView("选择一项", systemImage: "checklist", description: Text("从左侧队列选择需要处理的项目。"))
        }
    }
    private func editor(_ entry: CompletionEntry) -> some View {
        CompletionEditor(entry: entry, store: store, evidence: evidence, workspace: workspace, busy: busy)
    }
    private func evidencePanel(_ entry: CompletionEntry) -> some View {
        CompletionEvidence(entry: entry, store: store, evidence: evidence, workspace: workspace, busy: busy, dirty: workspace.isDirty(entry))
    }

    // MARK: Footer & actions

    private var footer: some View {
        HStack(spacing: DS.m) {
            VStack(alignment: .leading, spacing: 3) {
                if let failure = workspace.workflowError { Text(failure).font(.caption).foregroundStyle(DS.failure) }
                if let failure = evidence.error { Text(failure).font(.caption).foregroundStyle(DS.failure) }
                if !workspace.message.isEmpty { Text(workspace.message).font(.caption).foregroundStyle(.secondary) }
                if let entry = inbox.selectedItem?.completionEntry, workspace.isDirty(entry) {
                    Text("有未保存的修改；切换项目会保留草稿。").font(.caption).foregroundStyle(DS.draft)
                }
                if let reason = store.editorPauseReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if busy && store.editingAvailable { ProgressView().controlSize(.small) }
            Button("撤销上一笔") { undo() }.disabled(busy || workspace.undo == nil).help("撤销最近一次保存（⌥⌘Z）")
            if let entry = inbox.selectedItem?.completionEntry {
                Button(workspace.deferred.contains(entry.id) ? "放回队列" : "暂放") { toggleDeferred(entry) }
                    .disabled(busy || workspace.workflowError != nil).help("暂放后可在历史「暂放」找回（⌘D）")
                Button(entry.component == nil ? "下一笔" : "保存并下一笔") { save(entry) }
                    .buttonStyle(.borderedProminent).disabled(busy).help("⌘↩")
            }
        }.padding(.horizontal, DS.xl - 4).padding(.vertical, DS.m)
    }
    private var actions: InboxActions {
        let entry = inbox.selectedItem?.completionEntry
        let ready = !busy
        return InboxActions(
            save: entry.flatMap { entry in ready ? { save(entry) } : nil },
            deferItem: entry.flatMap { entry in ready && workspace.workflowError == nil ? { toggleDeferred(entry) } : nil },
            undo: ready && workspace.undo != nil ? { undo() } : nil,
            adopt: entry?.missingCategory == true && ready ? { NotificationCenter.default.post(name: .adoptCategorySuggestion, object: entry?.id) } : nil,
            move: { inbox.move($0) },
            search: { searchFocused = true },
            shortcuts: { showingShortcuts = true })
    }
    private func save(_ entry: CompletionEntry) {
        let previous = inbox.items.map(\.id), id = "c:" + entry.id
        Task {
            let success = entry.component == nil ? true : await store.saveCompletion(entry)
            guard success else { return }
            workspace.refresh(store, evidence)
            inbox.select(after: id, previous: previous)
            if entry.component != nil { ToastCenter.shared.show("已保存", undoTitle: "撤销") { undo() } }
        }
    }
    private func toggleDeferred(_ entry: CompletionEntry) {
        let previous = inbox.items.map(\.id), id = "c:" + entry.id
        let value = !workspace.deferred.contains(entry.id)
        Task {
            await workspace.setDeferred(entry.id, value: value, store: store)
            inbox.select(after: id, previous: previous)
            if value { ToastCenter.shared.show("已暂放，可在历史「暂放」找回") }
        }
    }
    private func undo() { Task { await store.undoCompletion(); workspace.refresh(store, evidence) } }
}

struct InboxRow: View {
    let info: InboxRowInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.title).lineLimit(2).font(.callout.weight(.medium))
                Spacer(minLength: DS.s)
                Text(info.amount.map(money) ?? "金额未知").monospacedDigit().font(.callout)
                    .foregroundStyle(info.amount == nil ? Color.secondary : Color.primary)
            }
            HStack(spacing: DS.xs) {
                Text(info.date.isEmpty ? "日期未知" : String(info.date.prefix(10))).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(info.badges.enumerated()), id: \.offset) { _, badge in StatusBadge(text: badge.0, tone: badge.1) }
            }
        }.padding(.vertical, DS.xs)
    }
}

/// An evidence association not tied to a single listed transaction.
struct InboxAssociationDetail: View {
    let candidate: Candidate
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    private var records: [BrowseRecord] {
        let ids = Set(candidate.record_ids + candidate.bank_ids)
        return evidence.records.filter { ids.contains($0.id) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.l) {
                VStack(alignment: .leading, spacing: DS.s) {
                    HStack(spacing: DS.s) {
                        Text(associationKindName(candidate.kind)).font(.title2.bold())
                        StatusBadge(text: associationStatusName(candidate, deferred: evidence.deferredCandidates.contains(candidate.id)), tone: candidate.review_required ? .accent : .neutral)
                    }
                    HStack(spacing: DS.xs) {
                        Text("这两侧记录是否是同一笔付款？只改变证据关联，不删除银行消费，也不确认消费人。").font(.callout).foregroundStyle(.secondary)
                        InfoButton(text: "支持：两侧记录归为同一笔交易。排除：两侧记录保持独立。仍需资料：保留在队列中，补充素材后再判断。金额相同不会自动确认关联。")
                    }
                }
                HStack(spacing: DS.s) {
                    let competing = !(candidate.active_competing_candidate_ids ?? []).isEmpty
                    Button(competing ? "支持此关联并排除竞争关联" : "支持关联") { decide("supports") }.buttonStyle(.borderedProminent)
                    Button("排除此关联") { decide("rejects") }
                    Button("仍需资料") { decide("needs_evidence") }
                }.disabled(evidence.loading || store.categoryBusy || !store.evidenceReviewAvailable)
                if !evidence.reviewMessage.isEmpty { Text(evidence.reviewMessage).font(.caption).foregroundStyle(.secondary) }
                ForEach(records) { RecordPane(record: $0, store: evidence) }
                if records.isEmpty { NoticeText(text: "原始记录尚未读取。", tone: .pending) }
            }.padding(DS.xl - 2).frame(maxWidth: 900, alignment: .leading)
        }
    }
    private func decide(_ judgment: String) {
        Task {
            await evidence.decide(candidate, judgment: judgment, finance: store)
            if evidence.error == nil { ToastCenter.shared.show(judgment == "supports" ? "已支持关联" : judgment == "rejects" ? "已排除关联" : "已标记仍需资料") }
        }
    }
}

private struct InboxShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let rows = [("j / ↓", "下一项"), ("k / ↑", "上一项"), ("⌘] / ⌘[", "下一项 / 上一项（任意位置）"), ("⌘↩", "保存并下一笔"), ("⌘D", "暂放 / 放回队列"),
                        ("⌥⌘Z", "撤销上一笔保存"), ("1 或 ⌥⌘1", "采用分类候选"), ("⌘1 – ⌘3", "概览 / 待办 / 交易"), ("⌘F 或 /", "搜索"), ("? 或 ⌘/", "显示本面板")]
    var body: some View {
        VStack(alignment: .leading, spacing: DS.l) {
            Text("待办快捷键").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: DS.xl, verticalSpacing: DS.s) {
                ForEach(rows, id: \.0) { key, title in
                    GridRow { Text(key).font(.body.monospaced()).foregroundStyle(DS.accent); Text(title) }
                }
            }
            Text("输入框聚焦时字母快捷键不生效。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(DS.xl).frame(width: 380)
    }
}

// MARK: 交易

struct MacTransactionsPage: View {
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    @State private var scope = 0
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Picker("范围", selection: $scope) { Text("交易").tag(0); Text("原始资料").tag(1) }
                        .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], DS.m)
                    if scope == 0 { FinanceTransactionList(store: store) } else { MacRawRecordList(store: store, evidence: evidence) }
                }.frame(width: min(380, geometry.size.width * 0.38), height: geometry.size.height)
                Divider()
                if scope == 0 {
                    FinanceSelectedTransaction(store: store, evidence: evidence, recordID: store.directDetailID)
                } else {
                    MacRawRecordDetail(store: store, evidence: evidence, back: { scope = 0 })
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
}

private struct MacRawRecordList: View {
    let store: FinancialStore
    @Bindable var evidence: BrowserStore
    @State private var platform: String?
    private var platforms: [String] { Array(Set(evidence.records.map(\.platform))).sorted { platformName($0) < platformName($1) } }
    private var records: [BrowseRecord] { evidence.records.filter { (platform == nil || $0.platform == platform) && evidence.matches($0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.s) {
            TextField("搜索时间、商户或金额", text: $evidence.query).textFieldStyle(.roundedBorder).padding(.horizontal, DS.m).padding(.top, DS.s)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: "全部", selected: platform == nil) { platform = nil }
                    ForEach(platforms, id: \.self) { name in FilterChip(title: platformName(name), selected: platform == name) { platform = name } }
                }.padding(.horizontal, DS.m)
            }
            Text("原始资料包含全部日期，不受统计区间和账户、分类、标签筛选影响" + (videoSummary.map { "；" + $0 } ?? "") + "。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, DS.m)
            List(selection: $evidence.selected) {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(platformName(record.platform)).font(.caption.weight(.medium)).foregroundStyle(DS.accent); Text(record.date).font(.caption).foregroundStyle(.secondary); Spacer(); Text(money(record.amount)).monospacedDigit() }
                        Text(record.title).lineLimit(2).font(.callout)
                    }.padding(.vertical, 3).tag(record.id)
                }
            }.listStyle(.inset)
                .overlay { if records.isEmpty { ContentUnavailableView("没有匹配记录", systemImage: "magnifyingglass", description: Text("清空搜索或切换平台。")) } }
        }
        .onAppear { evidence.section = "records" }
    }
    private var videoSummary: String? {
        let videos = store.report?.video_materials ?? []
        return videos.isEmpty ? nil : "其中录屏解析 \(videos.count) 条"
    }
}

private struct MacRawRecordDetail: View {
    @Bindable var store: FinancialStore
    let evidence: BrowserStore
    let back: () -> Void
    private var record: BrowseRecord? { evidence.records.first { $0.id == evidence.selected } }
    private var owner: FinancialLifecycle? { record.flatMap { record in store.report?.records.first { $0.evidence_keys.contains(record.id) } } }
    var body: some View {
        if let record {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.l) {
                    if let owner {
                        Button { store.inspectTransaction(owner.id); back() } label: { Label("查看所属交易：" + owner.title, systemImage: "arrow.right.circle") }
                            .buttonStyle(.link)
                    } else { NoticeText(text: "这条记录尚未归入任何交易。", tone: .pending) }
                    RecordPane(record: record, store: evidence)
                }.padding(DS.xl - 2)
            }.id(record.id)
        } else {
            ContentUnavailableView("选择一条原始记录", systemImage: "doc.text.viewfinder", description: Text("查看原始文字、银行裁剪行或订单卡片。")).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
