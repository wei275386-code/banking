#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PaymentImageCore

/// Main window: one sidebar for every page, a toolbar for global actions and a
/// status center for system work (sync, processor, pending recordings, conflicts).
struct MacRootView: View {
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    @Bindable var inbox: InboxModel
    @State private var dropTargeted = false

    private var sidebarSelection: Binding<String?> {
        Binding(get: { store.section }, set: { if let value = $0 { store.section = value } })
    }
    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Section {
                    Label("概览", systemImage: "square.grid.2x2").tag("overview")
                    Label("待办", systemImage: "checklist").badge(store.report == nil ? 0 : inbox.count(.all)).tag("completion")
                    Label("交易", systemImage: "list.bullet.rectangle").tag("details")
                }
                Section("分析") {
                    Label("标签", systemImage: "tag").tag("tags")
                    Label("支出调整", systemImage: "slider.horizontal.3").tag("focus")
                }
                Section("规划") {
                    Label("目标与情景", systemImage: "flag.checkered").tag("fire")
                    Label("买房与子女", systemImage: "house").tag("branches")
                    Label("模型参数", systemImage: "gearshape").tag("params")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { MacSidebarFooter(store: store) }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(Self.titles[store.section] ?? "概览")
                .toolbar { MacToolbar(store: store, evidence: evidence) }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .toastOverlay()
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in importDropped(providers); return true }
        .overlay { if dropTargeted { MacDropOverlay(store: store) } }
        .onAppear { inbox.bind(store, evidence); prepareInbox() }
        .task(id: store.revision) { await store.reconcileCompletion(); prepareInbox(); await store.refreshSyncConflictFlag() }
        .onChange(of: store.from) { _, _ in followPeriod() }
        .onChange(of: store.to) { _, _ in followPeriod() }
        .onChange(of: evidence.previewGeneration) { _, _ in prepareInbox() }
        .onChange(of: store.completion.allDates) { _, _ in prepareInbox() }
        .onChange(of: store.section) { _, _ in ReviewLatency.finish("navigate") }
        .onChange(of: store.report?.dataset_id) { _, _ in ReviewLatency.finish("startup-overview") }
        .fileImporter(isPresented: $store.showingPicker,
                      allowedContentTypes: store.pickerMode == "folder" ? [.folder] : [.pdf, .commaSeparatedText, .spreadsheet, .movie, .image, .data],
                      allowsMultipleSelection: store.pickerMode != "folder") { result in
            guard case .success(let urls) = result, !busy else { return }
            if store.pickerMode == "folder", let url = urls.first { _ = url.startAccessingSecurityScopedResource(); Task { await store.load(url); await evidence.load(url, finance: store.report) } }
            else { importMaterials(urls) }
        }
        .task(id: store.root) { await watchCurrentRoot() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FinancialDataChanged"))) { _ in Task { _ = await store.refreshLocalFilesIfNeeded(evidence) } }
    }

    static let shortcuts = [("overview", "概览"), ("completion", "待办"), ("details", "交易")]
    static let titles = ["overview": "概览", "completion": "待办", "details": "交易", "tags": "标签", "focus": "支出调整",
                         "fire": "目标与情景", "branches": "买房与子女", "params": "模型参数", "categories": "分类"]

    /// The queue backs the sidebar badge and overview card, so keep it current
    /// even while 待办 is not on screen.
    private func prepareInbox() {
        let workspace = store.completion
        if workspace.from.isEmpty { workspace.from = store.from; workspace.to = store.to }
        workspace.refresh(store, evidence)
    }
    /// 待办 follows the toolbar period; drafts live in the workspace and survive the refresh.
    private func followPeriod() {
        let workspace = store.completion
        guard workspace.from != store.from || workspace.to != store.to else { return }
        workspace.from = store.from; workspace.to = store.to
        workspace.refresh(store, evidence)
    }
    private var busy: Bool { store.completionSaving || store.importing || store.loading || evidence.loading || store.completion.persisting }

    @ViewBuilder private var detail: some View {
        if store.report == nil {
            VStack(spacing: DS.m) {
                if let error = store.error { NoticeText(text: error, tone: .failure).padding() }
                ContentUnavailableView("正在读取家庭复盘", systemImage: "chart.bar", description: Text("正在读取已导入的资料。"))
            }
        } else {
            switch store.section {
            case "completion": MacPageError(store: store) { MacInboxPage(store: store, evidence: evidence, inbox: inbox) }
            case "details": MacPageError(store: store) { MacTransactionsPage(store: store, evidence: evidence) }
            case "categories": NavigationStack { CategoryManagementPage(store: store) }
            default: MacScrollPage(store: store) { scrollContent }
            }
        }
    }
    @ViewBuilder private var scrollContent: some View {
        switch store.section {
        case "tags": ActiveFilterBar(store: store); FinanceTagsPage(store: store)
        case "focus": FinanceFocusPage(store: store)
        case "fire":
            if store.report?.fire_parameters.needsBaseInput == true { MissingParametersNotice(store: store, text: "先填写必需的模型参数，再查看 FIRE 情景。") }
            else { FinanceFirePage(store: store) }
        case "params": FinanceParametersPage(store: store).disabled(!store.editingAvailable)
        case "branches":
            if store.report?.fire_parameters.needsBaseInput == true { MissingParametersNotice(store: store, text: "先填写基础模型参数，再启用买房与子女情景。") }
            else { FinanceBranchesPage(store: store).disabled(!store.editingAvailable) }
        default:
            MacStatusBanner(store: store)
            ActiveFilterBar(store: store)
            FinanceOverviewPage(store: store, inbox: inbox) { kind in inbox.openPending(kind); store.section = "completion" }
        }
    }

    private func importDropped(_ providers: [NSItemProvider]) {
        guard store.materialImportAvailable, !busy else {
            ToastCenter.shared.show(store.materialImportAvailable ? "正在处理其他操作，请稍后再拖入。" : "当前资料暂不能导入素材。"); return
        }
        Task {
            var urls = [URL]()
            for provider in providers {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let file = URL(dataRepresentation: url, relativeTo: nil) { urls.append(file) }
            }
            guard !urls.isEmpty else { return }
            importMaterials(urls)
        }
    }
    private func importMaterials(_ urls: [URL]) {
        ToastCenter.shared.show("已加入处理队列：\(urls.count) 个文件")
        Task { await store.importMaterials(urls); if let root = store.root { await evidence.load(root, finance: store.report) } }
    }

    /// Unchanged from the previous root view: keep displayed files and the
    /// managed workspace in step with external writes.
    private func watchCurrentRoot() async {
        guard let root = store.root else { return }
        if store.clientWorkspacePaths != nil {
            store.familyClientSyncController?.evidence = evidence
            if evidence.root != root { await evidence.load(root, finance: store.report) }
            return
        }
        store.familyClientSyncController?.evidence = evidence
        if let paths = store.workspacePaths {
            if evidence.root != root { await evidence.load(root, finance: store.report) }
            while !Task.isCancelled {
                await store.reloadWorkspaceIfChanged(paths, evidence: evidence)
                try? await Task.sleep(for: .seconds(5))
            }
            return
        }
        var previous = ""
        while !Task.isCancelled {
            let stamp = ReviewFileVersion.names.map { name in
                let value = try? root.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey])
                return String(value?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }.joined(separator: "|")
            if stamp != previous, await store.refreshLocalFilesIfNeeded(evidence) { previous = stamp }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

/// Store-level failures (save, undo, file writes) stay visible on split pages too.
struct MacPageError<Content: View>: View {
    let store: FinancialStore
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                HStack {
                    NoticeText(text: error, tone: .failure)
                    Spacer()
                    Button("关闭") { store.error = nil }.buttonStyle(.borderless)
                }.padding(.horizontal, DS.l).padding(.vertical, DS.s).background(DS.failure.opacity(0.08))
                Divider()
            }
            content
        }
    }
}

struct MacScrollPage<Content: View>: View {
    let store: FinancialStore
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.l + 4) {
                if let error = store.error { NoticeText(text: error, tone: .failure) }
                content
            }.padding(DS.xl + 4).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }.id(store.section).background(DS.pageBackground)
    }
}

struct MissingParametersNotice: View {
    let store: FinancialStore; let text: String
    var body: some View {
        ContentUnavailableView {
            Label("参数尚未填写", systemImage: "slider.horizontal.below.square.filled.and.square")
        } description: { Text(text) } actions: {
            Button("填写模型参数") { store.section = "params" }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, minHeight: 360)
    }
}

private struct MacSidebarFooter: View {
    let store: FinancialStore
    private var role: String {
        if store.familyClientPaths != nil || store.clientWorkspacePaths != nil { return "家庭副本 · 由家庭 Mac 处理素材" }
        if store.workspacePaths != nil { return "本机家庭资料" }
        return "复盘文件夹"
    }
    var body: some View {
        HStack(spacing: DS.s) {
            Image(systemName: "house.fill").foregroundStyle(DS.accent)
            Text(role).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("设置（⌘,）")
        }.padding(.horizontal, DS.l).padding(.vertical, DS.m)
    }
}

// MARK: Toolbar

struct MacToolbar: ToolbarContent {
    @Bindable var store: FinancialStore
    let evidence: BrowserStore
    private var busy: Bool { store.importing || store.completionSaving || store.loading || store.completion.persisting }
    private var showsPeriod: Bool { store.report?.cutoff != nil && ["overview", "details", "tags", "focus"].contains(store.section) }
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if showsPeriod { PeriodMenu(store: store) }
            Button { store.pickerMode = "materials"; store.showingPicker = true } label: {
                Label(store.clientWorkspacePaths == nil ? "导入" : "发送素材", systemImage: "square.and.arrow.down")
            }
            .help(store.clientWorkspacePaths == nil ? "导入账单与素材；也可以直接拖入窗口" : "发送素材到家庭 Mac 处理")
            .disabled(!store.materialImportAvailable || busy)
            StatusCenterButton(store: store, evidence: evidence)
            Button {
                Task { if store.root != nil { await store.reloadCurrent(); if let current = store.root { await evidence.load(current, finance: store.report) } } }
            } label: { Label("刷新", systemImage: "arrow.clockwise") }
            .help("重新读取资料")
            .disabled(busy || evidence.loading)
        }
    }
}

struct PeriodMenu: View {
    @Bindable var store: FinancialStore
    @State private var custom = false
    var body: some View {
        Menu {
            Section("以资料截止日 \(store.report?.cutoff ?? "") 为基准") {
                ForEach(["本月", "上月", "今年", "近90天", "全部"], id: \.self) { name in Button(name) { store.selectRange(name) } }
            }
            Divider()
            Button("自定义…") { custom = true }
        } label: {
            Label(periodLabel, systemImage: "calendar").labelStyle(.titleAndIcon)
        }
        .help(store.report?.coverage?.label ?? "统计区间")
        .popover(isPresented: $custom) {
            Form {
                DatePicker("开始", selection: Binding(get: { parseDay(store.from) }, set: { store.from = min(day($0), store.to) }), displayedComponents: .date)
                DatePicker("截止", selection: Binding(get: { parseDay(store.to) }, set: { store.to = max(store.from, min(day($0), store.report?.cutoff ?? day($0))) }), displayedComponents: .date)
                Text("截止日不晚于资料截止日 " + (store.report?.cutoff ?? "")).font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).frame(width: 300)
        }
        .onChange(of: store.from) { _, _ in ReviewLatency.finish("date.from") }
        .onChange(of: store.to) { _, _ in ReviewLatency.finish("date.to") }
    }
    private var periodLabel: String { periodTitle(from: store.from, to: store.to) }
}

// MARK: Status center

struct StatusCenterButton: View {
    @Bindable var store: FinancialStore
    let evidence: BrowserStore
    @State private var shown = false
    private var attention: Bool {
        store.workspaceRuntimeFailure != nil || store.pendingVideoCount > 0
            || store.workspaceRequestStatuses.values.contains("needsReview") || store.syncConflictsPending
    }
    private var symbol: String {
        if store.importing { return "arrow.triangle.2.circlepath" }
        if store.workspaceRuntimeFailure != nil { return "exclamationmark.triangle" }
        return store.familyClientPaths != nil || store.clientWorkspacePaths != nil || !store.syncStatus.isEmpty ? "icloud" : "checkmark.circle"
    }
    var body: some View {
        Button { shown.toggle() } label: {
            Label("状态", systemImage: symbol)
                .overlay(alignment: .topTrailing) {
                    if attention { Circle().fill(DS.failure).frame(width: 7, height: 7).offset(x: 3, y: -2) }
                }
        }
        .help("同步、处理与资料状态")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            ScrollView { StatusCenterContent(store: store, evidence: evidence).padding(DS.l) }
                .frame(width: 400).frame(maxHeight: 560)
        }
    }
}

struct StatusCenterContent: View {
    @Bindable var store: FinancialStore
    let evidence: BrowserStore
    var body: some View {
        VStack(alignment: .leading, spacing: DS.l) {
            Text("状态").font(.title3.weight(.semibold))
            group("处理", symbol: store.importing ? "arrow.triangle.2.circlepath" : "gearshape.2") {
                if store.importing { ProgressView().controlSize(.small) }
                Text(processingText).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if store.processorTask != nil {
                    Button("取消处理") { store.processorTask?.cancel(); store.importState = "正在停止处理，并核对已保存状态…" }
                }
                if let failure = store.workspaceRuntimeFailure { NoticeText(text: failure, tone: .failure) }
                if !store.workspaceRuntimeNotice.isEmpty { Text(store.workspaceRuntimeNotice).font(.caption).foregroundStyle(.secondary) }
                if store.workspaceRuntimeFailure != nil {
                    Button("重新检查处理器") { Task { await store.retryWorkspaceRuntimeQualification() } }
                        .disabled(store.importing || store.loading || store.completionSaving || store.completion.persisting || store.editorPauseReason != nil)
                }
                if let reason = store.editorPauseReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            }
            if store.workspacePaths != nil || store.clientWorkspacePaths != nil {
                group("家庭同步", symbol: "icloud") {
                    Text(store.syncStatus.isEmpty ? "尚无同步消息。" : store.syncStatus).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    WorkspaceSyncActions(store: store, evidence: evidence)
                }
            }
            if store.workspaceState != nil {
                group("待解析录屏（\(store.pendingVideoCount)）", symbol: "film") {
                    if store.pendingVideos.isEmpty { Text("没有等待解析的录屏。").font(.callout).foregroundStyle(.secondary) }
                    ForEach(store.pendingVideos) { input in
                        VStack(alignment: .leading, spacing: DS.xs) {
                            Text(input.displayName).font(.callout.weight(.medium)).textSelection(.enabled)
                            Text(input.reasonMessage + "；原件已保留。").font(.caption).foregroundStyle(.secondary)
                            Button("重试解析") { Task { await store.retryPendingVideo(input) } }
                                .disabled(!store.processorAvailable || store.importing || store.loading || store.completionSaving || store.discoveryBusy || store.completion.persisting)
                        }
                    }
                    if store.pendingVideoCount > store.pendingVideos.count { Text("仅显示前 \(store.pendingVideos.count) 项。").font(.caption).foregroundStyle(.secondary) }
                }
            }
            WorkspaceRequestStatusView(store: store)
            MacSyncConflicts(store: store, evidence: evidence)
            if !store.workspaceNotice.isEmpty { NoticeText(text: store.workspaceNotice) }
        }
    }
    private var processingText: String {
        if !store.importState.isEmpty { return store.importState }
        return store.processorAvailable ? "处理器就绪。" : "处理器暂不可用。"
    }
    private func group<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.s) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }.cardStyle(padding: DS.m)
    }
}

/// Serious system problems surface on the overview, not only behind the toolbar icon.
struct MacStatusBanner: View {
    let store: FinancialStore
    var body: some View {
        if store.syncConflictsPending {
            banner("家庭同步收到并发修改，需要选择保留的版本。可在工具栏「状态」或「设置 › 同步」中处理。")
        } else if let failure = store.workspaceRuntimeFailure {
            banner("处理器需要检查：" + failure)
        } else if store.pendingVideoCount > 0 {
            banner("有 \(store.pendingVideoCount) 个录屏等待解析，可在工具栏「状态」中重试。")
        }
    }
    private func banner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout)
            .foregroundStyle(DS.pending).frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.m).background(DS.pending.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.corner))
    }
}

private struct MacDropOverlay: View {
    let store: FinancialStore
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: DS.m) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 44)).foregroundStyle(DS.accent)
                Text(store.clientWorkspacePaths == nil ? "松开以导入账单与素材" : "松开以发送素材到家庭 Mac").font(.title2.weight(.semibold))
                Text("支持 PDF、CSV、XLSX、图片和录屏").foregroundStyle(.secondary)
            }
            RoundedRectangle(cornerRadius: 16).strokeBorder(DS.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])).padding(DS.l)
        }.allowsHitTesting(false)
    }
}

// MARK: Filters

/// Account, category and tag filters affect every statistic; show them wherever
/// numbers depend on them so nothing is filtered silently.
struct ActiveFilterBar: View {
    @Bindable var store: FinancialStore
    private var active: Bool { store.account != "全部账户" || store.primary != "全部分类" || !store.selectedTags.isEmpty }
    var body: some View {
        if active {
            HStack(spacing: DS.s) {
                Text("筛选").font(.callout).foregroundStyle(.secondary)
                if store.account != "全部账户" { chip(store.account) { store.account = "全部账户" } }
                if store.primary != "全部分类" { chip(store.primary) { store.primary = "全部分类" } }
                ForEach(store.selectedTags, id: \.self) { tag in chip("#" + tag) { store.selectedTags.removeAll { $0 == tag } } }
                if store.selectedTags.count > 1 { Text(store.tagMatch == "all" ? "同时满足" : "满足任一").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Button("清除全部") { store.account = "全部账户"; store.primary = "全部分类"; store.selectedTags = [] }.buttonStyle(.borderless)
            }
        }
    }
    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) { HStack(spacing: DS.xs) { Text(title); Image(systemName: "xmark").font(.caption2.weight(.bold)) } }
            .buttonStyle(.bordered).controlSize(.small).tint(DS.accent).accessibilityLabel("移除筛选 \(title)")
    }
}

/// Filter menu used by the transaction list; mirrors the iOS filter sheet.
struct TransactionFilterMenu: View {
    @Bindable var store: FinancialStore
    var body: some View {
        Menu {
            Picker("账户", selection: $store.account) { Text("全部账户").tag("全部账户"); ForEach(store.accounts, id: \.self) { Text($0).tag($0) } }
            Picker("一级分类", selection: $store.primary) { Text("全部分类").tag("全部分类"); ForEach(store.report?.taxonomy ?? []) { Text($0.primary).tag($0.primary) } }
            Menu("标签") {
                ForEach(store.tags, id: \.self) { tag in
                    Toggle(tag, isOn: Binding(get: { store.selectedTags.contains(tag) }, set: { on in if on { store.selectedTags.append(tag) } else { store.selectedTags.removeAll { $0 == tag } } }))
                }
                Divider()
                Picker("多个标签", selection: $store.tagMatch) { Text("同时满足").tag("all"); Text("满足任一").tag("any") }
            }
        } label: { Label("筛选", systemImage: "line.3.horizontal.decrease.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .onChange(of: store.account) { _, _ in ReviewLatency.finish("account") }
            .onChange(of: store.primary) { _, _ in ReviewLatency.finish("category") }
    }
}

// MARK: Settings window

struct MacSettingsView: View {
    @Bindable var store: FinancialStore
    let evidence: BrowserStore
    var body: some View {
        Group {
            if store.root == nil {
                ContentUnavailableView("尚未打开家庭资料", systemImage: "tray", description: Text("在主窗口创建或打开资料后再调整设置。"))
            } else {
                TabView {
                    MacGeneralSettings(store: store).tabItem { Label("资料", systemImage: "internaldrive") }
                    HouseholdSettingsView(store: store).tabItem { Label("家庭", systemImage: "person.2") }
                    NavigationStack { CategoryManagementPage(store: store) }.tabItem { Label("分类", systemImage: "folder") }
                    MacSyncSettings(store: store, evidence: evidence).tabItem { Label("同步", systemImage: "icloud") }
                    MacMaintenanceSettings(store: store, evidence: evidence).tabItem { Label("备份与维护", systemImage: "externaldrive.badge.checkmark") }
                }
            }
        }.frame(width: 680, height: 560)
    }
}

private struct MacGeneralSettings: View {
    let store: FinancialStore
    var body: some View {
        Form {
            Section("当前资料") {
                LabeledContent("位置") { Text(store.root?.path ?? "").textSelection(.enabled).lineLimit(2).truncationMode(.middle) }
                LabeledContent("资料截止") { Text(store.report?.cutoff ?? "未建立范围") }
                LabeledContent("交易生命周期") { Text("\(store.report?.records.count ?? 0) 个") }
            }
            Section("统计边界") {
                Text(store.report?.coverage_note ?? "").font(.callout).textSelection(.enabled)
                Text("统计单位是交易生命周期；账户只是查看视角。").font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct MacSyncSettings: View {
    @Bindable var store: FinancialStore
    let evidence: BrowserStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.l) {
                VStack(alignment: .leading, spacing: DS.s) {
                    Text("家庭同步").font(.headline)
                    Text(store.syncStatus.isEmpty ? "尚无同步消息。" : store.syncStatus).foregroundStyle(.secondary).textSelection(.enabled)
                    WorkspaceSyncActions(store: store, evidence: evidence)
                    if store.workspacePaths == nil && store.clientWorkspacePaths == nil {
                        Text("复盘文件夹不参与家庭同步。").foregroundStyle(.secondary)
                    }
                }.cardStyle()
                WorkspaceRequestStatusView(store: store)
                MacSyncConflicts(store: store, evidence: evidence)
            }.padding(DS.xl)
        }
    }
}

private struct MacMaintenanceSettings: View {
    @Bindable var store: FinancialStore
    let evidence: BrowserStore
    private var busy: Bool { store.importing || evidence.loading || store.completionSaving || store.loading || store.completion.persisting }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.l) {
                if store.workspacePaths != nil || store.familyClientPaths != nil {
                    VStack(alignment: .leading, spacing: DS.s) {
                        Text("备份与检查").font(.headline)
                        Text("备份只包含已保存的内容；有未保存草稿时请先保存。").font(.callout).foregroundStyle(.secondary)
                        WorkspaceMaintenanceActions(store: store)
                    }.cardStyle()
                }
                if store.workspacePaths == nil && store.clientWorkspacePaths == nil {
                    VStack(alignment: .leading, spacing: DS.s) {
                        Text("复盘文件夹").font(.headline)
                        Button("选择其他复盘文件夹…") { store.pickerMode = "folder"; store.showingPicker = true }.disabled(busy)
                    }.cardStyle()
                }
            }.padding(DS.xl)
        }
    }
}
#endif
