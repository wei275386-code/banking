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
    @State private var inbox = InboxModel()
    @State private var overviewPath = [String]()
    @State private var detailPath = [String]()
    @State private var mePath = [String]()
    @State private var rawScope = false
    @State private var ready = false
    @Environment(\.scenePhase) private var scene
    private var reviewTabs: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $overviewPath) {
                MobilePage(title: "概览", finance: finance) {
                    FinanceOverviewPage(store: finance, inbox: inbox) { kind in inbox.kind = kind; tab = "completion" }
                    MobileFireSummary(finance: finance)
                }
                .navigationBarTitleDisplayMode(.large)
                .toolbar { periodMenu; filterButton }
                .navigationDestination(for: String.self) { destination in
                    switch destination {
                    case "tags": MobilePage(title: "标签", finance: finance) { FinanceTagsPage(store: finance) }.toolbar { filterButton }
                    case "focus": MobilePage(title: "支出调整", finance: finance) { FinanceFocusPage(store: finance) }.toolbar { filterButton }
                    default: MobileFire(finance: finance)
                    }
                }
            }
            .tabItem { Label("概览", systemImage: "square.grid.2x2") }.tag("overview")
            NavigationStack { MobileInboxList(finance: finance, evidence: evidence, inbox: inbox) }
                .tabItem { Label("待办", systemImage: "checklist") }
                .badge(inbox.count(.all))
                .tag("completion")
            NavigationStack(path: $detailPath) {
                MobileTransactions(finance: finance, evidence: evidence, raw: $rawScope).toolbar { if !rawScope { filterButton } }
                    .navigationDestination(for: String.self) { id in
                        FinanceSelectedTransaction(store: finance, evidence: evidence, recordID: id).navigationTitle("交易详情").navigationBarTitleDisplayMode(.inline).onAppear { finance.selected = id }
                    }
            }
            .tabItem { Label("交易", systemImage: "list.bullet.rectangle") }.tag("details")
            NavigationStack(path: $mePath) {
                MobileMe(finance: finance, evidence: evidence, services: services)
                    .navigationDestination(for: String.self) { destination in
                        if destination == "fire" { MobileFire(finance: finance) }
                        else { MobileData(finance: finance, evidence: evidence, services: services) }
                    }
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }.tag("me")
        }
        .tint(DS.accent)
        .toastOverlay(bottomPadding: 64)
        .sheet(isPresented: $filters) { MobileFilters(finance: finance) }
        .fileImporter(isPresented: $services.parameterPicker, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { services.importParameters(url, finance: finance) }
        }
        .fileExporter(isPresented: Binding(get: { services.exportDocument != nil }, set: { if !$0 { services.exportDocument = nil } }), document: ParameterExport(data: services.exportDocument ?? Data()), contentType: .json, defaultFilename: "家庭FIRE参数") { result in
            if case .failure(let error) = result { finance.error = error.localizedDescription }
            services.exportDocument = nil
        }
        .onAppear { inbox.bind(finance, evidence); prepareInbox() }
        .task(id: finance.revision) { await finance.reconcileCompletion(); prepareInbox() }
        .onChange(of: evidence.previewGeneration) { _, _ in prepareInbox() }
        .onChange(of: tab) { _, value in if value != "me" { finance.section = value } }
        .onChange(of: finance.section) { _, value in route(value) }
        .onChange(of: finance.selected) { _, id in
            if finance.section == "details", let id, detailPath.last != id { detailPath.append(id) }
        }
    }
    /// Keeps `FinancialStore.section` semantics shared with the Mac: pages set a
    /// section and the phone maps it onto a tab and navigation path.
    private func route(_ value: String) {
        switch value {
        case "overview", "completion": tab = value
        case "details":
            tab = value; rawScope = false
            if let id = finance.selected, detailPath.last != id { detailPath.append(id) }
        case "tags", "focus":
            tab = "overview"; if overviewPath.last != value { overviewPath.append(value) }
        case "fire", "branches", "params":
            tab = "overview"; if overviewPath.last != "fire" { overviewPath.append("fire") }
        case "data":
            tab = "me"; if mePath.last != "data" { mePath.append("data") }
        default: break
        }
    }
    private func prepareInbox() {
        let workspace = finance.completion
        if workspace.from.isEmpty { workspace.from = finance.from; workspace.to = finance.to }
        workspace.refresh(finance, evidence)
    }
    var body: some View {
        Group {
            if !ready {
                ContentUnavailableView("正在读取本机资料", systemImage: "tray", description: Text("首次使用会进入资料连接页面。"))
            } else if finance.report == nil {
                MobileWelcome(finance: finance, evidence: evidence, services: services)
            } else { reviewTabs }
        }
        .tint(DS.accent)
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
    private var periodMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                ForEach(["本月", "上月", "今年", "近90天", "全部"], id: \.self) { name in Button(name) { finance.selectRange(name) } }
                Divider()
                Button("自定义…") { filters = true }
            } label: { Text(periodTitle(from: finance.from, to: finance.to)).font(.callout) }
                .disabled(finance.report?.cutoff == nil)
        }
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
                        ForEach(["本月", "上月", "今年", "近90天", "全部"], id: \.self) { Text($0).tag($0) }
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
    @Binding var raw: Bool
    var body: some View {
        List {
            Section {
                Picker("范围", selection: $raw) { Text("交易").tag(false); Text("原始资料").tag(true) }.pickerStyle(.segmented)
                if !raw {
                    Picker("显示", selection: $finance.recordView) { ForEach(["全部消费", "待处理", "账户待关联", "资金流"], id: \.self) { Text($0).tag($0) } }
                    MobileActiveFilters(finance: finance)
                    Text(periodTitle(from: finance.from, to: finance.to) + " · \(finance.visibleRecords.count) 笔").font(.caption).foregroundStyle(.secondary)
                }
            }
            if raw { MobileRawRecords(finance: finance, evidence: evidence) }
            else {
                ForEach(finance.visibleRecords) { record in
                    NavigationLink(value: record.id) { FinanceTransactionRow(record: record) }
                }
            }
        }.navigationTitle("交易")
        .searchable(text: raw ? $evidence.query : $finance.query, prompt: raw ? "日期、商户或金额" : "日期、商户、金额或用户")
        .overlay { if !raw && finance.visibleRecords.isEmpty { ContentUnavailableView.search(text: finance.query) } }
        .onAppear { MobileEvidenceRegistry.evidence = evidence }
    }
}
/// Active account, category and tag filters as removable chips.
struct MobileActiveFilters: View {
    @Bindable var finance: FinancialStore
    var body: some View {
        if finance.account != "全部账户" || finance.primary != "全部分类" || !finance.selectedTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if finance.account != "全部账户" { chip(finance.account) { finance.account = "全部账户" } }
                    if finance.primary != "全部分类" { chip(finance.primary) { finance.primary = "全部分类" } }
                    ForEach(finance.selectedTags, id: \.self) { tag in chip("#" + tag) { finance.selectedTags.removeAll { $0 == tag } } }
                }
            }
        }
    }
    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) { HStack(spacing: DS.xs) { Text(title); Image(systemName: "xmark").font(.caption2.weight(.bold)) } }
            .buttonStyle(.bordered).controlSize(.small).tint(DS.accent).accessibilityLabel("移除筛选 \(title)")
    }
}
/// Read-only FIRE summary on the overview; editing lives under 我的.
struct MobileFireSummary: View {
    let finance: FinancialStore
    var body: some View {
        if finance.report?.fire_parameters.needsBaseInput == false {
            NavigationLink(value: "fire") {
                HStack {
                    Label("FIRE 目标与情景", systemImage: "flag.checkered").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }.cardStyle()
            }.buttonStyle(.plain)
        }
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
                    if !workspace.message.isEmpty { Text(workspace.message).font(.callout).foregroundStyle(DS.accent) }
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
                            else { Task { if await finance.saveCompletion(entry) {
                                workspace.refresh(finance, evidence); workspace.next(after: entry.id, previous: ids)
                                ToastCenter.shared.show("已保存", undoTitle: "撤销") { Task { await finance.undoCompletion(); workspace.refresh(finance, evidence) } }
                            } } }
                        }.buttonStyle(.borderedProminent)
                    }
                }
                if workspace.undo != nil { Button("撤销上一笔") { Task { await finance.undoCompletion(); workspace.refresh(finance, evidence) } }.font(.callout) }
            }.padding(12).frame(maxWidth: .infinity).background(.regularMaterial).disabled(busy)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground)).navigationTitle("补全").navigationBarTitleDisplayMode(.inline)
        .toolbar { MobileKeyboardToolbar() }
        .onAppear { workspace.selected = initial; workspace.refresh(finance, evidence) }
        .onChange(of: finance.revision) { _, _ in workspace.refresh(finance, evidence) }
        .onChange(of: evidence.previewGeneration) { _, _ in workspace.refresh(finance, evidence) }
    }
}
