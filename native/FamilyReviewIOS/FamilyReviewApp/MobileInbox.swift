import SwiftUI
import UniformTypeIdentifiers
import PaymentImageCore

/// 待办 tab: the same single queue as the Mac, tuned for quick one-handed review.
struct MobileInboxList: View {
    @Bindable var finance: FinancialStore
    @Bindable var evidence: BrowserStore
    @Bindable var inbox: InboxModel
    @State private var sending = false
    private var workspace: CompletionWorkspace { finance.completion }
    var body: some View {
        let items = inbox.items
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let history = inbox.history {
                            ForEach(InboxHistory.allCases) { kind in
                                FilterChip(title: kind.rawValue, selected: history == kind) { inbox.history = kind }
                                    .accessibilityIdentifier("inbox-history:" + kind.rawValue)
                            }
                        } else {
                            ForEach(InboxKind.allCases) { kind in
                                FilterChip(title: kind.rawValue, count: inbox.count(kind), selected: inbox.kind == kind) { inbox.kind = kind }
                                    .accessibilityIdentifier("inbox-kind:" + kind.rawValue)
                            }
                        }
                    }.padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                Text(caption(items.count))
                    .font(.caption).foregroundStyle(.secondary)
                if !workspace.message.isEmpty { Text(workspace.message).font(.caption).foregroundStyle(DS.accent) }
                if let error = finance.error { Text(error).font(.caption).foregroundStyle(DS.failure) }
            }
            ForEach(items) { item in
                NavigationLink { destination(item) } label: { MobileInboxRow(info: inbox.row(item), id: item.completionEntry?.id) }
                    .swipeActions(edge: .trailing) {
                        if let entry = item.completionEntry {
                            Button(workspace.deferred.contains(entry.id) ? "放回" : "暂放") {
                                let value = !workspace.deferred.contains(entry.id)
                                Task { await workspace.setDeferred(entry.id, value: value, store: finance); if value { ToastCenter.shared.show("已暂放，可在历史找回") } }
                            }.tint(DS.pending)
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(inbox.history == nil && inbox.query.isEmpty ? "全部处理完了" : "没有匹配项", systemImage: "checkmark.circle")
                } description: {
                    Text(inbox.history == nil ? "当前类型没有待处理的项目。" : "暂无记录。")
                }
            }
        }
        .navigationTitle(inbox.history == nil ? "待办" : "历史")
        .searchable(text: $inbox.query, prompt: "项目、日期或金额")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(inbox.history == nil ? "历史" : "待处理") { inbox.history = inbox.history == nil ? .saved : nil }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Toggle("包括区间外与日期未知", isOn: $inbox.includeAllDates)
                } label: { Label("选项", systemImage: "ellipsis.circle") }
                Button { sending = true } label: { Label("发送素材到 Mac", systemImage: "plus") }
                    .disabled(!finance.editingAvailable || finance.importing || finance.categoryBusy || evidence.loading)
            }
        }
        .fileImporter(isPresented: $sending, allowedContentTypes: [.pdf, .commaSeparatedText, .spreadsheet, .movie, .image, .data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { await importReporting(finance, urls, success: "已发送 \(urls.count) 个文件，Mac 处理后自动同步") }
        }
        .onChange(of: inbox.includeAllDates) { _, _ in workspace.refresh(finance, evidence) }
    }
    private func caption(_ count: Int) -> String {
        let range: String = inbox.includeAllDates ? "全部日期" : periodTitle(from: workspace.from, to: workspace.to)
        return "\(count) 项 · \(range) · 金额从大到小"
    }
    @ViewBuilder private func destination(_ item: InboxItem) -> some View {
        switch item {
        case .completion(let entry): MobileCompletionDetail(finance: finance, evidence: evidence, workspace: workspace, initial: entry.id)
        case .association(let candidate): MobileCandidate(candidate: candidate, finance: finance, evidence: evidence)
        case .sourceSet(let group): SourceRecordSetDetail(groupID: group.id, store: finance, evidence: evidence)
        }
    }
}

struct MobileInboxRow: View {
    let info: InboxRowInfo
    let id: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(info.title).lineLimit(2)
            HStack(spacing: DS.xs) {
                Text(info.date.isEmpty ? "日期未知" : String(info.date.prefix(10))).foregroundStyle(.secondary)
                ForEach(Array(info.badges.enumerated()), id: \.offset) { _, badge in StatusBadge(text: badge.0, tone: badge.1) }
                Spacer(minLength: DS.s)
                Text(info.amount.map(money) ?? "金额未知").monospacedDigit()
                    .accessibilityIdentifier(id.map { "completion-amount:" + $0 } ?? "")
            }.font(.caption)
        }.padding(.vertical, 3)
    }
}

/// 我的 tab: everything that is not daily review.
struct MobileMe: View {
    @Bindable var finance: FinancialStore
    @Bindable var evidence: BrowserStore
    @Bindable var services: MobileServices
    var body: some View {
        List {
            Section("家庭同步") {
                NavigationLink { MobileData(finance: finance, evidence: evidence, services: services) } label: {
                    LabeledContent { Text(services.connectionLabel).lineLimit(1) } label: { Label("资料与同步", systemImage: "icloud") }
                }
                Button { Task { await services.refresh(finance: finance, evidence: evidence) } } label: { Label("立即同步", systemImage: "arrow.clockwise") }
                    .disabled(services.syncing)
                if !services.conflicts.isEmpty {
                    NavigationLink { MobileData(finance: finance, evidence: evidence, services: services) } label: {
                        Label("同步冲突（\(services.conflicts.count)）", systemImage: "exclamationmark.triangle").foregroundStyle(DS.pending)
                    }
                }
            }
            Section("家庭") {
                NavigationLink { HouseholdSettingsView(store: finance) } label: { Label("成员、账户与归属", systemImage: "person.2") }
            }
            Section("分类与标签") {
                NavigationLink { CategoryManagementPage(store: finance) } label: { Label("分类管理", systemImage: "folder") }.accessibilityIdentifier("category-management")
                NavigationLink { MobilePage(title: "标签", finance: finance) { FinanceTagsPage(store: finance) } } label: { Label("标签", systemImage: "tag") }
                NavigationLink { MobilePage(title: "支出调整", finance: finance) { FinanceFocusPage(store: finance) } } label: { Label("支出调整", systemImage: "slider.horizontal.3") }
            }
            Section("FIRE 规划") {
                NavigationLink { MobileFire(finance: finance) } label: { Label("目标与情景", systemImage: "flag.checkered") }
                NavigationLink { MobilePage(title: "买房与子女", finance: finance) { FinanceBranchesPage(store: finance) } } label: { Label("买房与子女", systemImage: "house") }
                NavigationLink { MobilePage(title: "模型参数", finance: finance) { FinanceParametersPage(store: finance) } } label: { Label("模型参数", systemImage: "gearshape") }
            }
            Section("资料") {
                NavigationLink { MobileEvidenceList(finance: finance, evidence: evidence) } label: { Label("交易证据与关联复核", systemImage: "doc.text.viewfinder") }
                NavigationLink { MobilePage(title: "数据与待处理", finance: finance) { FinanceDataPage(store: finance, evidence: evidence) } } label: { Label("数据与待处理", systemImage: "tray.full") }
            }
            Section {
                LabeledContent("资料截止", value: finance.report?.cutoff ?? "未建立范围")
                LabeledContent("交易生命周期", value: "\(finance.report?.records.count ?? 0) 个")
            } footer: { Text("统计单位是交易生命周期；账户只是查看视角。") }
        }
        .navigationTitle("我的")
    }
}

struct MobileFire: View {
    @Bindable var finance: FinancialStore
    var body: some View {
        MobilePage(title: "目标与情景", finance: finance) {
            if finance.report?.fire_parameters.needsBaseInput == true {
                ContentUnavailableView("参数尚未填写", systemImage: "slider.horizontal.below.square.filled.and.square", description: Text("在「我的 › 模型参数」填写后查看 FIRE 情景。"))
            } else { FinanceFirePage(store: finance) }
        }
    }
}

/// Transactions tab list with the 交易｜原始资料 scope.
struct MobileRawRecords: View {
    @Bindable var finance: FinancialStore
    @Bindable var evidence: BrowserStore
    @State private var platform: String?
    private var records: [BrowseRecord] { evidence.records.filter { (platform == nil || $0.platform == platform) && evidence.matches($0) } }
    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: "全部", selected: platform == nil) { platform = nil }
                    ForEach(Array(Set(evidence.records.map(\.platform))).sorted(), id: \.self) { name in
                        FilterChip(title: platformName(name), selected: platform == name) { platform = name }
                    }
                }
            }
        }
        ForEach(records) { record in
            NavigationLink {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.l) {
                        if let owner = finance.report?.records.first(where: { $0.evidence_keys.contains(record.id) }) {
                            NavigationLink { FinanceSelectedTransaction(store: finance, evidence: evidence, recordID: owner.id).navigationTitle("交易详情").navigationBarTitleDisplayMode(.inline) } label: {
                                Label("查看所属交易：" + owner.title, systemImage: "arrow.right.circle").lineLimit(2)
                            }
                        } else { NoticeText(text: "这条记录尚未归入任何交易。", tone: .pending) }
                        RecordPane(record: record, store: evidence)
                    }.padding(12)
                }.navigationTitle("原始证据").navigationBarTitleDisplayMode(.inline)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(platformName(record.platform)).foregroundStyle(DS.accent); Text(record.date).foregroundStyle(.secondary); Spacer(); Text(money(record.amount)).monospacedDigit() }.font(.caption)
                    Text(record.title).lineLimit(2)
                }
            }
        }
    }
}
