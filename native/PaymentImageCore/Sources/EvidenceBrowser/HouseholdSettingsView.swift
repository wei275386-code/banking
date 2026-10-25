#if os(macOS) || os(iOS)
import Foundation
import SwiftUI
import PaymentImageCore

/// Local settings use the existing state transaction. Only unbound households
/// and the explicitly granted new family Host can save; client authority is separate.
extension WorkspaceEditSession {
    static func requireLocalHouseholdWriter(_ paths: WorkspacePaths) throws {
        try ReviewFamilyHost.requireSettingsWriter(paths: paths)
    }

    func writeHouseholdSettings(_ plan: HouseholdEditorPlan) throws -> StateHandle {
        guard case .workspace(let core) = plan else { throw WorkspaceError.invalid("完整资料 writer 不能提交 client 设置计划。") }
        return try writeHouseholdSettings(core)
    }
    func writeHouseholdSettings(_ plan: HouseholdSettingsEditPlan) throws -> StateHandle {
        try Self.requireLocalHouseholdWriter(paths)
        let (_, saved) = try write { _, config in
            // write() already holds the maintenance lease and full-pointer CAS.
            try Self.requireLocalHouseholdWriter(paths)
            let candidate = try plan.revalidate(paths: paths)
            try candidate.profileData.write(to: config.appendingPathComponent("family-profile.json"), options: .atomic)
            try candidate.policiesData.write(to: config.appendingPathComponent("account-policies.json"), options: .atomic)
        }
        return saved
    }
}

extension FinancialStore {
    func readHouseholdSettings() throws -> HouseholdSettingsState {
        guard let paths = workspacePaths, let state = workspaceState else {
            throw WorkspaceError.invalid("此资料尚未提供可编辑的家庭设置，请在本机完整资料中设置。")
        }
        try WorkspaceEditSession.requireLocalHouseholdWriter(paths)
        // The processor currently supports CNY only. Never let UI data grant FX.
        let settings = try HouseholdSettingsState.read(paths: paths, currencyCodes: ["CNY"],
            referencedMemberIDs: [], referencedAccountIDs: [])
        guard settings.pointer == state.pointer else { throw WorkspaceError.stalePointer }
        return settings
    }

    func persistHouseholdSettings(_ plan: HouseholdSettingsEditPlan) async -> Bool {
        guard editingAvailable, !completionSaving, !discoveryBusy, !categorySaving,
              !loading, !importing, !completion.persisting, let session = workspaceEditSession else {
            error = editorPauseReason ?? workspaceRuntimeFailure ?? "当前资料暂不能保存家庭设置。"
            return false
        }
        completionSaving = true
        defer { completionSaving = false }
        do {
            let saved = try await Task.detached { try session.writeHouseholdSettings(plan) }.value
            // A completed save must not replace a reader selected during the await.
            guard workspacePaths?.workspace.path == session.paths.workspace.path,
                  workspaceState?.pointer == session.state.pointer else { return true }
            adoptWorkspaceState(saved)
            error = nil
            return true
        } catch {
            self.error = "家庭设置未保存：" + error.localizedDescription
            return false
        }
    }
}

enum HouseholdEditorPlan: Sendable {
    case workspace(HouseholdSettingsEditPlan)
    case client(WorkspacePaths, ReviewFamilyClientSettingsPlan)
    var candidate: HouseholdSettings {
        switch self { case .workspace(let plan): return plan.candidate; case .client(_, let plan): return plan.candidate }
    }
}
enum HouseholdEditorBaseline: Sendable {
    case workspace(HouseholdSettingsState)
    case client(WorkspacePaths, ReviewFamilyClientHandle)
    var settings: HouseholdSettings {
        switch self { case .workspace(let value): return value.settings; case .client(_, let value): return value.settings }
    }
    var sources: [HouseholdRegisteredSource] {
        switch self { case .workspace(let value): return value.sources; case .client(_, let value): return value.sources }
    }
    func prepareEdit(profileData: Data, policiesData: Data) throws -> HouseholdEditorPlan {
        switch self {
        case .workspace(let state): return try .workspace(state.prepareEdit(profileData: profileData, policiesData: policiesData))
        case .client(let paths, let handle): return try .client(paths, ReviewFamilyClientSession.prepareSettings(paths: paths, expected: handle, profileData: profileData, policiesData: policiesData))
        }
    }
    func preview(_ plan: HouseholdEditorPlan) throws -> HouseholdSettingsImpact {
        switch (self, plan) {
        case (.workspace(let state), .workspace): return try state.previewImpact(candidate: plan.candidate)
        case (.client, .client(let paths, let plan)): return try ReviewFamilyClientSession.previewSettings(paths: paths, plan: plan)
        default: throw WorkspaceError.stalePointer
        }
    }
    @MainActor func matches(_ store: FinancialStore) -> Bool {
        switch self {
        case .workspace(let state): return store.workspaceState?.pointer == state.pointer
        case .client(let paths, let handle): return store.familyClientPaths == paths && store.familyClientHandle?.version == handle.version && store.root == handle.review
        }
    }
}
extension FinancialStore {
    func persistHouseholdSettings(_ plan: HouseholdEditorPlan) async -> Bool {
        switch plan {
        case .workspace(let core): return await persistHouseholdSettings(core)
        case .client(let paths, let plan):
            guard editingAvailable, !categoryBusy, let expected = familyClientHandle, familyClientPaths == paths else { return false }
            completionSaving = true; defer { completionSaving = false }
            do {
                let handle = try await Task.detached { try ReviewFamilyClientSession.saveSettings(paths: paths, plan: plan) }.value
                guard familyClientPaths == paths, familyClientHandle?.version == expected.version, root == expected.review else { return true }
                adoptFamilyClientEdit(handle); error = nil; return true
            } catch { self.error = "家庭设置未保存：" + error.localizedDescription; return false }
        }
    }
}

struct HouseholdSettingsDraft: Sendable {
    struct Member: Identifiable, Sendable {
        let id = UUID()
        let memberID: String
        var name: String, active: Bool, exclusionAllowed: Bool
    }
    struct Account: Identifiable, Sendable {
        let id = UUID()
        let accountID: String
        var name: String, ownerID: String?, active: Bool
        let currency: String
    }
    struct Rule: Identifiable, Sendable {
        let id = UUID()
        let ruleID: String
        var platform: String, sourceID: String?, sourceAccountID: String
        var sourceAccountName: String, paymentChannel: String, targetID: String?
        var confirmed: Bool, basis: String

        init(ruleID: String = UUID().uuidString.lowercased(), platform: String = "", sourceID: String? = nil,
             sourceAccountID: String = "", sourceAccountName: String = "", paymentChannel: String = "",
             targetID: String? = nil, confirmed: Bool = false, basis: String = "") {
            self.ruleID = ruleID; self.platform = platform; self.sourceID = sourceID
            self.sourceAccountID = sourceAccountID; self.sourceAccountName = sourceAccountName
            self.paymentChannel = paymentChannel; self.targetID = targetID
            self.confirmed = confirmed; self.basis = basis
        }
        init(_ rule: HouseholdFundingRule) {
            self.init(ruleID: rule.id, platform: rule.selector["platform"] ?? "", sourceID: rule.selector["source_id"],
                sourceAccountID: rule.selector["source_account_id"] ?? "", sourceAccountName: rule.selector["source_account_name"] ?? "",
                paymentChannel: rule.selector["payment_channel"] ?? "", targetID: rule.targetAccountID, confirmed: rule.confirmed, basis: rule.basis)
        }
        var document: [String: Any] {
            var selector = ["platform": platform]
            if let sourceID { selector["source_id"] = sourceID }
            for (key, value) in [("source_account_id", sourceAccountID), ("source_account_name", sourceAccountName), ("payment_channel", paymentChannel)] where !value.isEmpty {
                selector[key] = value
            }
            return ["id": ruleID, "source_selector": selector, "target_account_id": targetID.map { $0 as Any } ?? NSNull(),
                    "confirmed": confirmed, "basis": basis]
        }
    }
    struct SourceOwner: Identifiable, Sendable {
        let id = UUID()
        let source: HouseholdRegisteredSource
        var memberID: String?
        var label: String { source.path + " · " + source.platform + " · " + source.sha256.prefix(8) }
    }
    let baseline: HouseholdEditorBaseline
    var name: String, members: [Member], accounts: [Account]
    var routes: [Rule], aliases: [Rule], sourceOwners: [SourceOwner]

    init(_ baseline: HouseholdSettingsState) { self.init(.workspace(baseline)) }
    init(_ baseline: HouseholdEditorBaseline) {
        self.baseline = baseline
        let settings = baseline.settings
        name = settings.householdName
        let exclusions = Set(settings.exclusionMemberIDs.map { Data($0.utf8) })
        members = settings.members.map { Member(memberID: $0.id, name: $0.displayName,
            active: $0.status == "active", exclusionAllowed: exclusions.contains(Data($0.id.utf8))) }
        accounts = settings.accounts.map { Account(accountID: $0.id, name: $0.displayName,
            ownerID: $0.ownerMemberID, active: $0.status == "active", currency: $0.currency) }
        routes = settings.routes.map(Rule.init); aliases = settings.aliases.map(Rule.init)
        sourceOwners = baseline.sources.map { source in
            SourceOwner(source: source, memberID: settings.sourceOwners.first { Data($0.sourceID.utf8) == Data(source.id.utf8) }?.memberID)
        }
    }

    func prepare() throws -> HouseholdEditorPlan {
        let memberRows = members.map { ["id": $0.memberID, "display_name": $0.name,
            "status": $0.active ? "active" : "inactive"] }
        let accountRows = accounts.map { account -> [String: Any] in
            ["id": account.accountID, "display_name": account.name,
             "owner_member_id": account.ownerID.map { $0 as Any } ?? NSNull(),
             "currency": account.currency, "status": account.active ? "active" : "inactive"]
        }
        let unknown: [String: Any] = ["mode": "needs_review",
            "exclusion_member_ids": members.filter(\.exclusionAllowed).map(\.memberID)]
        // Encode opaque source IDs as raw JSON keys, never Swift dictionary keys.
        let ownerEntries = try sourceOwners.compactMap { owner -> Data? in
            guard let member = owner.memberID else { return nil }
            return try JSONEncoder().encode(owner.source.id) + Data(":".utf8) + JSONEncoder().encode(member)
        }
        let ownerMap = Data("{".utf8) + ownerEntries.enumerated().reduce(into: Data()) { bytes, entry in
            if entry.offset > 0 { bytes.append(Data(",".utf8)) }; bytes.append(entry.element)
        } + Data("}".utf8)
        var profile = try ReleaseCanonicalJSON.replacingObjectMember(raw: baseline.settings.profileData,
            key: "household_name", valueRaw: JSONEncoder().encode(name))
        profile = try ReleaseCanonicalJSON.replacingObjectMember(raw: profile, key: "members",
            valueRaw: JSONSerialization.data(withJSONObject: memberRows))
        var policies = try ReleaseCanonicalJSON.replacingObjectMember(raw: baseline.settings.policiesData,
            key: "accounts", valueRaw: JSONSerialization.data(withJSONObject: accountRows))
        policies = try ReleaseCanonicalJSON.replacingObjectMember(raw: policies, key: "unknown_account_policy",
            valueRaw: JSONSerialization.data(withJSONObject: unknown))
        for (key, rules) in [("routes", routes), ("aliases", aliases)] {
            policies = try ReleaseCanonicalJSON.replacingObjectMember(raw: policies, key: key,
                valueRaw: JSONSerialization.data(withJSONObject: rules.map(\.document)))
        }
        policies = try ReleaseCanonicalJSON.replacingObjectMember(raw: policies, key: "source_owners", valueRaw: ownerMap)
        return try baseline.prepareEdit(profileData: profile, policiesData: policies)
    }

    func preparePreview() throws -> (HouseholdEditorPlan, HouseholdSettingsImpact) {
        let plan = try prepare()
        return (plan, try baseline.preview(plan))
    }
}

struct HouseholdSettingsView: View {
    @Bindable var store: FinancialStore
    @State private var draft: HouseholdSettingsDraft?
    @State private var preview: HouseholdEditorPlan?
    @State private var impact: HouseholdSettingsImpact?
    @State private var previewing = false
    @State private var message = ""
    @State private var saving = false

    var body: some View {
        Form {
            if let draft {
                settingsForm(draft)
            } else {
                Section("家庭设置") { Text(message.isEmpty ? "正在读取家庭设置…" : message) }
            }
        }
        .disabled(saving || previewing)
        .navigationTitle("家庭设置")
        .task(id: store.workspacePaths?.workspace.path ?? store.familyClientPaths?.workspace.path) { reload() }
        .confirmationDialog("保存家庭设置？", isPresented: Binding(get: { preview != nil },
            set: { if !$0 { preview = nil } }), titleVisibility: .visible) {
            Button("确认保存") {
                guard let plan = preview else { return }
                preview = nil; saving = true
                Task {
                    let saved = await store.persistHouseholdSettings(plan)
                    saving = false
                    if saved { reload(); message = "家庭设置已保存。" }
                    else { message = store.error ?? "设置未保存，请重新读取后重试。" }
                }
            }
            Button("取消", role: .cancel) { preview = nil }
        } message: {
            if let settings = preview?.candidate {
                Text(previewMessage(settings))
            }
        }
    }

    @ViewBuilder private func settingsForm(_ value: HouseholdSettingsDraft) -> some View {
        Section("家庭") {
            TextField("家庭名称", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 }))
        }
        Section("成员") {
            ForEach(value.members.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    TextField("显示名称", text: Binding(get: { draft?.members[index].name ?? "" }, set: { draft?.members[index].name = $0 }))
                    Toggle("启用", isOn: Binding(get: { draft?.members[index].active ?? false }, set: { draft?.members[index].active = $0 }))
                    Toggle("允许排除该成员的未知账户交易", isOn: Binding(get: { draft?.members[index].exclusionAllowed ?? false }, set: { draft?.members[index].exclusionAllowed = $0 }))
                }
            }
            Button("添加成员") {
                draft?.members.append(.init(memberID: UUID().uuidString.lowercased(), name: "", active: true, exclusionAllowed: false))
            }
            Text("停用会保留历史身份与交易；未知交易不会自动归属给新成员。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("账户") {
            ForEach(value.accounts.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    TextField("账户名称", text: Binding(get: { draft?.accounts[index].name ?? "" }, set: { draft?.accounts[index].name = $0 }))
                    Picker("归属成员", selection: Binding<Data>(get: {
                        Data((draft?.accounts[index].ownerID ?? "").utf8)
                    }, set: { key in
                        draft?.accounts[index].ownerID = draft?.members.first { Data($0.memberID.utf8) == key }?.memberID
                    })) {
                        Text("未确认").tag(Data())
                        ForEach(value.members) { member in
                            Text(member.name.isEmpty ? "未命名成员" : member.name).tag(Data(member.memberID.utf8))
                        }
                    }
                    Text("币种：\(value.accounts[index].currency)")
                    Toggle("启用", isOn: Binding(get: { draft?.accounts[index].active ?? false }, set: { draft?.accounts[index].active = $0 }))
                }
            }
            Button("添加账户") {
                draft?.accounts.append(.init(accountID: UUID().uuidString.lowercased(), name: "", ownerID: nil, active: true, currency: "CNY"))
            }
            Text("账户归属不会认领交易消费者。当前支持人民币账户。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("来源归属") {
            ForEach(value.sourceOwners.indices, id: \.self) { index in
                Picker(value.sourceOwners[index].label, selection: Binding<Data>(get: {
                    Data((draft?.sourceOwners[index].memberID ?? "").utf8)
                }, set: { key in
                    draft?.sourceOwners[index].memberID = draft?.members.first { Data($0.memberID.utf8) == key }?.memberID
                })) {
                    Text("未确认").tag(Data())
                    ForEach(value.members) { member in Text(member.name.isEmpty ? "未命名成员" : member.name).tag(Data(member.memberID.utf8)) }
                }
            }
            Text(value.sourceOwners.isEmpty ? "导入来源后可设置归属。" : "只适用于该已保留来源原件，不从文件名推断成员。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        ruleSection("资金账户映射", alias: false, value: value)
        ruleSection("通道别名", alias: true, value: value)
        Section {
            Button("预览并保存") {
                guard let snapshot = draft else { return }
                previewing = true; message = "正在比较当前已解析证据…"
                Task {
                    do {
                        let result = try await Task.detached { try snapshot.preparePreview() }.value
                        guard snapshot.baseline.matches(store) else { throw WorkspaceError.stalePointer }
                        impact = result.1; preview = result.0; message = ""
                    } catch { message = "请检查设置：" + error.localizedDescription }
                    previewing = false
                }
            }
            .disabled(saving || !store.editingAvailable)
            Button("重新读取") { reload() }.disabled(saving)
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
        }
        .disabled(saving)
    }

    @ViewBuilder private func ruleSection(_ title: String, alias: Bool, value: HouseholdSettingsDraft) -> some View {
        Section(title) {
            let rules = alias ? value.aliases : value.routes
            ForEach(rules) { rule in
                ruleForm(ruleBinding(rule, alias: alias), value: value, alias: alias)
                Button("移除这条规则", role: .destructive) {
                    if alias { draft?.aliases.removeAll { $0.id == rule.id } } else { draft?.routes.removeAll { $0.id == rule.id } }
                }
            }
            Button(alias ? "添加通道别名" : "添加账户映射") {
                if alias { draft?.aliases.append(.init()) } else { draft?.routes.append(.init()) }
            }
            Text(alias ? "映射规则优先；别名可将通道明确标为非资金账户。" : "至少填写一个账号、账户名称或支付通道条件；多个条件须同时匹配。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func ruleBinding(_ original: HouseholdSettingsDraft.Rule, alias: Bool) -> Binding<HouseholdSettingsDraft.Rule> {
        Binding(get: {
            (alias ? draft?.aliases : draft?.routes)?.first { $0.id == original.id } ?? original
        }, set: { rule in
            if alias, let index = draft?.aliases.firstIndex(where: { $0.id == original.id }) { draft?.aliases[index] = rule }
            if !alias, let index = draft?.routes.firstIndex(where: { $0.id == original.id }) { draft?.routes[index] = rule }
        })
    }

    @ViewBuilder private func ruleForm(_ rule: Binding<HouseholdSettingsDraft.Rule>, value: HouseholdSettingsDraft, alias: Bool) -> some View {
        VStack(alignment: .leading) {
            Picker("平台", selection: rule.platform) {
                Text("请选择").tag("")
                Text("支付宝").tag("alipay"); Text("微信").tag("wechat"); Text("银行").tag("bank")
                Text("云闪付").tag("unionpay"); Text("美团").tag("meituan")
                if !["", "alipay", "wechat", "bank", "unionpay", "meituan"].contains(rule.wrappedValue.platform) {
                    Text(rule.wrappedValue.platform).tag(rule.wrappedValue.platform)
                }
            }
            Picker("适用来源", selection: Binding<Data>(get: { Data((rule.wrappedValue.sourceID ?? "").utf8) }, set: { key in
                rule.wrappedValue.sourceID = value.sourceOwners.first { Data($0.source.id.utf8) == key }?.source.id
            })) {
                Text("全部来源（同平台）").tag(Data())
                ForEach(value.sourceOwners) { owner in Text(owner.label).tag(Data(owner.source.id.utf8)) }
            }
            TextField("来源账号（完整标识）", text: rule.sourceAccountID)
            TextField("来源账户名称（按账单原文）", text: rule.sourceAccountName)
            TextField("支付通道（按账单原文）", text: rule.paymentChannel)
            Picker("目标账户", selection: Binding<Data>(get: { Data((rule.wrappedValue.targetID ?? "").utf8) }, set: { key in
                rule.wrappedValue.targetID = value.accounts.first { Data($0.accountID.utf8) == key }?.accountID
            })) {
                Text(alias ? "非资金通道" : "请选择").tag(Data())
                ForEach(value.accounts) { account in Text(account.name.isEmpty ? "未命名账户" : account.name).tag(Data(account.accountID.utf8)) }
            }
            TextField("确认依据", text: rule.basis)
            Toggle("已核对并启用", isOn: rule.confirmed)
        }
    }

    private func previewMessage(_ settings: HouseholdSettings) -> String {
        var text = "家庭：\(settings.householdName.isEmpty ? "未命名" : settings.householdName)；成员 \(settings.members.count) 位，账户 \(settings.accounts.count) 个。"
        if let impact {
            text += "与当前设置相比，\(impact.evidenceCount) 条已解析证据中，资金匹配变化 \(impact.changedFundingCount) 条，来源归属变化 \(impact.changedSourceOwnerCount) 条。新设置下匹配 \(impact.resolvedCount) 条、待核 \(impact.needsReviewCount) 条（含规则冲突 \(impact.conflictingCount) 条）、非资金通道 \(impact.nonFundingCount) 条。"
        }
        return text + "这是规则比较，现有交易及人工复核不会自动重算。"
    }

    private func reload() {
        preview = nil; impact = nil
        do {
            if let paths = store.familyClientPaths, let handle = store.familyClientHandle { draft = HouseholdSettingsDraft(.client(paths, handle)) }
            else { draft = HouseholdSettingsDraft(try store.readHouseholdSettings()) }
            message = ""
        }
        catch { draft = nil; message = "家庭设置暂不可用：" + error.localizedDescription }
    }
}
#endif
