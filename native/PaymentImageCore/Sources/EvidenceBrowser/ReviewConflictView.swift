#if os(macOS) || os(iOS)
import SwiftUI
import CoreFoundation
import PaymentImageCore

#if os(macOS)
struct MacSyncConflicts: View {
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    var body: some View { FamilySyncConflictChoices(store: store, evidence: evidence) }
}
private struct FamilySyncConflictChoices: View {
    @Bindable var store: FinancialStore
    @Bindable var evidence: BrowserStore
    @State private var hostChoice: ReviewFamilyHostConflictState?
    @State private var clientChoice: ReviewFamilyClientHandle?
    @State private var options = [String: [String]]()
    @State private var selected = [String: String]()
    @State private var busy = false
    @State private var notice = ""
    private var paths: WorkspacePaths? { store.familyClientPaths ?? store.workspacePaths }
    private var available: Bool {
        guard let paths else { return false }
        return FileManager.default.fileExists(atPath: paths.device.appendingPathComponent("family-connection.json").path)
    }
    var body: some View {
        if available {
            ReviewCard(title: "并发版本核对") {
                Button("读取已接收的并发版本") { Task { await refresh() } }
                if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if !options.isEmpty {
                    Text("各端原始修改均会保留。逐项选择后，一起保存版本决定；设置组合还会核对成员与账户引用。").font(.caption)
                    ForEach(options.keys.sorted(), id: \.self) { key in
                        Text(ReviewConflictText(report: store.report).title(key)).font(.headline)
                        ForEach(Array((options[key] ?? []).indices), id: \.self) { index in
                            let value = options[key]![index]
                            Button { selected[key] = value } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: selected[key].map { Data($0.utf8) == Data(value.utf8) } == true ? "checkmark.circle.fill" : "circle")
                                    ReviewConflictChoiceLabel(value: ReviewConflictText(report: store.report).value(value, key: key))
                                }
                            }.buttonStyle(.bordered)
                            if key.hasPrefix("settings/") {
                                DisclosureGroup("查看完整设置内容") {
                                    Text(value).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    Button("保存全部版本选择") { Task { await save() } }
                        .disabled(Set(selected.keys) != Set(options.keys))
                }
            }.disabled(busy || store.categoryBusy || evidence.loading)
                .onChange(of: store.root) { hostChoice = nil; clientChoice = nil; options = [:]; selected = [:]; notice = "" }
        }
    }
    @MainActor private func refresh() async {
        guard let paths, !busy, !store.categoryBusy, !evidence.loading else { return }
        let generation = store.workspaceSelectionGeneration
        busy = true; defer { busy = false }
        do {
            let host: ReviewFamilyHostConflictState?, client: ReviewFamilyClientHandle?
            if store.familyClientPaths != nil {
                client = try await ReviewSyncDetached.run { try ReviewFamilyClientSession.read(paths: paths) }; host = nil
            } else {
                host = try await ReviewSyncDetached.run { try ReviewFamilyHost.conflictState(paths: paths) }; client = nil
            }
            guard store.isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
            hostChoice = host; clientChoice = client; options = host?.options ?? client?.conflicts ?? [:]; selected = [:]
            notice = options.isEmpty ? "未发现已接收的并发版本。可先刷新或发布家庭同步，再核对。" : ""
        } catch {
            guard store.isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
            hostChoice = nil; clientChoice = nil; options = [:]; selected = [:]; notice = error.localizedDescription
        }
    }
    @MainActor private func save() async {
        guard let paths, !busy, !store.categoryBusy, !evidence.loading else { return }
        guard store.completion.drafts.isEmpty, !store.hasUnsavedParameters else { notice = "请先保存或还原当前草稿，再选择并发版本。"; return }
        let generation = store.workspaceSelectionGeneration, choices = selected
        busy = true; store.editorPauseReason = "正在保存并发版本决定"
        defer { busy = false; if store.isWorkspaceSelectionCurrent(paths: paths, generation: generation) { store.editorPauseReason = nil } }
        do {
            if let expected = clientChoice {
                let handle = try await ReviewSyncDetached.run { try ReviewFamilyClientSession.resolveConflicts(paths: paths, expected: expected, choices: choices) }
                guard store.isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
                try await store.loadFamilyClient(paths: paths, handle: handle, selectionIsCurrent: { store.isWorkspaceSelectionCurrent(paths: paths, generation: generation) })
            } else if let expected = hostChoice {
                let state = try await ReviewSyncDetached.run { try ReviewFamilyHost.resolveConflicts(paths: paths, expected: expected, choices: choices) }
                guard store.isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
                await store.loadWorkspace(paths, expectedPointer: state.pointer, selectionGeneration: generation)
            } else { throw WorkspaceError.stalePointer }
            guard store.isWorkspaceSelectionCurrent(paths: paths, generation: generation), let root = store.root else { return }
            await evidence.load(root, finance: store.report)
            guard store.isWorkspaceSelectionCurrent(paths: paths, generation: generation) else { return }
            options = [:]; selected = [:]; hostChoice = nil; clientChoice = nil
            notice = store.familyClientPaths == nil ? "决定已保存在本机；点击发布家庭同步，将核对结果发送到其他端。" : "决定已保存在本机；下一次刷新会发送此决定。"
            store.syncStatus = notice
        } catch { if store.isWorkspaceSelectionCurrent(paths: paths, generation: generation) { notice = "版本未保存，请重新读取并核对：" + error.localizedDescription } }
    }
}
#endif

struct ReviewConflictChoiceLabel: View {
    let value: String
    var body: some View {
        Text("使用：" + value).lineLimit(nil).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct ReviewConflictText {
    let report: FinancialReport?
    private static let fieldLabels = [
        "@category": "分类", "primary": "一级分类", "secondary": "二级分类", "tags": "标签", "excluded_from_completion_and_statistics": "从补全和统计中排除", "nature": "支出性质", "recurrence": "支出性质", "tag_basis": "标签依据", "classification_basis": "分类依据", "transaction_facts": "交易事实确认", "date": "交易日期", "userID": "消费人", "account": "支付账户", "amounts": "确认金额", "gross": "支付金额（分）", "refund": "退款金额（分）", "disposition": "统计处理", "targetID": "关联目标",
        "baseYear": "基准年", "birthYear": "出生年", "targetAge": "目标年龄", "currentFireAssets": "可投资资产", "afterTaxSalary": "税后年收入", "annualContribution": "每年投入",
        "annualHardCap": "年度硬上限", "expenseModes": "支出档位", "normal": "常态支出", "stress": "压力档支出", "ideal": "理想档支出", "expenseBreakdown": "年度预算",
        "buckets": "储备桶", "safetyBucket": "安全储备", "parentMedicalBucket": "父母医疗储备", "elderCareEnabled": "赡养储备开关", "elderCareBucket": "赡养储备", "otherBuckets": "其他储备", "includeBuckets": "目标包含储备桶",
        "investing": "投资", "withdrawalRate": "安全提取率", "annualReturn": "名义年收益率", "inflation": "通胀率", "maxDrawdown": "最大回撤",
        "branches": "情景", "housing": "买房", "children": "子女", "enabled": "启用情景", "year": "计划年份", "totalPrice": "总价", "downPaymentRatio": "首付比例", "loanRate": "贷款年利率", "loanYears": "贷款年数",
        "fees": "税费", "renovation": "装修", "annualMaintenance": "年度维护", "reduceRent": "购房后减少原租金", "minLiquidAssets": "最低流动资产", "ownerHomeCountsAsFireAsset": "自住房计入 FIRE 资产", "annualRentReduction": "年度租金减少",
        "count": "子女数量", "annualCost": "每名子女年度成本", "educationBucket": "教育储备", "incomeImpact": "年度收入减少"
    ]
    func title(_ key: String) -> String {
        if key == "settings/family-profile" { return "家庭、成员设置" }
        if key == "settings/account-policies" { return "账户、付款规则设置" }
        if key == "catalog/@tree" { return "分类目录 · 主、二级分类" }
        if key.hasPrefix("parameter/") {
            let path = key.dropFirst(10).split(separator: "/").map(String.init)
            return "模型参数 · " + path.map { Self.fieldLabels[$0] ?? $0 }.joined(separator: " / ")
        }
        let deferred = key.hasPrefix("deferred/")
        let rest = String(key.dropFirst(9))
        let split = deferred ? nil : rest.lastIndex(of: "/")
        let rawID = split.map { String(rest[..<$0]) } ?? rest
        let id = rawID.hasPrefix("transaction:") ? String(rawID.dropFirst(12)) : rawID
        let field = split.map { String(rest[rest.index(after: $0)...]) } ?? ""
        if rawID.hasPrefix("source-set:"), let report,
           let group = SourceRecordSets.groups(report).first(where: { $0.reviewOverrideKey == rawID }) {
            return group.date + " · " + (group.kind == "refund" ? "退款来源组" : "付款来源组") + " · 来源归并决定"
        }
        let record = report?.records.first { record in
            record.id == id || record.components.contains { $0.id == id || ($0.classification_keys ?? []).contains(id) }
        }
        let name = record.map { $0.date + " · " + $0.title } ?? "复盘项目"
        return name + " · " + (deferred ? "暂放状态" : Self.fieldLabels[field] ?? "补全信息")
    }
    func value(_ text: String, key: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else { return "未设置" }
        if key == "settings/family-profile", let row = object as? [String: Any] {
            let name = (row["household_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "未命名家庭"
            let members = (row["members"] as? [[String: Any]] ?? []).map { ($0["display_name"] as? String ?? "成员") + ($0["status"] as? String == "inactive" ? "（已停用）" : "") }
            return name + "；成员：" + (members.isEmpty ? "暂无" : members.joined(separator: "、"))
        }
        if key == "settings/account-policies", let row = object as? [String: Any] {
            let accounts = row["accounts"] as? [[String: Any]] ?? []
            let labels = Dictionary(accounts.compactMap { item -> (String, String)? in
                guard let id = item["id"] as? String, let name = item["display_name"] as? String else { return nil }; return (id, name)
            }, uniquingKeysWith: { first, _ in first })
            let accountDescriptions: [String] = accounts.map { account in
                let name = account["display_name"] as? String ?? "账户"
                let currency = account["currency"] as? String ?? ""
                let inactive = account["status"] as? String == "inactive" ? "，已停用" : ""
                return name + "（" + currency + inactive + "）"
            }
            var lines = ["账户：" + (accountDescriptions.isEmpty ? "暂无" : accountDescriptions.joined(separator: "、"))]
            for rule in (row["routes"] as? [[String: Any]] ?? []) + (row["aliases"] as? [[String: Any]] ?? []) {
                let selector = rule["source_selector"] as? [String: Any] ?? [:]
                let source = ["platform", "source_account_name", "payment_channel"].compactMap { selector[$0] as? String }.joined(separator: " / ")
                let target = (rule["target_account_id"] as? String).flatMap { labels[$0] } ?? "待核对账户"
                lines.append(source + " → " + target + "；" + (rule["basis"] as? String ?? "") + (rule["confirmed"] as? Bool == true ? "（已确认）" : "（待确认）"))
            }
            return lines.joined(separator: "；")
        }
        if key.hasSuffix("/source_record_set_review") {
            if object is NSNull { return "恢复自动规则" }
            if let review = try? JSONDecoder().decode(SourceRecordSetReview.self, from: Data(text.utf8)) {
                let label = review.disposition == .confirm ? "确认整组归并" : review.disposition == .reject ? "拒绝归并" : "恢复自动规则"
                let group = report.flatMap { report in SourceRecordSets.groups(report).first { key == "override/" + $0.reviewOverrideKey + "/source_record_set_review" } }
                return label + (group?.fingerprint == review.fingerprint ? " · 当前整组证据" : " · 另一版证据，需复核")
            }
        }
        if key == "catalog/@tree", let catalog = try? JSONDecoder().decode(CategoryCatalog.self, from: Data(text.utf8)) {
            let categories = catalog.taxonomy.map { $0.primary + "：" + ($0.secondaries.isEmpty ? "暂无二级分类" : $0.secondaries.joined(separator: "、")) }.joined(separator: "；")
            let history = catalog.aliases.map { alias in
                let target = catalog.secondaries.first { $0.id == alias.targetID }
                let parent = catalog.primaries.first { $0.id == target?.primaryID }
                return alias.primary + " / " + alias.secondary + " → " + (parent?.name ?? "待分类") + " / " + (target?.name ?? "待分类")
            }
            return categories + "；历史分类名称关联（\(history.count)）：" + (history.isEmpty ? "无" : history.joined(separator: "、"))
        }
        if key.hasSuffix("/transaction_facts"), let review = try? JSONDecoder().decode(TransactionFactReview.self, from: Data(text.utf8)) {
            var lines = [review.disposition.title]
            if let date = review.date { lines.append("日期：" + date) }
            if let user = review.userID { lines.append("消费人：" + user) }
            if let account = review.account { lines.append("账户：" + account) }
            for id in review.amounts.keys.sorted() {
                let amount = review.amounts[id]!
                lines.append("支付 " + NSDecimalNumber(value: amount.gross).dividing(by: 100).stringValue + " 元 / 退款 " + NSDecimalNumber(value: amount.refund).dividing(by: 100).stringValue + " 元")
            }
            if let targetID = review.targetID, let target = report?.records.first(where: { $0.id == targetID || $0.components.contains { $0.id == targetID } }) { lines.append("关联：" + target.date + " · " + target.title) }
            return lines.joined(separator: "；")
        }
        if object is NSNull {
            if key.hasPrefix("deferred/") { return "放回队列" }
            if key.hasSuffix("/@category") { return "采用原始分类" }
            if key.hasSuffix("/tags") { return "采用原始标签" }
            return "未设置"
        }
        if let string = object as? String { return string.isEmpty ? "未设置" : string }
        if let values = object as? [String] { return values.isEmpty ? "无标签" : values.joined(separator: "、") }
        if let category = object as? [String: String], let primary = category["primary"] {
            return [primary, category["secondary"] ?? ""].filter { !$0.isEmpty }.joined(separator: " / ")
        }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return key.hasPrefix("deferred/") ? (number.boolValue ? "暂放" : "放回队列") : (number.boolValue ? "启用" : "关闭") }
            let leaf = key.split(separator: "/").last.map(String.init) ?? ""
            if ["withdrawalRate", "annualReturn", "inflation", "maxDrawdown", "downPaymentRatio", "loanRate"].contains(leaf) { return (number.doubleValue * 100).formatted(.number.precision(.fractionLength(0...2))) + "%" }
            return number.doubleValue.formatted(.number.precision(.fractionLength(0...2)))
        }
        return readableMetadata(object)
    }
    private func readableMetadata(_ object: Any) -> String {
        if object is NSNull { return "未设置" }
        if let string = object as? String { return FactDisposition(rawValue: string)?.title ?? (string.isEmpty ? "未设置" : string) }
        if let dictionary = object as? [String: Any] {
            return dictionary.isEmpty ? "未设置" : dictionary.keys.sorted().filter { !["signature", "targetSignature", "version"].contains($0) }.map { (Self.fieldLabels[$0] ?? $0) + "：" + readableMetadata(dictionary[$0]!) }.joined(separator: "；")
        }
        if let array = object as? [Any] { return array.isEmpty ? "未设置" : array.map(readableMetadata).joined(separator: "、") }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "是" : "否" }
            return number.doubleValue.formatted(.number.precision(.fractionLength(0...2)))
        }
        return String(describing: object)
    }
}


#endif
