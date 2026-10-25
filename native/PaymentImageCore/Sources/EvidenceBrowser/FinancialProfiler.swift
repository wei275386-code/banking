#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import PaymentImageCore

/// Opt-in, read-only profiling against the same store and SwiftUI views as the app.
@MainActor enum FinancialProfiler {
    static func runIfRequested() async -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--profile-finance"), args.count > index + 2 else { return false }
        let folder = URL(fileURLWithPath: args[index + 1])
        let destination = URL(fileURLWithPath: args[index + 2])
        var samples = [[String: Any]]()
        func measure<T>(_ name: String, _ operation: () -> T) -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = operation()
            samples.append(["name": name, "ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000])
            return result
        }
        let store = FinancialStore(), evidence = BrowserStore()
        let start = DispatchTime.now().uptimeNanoseconds
        await store.load(folder)
        samples.append(["name": "load", "ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000])
        guard let report = store.report else { return true }
        var checksum = 0
        for iteration in 0..<3 {
            checksum += measure("overview.statistics") { store.stats.net }
            checksum += measure("overview.monthly") { store.monthlyStats.net }
            checksum += measure("overview.months") { store.fullMonths.count }
            checksum += measure("focus.recurring") {
                let rows = store.classifiedRecords.filter { store.fullMonths.contains(String($0.date.prefix(7))) }.map { record in
                    var r = record; r.components = r.components.filter { $0.recurrence != "one_time" }; return r
                }
                return FinancialMath.statistics(rows).net
            }
            checksum += measure("details.filter") { store.visibleRecords.count }
            for section in ["overview", "tags", "focus", "details", "fire", "branches", "params", "data"] {
                store.section = section
                measure("render." + section) {
                    let host = NSHostingView(rootView: FinanceRootView(store: store, evidence: evidence))
                    host.frame = NSRect(x: 0, y: 0, width: 1280, height: 860)
                    host.layoutSubtreeIfNeeded()
                    checksum += Int(host.fittingSize.height)
                }
            }
            store.section = "overview"
            if iteration == 0 { store.account = store.accounts.first ?? "全部账户" }
            if iteration == 1 { store.account = "全部账户"; store.primary = report.taxonomy.first?.primary ?? "全部分类" }
        }
        store.account = "全部账户"; store.primary = "全部分类"; store.query = ""; store.section = "details"
        store.selected = store.records.first?.id
        let persistent = NSHostingView(rootView: FinanceRootView(store: store, evidence: evidence))
        persistent.frame = NSRect(x: 0, y: 0, width: 1280, height: 860)
        persistent.layoutSubtreeIfNeeded(); _ = persistent.fittingSize
        for _ in 0..<3 {
            for mode in ["待处理", "资金流", "全部消费"] {
                measure("interaction.record-mode." + mode) {
                    store.recordView = mode
                    persistent.layoutSubtreeIfNeeded()
                    checksum += Int(persistent.fittingSize.height)
                }
            }
        }
        var tagSamples = [[String: Any]]()
        for match in ["all", "any"] {
            store.selectedTags = ["旅行场景", "便利店"]; store.tagMatch = match; store.section = "tags"
            let stats = measure("tags." + match + ".statistics") { store.stats }
            tagSamples.append(["tags": store.selectedTags, "match": match, "net_cents": stats.net, "count": stats.count])
            measure("render.tags." + match + ".minimum-window") {
                let host = NSHostingView(rootView: FinanceRootView(store: store, evidence: evidence))
                host.frame = NSRect(x: 0, y: 0, width: 1180, height: 800)
                host.layoutSubtreeIfNeeded(); checksum += Int(host.fittingSize.height)
            }
        }
        let data: [String: Any] = ["samples": samples, "records": report.records.count, "checksum": checksum,
                                  "tag_samples": tagSamples,
                                  "measurement": "Store CPU wall time and offscreen NSHostingView layout; not end-to-end display latency"]
        do { try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: destination) }
        catch { print(error) }
        NSApplication.shared.terminate(nil)
        return true
    }
}
#endif
