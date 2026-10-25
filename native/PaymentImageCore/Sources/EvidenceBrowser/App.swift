#if os(macOS) || os(iOS)
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation
import UniformTypeIdentifiers
import CryptoKit
import ImageIO
import PaymentImageCore

struct ExportObservation: Decodable, Sendable {
    let platform: String; let transaction_time: String; let merchant: String?; let title: String?
    let platform_reported_amount_cents: Int?; let raw_status: String
    let source_evidence: EvidenceReference
}
struct Cluster: Decodable, Sendable { let cluster_id: String; let representative: ExportObservation }
struct BankRow: Decodable, Sendable {
    let id: Int; let date: String; let description: String; let amount_cents: Int
    let is_credit: Int; let source_evidence: EvidenceReference
    let human_transaction_confirmation: BankConfirmation?
}
struct BankConfirmation: Decodable, Sendable { let user_relation: String }
struct Candidate: Decodable, Sendable, Identifiable {
    var id: String { candidate_id }
    let candidate_id: String; let kind: String; let record_ids: [String]; let bank_ids: [String]
    let association_status: String; let review_required: Bool
    let active_competing_candidate_ids: [String]?
}
struct CardFieldsSummary: Decodable, Sendable { let amountCents: Int?; let status: String?; let orderedMinute: String? }
struct Card: Decodable, Sendable {
    let card_id: String; let visible_title: String?; let parsed: CardFieldsSummary?; let source_evidence: EvidenceReference
}
struct CardProbe: Decodable, Sendable { let samples: [Card] }
struct Report: Decodable, Sendable {
    let coverage: WorkspaceCoverage?
    let dataset_id: String; let backfill_cutoff_date: String?; let clusters: [Cluster]
    let bank_records: [BankRow]; let candidates: [Candidate]; let ocr_probe: CardProbe?
    let review_summary: [String: Int]
}
struct BrowseRecord: Identifiable, Sendable {
    let id: String; let platform: String; let date: String; let title: String
    let amount: Int?; let status: String; let evidence: EvidenceReference
    var userRelation = "unknown"
    var userId: String? = nil
}
// CGImage is immutable; decode and downsample once on the worker, reuse on the UI thread.
struct PreviewImage: @unchecked Sendable { let pixels: CGImage }
struct PreviewData: Sendable { let rawText: String; let image: PreviewImage?; let source: URL?; let error: String? }

@Observable @MainActor final class BrowserStore {
    var report: Report?; var records = [BrowseRecord](); var root: URL?
    var error: String?; var loading = false; var section = "needs_review"; var query = ""
    var selected: String?; var previews = [String: PreviewData]()
    var previewTasks = Set<String>()
    var previewGeneration = UUID()
    var deferredCandidates = Set<String>()
    var orderedCandidates = [Candidate]()
    @ObservationIgnored var sourceVersion = "missing"
    var reviewMessage = ""
    @ObservationIgnored private var loadGeneration = UUID()

    func load(_ folder: URL, finance: FinancialReport? = nil) async {
        let generation = UUID(); loadGeneration = generation
        loading = true; error = nil
        let scoped = folder.startAccessingSecurityScopedResource()
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let bytes = try Data(contentsOf: ReviewDataSource.url("payment-evidence.json", root: folder))
                let result = try JSONDecoder().decode(Report.self, from: bytes)
                var deferred = Set<String>()
                if let bytes = try? Data(contentsOf: folder.appendingPathComponent("review-state.json")),
                   let state = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                   let object = state["deferred_associations"] as? [String: Any],
                   let ids = object["candidate_ids"] as? [String] { deferred = Set(ids) }
                var records = result.clusters.map { c in
                    let o = c.representative
                    return BrowseRecord(id: c.cluster_id, platform: o.platform, date: o.transaction_time,
                                        title: [o.merchant, o.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                        amount: o.platform_reported_amount_cents, status: o.raw_status, evidence: o.source_evidence)
                } + result.bank_records.map { b in
                    BrowseRecord(id: "bank:\(b.id)", platform: "bank", date: b.date, title: b.description,
                                 amount: b.amount_cents, status: b.is_credit == 1 ? "贷记／收入方向" : "银行扣款", evidence: b.source_evidence,
                                 userRelation: b.human_transaction_confirmation?.user_relation ?? "unknown")
                } + (result.ocr_probe?.samples ?? []).map { card in
                    BrowseRecord(id: "card:" + card.card_id, platform: "card", date: card.parsed?.orderedMinute ?? "",
                                 title: card.visible_title ?? "订单卡片", amount: card.parsed?.amountCents, status: card.parsed?.status ?? "待核", evidence: card.source_evidence)
                }
                let financial: FinancialReport?
                if let finance { financial = finance }
                else if let bytes = try? Data(contentsOf: ReviewDataSource.url("financial-review.json", root: folder)) {
                    financial = try? JSONDecoder().decode(FinancialReport.self, from: bytes)
                } else { financial = nil }
                if let financial {
                    if (financial.video_materials ?? []).contains(where: { $0.platform == "card" }) { records.removeAll { $0.platform == "card" } }
                    records += (financial.video_materials ?? []).map { v in BrowseRecord(id: v.id, platform: v.platform ?? "unionpay", date: v.date,
                        title: v.title, amount: v.amount_cents, status: v.status + (v.date_basis == "year_label_conflicts_weekday" ? " · 年份待核" : ""), evidence: v.source_evidence) }
                    var usersByEvidence = [String: String]()
                    for lifecycle in financial.records {
                        if let user = lifecycle.user_id {
                            for key in lifecycle.evidence_keys { usersByEvidence[key] = AccountConsolidation.displayName(user) }
                        }
                    }
                    for index in records.indices { records[index].userId = usersByEvidence[records[index].id] }
                }
                records = TransactionListOrder.sorted(records, amount: \.amount, date: \.date, id: \.id)
                let lookup = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let candidates = TransactionListOrder.sorted(result.candidates, amount: { candidate in
                    (candidate.record_ids + candidate.bank_ids).compactMap { lookup[$0]?.amount }.max { $0.magnitude < $1.magnitude }
                }, date: { candidate in
                    (candidate.record_ids + candidate.bank_ids).compactMap { lookup[$0]?.date }.max() ?? ""
                }, id: \.id)
                return (result, records, deferred, ReviewFileVersion.of(bytes), candidates)
            }.value
            ReviewLatency.record("evidence-load-worker", milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            guard loadGeneration == generation else { if scoped { folder.stopAccessingSecurityScopedResource() }; return }
            root?.stopAccessingSecurityScopedResource(); root = folder
            report = loaded.0; records = loaded.1; deferredCandidates = loaded.2
            sourceVersion = loaded.3; orderedCandidates = loaded.4
            selected = nil; previews = [:]; previewTasks = []; previewGeneration = UUID()
        } catch { if scoped { folder.stopAccessingSecurityScopedResource() }; self.error = error.localizedDescription }
        if loadGeneration == generation { loading = false }
    }

    func decide(_ candidate: Candidate, judgment: String, finance: FinancialStore) async {
        guard let root, let report, finance.evidenceReviewAvailable, !finance.categoryBusy, !loading, finance.root == root, ["supports", "rejects", "needs_evidence"].contains(judgment),
              let currentCandidate = report.candidates.first(where: { $0.id == candidate.id && $0.record_ids == candidate.record_ids && $0.bank_ids == candidate.bank_ids && $0.association_status == candidate.association_status }) else { return }
#if os(iOS)
        guard !MobileServices.shared.pendingReviews.contains(candidate.id) else { reviewMessage = "此候选已有复核请求，等待 Mac 处理后再修改。"; return }
        loading = true; defer { loading = false }
        do {
            var decisions = [candidate.id: ["judgment": judgment]]
            if judgment == "supports" {
                for id in currentCandidate.active_competing_candidate_ids ?? [] { decisions[id] = ["judgment": "rejects"] }
            }
            let bytes = try JSONSerialization.data(withJSONObject: ["dataset_id": report.dataset_id, "decisions": decisions, "expected_projection": ReviewSyncIO.digest(try Data(contentsOf: ReviewDataSource.url("payment-evidence.json", root: root)))])
            try await MobileServices.shared.enqueue(kind: "review", payload: bytes, files: [])
            reviewMessage = "复核请求已保存，Mac 处理后自动同步结果。"; error = nil
        } catch { self.error = error.localizedDescription }

#else
        loading = true; finance.completionSaving = true; error = nil
        defer { loading = false; finance.completionSaving = false }
        do {
            var decisions = [candidate.id: ["judgment": judgment]]
            if judgment == "supports" {
                for id in currentCandidate.active_competing_candidate_ids ?? [] { decisions[id] = ["judgment": "rejects"] }
            }
            let bytes = try JSONSerialization.data(withJSONObject: ["dataset_id": report.dataset_id, "decisions": decisions, "expected_projection": sourceVersion])
            if finance.clientWorkspacePaths != nil {
                let request = try await finance.enqueueClientProcessingRequest(kind: "review", payload: bytes, files: [])
                guard finance.root == root else { return }
                reviewMessage = "复核请求已保存在本机，等待指定家庭 Mac 处理。请求 " + String(request.id.prefix(8))
                return
            }
            let runtime = try await finance.resolveWorkspaceProcessorRuntime()
            try await finance.requireWorkspaceRuntimeQualification(runtime)
            let executor = try await finance.makeProcessorExecution(runtime: runtime)
            let result = try await finance.runProcessor(executor, operation: .review, input: bytes)
            await finance.reloadCurrent()
            guard finance.error == nil else { reviewMessage = "复核已落盘，但财务数据刷新失败。请刷新数据。"; return }
            if let current = finance.root { await load(current, finance: finance.report) }
            guard error == nil else { reviewMessage = "复核已落盘，但证据刷新失败。请刷新数据。"; return }
            reviewMessage = result.isFullySuccessful ? "复核已保存，财务复盘已更新。" : "复核处理部分完成：" + result.message
        } catch { self.error = "复核请求尚未完成确认：" + error.localizedDescription }
        loading = false

#endif
    }

    func preview(_ record: BrowseRecord) async {
        guard previews[record.id] == nil, !previewTasks.contains(record.id), let folder = root else { return }
        previewTasks.insert(record.id)
        let generation = previewGeneration
        let evidence = record.evidence
        ReviewLatency.begin("evidence-preview")
#if os(iOS)
        do { try await MobileServices.shared.ensure(record.evidence) }
        catch { previews[record.id] = PreviewData(rawText: "", image: nil, source: nil, error: "素材尚未同步：" + error.localizedDescription); previewTasks.remove(record.id); return }
#endif
        let result = await Task.detached { () -> PreviewData in
            do {
                let pin = try ReviewDataSource.pinReview(folder)
                defer { withExtendedLifetime(pin) {} }
                func read(_ asset: EvidenceAsset) throws -> Data {
                    let bytes = try Data(contentsOf: ReviewDataSource.assetURL(asset.path, root: folder))
                    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    guard hash == asset.sha256 else { throw NSError(domain: "Evidence", code: 2, userInfo: [NSLocalizedDescriptionKey: "素材校验失败，文件可能已修改"]) }
                    return bytes
                }
                var text = ""
                if let raw = evidence.raw {
                    let bytes = try read(raw)
                    let payload = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                    text = payload?["literal_text"] as? String ?? ""
                    if let headers = payload?["header"] as? [Any], let values = payload?["values"] as? [Any] {
                        text = zip(headers, values).filter { !($0.0 is NSNull) && !String(describing: $0.0).isEmpty }.map { "\($0): \($1 is NSNull ? "" : String(describing: $1))" }.joined(separator: "\n") + "\n\n原始记录文本：\n" + text
                    }
                } else if record.platform == "card" {
                    guard let ocr = evidence.ocr_result else { throw NSError(domain: "Evidence", code: 3, userInfo: [NSLocalizedDescriptionKey: "缺少原始OCR结果快照"]) }
                    let bytes = try read(ocr)
                    let data = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                    let rows = data?["results"] as? [[String: Any]] ?? []
                    let row = rows.first { "card:" + ($0["cardID"] as? String ?? "") == record.id }
                    let recognized = row?["recognized"] as? [String: Any]
                    text = (recognized?["lines"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                let image = try evidence.image.map { asset -> PreviewImage in
                    let bytes = try read(asset)
                    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                          let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 2200,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary) else {
                        throw NSError(domain: "Evidence", code: 4, userInfo: [NSLocalizedDescriptionKey: "素材图片无法解码"])
                    }
                    return PreviewImage(pixels: pixels)
                }
                let original = try evidence.source.map { try ReviewDataSource.assetURL($0.path, root: folder) }
                return PreviewData(rawText: text, image: image, source: original, error: nil)
            } catch { return PreviewData(rawText: "", image: nil, source: nil, error: error.localizedDescription) }
        }.value
        if root == folder && previewGeneration == generation {
            if previews.count >= 12, let old = previews.keys.first(where: { $0 != record.id }) { previews.removeValue(forKey: old) }
            previews[record.id] = result
            ReviewLatency.finish("evidence-preview")
            previewTasks.remove(record.id)
        }
    }
    var candidates: [Candidate] {
        orderedCandidates.filter { (section != "needs_review" || $0.review_required) && matches($0) }
    }
    func matches(_ c: Candidate) -> Bool {
        query.isEmpty || records.filter { c.record_ids.contains($0.id) || c.bank_ids.contains($0.id) }.contains { matches($0) }
    }
    func matches(_ r: BrowseRecord) -> Bool { query.isEmpty || (platformName(r.platform) + " " + r.date + " " + r.title + " " + money(r.amount) + " " + (r.amount.map { String(format: "%.2f", Double($0)/100) } ?? "")).localizedCaseInsensitiveContains(query) }
    var visibleRecords: [BrowseRecord] { records.filter { (section != "cards" || $0.platform == "card") && matches($0) } }
    func originalURL(_ asset: EvidenceSource) async throws -> URL {
        guard let folder = root else { throw WorkspaceError.invalid("请先打开资料。") }
        let result = try await Task.detached {
            let pin = try ReviewDataSource.pinReview(folder)
            defer { withExtendedLifetime(pin) {} }
            if folder.deletingLastPathComponent().lastPathComponent == "client-views" {
                let paths = try WorkspacePaths(workspace: folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
                guard let handle = try ReviewFamilyClientSession.read(paths: paths), handle.review == folder else { throw WorkspaceError.stalePointer }
                return try ReviewFamilyClientSession.material(paths: paths, expected: handle, path: asset.path, hash: asset.sha256)
            }
            return try ReviewDataSource.verifiedAssetURL(asset.path, hash: asset.sha256, root: folder)
        }.value
        guard root == folder else { throw CancellationError() }
        return result
    }
    var selectedRecords: [BrowseRecord] {
        guard let selected else { return [] }
        if ["needs_review", "all_links"].contains(section), let candidate = candidates.first(where: { $0.id == selected }) {
            return records.filter { candidate.record_ids.contains($0.id) || candidate.bank_ids.contains($0.id) }
        }
        return ["records", "cards"].contains(section) ? visibleRecords.filter { $0.id == selected } : []
    }
}

func money(_ value: Int?) -> String { value.map { (Double($0) / 100).formatted(.currency(code: "CNY").locale(Locale(identifier: "zh_CN")).precision(.fractionLength(2))) } ?? "金额未知" }
func platformName(_ name: String) -> String { ["wechat":"微信", "alipay":"支付宝", "meituan":"美团", "unionpay":"云闪付", "nihao_china":"nihao china", "taobao_card":"淘宝订单", "bank":"银行", "card":"订单卡片"][name] ?? name }
func statusName(_ value: String) -> String { ["bank_debit":"银行扣款", "bank_credit":"银行贷记", "repayment":"还款", "payment":"支付记录", "refund":"退款记录", "transfer":"转账", "authorization":"授权／冻结", "receipt":"收款", "agency_receipt":"代购回款", "unknown":"类型待确定"][value] ?? value }

struct RecordPane: View {
    @State private var loadingOriginal = false
    @State private var originalError: String?
    let record: BrowseRecord; let store: BrowserStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(platformName(record.platform)).font(.headline); Spacer(); Text(money(record.amount)).font(.title2).monospacedDigit() }
            Text(record.date + " · " + statusName(record.status)).foregroundStyle(.secondary)
            Text(record.title).textSelection(.enabled)
            Text(record.userId.map { "用户：\($0) · 来源归属及关联依据见交易生命周期" } ?? (record.userRelation == "other_user" ? "已确认其他用户消费；具体身份未知" : "支付人和用户归属未知")).font(.caption).foregroundStyle(.secondary)
            if let data = store.previews[record.id] {
                if let error = data.error { Text(error).foregroundStyle(.red) }
                if let image = data.image {
                    Image(decorative: image.pixels, scale: 1).resizable().scaledToFit()
                        .frame(maxWidth: ["card", "taobao_card"].contains(record.platform) ? 760 : record.platform == "unionpay" ? 900 : 1100,
                               maxHeight: ["card", "taobao_card"].contains(record.platform) ? 850 : record.platform == "unionpay" ? 450 : 220)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !data.rawText.isEmpty { Text(data.rawText).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding().background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 8)) }
                if data.source != nil {
#if os(macOS)
                    if let asset = record.evidence.source { originalControls(asset) }
#else
                    if let source = record.evidence.source { MobileOriginalLink(source: source) }
#endif
                }
                if let name = record.evidence.source?.original_name { Text("来源：" + name).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            } else { ProgressView("读取原始证据…") }
#if os(iOS)
            if store.previews[record.id]?.error != nil { Button("重试读取素材") { store.previews.removeValue(forKey: record.id); Task { await store.preview(record) } } }
#endif
        }.padding(20).background(.background).clipShape(RoundedRectangle(cornerRadius: 12))
            .id(store.previewGeneration.uuidString + record.id)
            .task(id: store.previewGeneration.uuidString + record.id) { await store.preview(record) }
    }
#if os(macOS)
    @ViewBuilder private func originalControls(_ asset: EvidenceSource) -> some View {
        Button(loadingOriginal ? "正在读取原件…" : "打开保存的原始文件") { openOriginal(asset) }
            .disabled(loadingOriginal)
        if let originalError { Text(originalError).foregroundStyle(.red) }
    }
    private func openOriginal(_ asset: EvidenceSource) {
        loadingOriginal = true; originalError = nil
        Task {
            defer { loadingOriginal = false }
            do { NSWorkspace.shared.open(try await store.originalURL(asset)) }
            catch { originalError = error.localizedDescription }
        }
    }
#endif

}

#if os(macOS)
struct BrowserView: View {
    @Bindable var store: BrowserStore
    let financial: FinancialStore
    @State private var choosingFolder = false
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
            List(selection: $store.section) {
                Label("需要处理", systemImage: "checklist").tag("needs_review")
                Label("所有关联", systemImage: "link").tag("all_links")
                Label("原始记录", systemImage: "doc.text.magnifyingglass").tag("records")
                Label("订单卡片", systemImage: "photo.on.rectangle").tag("cards")
            }.navigationTitle("支付证据")
            VStack(alignment: .leading, spacing: 6) {
                if let report = store.report {
                    Text(report.backfill_cutoff_date.map { "补录截止 " + $0 } ?? "暂无可靠日期")
                    Text("人工支持 \(report.review_summary["human_supported"] ?? 0) · 规则通过 \(report.review_summary["rule_supported"] ?? 0)")
                }
                Button("选择证据文件夹") { choosingFolder = true }.disabled(financial.workspacePaths != nil || financial.importing || store.loading || financial.completionSaving || financial.loading || financial.completion.persisting)
            }.font(.caption).padding()
            }.navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } content: {
            VStack {
                if store.loading { ProgressView("读取记录…").padding() }
                if let error = store.error { Text(error).foregroundStyle(.red).padding() }
                if !store.reviewMessage.isEmpty { Text(store.reviewMessage).font(.caption).foregroundStyle(.secondary).padding() }
                List(selection: $store.selected) {
                    if ["needs_review", "all_links"].contains(store.section) {
                        ForEach(store.candidates) { c in
                            VStack(alignment: .leading) {
                                Text(["wallet_bank":"钱包与银行", "grouped_wallet_bank":"组合支付与银行", "meituan_wechat":"美团与微信", "meituan_bank":"美团 ApplePay 与银行"][c.kind] ?? c.kind)
                                Text(store.deferredCandidates.contains(c.id) ? "已暂挂 · 设备尾号待确认" : c.association_status == "supported_by_user" ? (c.review_required ? "支持已保存 · 扣款分配待核" : "人工支持已保存") : c.association_status == "rule_supported" ? "规则通过" : c.association_status == "rejected_by_user" ? "人工已排除" : "待核").font(.caption).foregroundStyle(.secondary)
                                if let r = store.records.first(where: { c.record_ids.contains($0.id) }) { Text(r.date + " · " + money(r.amount)).font(.caption); Text(r.title).lineLimit(2).font(.caption) }
                                ForEach(store.records.filter { c.bank_ids.contains($0.id) }) { b in Text(b.title).lineLimit(2).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 5).tag(c.id)
                        }
                    } else {
                        ForEach(store.visibleRecords) { r in
                            VStack(alignment: .leading) { Text(platformName(r.platform) + " · " + money(r.amount)); Text(r.date).font(.caption).foregroundStyle(.secondary); Text(r.title).lineLimit(2).font(.caption) }.padding(.vertical, 5).tag(r.id)
                        }
                    }
                }
                .overlay { if (["needs_review", "all_links"].contains(store.section) ? store.candidates.isEmpty : store.visibleRecords.isEmpty) { ContentUnavailableView("没有匹配记录", systemImage: "magnifyingglass", description: Text("试试清空搜索条件。")) } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400).navigationTitle(["needs_review":"需要处理", "all_links":"所有关联", "records":"原始记录", "cards":"订单卡片"][store.section] ?? "记录")
                .searchable(text: $store.query, prompt: "时间、商户或金额")
        } detail: {
            if store.selectedRecords.isEmpty {
                ContentUnavailableView("选择一条记录", systemImage: "doc.text.viewfinder", description: Text("查看原始文字、银行裁剪行或订单卡片。需要处理的关联可在此保存复核结果。"))
            } else {
                ScrollView { LazyVStack(spacing: 16) {
                    if let candidate = store.report?.candidates.first(where: { $0.id == store.selected }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("这项判断只改变证据关联，不删除其他银行消费，也不确认用户身份。").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button((candidate.active_competing_candidate_ids ?? []).isEmpty ? "支持关联" : "支持此关联并排除竞争关联") { Task { await store.decide(candidate, judgment: "supports", finance: financial) } }
                                Button("排除此关联") { Task { await store.decide(candidate, judgment: "rejects", finance: financial) } }
                                Button("仍需资料") { Task { await store.decide(candidate, judgment: "needs_evidence", finance: financial) } }
                            }.disabled(store.loading || financial.categoryBusy || !financial.evidenceReviewAvailable)
                        }
                    }
                    ForEach(store.selectedRecords) { RecordPane(record: $0, store: store) } }.padding() }
            }
        }.frame(minWidth: 1180, minHeight: 800)
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result, !financial.completionSaving, !financial.importing, !financial.loading, !store.loading, !financial.completion.persisting { Task { await financial.load(url); await store.load(url, finance: financial.report) } }
            }

    }
}

@main struct EvidenceBrowserApp: App {
    init() {
        ReviewLatency.begin("startup-overview")
        if CommandLine.arguments.contains("--profile-finance") {
            Task { _ = await FinancialProfiler.runIfRequested() }
        }
    }
    @State private var finance = FinancialStore()
    @State private var evidence = BrowserStore()
    @State private var activeTab = 0
    var body: some Scene { WindowGroup("家庭财务复盘") {
        Group {
        if finance.root == nil { WorkspaceWelcomeView(finance: finance, evidence: evidence) }
        else { TabView(selection: $activeTab) {
            FinanceRootView(store: finance, evidence: evidence).tabItem { Label("财务复盘", systemImage: "chart.bar") }.tag(0)
            Group {
                if activeTab == 1 { BrowserView(store: evidence, financial: finance) }
                else { Color.clear }
            }.tabItem { Label("交易证据", systemImage: "doc.text.viewfinder") }.tag(1)
            HouseholdSettingsView(store: finance).tabItem { Label("家庭设置", systemImage: "person.2.badge.gearshape") }.tag(2)
        }.task(id: finance.root) {
            guard let root = finance.root else { return }
            await finance.resumeDisplayedWorkspace(root, evidence: evidence)
        }
        }
        }
    }.defaultSize(width: 1280, height: 860).windowResizability(.contentMinSize) }
}
#endif
#else
import Foundation
@main struct EvidenceBrowserApp { static func main() { print("桌面证据浏览器需要 macOS；共享证据模型可用于 iOS。") } }
#endif
