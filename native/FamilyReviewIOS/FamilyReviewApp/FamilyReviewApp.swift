import SwiftUI
import UIKit
import PaymentImageCore

@main struct FamilyReviewMobileApp: App {
    @State private var finance = FinancialStore()
    @State private var evidence = BrowserStore()
    var body: some Scene {
        WindowGroup {
            MobileRoot(finance: finance, evidence: evidence)
                .environment(\.locale, Locale(identifier: "zh_CN"))
        }
    }
}
struct MobileRoot: View {
    @Bindable var finance: FinancialStore
    @Bindable var evidence: BrowserStore
    @State private var services = MobileServices.shared
    @State private var tab = "overview"
    @State private var filters = false
    @State private var overviewPath = [String]()
    @State private var detailPath = [String]()
    @State private var ready = false
    @Environment(\.scenePhase) private var scene
    private var reviewTabs: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $overviewPath) { MobilePage(title: "家庭复盘", finance: finance) {
                NavigationLink { HouseholdSettingsView(store: finance) } label: { Label("家庭设置", systemImage: "person.2.badge.gearshape") }
                NavigationLink { CategoryManagementPage(store: finance) } label: { Label("分类修改", systemImage: "folder.badge.gearshape") }.accessibilityIdentifier("category-management")
                FinanceOverviewPage(store: finance)
                NavigationLink("标签与 Patterns") { MobilePage(title: "标签与 Patterns", finance: finance) { FinanceTagsPage(store: finance) }.toolbar { filterButton } }
                NavigationLink("关注与调整") { MobilePage(title: "关注与调整", finance: finance) { FinanceFocusPage(store: finance) }.toolbar { filterButton } }
            }.toolbar { filterButton }
                .navigationDestination(for: String.self) { destination in
                    if destination == "tags" { MobilePage(title: "标签与 Patterns", finance: finance) { FinanceTagsPage(store: finance) }.toolbar { filterButton } }
                }
            }
            .tabItem { Label("复盘", systemImage: "chart.bar.xaxis") }.tag("overview")
            NavigationStack { MobileCompletionList(finance: finance, evidence: evidence) }
                .tabItem { Label("补全", systemImage: "checklist") }.tag("completion")
            NavigationStack(path: $detailPath) { MobileTransactions(finance: finance, evidence: evidence).toolbar { filterButton }
                .navigationDestination(for: String.self) { id in
                    FinanceSelectedTransaction(store: finance, evidence: evidence, recordID: id).navigationTitle("交易详情").navigationBarTitleDisplayMode(.inline).onAppear { finance.selected = id }
                }
            }
                .tabItem { Label("明细", systemImage: "list.bullet.rectangle") }.tag("details")
            NavigationStack { MobilePage(title: "FIRE 规划", finance: finance) {
                NavigationLink { MobilePage(title: "模型参数", finance: finance) { FinanceParametersPage(store: finance) } } label: { Label("模型参数", systemImage: "gearshape") }
                NavigationLink { MobilePage(title: "买房与子女", finance: finance) { FinanceBranchesPage(store: finance) } } label: { Label("买房与子女", systemImage: "house") }
                FinanceFirePage(store: finance)
            } }.tabItem { Label("规划", systemImage: "flag.checkered") }.tag("fire")
            NavigationStack { MobileData(finance: finance, evidence: evidence, services: services) }
                .tabItem { Label("资料", systemImage: "tray.full") }.tag("data")
        }
        .tint(.teal)
        .sheet(isPresented: $filters) { MobileFilters(finance: finance) }
        .fileImporter(isPresented: $services.parameterPicker, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { services.importParameters(url, finance: finance) }
        }
        .fileExporter(isPresented: Binding(get: { services.exportDocument != nil }, set: { if !$0 { services.exportDocument = nil } }), document: ParameterExport(data: services.exportDocument ?? Data()), contentType: .json, defaultFilename: "家庭FIRE参数") { result in
            if case .failure(let error) = result { finance.error = error.localizedDescription }
            services.exportDocument = nil
        }
        .onChange(of: tab) { _, value in finance.section = value }
        .onChange(of: finance.section) { _, value in
            if ["overview", "completion", "details", "fire", "data"].contains(value) {
                tab = value
                if value == "details", let id = finance.selected, detailPath.last != id { detailPath.append(id) }
            }
            else if value == "tags" {
                tab = "overview"
                if overviewPath.last != "tags" { overviewPath.append("tags") }
            }
        }
        .onChange(of: finance.selected) { _, id in
            if finance.section == "details", let id, detailPath.last != id { detailPath.append(id) }
        }
    }
    var body: some View {
        Group {
            if !ready {
                ContentUnavailableView("正在读取本机资料", systemImage: "tray", description: Text("首次使用会进入资料连接页面。"))
            } else if finance.report == nil {
                MobileWelcome(finance: finance, evidence: evidence, services: services)
            } else { reviewTabs }
        }
        .tint(.teal)
        .task {
            MobileEvidenceRegistry.evidence = evidence
            await openLocalReview()
        }
        // A new connected client must keep waiting for its first verified
        // checkpoint even when it has no report yet. The client never publishes
        // a host ledger or creates an empty family workspace.
        .task(id: ready && services.hasRefreshTarget && scene == .active) {
            guard ready, services.hasRefreshTarget, scene == .active else { return }
            while !Task.isCancelled {
                await services.refresh(finance: finance, evidence: evidence)
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
            }
        }
    }
    private func openLocalReview() async {
        do {
            let source = try await services.bootstrap()
            if let root = source.localReview {
                services.bindFamilyClient(to: finance)
                await finance.load(root)
                if finance.report != nil { await evidence.load(root, finance: finance.report) }
            }
        } catch { finance.error = "本机资料读取未完成：" + error.localizedDescription }
        ready = true
    }
    private var filterButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { Button { filters = true } label: { Label("筛选", systemImage: "line.3.horizontal.decrease") } }
    }
}
struct MobileKeyboardToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("完成输入") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
    }
}
struct MobilePage<Content: View>: View {
    let title: String
    @Bindable var finance: FinancialStore
    var requiresReport = true
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = finance.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if finance.report != nil || !requiresReport { content }
                else if finance.loading { ContentUnavailableView("正在读取复盘", systemImage: "chart.bar") }
                else { ContentUnavailableView("尚未载入复盘", systemImage: "tray", description: Text("在资料页打开已有复盘副本。")) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.scrollDismissesKeyboard(.interactively).background(Color(uiColor: .systemGroupedBackground)).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { MobileKeyboardToolbar() }
        .refreshable { await MobileServices.shared.refresh(finance: finance, evidence: MobileEvidenceRegistry.evidence ?? BrowserStore()) }
    }
}
// The root installs the shared evidence store; all refresh actions use the same instance.
@MainActor enum MobileEvidenceRegistry { static var evidence: BrowserStore? }
struct MobileFilters: View {
    @Bindable var finance: FinancialStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("统计区间") {
                    Picker("快捷区间", selection: Binding(get: { "选择区间" }, set: { finance.selectRange($0) })) {
                        Text("选择区间").tag("选择区间")
                        ForEach(["今年", "近30天", "近90天", "全部"], id: \.self) { Text($0).tag($0) }
                    }
                    DatePicker("开始日期", selection: Binding(get: { parseDay(finance.from) }, set: { finance.from = min(day($0), finance.to) }), displayedComponents: .date)
                    DatePicker("截止日期", selection: Binding(get: { parseDay(finance.to) }, set: { finance.to = max(finance.from, min(day($0), finance.report?.cutoff ?? day($0))) }), in: ...parseDay(finance.report?.cutoff ?? day(Date())), displayedComponents: .date)
                }
                Section("交易视角") {
                    Picker("账户", selection: $finance.account) { Text("全部账户").tag("全部账户"); ForEach(finance.accounts, id: \.self) { Text($0).tag($0) } }
                    Picker("一级分类", selection: $finance.primary) { Text("全部分类").tag("全部分类"); ForEach(finance.report?.taxonomy ?? []) { Text($0.primary).tag($0.primary) } }
                }
                Section("标签") {
                    Picker("匹配方式", selection: $finance.tagMatch) { Text("全部所选标签").tag("all"); Text("任一所选标签").tag("any") }
                    ForEach(finance.tags, id: \.self) { tag in
                        Toggle(tag, isOn: Binding(get: { finance.selectedTags.contains(tag) }, set: { selected in if selected { finance.selectedTags.append(tag) } else { finance.selectedTags.removeAll { $0 == tag } } }))
                    }
                    Button("清空标签") { finance.selectedTags = [] }
                }
                Button("恢复全部筛选") { finance.selectRange("今年"); finance.account = "全部账户"; finance.primary = "全部分类"; finance.selectedTags = []; finance.query = "" }
            }.navigationTitle("筛选").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
struct MobileTransactions: View {
    @Bindable var finance: FinancialStore
    @Bindable var evidence: BrowserStore
    var body: some View {
        List {
            Section {
                Text(finance.from + " 至 " + finance.to).font(.caption).foregroundStyle(.secondary)
                Picker("显示", selection: $finance.recordView) { ForEach(["全部消费", "待处理", "账户待关联", "资金流"], id: \.self) { Text($0).tag($0) } }
            }
            ForEach(finance.visibleRecords) { record in
                NavigationLink(value: record.id) { FinanceTransactionRow(record: record) }
            }
        }.navigationTitle("支出明细").searchable(text: $finance.query, prompt: "日期、商户、金额或用户")
        .overlay { if finance.visibleRecords.isEmpty { ContentUnavailableView.search(text: finance.query) } }
        .onAppear { MobileEvidenceRegistry.evidence = evidence }
    }
}
struct MobileCompletionList: View {
    @Bindable var finance: FinancialStore
    @Bindable var evidence: BrowserStore
    var workspace: CompletionWorkspace { finance.completion }
    var body: some View {
        List {
            Section {
                NavigationLink { SourceRecordSetList(store: finance, evidence: evidence) } label: {
                    Label("来源归并（\(finance.sourceRecordGroups.count)）", systemImage: "rectangle.3.group")
                }.accessibilityIdentifier("source-set-list")
            }
            Section {
                Picker("处理队列", selection: Binding(get: { workspace.mode }, set: { workspace.mode = $0 })) { ForEach(["优先补全", "待分类", "待核事实", "退款候选", "暂放", "本次已保存", "已确认", "已排除"], id: \.self) { Text($0).tag($0) } }
                Toggle("包含范围外及日期未知资料", isOn: Binding(get: { workspace.allDates }, set: { workspace.allDates = $0; workspace.refresh(finance, evidence) }))
                Text("只扩大补全队列，统计范围不变；同名联动始终覆盖全资料库。跳过暂放、本次已保存及已确认项目；按金额从大到小，金额未知排最后。").font(.caption).foregroundStyle(.secondary)
                Text(workspace.from + " 至 " + workspace.to + " · \(workspace.visible.count) 项").font(.caption).foregroundStyle(.secondary)
                Text("本次保存 \(workspace.saved.count) 项 · 暂放 \(workspace.deferred.count) 项").font(.caption).foregroundStyle(.secondary)
                Text("同名商家自动确认，可在「已确认」复查").font(.caption).foregroundStyle(.teal)
                if !workspace.message.isEmpty { Text(workspace.message).font(.caption).foregroundStyle(.teal) }
                if let error = finance.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            ForEach(workspace.visible) { entry in
                NavigationLink { MobileCompletionDetail(finance: finance, evidence: evidence, workspace: workspace, initial: entry.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.component?.title ?? entry.record.title).lineLimit(2)
                        HStack { Text(entry.record.date.isEmpty ? "日期未知" : entry.record.date); Spacer(); Text(entry.amountUnknown ? "金额未知" : money(entry.impact)).monospacedDigit().accessibilityIdentifier("completion-amount:" + entry.id) }.font(.caption)
                        Text(entry.issueSummaries.joined(separator: " · ")).font(.caption).foregroundStyle(.orange)
                        if workspace.isDirty(entry) { Text("未保存草稿").font(.caption).foregroundStyle(.blue) }
                    }.padding(.vertical, 5)
                }
            }
        }.navigationTitle("补全").searchable(text: Binding(get: { workspace.query }, set: { workspace.query = $0 }), prompt: "项目、日期或金额")
        .onAppear { if workspace.from.isEmpty { workspace.from = finance.from; workspace.to = finance.to }; workspace.refresh(finance, evidence) }
        .task(id: finance.revision) { await finance.reconcileCompletion(); workspace.refresh(finance, evidence) }
        .onChange(of: finance.revision) { _, _ in workspace.refresh(finance, evidence) }
        .onChange(of: evidence.previewGeneration) { _, _ in workspace.refresh(finance, evidence) }
    }
}
struct MobileCompletionDetail: View {
    @Bindable var finance: FinancialStore
    @Bindable var evidence: BrowserStore
    @Bindable var workspace: CompletionWorkspace
    let initial: String
    var busy: Bool { finance.loading || finance.completionSaving || finance.importing || workspace.persisting || evidence.loading }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = finance.error { Text(error).foregroundStyle(.red) }
                    if !workspace.message.isEmpty { Text(workspace.message).font(.callout).foregroundStyle(.teal) }
                    if let entry = workspace.current {
                        CompletionEditor(entry: entry, store: finance, evidence: evidence, workspace: workspace, busy: busy).id(entry.id)
                        CompletionEvidence(entry: entry, store: finance, evidence: evidence, workspace: workspace, busy: busy, dirty: workspace.isDirty(entry)).id(entry.id)
                    } else { ContentUnavailableView("此队列已完成", systemImage: "checkmark.circle") }
                }.padding(16)
            }.scrollDismissesKeyboard(.interactively).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            VStack(spacing: 8) {
                if let entry = workspace.current {
                    HStack {
                        Button(workspace.deferred.contains(entry.id) ? "放回队列" : "暂放") {
                            let ids = workspace.visible.map(\.id)
                            Task { await workspace.setDeferred(entry.id, value: !workspace.deferred.contains(entry.id)); workspace.next(after: entry.id, previous: ids) }
                        }.buttonStyle(.bordered)
                        Button(entry.component == nil ? "下一笔" : "保存并下一笔") {
                            let ids = workspace.visible.map(\.id)
                            if entry.component == nil { workspace.next(after: entry.id, previous: ids) }
                            else { Task { if await finance.saveCompletion(entry) { workspace.refresh(finance, evidence); workspace.next(after: entry.id, previous: ids) } } }
                        }.buttonStyle(.borderedProminent)
                    }
                }
                if workspace.undo != nil { Button("撤销上一笔") { Task { await finance.undoCompletion(); workspace.refresh(finance, evidence) } }.font(.callout) }
            }.padding(12).frame(maxWidth: .infinity).background(.regularMaterial).disabled(busy)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground)).navigationTitle("项目补全").navigationBarTitleDisplayMode(.inline)
        .toolbar { MobileKeyboardToolbar() }
        .onAppear { workspace.selected = initial; workspace.refresh(finance, evidence) }
        .onChange(of: finance.revision) { _, _ in workspace.refresh(finance, evidence) }
        .onChange(of: evidence.previewGeneration) { _, _ in workspace.refresh(finance, evidence) }
    }
}
