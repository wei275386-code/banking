#if os(macOS) || os(iOS)
import SwiftUI
import PaymentImageCore

private struct CategoryEditRequest: Identifiable {
    let id = UUID()
    let catalog: CategoryCatalog
    var primaryID: String?
    var secondaryID: String?
    var deleting = false
}

struct CategoryManagementPage: View {
    @Bindable var store: FinancialStore
    @State private var search = ""
    @State private var editing: CategoryEditRequest?
    private var matching: [CategoryPrimary] {
        guard let catalog = store.categoryCatalog else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let children = Dictionary(grouping: catalog.secondaries, by: \.primaryID)
        return catalog.primaries.filter { parent in
            query.isEmpty || parent.name.localizedCaseInsensitiveContains(query) || (children[parent.id] ?? []).contains {
                $0.name.localizedCaseInsensitiveContains(query)
            }
        }
    }
    var body: some View {
        let groups = Dictionary(grouping: store.categoryCatalog?.secondaries ?? [], by: \.primaryID)
        List {
            Section {
                Text("主分类管理支出用途，二级分类细分用途。改名和移动会更新历史交易；删除时选择迁移目标。").font(.callout).foregroundStyle(.secondary)
                if !store.categoryMessage.isEmpty { Text(store.categoryMessage).font(.callout).foregroundStyle(.teal).accessibilityIdentifier("category-status") }
                if let error = store.error { Text(error).foregroundStyle(.red) }
            }
            Section("主分类 · \(matching.count)") {
                ForEach(matching) { parent in
                    NavigationLink {
                        PrimaryCategoryDetail(store: store, primaryID: parent.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(parent.name).font(.headline)
                            let children = groups[parent.id] ?? []
                            Text("\(children.count) 个二级分类 · \(children.reduce(0) { $0 + store.categoryUsage[$1.id, default: 0] }) 个消费项目").font(.caption).foregroundStyle(.secondary)
                            if !search.isEmpty { Text(children.map(\.name).joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }.padding(.vertical, 3)
                    }.accessibilityIdentifier("category-primary-" + parent.name)
                }
                if matching.isEmpty { Text("没有匹配分类").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("分类修改")
        .searchable(text: $search, prompt: "搜索主分类或二级分类")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { if let catalog = store.categoryCatalog { editing = CategoryEditRequest(catalog: catalog) } } label: { Label("新增主分类", systemImage: "plus") }
                    .accessibilityIdentifier("category-add-primary").disabled(store.categoryBusy || store.categoryCatalog == nil)
            }
        }
        .sheet(item: $editing) { CategoryEditor(store: store, request: $0) }
    }
}

private struct PrimaryCategoryDetail: View {
    @Bindable var store: FinancialStore
    let primaryID: String
    @State private var editing: CategoryEditRequest?
    @Environment(\.dismiss) private var dismiss
    private var parent: CategoryPrimary? { store.categoryCatalog?.primaries.first { $0.id == primaryID } }
    private var children: [CategorySecondary] { store.categoryCatalog?.secondaries.filter { $0.primaryID == primaryID } ?? [] }
    var body: some View {
        List {
            if let parent {
                Section {
                    Text("\(children.count) 个二级分类 · \(children.reduce(0) { $0 + store.categoryUsage[$1.id, default: 0] }) 个消费项目（全部资料库）").font(.callout).foregroundStyle(.secondary)
                    NavigationLink("查看分类下交易") {
                        CategoryTransactionsPage(store: store, primaryID: primaryID)
                    }.accessibilityIdentifier("category-view-transactions")
                    if parent.name == "待分类" { Text("此分类保留用于尚未确认用途的项目。").font(.callout).foregroundStyle(.secondary) }
                    else {
                        Button("修改主分类名称") { open() }.accessibilityIdentifier("category-rename-primary")
                        Button("删除主分类", role: .destructive) { open(deleting: true) }.accessibilityIdentifier("category-delete-primary")
                    }
                }
                Section("二级分类") {
                    ForEach(children) { child in
                        if parent.name == "待分类" && child.name == "待分类" {
                            Label(child.name, systemImage: "lock").foregroundStyle(.secondary)
                        } else {
                            Button { open(secondaryID: child.id) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(child.name).foregroundStyle(.primary)
                                        Text("\(store.categoryUsage[child.id, default: 0]) 个消费项目").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "pencil").foregroundStyle(.secondary)
                                }
                            }.accessibilityIdentifier("category-secondary-" + child.name)
                        }
                        NavigationLink {
                            CategoryTransactionsPage(store: store, primaryID: primaryID, secondaryID: child.id)
                        } label: {
                            Label("查看「\(child.name)」下交易", systemImage: "list.bullet")
                        }.accessibilityIdentifier("category-transactions-" + child.name)
                    }
                    if children.isEmpty { Text("暂无二级分类，新增后可用于交易分类。").foregroundStyle(.secondary) }
                    if parent.name != "待分类" {
                        Button { open(newSecondary: true) } label: { Label("新增二级分类", systemImage: "plus") }.accessibilityIdentifier("category-add-secondary")
                    }
                }
                if !store.categoryMessage.isEmpty { Section { Text(store.categoryMessage).foregroundStyle(.teal) } }
                if let error = store.error { Section { Text(error).foregroundStyle(.red) } }
            }
        }
        .navigationTitle(parent?.name ?? "分类已删除")
        .disabled(store.categoryBusy)
        .sheet(item: $editing) { CategoryEditor(store: store, request: $0) }
        .onChange(of: parent?.id) { _, value in if value == nil { dismiss() } }
    }
    private func open(secondaryID: String? = nil, deleting: Bool = false, newSecondary: Bool = false) {
        guard let catalog = store.categoryCatalog else { return }
        editing = CategoryEditRequest(catalog: catalog, primaryID: primaryID, secondaryID: newSecondary ? "" : secondaryID, deleting: deleting)
    }
}

private struct CategoryBatchRequest: Identifiable {
    let id = UUID()
    let entries: [CompletionEntry]
    let catalog: CategoryCatalog
    let document: Data
    let unbinding: Bool
}

private struct CategoryTransactionsPage: View {
    @Bindable var store: FinancialStore
    let primaryID: String
    var secondaryID: String? = nil
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var batch: CategoryBatchRequest?
    private var entries: [CompletionEntry] { store.categoryTransactions(primaryID: primaryID, secondaryID: secondaryID) }
    private var visible: [CompletionEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            search.isEmpty || [entry.record.title, entry.component?.title ?? "", entry.record.date,
                entry.component.map { money($0.net_cents) } ?? "", entry.record.account_views.joined(separator: " ")]
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }
    private var title: String {
        if let secondaryID { return store.categoryCatalog?.secondaries.first { $0.id == secondaryID }?.name ?? "分类已删除" }
        return store.categoryCatalog?.primaries.first { $0.id == primaryID }?.name ?? "分类已删除"
    }
    var body: some View {
        List {
            Section {
                Text("全部资料库 · \(entries.count) 个消费项目。拆分交易按项目选择。").font(.callout).foregroundStyle(.secondary)
                Text("当前显示 \(visible.count) 项 · 已选 \(selected.count) 项").accessibilityIdentifier("category-selection-count")
                HStack {
                    Button("全选当前结果") { selected.formUnion(visible.map(\.id)) }.accessibilityIdentifier("category-select-all").disabled(visible.isEmpty)
                    Spacer()
                    Button("清空选择") { selected.removeAll() }.disabled(selected.isEmpty)
                }.buttonStyle(.borderless)
                HStack {
                    Button("解绑", role: .destructive) { open(unbinding: true) }.accessibilityIdentifier("category-batch-unbind")
                    Spacer()
                    Button("换绑分类") { open(unbinding: false) }.accessibilityIdentifier("category-batch-rebind")
                }.buttonStyle(.bordered).disabled(selected.isEmpty)
                if !store.categoryMessage.isEmpty { Text(store.categoryMessage).font(.caption).foregroundStyle(.teal) }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
                if store.categorySaving { ProgressView("正在保存…") }
            }
            Section("交易项目") {
                ForEach(visible) { entry in
                    Button {
                        if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(entry.id) ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.component?.title ?? entry.record.title).font(.headline).foregroundStyle(.primary)
                                Text(entry.record.date + " · " + money(entry.component?.net_cents ?? 0)).foregroundStyle(.primary)
                                Text((entry.component?.primary ?? "") + " / " + (entry.component?.secondary ?? "")).font(.caption).foregroundStyle(.secondary)
                                Text(entry.record.account_views.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                                if entry.record.reviewExcluded { Text("已从统计中排除").font(.caption).foregroundStyle(.orange) }
                                else if entry.component?.included == false { Text("尚未纳入统计").font(.caption).foregroundStyle(.orange) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("category-transaction-" + entry.id)
                        .accessibilityAddTraits(selected.contains(entry.id) ? .isSelected : [])
                }
                if visible.isEmpty { Text(entries.isEmpty ? "此分类下暂无交易。" : "没有匹配交易。").foregroundStyle(.secondary) }
            }
        }.navigationTitle(title + " · 交易")
            .searchable(text: $query, prompt: "搜索日期、商户、金额或账户")
            .disabled(store.categoryBusy)
            .sheet(item: $batch) { request in
                CategoryBatchEditor(store: store, request: request) { selected.removeAll() }
            }
            .onChange(of: store.revision) { _, _ in selected.removeAll() }
    }
    private func open(unbinding: Bool) {
        guard let catalog = store.categoryCatalog else { return }
        batch = CategoryBatchRequest(entries: entries.filter { selected.contains($0.id) }, catalog: catalog, document: store.overrideDocument, unbinding: unbinding)
    }
}

private struct CategoryBatchEditor: View {
    @Bindable var store: FinancialStore
    let request: CategoryBatchRequest
    let saved: () -> Void
    @State private var targetID = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var pendingID: String { request.catalog.resolve(primary: "待分类", secondary: "待分类").id ?? "" }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("已选择 \(request.entries.count) 个消费项目").font(.headline)
                    Text(request.unbinding ? "解绑后移至「待分类 / 待分类」，可稍后重新补全用途。" : "将所选项目移至以下二级分类。")
                        .fixedSize(horizontal: false, vertical: true)
                    if !request.unbinding {
                        Picker("目标分类", selection: $targetID) {
                            Text("请选择分类").tag("")
                            ForEach(request.catalog.secondaries.filter { $0.id != pendingID }) { child in
                                Text((request.catalog.primaries.first { $0.id == child.primaryID }?.name ?? "") + " / " + child.name).tag(child.id)
                            }
                        }.accessibilityIdentifier("category-batch-target")
                    }
                    Text("金额、退款、标签和统计纳入状态保留；用途需重新确认。只修改所选项目。").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if store.categorySaving { Section { ProgressView("正在保存…") } }
            }.formStyle(.grouped)
                .navigationTitle(request.unbinding ? "批量解绑" : "批量换绑分类")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(store.categorySaving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(request.unbinding ? "确认解绑" : "确认换绑") {
                            Task {
                                if await store.rebindCategoryTransactions(request.entries, targetID: request.unbinding ? pendingID : targetID, expectedCatalog: request.catalog, expectedDocument: request.document) {
                                    saved(); dismiss()
                                } else { error = store.error }
                            }
                        }.accessibilityIdentifier("category-batch-save")
                            .disabled(store.categoryBusy || (request.unbinding ? pendingID.isEmpty : targetID.isEmpty))
                    }
                }.interactiveDismissDisabled(store.categorySaving)
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 340)
        #endif
    }
}

private struct CategoryEditor: View {
    @Bindable var store: FinancialStore
    let request: CategoryEditRequest
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var parentID = ""
    @State private var replacementID = ""
    @State private var deleting = false
    @State private var error: String?
    @State private var initialized = false
    private var secondary: CategorySecondary? { request.catalog.secondaries.first { $0.id == request.secondaryID } }
    private var parent: CategoryPrimary? { request.catalog.primaries.first { $0.id == request.primaryID } }
    private var isSecondary: Bool { request.secondaryID != nil }
    private var isNew: Bool { isSecondary ? secondary == nil : parent == nil }
    private var title: String { deleting ? (isSecondary ? "删除二级分类" : "删除主分类") : (isNew ? "新增" : "修改") + (isSecondary ? "二级分类" : "主分类") }
    private var targets: [CategorySecondary] {
        request.catalog.secondaries.filter {
            isSecondary ? $0.id != secondary?.id : $0.primaryID != parent?.id
        }
    }
    private var usage: Int {
        if let secondary { return store.categoryUsage[secondary.id, default: 0] }
        return request.catalog.secondaries.filter { $0.primaryID == parent?.id }.reduce(0) { $0 + store.categoryUsage[$1.id, default: 0] }
    }
    var body: some View {
        NavigationStack {
            Form {
                if deleting {
                    Section("迁移历史项目") {
                        Text("将删除「\(secondary?.name ?? parent?.name ?? "")」\(isSecondary ? "" : "及其全部二级分类")。\(usage) 个消费项目将移至所选分类，金额、退款和原始记录保留。")
                            .fixedSize(horizontal: false, vertical: true)
                        Picker("迁移目标", selection: $replacementID) {
                            ForEach(targets) { child in
                                Text((request.catalog.primaries.first { $0.id == child.primaryID }?.name ?? "") + " / " + child.name).tag(child.id)
                            }
                        }.accessibilityIdentifier("category-replacement")
                        Text("历史名称也会关联到迁移目标，后续导入不会重新创建已删除分类。迁移后的项目需重新确认用途。").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Section {
                        TextField("分类名称", text: $name).accessibilityIdentifier("category-name")
                        if isSecondary {
                            Picker("所属主分类", selection: $parentID) {
                                ForEach(request.catalog.primaries.filter { $0.name != "待分类" }) { Text($0.name).tag($0.id) }
                            }.accessibilityIdentifier("category-parent")
                        }
                        Text("名称最多 40 字。同一层级名称不能重复。改名或移动会应用到全部历史项目。").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !isNew {
                        Section { Button("删除此分类", role: .destructive) { deleting = true; error = nil }.accessibilityIdentifier("category-delete") }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("category-error") } }
                if store.categorySaving { Section { ProgressView("正在保存分类…") } }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(store.categorySaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(deleting ? "删除并迁移" : "保存", role: deleting ? .destructive : nil) { Task { await save() } }
                        .accessibilityIdentifier("category-save")
                        .disabled(store.categoryBusy || (deleting ? replacementID.isEmpty : name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .interactiveDismissDisabled(store.categorySaving)
            .onAppear {
                guard !initialized else { return }
                initialized = true
                name = secondary?.name ?? parent?.name ?? ""
                if isNew { name = "" }
                parentID = secondary?.primaryID ?? parent?.id ?? ""
                replacementID = targets.first { child in child.name == "待分类" && request.catalog.primaries.first(where: { $0.id == child.primaryID })?.name == "待分类" }?.id ?? targets.first?.id ?? ""
                deleting = request.deleting
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 420, idealHeight: 480)
        #endif
    }
    private func save() async {
        do {
            var next = request.catalog
            if deleting, let secondary { try next.deleteSecondary(id: secondary.id, replacementID: replacementID) }
            else if deleting, let parent { try next.deletePrimary(id: parent.id, replacementID: replacementID) }
            else if let secondary { try next.renameSecondary(id: secondary.id, name: name, primaryID: parentID) }
            else if isSecondary { _ = try next.addSecondary(primaryID: parentID, name: name) }
            else if let parent { try next.renamePrimary(id: parent.id, name: name) }
            else { _ = try next.addPrimary(name: name) }
            if await store.saveCategoryCatalog(next, expected: request.catalog) { dismiss() }
            else { error = store.error }
        } catch { self.error = error.localizedDescription }
    }
}
#endif
