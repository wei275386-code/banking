#if os(macOS) || os(iOS)
import SwiftUI
import PaymentImageCore


struct SourceRecordSetList: View {
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    @State private var query = ""
    @State private var mode = "全部"
    private var groups: [SourceRecordSet] {
        store.sourceRecordGroups.filter { group in
            (mode == "全部" || group.statusTitle == mode) && (query.isEmpty || ([group.date, group.kind, group.basis, money(group.amount_cents)] + group.evidence_keys).joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        List {
            Section {
                Text("整组核对两种来源，只保留银行记账锚点。付款来源归并与退款关联分别确认。").font(.caption).foregroundStyle(.secondary)
                Picker("来源组状态", selection: $mode) {
                    ForEach(["全部", "待确认", "已归并", "已拒绝", "证据变化，待复核"], id: \.self) { Text($0).tag($0) }
                }
            }
            ForEach(groups) { group in
                NavigationLink { SourceRecordSetDetail(groupID: group.id, store: store, evidence: evidence) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(group.kind == "refund" ? "退款来源组" : "付款来源组").font(.headline); Spacer(); Text("匹配金额 " + money(group.amount_cents)).monospacedDigit() }
                        Text(group.date.isEmpty ? "日期未知" : group.date).font(.caption)
                        Text("银联 \(group.network_count) 笔 · 银行 \(group.bank_count) 笔 · " + group.statusTitle).font(.caption).foregroundStyle(group.confirmed ? Color.teal : Color.orange)
                        if let reason = group.review_reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 5)
                }.accessibilityIdentifier("source-set-" + group.id)
            }
            if groups.isEmpty { Text("没有匹配的来源组").foregroundStyle(.secondary) }
        }.navigationTitle("来源归并").searchable(text: $query, prompt: "日期、金额或证据")
    }
}

struct SourceRecordSetActions: View {
    let record: FinancialLifecycle
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    @State private var selected: SourceRecordSet?
    var body: some View {
        ForEach(store.sourceRecordGroups.filter { $0.retained_ids.contains(record.id) || $0.shadow_ids.contains(record.id) }) { group in
            Button { selected = group } label: {
                Text("整组来源 · " + group.statusTitle + " · 查看全部参与记录与证据").font(.caption)
            }.accessibilityIdentifier("transaction-source-set-" + group.id)
        }
        .sheet(item: $selected) { group in
            NavigationStack {
                SourceRecordSetDetail(groupID: group.id, store: store, evidence: evidence)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { selected = nil } } }
            }
        }
    }
}

struct SourceRecordSetDetail: View {
    let groupID: String
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    @State private var selectedEvidence: BrowseRecord?
    private var group: SourceRecordSet? { store.sourceRecordGroups.first { $0.id == groupID } }
    private var records: [String: FinancialLifecycle] {
        guard let base = store.baseReport else { return [:] }
        return Dictionary(SourceRecordSets.baselineRecords(base).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    var body: some View {
        ScrollView {
            if let group {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.kind == "refund" ? "退款来源整组核对" : "付款来源整组核对").font(.title2.bold())
                        Text((group.date.isEmpty ? "日期未知" : group.date) + " · 匹配金额 " + money(group.amount_cents)).monospacedDigit()
                        Text(group.statusTitle).font(.headline).foregroundStyle(group.confirmed ? Color.teal : Color.orange).accessibilityIdentifier("source-set-status")
                        Text(group.basis).textSelection(.enabled)
                        if let reason = group.review_reason { Text(reason).foregroundStyle(.orange) }
                        Text("组内不指定逐笔配对；银行交易 ID、原始金额与已确认退款关联保持各自归属。归并只消除同一资金流的多来源重复记录，不额外扣减退款。").font(.caption).foregroundStyle(.secondary)
                    }
                    ReviewCard(title: "保留银行记录 · \(group.retained_ids.count) 笔") {
                        participants(group.retained_ids, retained: true)
                    }
                    ReviewCard(title: "另一来源原始记录 · \(group.shadow_ids.count) 笔") {
                        participants(group.shadow_ids, retained: false)
                    }
                    ReviewCard(title: "整组原始证据 · \(group.evidence_keys.count) 项") {
                        ForEach(group.evidence_keys, id: \.self) { key in
                            if let record = evidence.records.first(where: { $0.id == key }) {
                                Button { selectedEvidence = record } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(platformName(record.platform) + " · " + record.date + " · " + money(record.amount))
                                        Text(record.title).font(.caption)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.bordered)
                            } else { Text(key + " · 原始证据暂未加载").font(.caption).textSelection(.enabled) }
                        }
                    }
                    ReviewStack {
                        if group.confirmed {
                            Button("撤销归并") { save(group, .reject) }.accessibilityIdentifier("source-set-undo")
                        } else {
                            Button("确认整组归并") { save(group, .confirm) }.buttonStyle(.borderedProminent).disabled(!group.can_confirm).accessibilityIdentifier("source-set-confirm")
                            Button("拒绝归并") { save(group, .reject) }.disabled(group.status == "rejected").accessibilityIdentifier("source-set-reject")
                        }
                        Button("恢复自动规则") { save(group, .automatic) }.accessibilityIdentifier("source-set-automatic")
                    }.disabled(store.categoryBusy || evidence.loading)
                    if store.categoryBusy { ProgressView() }
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            } else { ContentUnavailableView("来源组已更新", systemImage: "arrow.clockwise", description: Text("请返回列表重新选择。")) }
        }.navigationTitle("来源组详情")
        .sheet(item: $selectedEvidence) { record in
            NavigationStack {
                ScrollView { RecordPane(record: record, store: evidence).padding(16) }
                    .navigationTitle("原始证据").toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { selectedEvidence = nil } } }
            }
        }
    }
    @ViewBuilder private func participants(_ ids: [String], retained: Bool) -> some View {
        let lookup = records
        ForEach(TransactionListOrder.sorted(ids, amount: { lookup[$0]?.transactionListAmount }, date: { lookup[$0]?.date ?? "" }, id: { $0 }), id: \.self) { id in
            if let record = lookup[id] {
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.date + " · " + record.title).font(.subheadline.bold()).textSelection(.enabled)
                    Text(record.events.map { $0.date + " · " + statusName($0.kind) + " · " + money($0.amount_cents) }.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    Text(record.userDisplayName + " · " + (record.payment_accounts ?? record.account_views).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                    if retained {
                        NavigationLink("查看保留交易与退款关联") {
                            FinanceSelectedTransaction(store: store, evidence: evidence, recordID: id).navigationTitle("保留交易")
                        }.font(.caption)
                    }
                    Text("交易 ID：" + id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(.vertical, 5)
            } else { Text("参与记录缺失：" + id).font(.caption).foregroundStyle(.orange) }
        }
    }
    private func save(_ group: SourceRecordSet, _ disposition: SourceRecordSetDisposition) { Task { _ = await store.saveSourceSet(group, disposition: disposition) } }
}
#endif
