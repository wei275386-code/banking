import SwiftUI
import Observation
import UniformTypeIdentifiers
import PaymentImageCore
import Darwin

struct ParameterExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
private final class SyncPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q }()
    init(_ url: URL) { presentedItemURL = url }
    func presentedItemDidChange() { NotificationCenter.default.post(name: .init("ReviewProviderChanged"), object: nil) }
    func presentedSubitemDidChange(at url: URL) { presentedItemDidChange() }
    func presentedSubitemDidAppear(at url: URL) { presentedItemDidChange() }
}
@Observable @MainActor final class MobileServices {
    static let shared = MobileServices()
    nonisolated private static var qaArguments: [String] {
#if FAMILY_REVIEW_QA
        CommandLine.arguments
#else
        []
#endif
    }
    var dataSource = MobileReviewDataSource.awaitingCheckpoint
    var hasLocalReview: Bool { dataSource.localReview != nil }
    var hasRefreshTarget: Bool { familyConnection.map { !$0.requiresReconnection } ?? false }
    var hasFamilyClientBackup: Bool { familyHandle != nil }
    var hasCheckpointConnection: Bool {
        familyConnection != nil || FileManager.default.fileExists(atPath: checkpointWorkspaceURL.appendingPathComponent("device/family-connection.json").path)
    }
    let checkpointConnectionNotice = "请在 Mac 建立家庭资料，再选择 Mac 发布的家庭同步目录。"
    var root: URL
    var remote: URL?
    var syncing = false
    var status = "本机数据可离线使用"
    var connectionLabel = "尚未连接 iCloud Drive"
    var exportDocument: Data?
    var parameterPicker = false
    var conflicts = [String]()
    var conflictOptions = [String: [String]]()
    var pendingReviews = Set<String>()
    var requests = [String: String]()
    private let storageLocations: AppStorageLocations
    private let preferences: UserDefaults
    private let fixtureStorageName: String?
    private var checkpointWorkspaceURL: URL
    private var familyConnection: ReviewFamilyClientConnection?
    private var familyHandle: ReviewFamilyClientHandle?
    private var presenter: SyncPresenter?
    private var importDates = [String: Date]()
    private init() {
        let domain = AppStorageLocations.launchDomain
        let qa = domain != .production
        let locations: AppStorageLocations
        do { locations = try AppStorageLocations.system(domain: domain) }
        catch { preconditionFailure("系统应用资料目录无法定位，未创建或修改任何账本。") }
        storageLocations = locations
        do { preferences = try locations.preferences() }
        catch { preconditionFailure("隔离设置域无法打开，未回退到生产设置。") }
        var name: String?
        if qa && Self.qaArguments.contains("--qa-isolated") && Self.qaArguments.contains("--qa-amount-sort") {
            name = "FamilyReviewAmountSortQA"
        }
        fixtureStorageName = name
        let initialRoot: URL
        do {
            let base = locations.support.appendingPathComponent("Mobile/" + (name ?? (qa ? "FamilyReviewQA" : "FamilyReview")))
            if name == nil, let identity = preferences.string(forKey: "review.imported.workspace") {
                initialRoot = try MobileStoragePlan.importedReviewURL(locations: locations, identity: identity)
            } else { initialRoot = base }
        } catch { preconditionFailure("本机资料位置无效，未创建或修改任何账本。") }
        root = initialRoot
        checkpointWorkspaceURL = initialRoot.appendingPathComponent("Client")
    }
    private func requireStorageReady() throws {
        if fixtureStorageName == nil, let identity = preferences.string(forKey: "review.imported.workspace") {
            try MobileStoragePlan.requireSelectedImportedStorage(locations: storageLocations, identity: identity)
        }
    }
#if FAMILY_REVIEW_QA
    /// Versioned from-zero schema fixture. No Seed, bundle report, current
    /// household or provider is read. Scenario transforms use only this template.
    nonisolated private static func syntheticQABaseline() throws -> (report: [String: Any], payment: [String: Any]) {
        let raw = Data(#"""
{
  "report": {
    "dataset_id": "synthetic-mobile-qa-v1",
    "cutoff": "2026-09-13",
    "records": [
      {
        "id": "qa-template-record",
        "date": "2026-09-01",
        "title": "Synthetic purchase",
        "status": "Synthetic",
        "account_views": [],
        "evidence_keys": [],
        "components": [
          {
            "id": "qa-template-item",
            "title": "Synthetic purchase",
            "gross_cents": 100,
            "refund_cents": 0,
            "net_cents": 100,
            "primary": "日常消费",
            "secondary": "咖啡茶饮",
            "classification_basis": "From-zero QA fixture",
            "included": true,
            "reason": "",
            "recurrence": "one_time",
            "tags": [],
            "classification_keys": [
              "qa-template-item"
            ]
          }
        ],
        "events": [],
        "user_id": "synthetic-ui-member",
        "user_relation": "self",
        "non_consumption": false,
        "unallocated_credit_cents": 0,
        "payment_accounts": [],
        "payment_account_status": "unresolved"
      }
    ],
    "taxonomy": [
      {
        "primary": "日常消费",
        "secondaries": [
          "咖啡茶饮",
          "餐饮"
        ]
      },
      {
        "primary": "生产力工具",
        "secondaries": [
          "设备"
        ]
      },
      {
        "primary": "待分类",
        "secondaries": [
          "待分类"
        ]
      }
    ],
    "fire_parameters": {
      "baseYear": 2026,
      "birthYear": 1990,
      "targetAge": 55,
      "currentFireAssets": 100000,
      "afterTaxSalary": 200000,
      "annualContribution": 120000,
      "expenseModes": {
        "normal": 70000
      },
      "annualHardCap": 100000,
      "expenseBreakdown": {},
      "buckets": {
        "safetyBucket": 0,
        "parentMedicalBucket": 0,
        "elderCareEnabled": false,
        "elderCareBucket": 0,
        "otherBuckets": 0,
        "includeBuckets": false
      },
      "investing": {
        "withdrawalRate": 0.035,
        "annualReturn": 0.06,
        "inflation": 0.025,
        "maxDrawdown": 0.3
      },
      "branches": {
        "housing": {
          "enabled": false,
          "year": 2026,
          "totalPrice": 0,
          "downPaymentRatio": 0,
          "loanRate": 0,
          "loanYears": 0,
          "fees": 0,
          "renovation": 0,
          "annualMaintenance": 0,
          "reduceRent": false,
          "minLiquidAssets": 0,
          "ownerHomeCountsAsFireAsset": false
        },
        "children": {
          "enabled": false,
          "count": 0,
          "birthYear": 2028,
          "annualCost": 0,
          "educationBucket": 0,
          "incomeImpact": 0
        }
      }
    },
    "coverage_note": "From-zero QA fixture; no household source inputs.",
    "coverage_complete": true
  },
  "payment": {
    "dataset_id": "synthetic-mobile-qa-v1",
    "backfill_cutoff_date": "2026-09-13",
    "review_summary": {},
    "clusters": [],
    "bank_records": [
      {
        "id": 9901,
        "date": "2026-09-01",
        "description": "Synthetic debit",
        "amount_cents": 100,
        "is_credit": 0,
        "currency": "CNY",
        "source_evidence": {
          "kind": "synthetic"
        }
      }
    ],
    "candidates": [],
    "ocr_probe": {
      "samples": []
    }
  }
}
"""#.utf8)
        let documents = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        return (documents["report"] as! [String: Any], documents["payment"] as! [String: Any])
    }
    // Deterministic UI QA only; no path or launch flag can target the live ledger.
    nonisolated private static func prepareAmountSortQA(root: URL) throws {
        guard Self.qaArguments.contains("--qa-isolated"), Self.qaArguments.contains("--qa-amount-sort"),
              root.lastPathComponent == "FamilyReviewAmountSortQA" else { throw CocoaError(.fileWriteNoPermission) }
        let fm = FileManager.default
        let marker = root.appendingPathComponent("qa-fixture-provenance.json")
        let provenance = Data(#"{"kind":"synthetic","generator":"MobileServices.syntheticQABaseline","scenario":"amount-sort-v1"}"#.utf8)
        if fm.fileExists(atPath: root.path) {
            guard (try? Data(contentsOf: marker)) == provenance else {
                throw WorkspaceError.invalid("旧 QA 资料没有合成来源标记，已保留；请使用新的隔离 QA 容器。")
            }
            if Self.qaArguments.contains("--qa-reset-amount-sort") { try fm.removeItem(at: root) }
            else if fm.fileExists(atPath: root.appendingPathComponent("financial-review.json").path) { return }
        }
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        try provenance.write(to: marker, options: .atomic)
        let baseline = try syntheticQABaseline()
        var report = baseline.report
        let template = (report["records"] as! [[String:Any]]).first { !($0["components"] as! [Any]).isEmpty }!
        let originalComponent = (template["components"] as! [[String:Any]])[0]
        func component(_ id: String, _ title: String, _ cents: Int, primary: String = "日常消费", secondary: String = "咖啡茶饮", pending: String = "") -> [String:Any] {
            var c = originalComponent
            c["id"] = id; c["title"] = title; c["net_cents"] = cents; c["gross_cents"] = cents; c["refund_cents"] = 0
            c["primary"] = primary; c["secondary"] = secondary; c["classification_keys"] = [id]
            c["included"] = pending.isEmpty; c["reason"] = pending; c["recurrence"] = "one_time"; c["tags"] = []
            c["classification_basis"] = "隔离金额排序验收"; c.removeValue(forKey:"completion_confirmation"); c.removeValue(forKey:"reimbursement_cents")
            return c
        }
        func record(_ id: String, _ title: String, _ components: [[String:Any]], date: String = "2026-09-01", credit: Int = 0) -> [String:Any] {
            var r = template
            r["id"] = id; r["title"] = title; r["date"] = date; r["components"] = components
            r["status"] = "隔离排序样本"; r["events"] = []; r["evidence_keys"] = ["bank:9901","bank:9902"]
            r["account_views"] = ["QA"]; r["payment_accounts"] = ["QA"]; r["payment_account_status"] = "identified"
            r["user_relation"] = "self"; r["user_id"] = "QA"; r["non_consumption"] = false
            r["unallocated_credit_cents"] = credit; r["excluded_from_completion_and_statistics"] = false
            for key in ["fact_review_status","trace_sources","payment_events","bank_settlement_group","account_identity_before_consolidation"] { r.removeValue(forKey:key) }
            return r
        }
        var rows = [record("sort-multi","排序：组合购买 910元",[component("sort-multi-small","排序：组合咖啡 10元",1000),component("sort-multi-large","排序：组合设备 900元",90000,primary:"生产力工具",secondary:"设备")]),
            record("sort-credit","排序：退款来源 700元",[],credit:70000),
            record("sort-high","排序：待分类 500元",[component("sort-high","排序：待分类 500元",50000,primary:"待分类",secondary:"待分类")]),
            record("sort-single","排序：独立咖啡 300元",[component("sort-single","排序：独立咖啡 300元",30000)]),
            record("sort-tie-a","排序：同额较早 200元",[component("sort-tie-a","排序：同额较早 200元",20000)]),
            record("sort-tie-b","排序：同额较新 200元",[component("sort-tie-b","排序：同额较新 200元",20000)],date:"2026-09-02")]
        for index in 0..<32 {
            let id = String(format:"sort-page-%02d",index), cents = (32-index)*100
            rows.append(record(id,"排序：分页样本 " + String(32-index) + "元",[component(id,"排序：分页样本 " + String(32-index) + "元",cents)]))
        }
        rows.append(record("sort-pending","排序：待核事实 0.50元",[component("sort-pending","排序：待核事实 0.50元",50,pending:"日期待核")]))
        var zero = component("sort-zero","排序：全额退款零元",0,primary:"待分类",secondary:"待分类"); zero["gross_cents"] = 100; zero["refund_cents"] = 100
        rows.append(record("sort-zero","排序：全额退款零元",[zero]))
        rows.append(record("sort-unknown","排序：金额未知",[component("sort-unknown","排序：金额未知",0,primary:"待分类",secondary:"待分类",pending:"支付金额待确定")]))
        report["records"] = Array(rows.reversed()); report["dataset_id"] = "amount-sort-isolated-qa"; report["cutoff"] = "2026-09-13"
        for key in ["source_record_sets","source_record_set_candidates","source_record_set_unresolved","refund_candidates","video_materials"] { report.removeValue(forKey:key) }
        try ReviewSyncIO.json(report).write(to:root.appendingPathComponent("financial-review.json"),options:.atomic)
        var payment = baseline.payment
        let bankTemplate = (payment["bank_records"] as! [[String:Any]])[0]
        payment["bank_records"] = [(9901,100,"隔离排序证据 1元"),(9902,90000,"隔离排序证据 900元"),(9903,50000,"隔离排序证据 500元")].map { id,amount,title in
            var b = bankTemplate; b["id"] = id; b["amount_cents"] = amount; b["description"] = title; b["date"] = "2026-09-01"; return b
        }
        payment["clusters"] = []; payment["ocr_probe"] = NSNull(); payment["dataset_id"] = "amount-sort-isolated-qa"
        payment["candidates"] = [("qa-low",["bank:9901"]),("qa-high",["bank:9902","bank:9903"])].map { id,ids in
            ["candidate_id":id,"kind":"QA","record_ids":ids,"bank_ids":[],"association_status":"隔离排序候选 " + id,"review_required":true] as [String:Any]
        }
        try ReviewSyncIO.json(payment).write(to:root.appendingPathComponent("payment-evidence.json"),options:.atomic)
    }
#endif
    @discardableResult func bootstrap() async throws -> MobileReviewDataSource {
        try requireStorageReady()
#if FAMILY_REVIEW_QA
        if fixtureStorageName != nil {
            let source = try await Task.detached { [root] in
                try Self.prepareAmountSortQA(root: root)
                return try MobileBootstrapPolicy.source(at: root)
            }.value
            dataSource = source; status = "隔离合成场景"; connectionLabel = "未连接 provider"
            return source
        }
#endif
        let checkpointPaths = try WorkspacePaths(workspace: checkpointWorkspaceURL)
        if let connection = try await ReviewSyncDetached.run({ try ReviewFamilyClientSession.readConnection(paths: checkpointPaths) }) {
            familyConnection = connection
            familyHandle = try await ReviewSyncDetached.run { try ReviewFamilyClientSession.read(paths: checkpointPaths) }
            if let handle = familyHandle { root = handle.review; dataSource = .localCopy(root) }
            else { dataSource = .awaitingCheckpoint }
            await resumeFamilyConnection(connection)
            return dataSource
        }
        let source = try await Task.detached { [root] in try MobileBootstrapPolicy.source(at: root) }.value
        dataSource = source
        status = hasLocalReview ? "本机复盘副本可离线使用。" : "请选择 Mac 已发布的家庭同步目录，或打开已有复盘副本。"
        connectionLabel = "尚未连接家庭资料"
        return source
    }
    private func installPresenter(_ url: URL) {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        let next = SyncPresenter(url); NSFileCoordinator.addFilePresenter(next); presenter = next
    }
    func bindFamilyClient(to finance: FinancialStore) {
        guard let handle = familyHandle, let paths = try? WorkspacePaths(workspace: checkpointWorkspaceURL) else { return }
        finance.familyClientPaths = paths; finance.familyClientHandle = handle; finance.pinnedClientReview = handle.review
        finance.workspacePaths = nil; finance.workspaceState = nil; finance.workspaceWritable = true
        finance.workspaceProcessorEligible = false; finance.workspaceRuntimeReady = false; finance.workspaceRuntimeFailure = nil
    }
    private func resumeFamilyConnection(_ connection: ReviewFamilyClientConnection) async {
        if connection.requiresReconnection {
            remote = nil; connectionLabel = "已恢复的本机家庭副本"; status = "可离线使用；同步前请重新选择原同步目录。"; return
        }
        do {
            var selected = connection.remote
            if let bookmark = connection.bookmark {
                var stale = false
                selected = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale, selected.path == connection.remote.path else { throw WorkspaceError.invalid("请重新选择原同步目录。") }
            }
            _ = selected.startAccessingSecurityScopedResource(); remote = selected
            connectionLabel = selected.lastPathComponent; installPresenter(selected)
            status = "家庭副本可离线使用"
        } catch { status = "本机家庭副本已保留；请重新选择原同步目录。" }
    }
    private func refreshFamily(finance: FinancialStore, evidence: BrowserStore) async {
        guard !syncing, localReviewIsIdle(finance, evidence), finance.completion.drafts.isEmpty, !finance.hasUnsavedParameters else { return }
        let paths: WorkspacePaths
        do { paths = try WorkspacePaths(workspace: checkpointWorkspaceURL) } catch { status = error.localizedDescription; return }
        let expectedSelection = familyConnection?.selection
        syncing = true; defer { syncing = false }
        do {
            let prepared = try await Task.detached { () async throws -> ReviewFamilyClientRefreshPreparation in
                if try ReviewFamilyClientSession.read(paths: paths) != nil { try await ReviewFamilyClientSession.transfer(paths: paths) }
                return try ReviewFamilyClientSession.prepareRefresh(paths: paths)
            }.value
            guard paths.workspace == checkpointWorkspaceURL, expectedSelection == familyConnection?.selection else { return }
            guard localReviewIsIdle(finance, evidence), finance.completion.drafts.isEmpty, !finance.hasUnsavedParameters else { status = "快照已准备，请先保存或还原当前草稿。"; return }
            finance.editorPauseReason = "正在更新家庭副本"
            defer { finance.editorPauseReason = nil }
            let handle: ReviewFamilyClientHandle?
            switch prepared {
            case .current: handle = try await ReviewSyncDetached.run { try ReviewFamilyClientSession.read(paths: paths) }
            case .waiting: status = "等待完整家庭快照；已保存资料与修改仍保留。"; return
            case .ready(let value): handle = try await ReviewSyncDetached.run { try ReviewFamilyClientSession.commitRefresh(paths: paths, prepared: value) }
            }
            guard let handle, paths.workspace == checkpointWorkspaceURL, expectedSelection == familyConnection?.selection else { return }
            if finance.familyClientHandle?.version != handle.version || finance.root != handle.review {
                try await finance.loadFamilyClient(paths: paths, handle: handle, selectionIsCurrent: { self.checkpointWorkspaceURL == paths.workspace && self.familyConnection?.selection == expectedSelection })
                await evidence.load(handle.review, finance: finance.report)
            }
            familyHandle = handle; root = handle.review; dataSource = .localCopy(root)
            let requestTransport = try ReviewFamilyClientSession.requestTransport(paths: paths, expected: handle)
            requests = try await requestTransport.localStatuses()
            // Settings conflicts wait before selection; any retained ordinary
            // The current conflict remains visible for explicit resolution.
            conflicts = handle.conflicts.keys.sorted(); conflictOptions = handle.conflicts
            status = conflicts.isEmpty ? "已同步；本机修改会保留至真实纳入家庭快照。" : "并发修改已保留，等待字段版本核对。"
        } catch { status = "等待同步：" + error.localizedDescription }
    }
    func connect(_ directory: URL, finance: FinancialStore, evidence: BrowserStore) async {
        do { try requireStorageReady() } catch { status = error.localizedDescription; return }
        guard !syncing, localReviewIsIdle(finance, evidence), finance.completion.drafts.isEmpty, !finance.hasUnsavedParameters else { return }
        syncing = true
        let scoped = directory.startAccessingSecurityScopedResource()
        do {
            let paths = try WorkspacePaths(workspace: checkpointWorkspaceURL)
            let bookmark = try directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let connection = try await ReviewSyncDetached.run { try ReviewFamilyClientSession.connect(paths: paths, remote: directory, bookmark: bookmark) }
            familyConnection = connection
            remote?.stopAccessingSecurityScopedResource(); remote = directory
            connectionLabel = directory.lastPathComponent; installPresenter(directory)
            syncing = false
            await refreshFamily(finance: finance, evidence: evidence)
        } catch {
            if scoped { directory.stopAccessingSecurityScopedResource() }
            syncing = false; status = "家庭连接未完成：" + error.localizedDescription
        }
    }
    func refresh(finance: FinancialStore, evidence: BrowserStore) async {
        do { try requireStorageReady() } catch { status = error.localizedDescription; return }
        guard familyConnection != nil else { return }
        await refreshFamily(finance: finance, evidence: evidence)
    }
    private func localReviewIsIdle(_ finance: FinancialStore, _ evidence: BrowserStore) -> Bool {
        !finance.loading && !finance.categorySaving && !finance.completionSaving && !finance.completion.persisting && !finance.importing && !evidence.loading
    }
    func enqueue(kind: String, payload: Data, files: [URL]) async throws {
        if let handle = familyHandle {
            let paths = try WorkspacePaths(workspace: checkpointWorkspaceURL)
            let transport = try ReviewFamilyClientSession.requestTransport(paths: paths, expected: handle)
            let author = try ReviewFamilyClientSession.requestDeviceID(paths: paths)
            let scopes = files.filter { $0.startAccessingSecurityScopedResource() }
            defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
            let request: ReviewFamilyRequest
            switch kind {
            case "review": request = try await transport.enqueueReview(payload: payload, authorDeviceID: author)
            case "import": request = try await transport.enqueueImport(files: files, authorDeviceID: author)
            default: throw WorkspaceError.invalid("processing request kind")
            }
            requests = try await transport.localStatuses()
            if kind == "import" { importDates[request.id] = ISO8601DateFormatter().date(from: request.createdAtRaw) ?? Date() }
            return
        }
        throw WorkspaceError.invalid("请先连接当前家庭副本，再发送处理请求。")
    }
    func ensure(_ reference: EvidenceReference) async throws {
        for asset in [reference.raw, reference.image, reference.ocr_result].compactMap({ $0 }) {
            let file: URL
            if let handle = familyHandle {
                let paths = try WorkspacePaths(workspace: checkpointWorkspaceURL)
                file = try await ReviewSyncDetached.run {
                    try ReviewFamilyClientSession.material(paths: paths, expected: handle, path: asset.path, hash: asset.sha256)
                }
            } else { file = try ReviewDataSource.assetURL(asset.path, root: root) }
            guard try await ReviewSyncDetached.run({ try ReviewSyncIO.digestFile(file) == asset.sha256 }) else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
    func backupFamilyClient(to parent: URL, finance: FinancialStore) async {
        guard familyHandle != nil, !syncing, !finance.loading, !finance.importing else { return }
        guard finance.completion.drafts.isEmpty, !finance.hasUnsavedParameters else { finance.error = "请先保存或还原当前草稿，再备份本机副本。"; return }
        finance.importing = true
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { finance.importing = false; if scoped { parent.stopAccessingSecurityScopedResource() } }
        do {
            let paths = try WorkspacePaths(workspace: checkpointWorkspaceURL)
            let destination = parent.appendingPathComponent("家庭副本备份-" + UUID().uuidString.lowercased())
            try await ReviewSyncDetached.run { try ReviewFamilyClientSession.exportSelectedBackup(paths: paths, destination: destination) }
            status = "本机副本及未同步修改已保存到：" + destination.lastPathComponent
        } catch { finance.error = error.localizedDescription }
    }
    func restoreFamilyClient(_ package: URL, finance: FinancialStore, evidence: BrowserStore) async {
        guard !hasCheckpointConnection, !syncing, !finance.loading, !finance.importing, !finance.completionSaving else { return }
        finance.importing = true
        let scoped = package.startAccessingSecurityScopedResource()
        defer { finance.importing = false; if scoped { package.stopAccessingSecurityScopedResource() } }
        do {
            guard fixtureStorageName == nil else { throw WorkspaceError.invalid("请先完成本机资料位置恢复。") }
            let identity = ReviewSyncIO.digest(Data(UUID().uuidString.utf8))
            let container = try MobileStoragePlan.importedReviewURL(locations: storageLocations, identity: identity)
            let paths = try WorkspacePaths(workspace: container.appendingPathComponent("Client"))
            let handle: ReviewFamilyClientHandle
            do {
                handle = try await ReviewSyncDetached.run { try ReviewFamilyClientSession.restoreSelectedBackup(package: package, destination: paths.workspace) }
            } catch {
                // This UUID-owned empty container was never selected or reused.
                if FileManager.default.fileExists(atPath: container.path),
                   (try? FileManager.default.contentsOfDirectory(atPath: container.path).isEmpty) == true { try? FileManager.default.removeItem(at: container) }
                throw error
            }
            let connection = try ReviewFamilyClientSession.readConnection(paths: paths)
            guard let connection else { throw WorkspaceError.invalid("恢复的家庭连接缺失") }
            remote?.stopAccessingSecurityScopedResource(); remote = nil
            if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }; presenter = nil
            checkpointWorkspaceURL = paths.workspace; familyHandle = handle; familyConnection = connection
            root = handle.review; dataSource = .localCopy(root)
            preferences.set(identity, forKey: "review.imported.workspace")
            requests = [:]; pendingReviews = []; conflicts = handle.conflicts.keys.sorted(); conflictOptions = handle.conflicts
            bindFamilyClient(to: finance)
            await finance.load(root); if finance.report != nil { await evidence.load(root, finance: finance.report) }
            await resumeFamilyConnection(connection)
        } catch { finance.error = error.localizedDescription }
    }
    func importDataset(_ directory: URL, finance: FinancialStore, evidence: BrowserStore) async {
        do { try requireStorageReady() } catch { finance.error = error.localizedDescription; return }
        guard !hasCheckpointConnection else { finance.error = "已连接家庭资料，请先保留当前副本后再打开其他资料。"; return }
        guard !syncing, !finance.loading, !finance.importing, !finance.completionSaving else { return }
        finance.importing = true
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() }; finance.importing = false }
        do {
            let imported = try await Task.detached { [locations = storageLocations] in
                let fm = FileManager.default
                let financial = try ReviewSyncIO.read(directory.appendingPathComponent("financial-review.json"))
                let payment = try ReviewSyncIO.read(directory.appendingPathComponent("payment-evidence.json"))
                _ = try JSONDecoder().decode(FinancialReport.self, from: financial)
                _ = try JSONDecoder().decode(Report.self, from: payment)
                let identity = ReviewSyncIO.digest(financial + payment)
                let target = try MobileStoragePlan.importedReviewURL(locations: locations, identity: identity)
                let stage = target.deletingLastPathComponent().appendingPathComponent(".import-" + UUID().uuidString)
                try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: stage) }
                var assets = [String: String]()
                func collect(_ object: Any) {
                    if let value = object as? [String: Any] {
                        if let path = value["path"] as? String, let hash = value["sha256"] as? String { assets[path] = hash }
                        for child in value.values { collect(child) }
                    } else if let values = object as? [Any] { for child in values { collect(child) } }
                }
                collect(try JSONSerialization.jsonObject(with: financial)); collect(try JSONSerialization.jsonObject(with: payment))
                for (path, hash) in assets {
                    let source = try EvidencePath.resolve(path, root: directory)
                    let destination = try EvidencePath.resolve(path, root: stage)
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try ReviewSyncIO.copyImmutable(source, at: destination, hash: hash)
                }
                try financial.write(to: stage.appendingPathComponent("financial-review.json")); try payment.write(to: stage.appendingPathComponent("payment-evidence.json"))
                for name in ["review-overrides.json", "fire-parameters-user.json", "completion-workflow.json", "import-inventory.json", "category-catalog.json"] {
                    let source = directory.appendingPathComponent(name)
                    if fm.fileExists(atPath: source.path) {
                        let bytes = try ReviewSyncIO.read(source)
                        if name == "category-catalog.json" { _ = try JSONDecoder().decode(CategoryCatalog.self, from: bytes).validated() }
                        try bytes.write(to: stage.appendingPathComponent(name))
                    }
                }
                if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: stage, to: target) }
                return (identity, target)
            }.value
            remote?.stopAccessingSecurityScopedResource(); remote = nil
            if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }; presenter = nil
            familyConnection = nil; familyHandle = nil; finance.familyClientHandle = nil; finance.familyClientPaths = nil; finance.pinnedClientReview = nil
            root = imported.1; dataSource = .localCopy(root)
            checkpointWorkspaceURL = root.appendingPathComponent("Client")
            if fixtureStorageName == nil {
                preferences.set(imported.0, forKey: "review.imported.workspace")
            }
            requests = [:]; importDates = [:]; pendingReviews = []; conflicts = []; conflictOptions = [:]
            finance.importState = ""
            connectionLabel = "独立复盘，尚未连接同步目录"; status = "原复盘数据已保留。当前资料已复制到本机。"
            await finance.load(root); await evidence.load(root, finance: finance.report)
        } catch { finance.error = "复盘文件夹未导入：" + error.localizedDescription }
    }
    func original(_ source: EvidenceSource) async throws -> URL {
        if let handle = familyHandle {
            let paths = try WorkspacePaths(workspace: checkpointWorkspaceURL)
            return try await ReviewSyncDetached.run {
                try ReviewFamilyClientSession.material(paths: paths, expected: handle, path: source.path, hash: source.sha256)
            }
        }
        let file = try ReviewDataSource.assetURL(source.path, root: root)
        guard try await ReviewSyncDetached.run({ try ReviewSyncIO.digestFile(file) == source.sha256 }) else { throw CocoaError(.fileReadCorruptFile) }
        return file
    }
    func resolve(key: String, value: String, finance: FinancialStore, evidence: BrowserStore) async {
        guard !syncing, localReviewIsIdle(finance, evidence) else { return }
        if let connection = familyConnection {
            guard let expected = familyHandle, finance.completion.drafts.isEmpty, !finance.hasUnsavedParameters else { status = "请先保存或还原当前草稿，再核对版本。"; return }
            let expectedWorkspace = checkpointWorkspaceURL
            syncing = true; finance.editorPauseReason = "正在保存版本选择"
            defer { syncing = false; if checkpointWorkspaceURL == expectedWorkspace, familyConnection?.selection == connection.selection { finance.editorPauseReason = nil } }
            do {
                let paths = try WorkspacePaths(workspace: checkpointWorkspaceURL)
                let handle = try await ReviewSyncDetached.run { try ReviewFamilyClientSession.resolveConflicts(paths: paths, expected: expected, choices: [key: value]) }
                guard paths.workspace == checkpointWorkspaceURL, familyConnection?.selection == connection.selection else { return }
                try await finance.loadFamilyClient(paths: paths, handle: handle, selectionIsCurrent: { self.checkpointWorkspaceURL == paths.workspace && self.familyConnection?.selection == connection.selection })
                await evidence.load(handle.review, finance: finance.report)
                guard paths.workspace == checkpointWorkspaceURL, familyConnection?.selection == connection.selection else { return }
                familyHandle = handle; root = handle.review; dataSource = .localCopy(root)
                conflicts = handle.conflicts.keys.sorted(); conflictOptions = handle.conflicts
                status = "版本选择已保存在本机，下一次同步会发送此决定。"
            } catch {
                if checkpointWorkspaceURL == expectedWorkspace, familyConnection?.selection == connection.selection { status = "版本未保存，请刷新后核对：" + error.localizedDescription }
            }
            return
        }
    }
    func importParameters(_ url: URL, finance: FinancialStore) {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let original = finance.report?.fire_parameters, old = finance.parameterDocument
        do {
            let bytes = try ReviewSyncIO.read(url, limit: 1_000_000)
            finance.parameterDocument = try ParameterDocument.merging(base: old ?? bytes, changes: bytes)
            finance.report?.fire_parameters = try JSONDecoder().decode(FireParameters.self, from: finance.parameterDocument!)
            finance.saveParameters()
            if finance.error != nil { if let original { finance.report?.fire_parameters = original }; finance.parameterDocument = old }
        } catch { if let original { finance.report?.fire_parameters = original }; finance.parameterDocument = old; finance.error = "参数未导入：" + error.localizedDescription }
    }
}
