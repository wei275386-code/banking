import SwiftUI
import PaymentImageCore
import UniformTypeIdentifiers
import QuickLook
import CoreFoundation

struct MobileWelcome: View {
    @Bindable var finance: FinancialStore
    @Bindable var evidence: BrowserStore
    @Bindable var services: MobileServices
    private enum FolderChoice { case family, localCopy, backup }
    @State private var folderChoice = FolderChoice.family
    @State private var choosingFolder = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "house.and.flag").font(.largeTitle).foregroundStyle(.teal)
                    Text("欢迎使用家庭财务复盘").font(.title2.bold())
                    Text("手机用于查看家庭资料并保存本机修改。首次使用，请连接 Mac 已建立的家庭同步目录。").foregroundStyle(.secondary)
                    ReviewCard(title: "连接家庭资料") {
                        Button("选择家庭同步目录") { folderChoice = .family; choosingFolder = true }
                            .buttonStyle(.borderedProminent).disabled(finance.importing || services.syncing)
                        Text("在 Files 中选择 Mac 已发布的 iCloud Drive 文件夹。快照齐全并通过检查后，会自动打开家庭资料。").font(.caption).foregroundStyle(.secondary)
                        Text(services.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if services.syncing { ProgressView("正在接收并检查家庭资料…") }
                        if services.hasRefreshTarget {
                            Button("重新检查家庭快照") { Task { await services.refresh(finance: finance, evidence: evidence) } }
                                .disabled(finance.importing || services.syncing)
                        }
                    }
                    ReviewCard(title: "打开已有资料") {
                        Button("恢复家庭副本备份") { folderChoice = .backup; choosingFolder = true }
                            .disabled(finance.importing || services.syncing || services.hasCheckpointConnection)
                        Button("选择已有复盘副本") { folderChoice = .localCopy; choosingFolder = true }
                            .buttonStyle(.bordered).disabled(finance.importing || services.syncing || services.hasCheckpointConnection)
                        Text("选择含 financial-review.json 和 payment-evidence.json 的复盘文件夹。会复制到本机，原资料保留。").font(.caption).foregroundStyle(.secondary)
                        if finance.importing { ProgressView("正在复制并检查复盘副本…") }
                    }
                    if let error = finance.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        Button("重新读取本机资料") { Task {
                            do {
                                let source = try await services.bootstrap()
                                if let root = source.localReview { await finance.load(root); if finance.report != nil { await evidence.load(root, finance: finance.report) } }
                            } catch { finance.error = "本机资料读取未完成：" + error.localizedDescription }
                        } }.disabled(finance.importing || finance.loading)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("家庭资料").navigationBarTitleDisplayMode(.inline)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                let choice = folderChoice
                Task {
                    switch choice {
                    case .family: await services.connect(url, finance: finance, evidence: evidence)
                    case .localCopy: await services.importDataset(url, finance: finance, evidence: evidence)
                    case .backup: await services.restoreFamilyClient(url, finance: finance, evidence: evidence)
                    }
                }
            case .failure(let error): finance.error = "选择资料未完成：" + error.localizedDescription
            }
        }
    }
}

struct MobileData: View {
    @Bindable var finance: FinancialStore
    @Bindable var evidence: BrowserStore
    @Bindable var services: MobileServices
    private enum PickerKind { case sync, dataset, materials, backup }
    @State private var pickerKind = PickerKind.sync
    @State private var choosingFile = false
    private var pickerTypes: [UTType] { pickerKind == .materials ? [.pdf, .commaSeparatedText, .spreadsheet, .movie, .data] : [.folder] }
    var body: some View {
        MobilePage(title: "资料与同步", finance: finance, requiresReport: false) {
            ReviewCard(title: "iCloud Drive") {
                Label(services.connectionLabel, systemImage: "icloud")
                Text(services.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Button("选择 iCloud Drive 同步目录") { pickerKind = .sync; choosingFile = true }.buttonStyle(.borderedProminent).disabled(services.syncing)
                Button("立即同步") { Task { await services.refresh(finance: finance, evidence: evidence) } }.disabled(services.syncing)
                Text("在 Files 的「浏览」中进入「iCloud 云盘」，选择 Mac 已连接的「家庭财务复盘同步」文件夹。分类、标签、补全和参数先保存在本机；Mac App 运行时处理账单导入和关联复核。").font(.caption).foregroundStyle(.secondary)
                if !services.conflicts.isEmpty {
                    DisclosureGroup("并发修改历史（\(services.conflicts.count)）") {
                        Text("同一项目的并发版本均保留。请选择要保留的值。").font(.caption)
                        ForEach(services.conflicts, id: \.self) { key in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(conflictTitle(key)).font(.callout)
                                ForEach(services.conflictOptions[key] ?? [], id: \.self) { value in
                                    Button { Task { await services.resolve(key: key, value: value, finance: finance, evidence: evidence) } } label: { ReviewConflictChoiceLabel(value: conflictValue(value, key: key)) }.buttonStyle(.bordered).disabled(services.syncing || finance.categoryBusy || evidence.loading || !finance.editingAvailable)
                                }
                            }
                        }
                    }
                }
            }
            if services.hasFamilyClientBackup {
                ReviewCard(title: "本机副本备份") {
                    Button("选择备份保存位置") { pickerKind = .backup; choosingFile = true }
                        .disabled(finance.categoryBusy || services.syncing || finance.importing)
                    Text("保留本机资料和未同步修改。恢复后可离线使用，再重新选择原同步目录。").font(.caption).foregroundStyle(.secondary)
                }
            }
            ReviewCard(title: "导入与处理") {
                Button("导入账单与素材") { pickerKind = .materials; choosingFile = true }.buttonStyle(.borderedProminent).disabled(finance.categoryBusy || evidence.loading || services.syncing || !finance.editingAvailable)
                Text(finance.importState).font(.callout).foregroundStyle(.secondary)
                ForEach(services.requests.keys.sorted(), id: \.self) { id in
                    VStack(alignment: .leading) { Text(services.requests[id] ?? ""); Text(id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Text("支持官方 PDF、CSV、XLSX 和录屏。原素材先保存在手机；Mac 使用现有解析器核对及去重，完成后同步结果。").font(.caption).foregroundStyle(.secondary)
                Button("选择复盘文件夹") { pickerKind = .dataset; choosingFile = true }.disabled(finance.categoryBusy || evidence.loading || services.syncing || services.hasCheckpointConnection)
            }
            NavigationLink { MobileEvidenceList(finance: finance, evidence: evidence) } label: { Label("交易证据与关联复核", systemImage: "doc.text.viewfinder") }
            FinanceDataPage(store: finance, evidence: evidence)
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: pickerTypes, allowsMultipleSelection: pickerKind == .materials) { result in
            guard case .success(let urls) = result, let first = urls.first else { return }
            switch pickerKind {
            case .sync: Task { await services.connect(first, finance: finance, evidence: evidence) }
            case .dataset: Task { await services.importDataset(first, finance: finance, evidence: evidence) }
            case .materials: Task { await finance.importMaterials(urls) }
            case .backup: Task { await services.backupFamilyClient(to: first, finance: finance) }
            }
        }
    }
    private func conflictTitle(_ key: String) -> String { ReviewConflictText(report: finance.report).title(key) }
    private func conflictValue(_ text: String, key: String) -> String { ReviewConflictText(report: finance.report).value(text, key: key) }

}
struct MobileEvidenceList: View {
    @Bindable var finance: FinancialStore
    @Bindable var evidence: BrowserStore
    var body: some View {
        List {
            Picker("证据视角", selection: $evidence.section) {
                Text("需要处理").tag("needs_review"); Text("所有关联").tag("all_links"); Text("原始记录").tag("records"); Text("订单卡片").tag("cards")
            }
            if ["needs_review", "all_links"].contains(evidence.section) {
                ForEach(evidence.candidates) { candidate in
                    NavigationLink { MobileCandidate(candidate: candidate, finance: finance, evidence: evidence) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.association_status)
                            if let record = evidence.records.first(where: { candidate.record_ids.contains($0.id) }) { Text(record.title).lineLimit(2); Text(record.date + " · " + money(record.amount)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            } else {
                ForEach(evidence.visibleRecords) { record in
                    NavigationLink { ScrollView { RecordPane(record: record, store: evidence).padding(12) }.navigationTitle("原始证据").navigationBarTitleDisplayMode(.inline) } label: {
                        VStack(alignment: .leading) { Text(record.title).lineLimit(2); Text(platformName(record.platform) + " · " + record.date + " · " + money(record.amount)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }.navigationTitle("交易证据").searchable(text: $evidence.query, prompt: "日期、商户或金额")
    }
}
struct MobileCandidate: View {
    let candidate: Candidate
    @Bindable var finance: FinancialStore
    @Bindable var evidence: BrowserStore
    private var live: Candidate? { evidence.report?.candidates.first { $0.id == candidate.id } }
    private var busy: Bool { evidence.loading || finance.categoryBusy || MobileServices.shared.pendingReviews.contains(candidate.id) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("此判断只改变证据关联，不确认身份或删除其他银行消费。").font(.caption).foregroundStyle(.secondary)
                if !evidence.reviewMessage.isEmpty { Text(evidence.reviewMessage).foregroundStyle(.teal) }
                if let error = evidence.error { Text(error).foregroundStyle(.red) }
                if let live {
                    Text("关联状态：" + live.association_status).font(.caption)
                    ForEach(evidence.records.filter { live.record_ids.contains($0.id) || live.bank_ids.contains($0.id) }) { RecordPane(record: $0, store: evidence) }
                    Group {
                        Button((live.active_competing_candidate_ids ?? []).isEmpty ? "支持关联" : "支持此关联并排除竞争关联") { Task { await evidence.decide(live, judgment: "supports", finance: finance) } }.buttonStyle(.borderedProminent)
                        Button("排除此关联") { Task { await evidence.decide(live, judgment: "rejects", finance: finance) } }.buttonStyle(.bordered)
                        Button("仍需资料") { Task { await evidence.decide(live, judgment: "needs_evidence", finance: finance) } }.buttonStyle(.bordered)
                    }.disabled(busy)
                } else { Text("此候选已更新，请返回列表重新选择。") }
            }.padding(16)
        }.navigationTitle("关联复核").navigationBarTitleDisplayMode(.inline)
    }
}

struct MobileOriginalLink: View {
    let source: EvidenceSource
    @State private var url: URL?
    @State private var preview: URL?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading) {
            if let url {
                HStack { Button("打开原始文件") { preview = url }; ShareLink("分享原始文件", item: url) }
            } else {
                Button(loading ? "正在读取原始文件…" : "打开原始文件") {
                    loading = true
                    Task {
                        do { let original = try await MobileServices.shared.original(source); url = original; preview = original }
                        catch { self.error = error.localizedDescription }
                        loading = false
                    }
                }.disabled(loading)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.quickLookPreview($preview)
    }
}
