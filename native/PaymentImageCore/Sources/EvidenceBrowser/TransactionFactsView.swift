#if os(macOS) || os(iOS)
import SwiftUI
import PaymentImageCore

struct TransactionFactActions: View {
    let record: FinancialLifecycle
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    @State private var factEdit: FactEdit?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SourceRecordSetActions(record: record, store: store, evidence: evidence)
            TransactionTraceView(record: record, evidence: evidence)
            RefundCandidateActions(record: record, store: store, evidence: evidence)
            if let status = record.fact_review_status { Text(status).font(.caption).foregroundStyle(status.hasPrefix("事实已确认") ? Color.teal : .orange).textSelection(.enabled) }
            if let review = store.overrides[record.reviewOverrideKey]?.transaction_facts,
               let targetID = review.targetID,
               let target = store.report?.records.first(where: { $0.id == targetID || $0.components.contains { $0.id == targetID } }) {
                Button((review.disposition == .refund ? "原购买：" : "保留交易：") + target.date + " · " + target.title) { store.selected = target.id; store.directDetailID = target.id; store.section = "details" }.font(.caption)
            }
            if let associationOwner {
                if let association = store.overrides[associationOwner.reviewOverrideKey]?.transaction_facts?.refundAssociation {
                    ForEach(store.allTransactionsByAmount.filter { association.targetSignatures[$0.id] != nil }) { target in
                        Button("原购买：" + target.date + " · " + target.title) { store.inspectTransaction(target.id) }.font(.caption)
                    }
                }
                Button("撤销候选确认") {
                    Task {
                        _ = await store.resetFacts(associationOwner)
                    }
                }.accessibilityIdentifier("refund-candidate-reset")
                if associationOwner.id != record.id {
                    Button("查看整组确认") { store.inspectTransaction(associationOwner.id) }.font(.caption)
                }
            }
            ForEach(refundSources, id: \.id) { source in
                Button("关联退款：" + source.date + " · " + source.title) { store.selected = source.id; store.directDetailID = source.id; store.section = "details" }.font(.caption)
            }
            Button(associationOwner.map { $0.id != record.id } == true ? "查看整组事实确认" : "确认交易事实") { factEdit = store.beginFactEdit(associationOwner ?? record) }.buttonStyle(.bordered).accessibilityIdentifier("transaction-facts")
        }.disabled(store.categoryBusy)
            .sheet(item: $factEdit) { edit in
                TransactionFactForm(edit: edit, store: store)
            }
    }
    private var refundSources: [FinancialLifecycle] {
        let ids = Set(record.components.map(\.id))
        return store.allTransactionsByAmount.filter { source in
            guard source.status == "退款已关联原购买项目", let review = store.overrides[source.reviewOverrideKey]?.transaction_facts,
                  review.disposition == .refund else { return false }
            if let association = review.refundAssociation { return !ids.isDisjoint(with: association.allocations.keys) }
            return review.targetID.map { ids.contains($0) } ?? false
        }
    }
    private var associationOwner: FinancialLifecycle? {
        (store.report?.records ?? []).first { owner in
            guard let association = store.overrides[owner.reviewOverrideKey]?.transaction_facts?.refundAssociation else { return false }
            return association.sourceSignatures[record.id] != nil
        }
    }
}


struct RefundCandidateActions: View {
    let record: FinancialLifecycle
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    private var candidates: [RefundCandidate] {
        guard record.unallocated_credit_cents > 0, !record.reviewExcluded, !record.non_consumption else { return [] }
        return TransactionListOrder.sorted((store.baseReport?.refund_candidates ?? []).filter { $0.source_ids.contains(record.id) }, amount: \.amount, date: { _ in "" }, id: \.id)
    }
    var body: some View {
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("退款关联候选").font(.headline)
                if candidates.count > 1,
                   let first = candidates.first,
                   candidates.allSatisfy({ Set($0.source_ids) == Set(first.source_ids) }) {
                    Text("\(first.source_ids.count) 笔退款，共 \(money(first.amount)) · \(candidates.count) 个关联方案")
                        .font(.subheadline.bold())
                    Text("下方卡片对应同一笔或同一组退款，请只确认其中一个方案。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("核对下方原购买，点一次确认即可冲减净消费。候选尚未影响统计。").font(.caption).foregroundStyle(.secondary)
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(candidate.confidence + (candidate.competing ? " · 请选择其中一个" : "")).font(.caption).foregroundStyle(.orange)
                        if candidate.grouped {
                            Text("整组退款 " + money(candidate.amount) + " · " + String(candidate.source_ids.count) + " 笔退款").font(.subheadline.bold())
                            ForEach(store.allTransactionsByAmount.filter { candidate.source_ids.contains($0.id) }) { refundSource in
                                Text(refundSource.date + " · " + money(refundSource.unallocated_credit_cents) + " · " + refundSource.title).font(.caption)
                                TransactionTraceView(record: refundSource, evidence: evidence)
                            }
                        }
                        ForEach(orderedTargets(candidate), id: \.component_id) { target in
                            if let purchase = store.report?.records.first(where: { $0.id == target.record_id }),
                               let component = purchase.components.first(where: { $0.id == target.component_id }) {
                                Button { store.inspectTransaction(purchase.id) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(purchase.date + " · " + component.title).fixedSize(horizontal: false, vertical: true)
                                        Text(paymentTime(purchase, component: component)).font(.subheadline).monospacedDigit()
                                        Text("原付款 " + money(component.gross_cents) + " · 本次退款 " + money(target.refund_cents) + " · 确认后净额 " + money(component.net_cents - target.refund_cents)).font(.caption)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                TransactionTraceView(record: purchase, evidence: evidence)
                            }
                        }
                        Text(candidate.basis).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(candidate.grouped ? "确认整组退款关联" : "确认退款关联") {
                            Task { _ = await store.confirmRefundCandidate(candidate) }
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("refund-candidate-confirm-" + candidate.id)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
            }.disabled(store.categoryBusy)
        }
    }
    private func orderedTargets(_ candidate: RefundCandidate) -> [RefundCandidateTarget] {
        let purchases = Dictionary(store.allTransactionsByAmount.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let components = Dictionary(store.allTransactionsByAmount.flatMap(\.components).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return TransactionListOrder.sorted(candidate.targets, amount: { components[$0.component_id]?.gross_cents },
                                          date: { purchases[$0.record_id]?.date ?? "" }, id: \.component_id)
    }
    private func paymentTime(_ purchase: FinancialLifecycle, component: FinancialComponent) -> String {
        let keys = Set((component.classification_keys ?? []) + [component.id])
        func dates(_ events: [FinancialEvent]) -> [String] {
            events.filter { keys.contains($0.id) && ($0.kind == "payment" || $0.kind == "bank_debit") && $0.date.contains(":") }.map(\.date)
        }
        let projected = dates(purchase.paymentEvents)
        let times = Array(Set(projected.isEmpty ? dates(purchase.events) : projected)).sorted()
        if times.isEmpty, (purchase.trace_sources ?? []).contains(where: { $0.association == "candidate" && $0.event_kind == "payment" && $0.date.contains(":") }) {
            return "银行未提供具体付款时间；平台时间见下方待核线索"
        }
        return times.isEmpty ? "付款时间未提供" : "付款时间：" + times.joined(separator: "、")
    }
}
/// Evidence summaries are visible before confirmation, including unresolved
/// competing sources. Opening a source never changes its association status.
struct TransactionTraceView: View {
    let record: FinancialLifecycle
    @Bindable var evidence: BrowserStore
    @State private var selectedSource: BrowseRecord?
    private var sources: [TransactionTraceSource] {
        TransactionListOrder.sorted(record.trace_sources ?? [], amount: \.amount_cents, date: \.date, id: \.id)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("交易溯源").font(.headline)
            if sources.isEmpty {
                Text("溯源摘要尚未提供，请在下方原始证据区核对来源。").font(.caption).foregroundStyle(.orange)
            }
            ForEach(sources) { source in
                TransactionTraceSourceView(source: source) {
                    guard let reference = source.source_evidence else { return }
                    selectedSource = BrowseRecord(id: source.id, platform: source.platform, date: source.date,
                        title: source.title ?? source.merchant ?? "原始记录", amount: source.amount_cents,
                        status: source.status, evidence: reference, userId: AccountConsolidation.displayName(source.owner_id))
                }
            }
        }
        .sheet(item: $selectedSource) { source in
            NavigationStack {
                ScrollView { RecordPane(record: source, store: evidence).padding(16) }
                    .navigationTitle("原始证据").toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { selectedSource = nil } } }
            }
        }
    }
}
struct TransactionTraceSourceView: View {
    let source: TransactionTraceSource
    let open: () -> Void
    private var title: String {
        var names = [String]()
        for name in [source.merchant, source.title].compactMap({ $0 }) where !name.isEmpty {
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "商户与商品：来源未提供" : names.joined(separator: " · ")
    }
    private var heading: String { (source.association == "linked" ? "已关联证据 · " : "待核线索 · ") + platformName(source.platform) }
    private var locator: String { (source.source_name ?? "来源文件未知") + (source.location.isEmpty ? "" : " · " + source.location) }
    private var eventLabel: String { source.event_kind == "supporting_material" ? "订单资料（日期不代表付款时间）" : statusName(source.event_kind) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(heading).font(.caption.bold()).foregroundStyle(source.association == "linked" ? Color.teal : Color.orange)
            Text(title).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text(source.date + " · " + eventLabel + " · " + money(source.amount_cents) + " " + source.currency).font(.caption).textSelection(.enabled)
            DisclosureGroup("支付方式、单号与来源") {
                VStack(alignment: .leading, spacing: 5) {
                    times
                    references
                    Text(locator).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption)
            if source.association != "linked" { Text(source.basis).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if source.source_evidence != nil {
                Button("查看原始证据", action: open).buttonStyle(.bordered).accessibilityIdentifier("trace-source-" + source.id)
            } else { Text("此来源尚无可打开的原始文件").font(.caption).foregroundStyle(.secondary) }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private var times: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !source.status.isEmpty { Text("来源状态：" + source.status).font(.caption).textSelection(.enabled) }
            if !source.date.contains(":") { Text("交易时间：来源未提供具体时分").font(.caption).foregroundStyle(.secondary) }
            if let posted = source.post_date, !posted.isEmpty {
                Text((source.platform == "bank" ? "入账日期：" : "交易成功时间：") + posted).font(.caption).textSelection(.enabled)
            }
            Text("支付方式：" + (source.payment_method ?? "来源未提供")).font(.caption).textSelection(.enabled)
            Text("来源用户：" + (AccountConsolidation.displayName(source.owner_id) ?? "未确认")).font(.caption).textSelection(.enabled)
        }
    }
    private var references: some View {
        Group {
            if source.platform != "bank" {
                Text("交易单号：" + (source.provider_reference ?? "来源未提供") + "\n商家单号：" + (source.merchant_reference ?? "来源未提供"))
                    .font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}
struct TransactionFactForm: View {
    let record: FinancialLifecycle
    let original: FinancialLifecycle
    @Bindable var store: FinancialStore
    let edit: FactEdit
    @State private var draft: TransactionFactReview
    @State private var dateEnabled: Bool
    @State private var userEnabled: Bool
    @State private var accountEnabled: Bool
    @State private var correctedDate: Date
    @State private var user: String
    @State private var account: String
    @State private var choosingTarget = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(edit: FactEdit, store: FinancialStore) {
        self.edit = edit; self.record = edit.record; self.original = edit.original; self.store = store
        let record = edit.record, initial = edit.initial
        _draft = State(initialValue: initial)
        _dateEnabled = State(initialValue: initial.date != nil)
        _userEnabled = State(initialValue: initial.userID != nil)
        _accountEnabled = State(initialValue: initial.account != nil)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        _correctedDate = State(initialValue: formatter.date(from: initial.date ?? record.date) ?? Date())
        _user = State(initialValue: initial.userID ?? record.user_id ?? "")
        _account = State(initialValue: initial.account ?? record.payment_accounts?.first ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("当前交易") {
                    Text(record.title).font(.headline)
                    Text(record.date + " · " + record.status)
                    Text("原证据保留。确认只作用于本笔，不会向同名商家传播。").font(.caption).foregroundStyle(.secondary)
                    if let status = record.fact_review_status { Text(status).font(.caption) }
                    ForEach(record.components) { component in
                        Text(component.title + "：" + money(component.net_cents) + " · " + (component.included ? "已纳入统计" : "尚未纳入统计"))
                        if !component.reason.isEmpty { Text(component.reason).font(.caption).foregroundStyle(.orange) }
                    }
                }
                Section("核实后的处理") {
                    Picker("统计处理", selection: $draft.disposition) { ForEach(FactDisposition.allCases, id: \.self) { Text($0.title).tag($0) } }.accessibilityIdentifier("fact-disposition")
                    Text("选择纳入统计，表示已核实日期、金额和重复风险；分类未知仍可先计入总消费。一次性购买计入实际消费，不计入持续支出情景。").font(.caption).foregroundStyle(.secondary)
                    if draft.disposition == .duplicate || draft.disposition == .refund {
                        if draft.refundAssociation != nil && draft.disposition == .refund {
                            Text("已保存退款候选确认。可在详情查看所有原购买，或点下方「恢复原始证据判断」撤销。").font(.caption)
                        } else {
                            Button(targetTitle) { choosingTarget = true }.accessibilityIdentifier("fact-target")
                        }
                        if draft.disposition == .refund && draft.refundAssociation == nil {
                            FactMoneyField(title: "本笔退款金额（元）", cents: Binding(get: { draft.refundCents ?? original.unallocated_credit_cents }, set: { draft.refundCents = $0 }))
                        }
                    }
                }
                Section("日期与归属") {
                    Toggle("确认或更正交易日期", isOn: $dateEnabled)
                    if dateEnabled { DatePicker("完整交易日期", selection: $correctedDate, displayedComponents: .date).accessibilityIdentifier("fact-date") }
                    Toggle("确认消费人", isOn: $userEnabled)
                    if userEnabled {
                        TextField("消费人名称", text: $user).accessibilityIdentifier("fact-user")
                        Menu("已有消费人") { ForEach(Array(Set((store.report?.records ?? []).compactMap(\.user_id))).sorted(), id: \.self) { name in Button(AccountConsolidation.displayName(name) ?? name) { user = name } } }
                    }
                    Toggle("确认支付账户", isOn: $accountEnabled)
                    if accountEnabled {
                        TextField("支付账户名称或尾号", text: $account).accessibilityIdentifier("fact-account")
                        Menu("已有账户") { ForEach(store.accounts, id: \.self) { name in Button(name) { account = name } } }
                    }
                }
                Section("更正支付与退款金额") {
                    ForEach(original.components) { component in
                        Toggle(component.title, isOn: Binding(get: { draft.amounts[component.id] != nil }, set: { enabled in
                            draft.amounts[component.id] = enabled ? FactAmounts(gross: component.gross_cents, refund: component.refund_cents) : nil
                        }))
                        if draft.amounts[component.id] != nil {
                            FactMoneyField(title: "原支付金额（元）", cents: Binding(get: { draft.amounts[component.id]?.gross ?? 0 }, set: { draft.amounts[component.id]?.gross = $0 }))
                            FactMoneyField(title: "已退款金额（元）", cents: Binding(get: { draft.amounts[component.id]?.refund ?? 0 }, set: { draft.amounts[component.id]?.refund = $0 }))
                        }
                    }
                }
                Section("保存") {
                    if let error { Text(error).foregroundStyle(.red) }
                    Button("保存事实确认") { save(reset: false) }.buttonStyle(.borderedProminent).accessibilityIdentifier("fact-save")
                    Button("恢复原始证据判断") { save(reset: true) }.accessibilityIdentifier("fact-reset")
                }
            }.formStyle(.grouped).disabled(store.categoryBusy)
                .navigationTitle("确认交易事实")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(store.completionSaving) }
                    #if os(iOS)
                    MobileKeyboardToolbar()
                    #endif
                }
                .sheet(isPresented: $choosingTarget) {
                    FactTargetPicker(sourceID: original.id, refund: draft.disposition == .refund, store: store) { id, signature in
                        draft.targetID = id; draft.targetSignature = signature
                        if draft.disposition == .refund && draft.refundCents == nil { draft.refundCents = original.unallocated_credit_cents > 0 ? original.unallocated_credit_cents : original.events.filter { $0.kind.contains("refund") || $0.kind == "bank_credit" }.reduce(0) { $0 + $1.amount_cents } }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 640)
        #endif
    }
    private var targetTitle: String {
        guard let id = draft.targetID, let target = store.report?.records.first(where: { $0.id == id || $0.components.contains { $0.id == id } }) else { return draft.disposition == .refund ? "选择原购买项目" : "选择要保留的交易" }
        let component = target.components.first { $0.id == id }
        return target.date + " · " + (component?.title ?? target.title)
    }
    private func save(reset: Bool) {
        var value = draft
        // Re-confirm against the raw evidence currently shown by this form.
        value.signature = (try? TransactionFacts.signature(original)) ?? value.signature
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        value.date = dateEnabled ? formatter.string(from: correctedDate) : nil
        value.userID = userEnabled ? user : nil; value.account = accountEnabled ? account : nil
        Task {
            if await store.saveFacts(edit, review: reset ? nil : value) { dismiss() }
            else { error = store.error }
        }
    }
}
struct FactMoneyField: View {
    let title: String
    @Binding var cents: Int
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading) {
            TextField(title, text: $text)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .onAppear { text = NSDecimalNumber(value: cents).dividing(by: 100).stringValue }
                .onChange(of: text) { _, value in
                    if let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), amount >= 0, amount <= 10_000_000_000,
                       NSDecimalNumber(decimal: amount * 100).decimalValue == Decimal(NSDecimalNumber(decimal: amount * 100).int64Value) {
                        cents = NSDecimalNumber(decimal: amount * 100).intValue
                    } else { cents = -1 }
                }
            if cents < 0 { Text("请输入非负金额，最多两位小数。").font(.caption).foregroundStyle(.red) }
        }
    }
}
struct FactTargetPicker: View {
    let sourceID: String
    let refund: Bool
    let store: FinancialStore
    let select: (String, String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    private struct Target: Identifiable {
        let record: FinancialLifecycle
        let component: FinancialComponent?
        var id: String { component?.id ?? record.id }
    }
    private var targets: [Target] {
        let records = store.allTransactionsByAmount.filter {
            $0.id != sourceID && !$0.reviewExcluded && !$0.non_consumption &&
            (query.isEmpty || ($0.date + " " + $0.title + " " + $0.components.map { money($0.gross_cents) }.joined(separator: " ")).localizedCaseInsensitiveContains(query))
        }
        let rows = records.flatMap { record -> [Target] in
            refund ? record.components.filter { $0.gross_cents > $0.refund_cents }.map { Target(record: record, component: $0) }
                   : [Target(record: record, component: nil)]
        }
        return TransactionListOrder.sorted(rows, amount: { $0.component?.net_cents ?? $0.record.transactionListAmount },
                                          date: { $0.record.date }, id: \.id)
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(targets) { target in targetButton(target.record, component: target.component) }
            }.searchable(text: $query, prompt: "日期、商户或金额").navigationTitle(refund ? "原购买项目" : "保留的交易")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 500)
        #endif
    }
    private func targetButton(_ record: FinancialLifecycle, component: FinancialComponent?) -> some View {
        Button {
            if let raw = store.baseReport?.records.first(where: { $0.id == record.id }), let signature = try? TransactionFacts.signature(raw) {
                select(component?.id ?? record.id, signature); dismiss()
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(component?.title ?? record.title)
                Text(record.date + " · " + money(component?.net_cents ?? record.components.reduce(0) { $0 + $1.net_cents })).font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}


#endif
