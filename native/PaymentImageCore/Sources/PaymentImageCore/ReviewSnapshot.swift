import Foundation

/// Pure derived data. UI selection and FIRE parameter edits do not invalidate it.
public struct ReviewSnapshot: Sendable {
    public let records: [FinancialLifecycle]
    public let classifiedRecords: [FinancialLifecycle]
    public let statistics: ReviewStatistics
    public let monthlyStatistics: ReviewStatistics
    public let recurringStatistics: ReviewStatistics
    public let fullMonths: [String]
    public let largestUnclassified: [(FinancialLifecycle, FinancialComponent)]

    public init(records source: [FinancialLifecycle], from: String, to: String, account: String, primary: String,
                query: String = "", searchText: [String: String] = [:], tags: [String] = [], tagMatch: String = "all") {
        let months = Self.completeMonths(from: from, to: to)
        let monthSet = Set(months)
        func matches(_ c: FinancialComponent) -> Bool {
            (primary == "全部分类" || c.primary == primary) && (tags.isEmpty ||
                (tagMatch == "any" ? tags.contains { c.tags.contains($0) } : tags.allSatisfy { c.tags.contains($0) }))
        }
        let records = source.filter { r in
            r.date >= from && r.date <= to && (account == "全部账户" || r.account_views.contains(account)) &&
            ((primary == "全部分类" && tags.isEmpty) || r.components.contains(where: matches)) &&
            (query.isEmpty || (searchText[r.id] ?? r.title + " " + r.date).localizedCaseInsensitiveContains(query))
        }
        let classified = primary == "全部分类" && tags.isEmpty ? records : records.map { record in
            var r = record; r.components = r.components.filter(matches); return r
        }
        let complete = classified.filter { monthSet.contains(String($0.date.prefix(7))) }
        let recurring = complete.map { record in
            var r = record; r.components = r.components.filter { $0.effectiveRecurrence == "recurring" }; return r
        }
        self.records = TransactionListOrder.sorted(records); classifiedRecords = TransactionListOrder.sorted(classified); fullMonths = months
        statistics = FinancialMath.statistics(classified)
        monthlyStatistics = FinancialMath.statistics(complete)
        recurringStatistics = FinancialMath.statistics(recurring)
        largestUnclassified = Array(TransactionListOrder.sorted(classified.filter { !$0.non_consumption && !$0.reviewExcluded }.flatMap { r in
            r.components.filter { $0.included && $0.primary == "待分类" }.map { (r, $0) }
        }, amount: { $0.1.net_cents }, date: { $0.0.date }, id: { $0.1.id }).prefix(5))
    }

    /// Project only the purchase items contributing to this category's total.
    /// The full lifecycle remains in `records` for opening evidence and editing.
    public func spendingTransactions(primary: String, secondary: String) -> [FinancialLifecycle] {
        TransactionListOrder.sorted(classifiedRecords.compactMap { record in
            guard !record.non_consumption, !record.reviewExcluded else { return nil }
            var projected = record
            projected.components = record.components.filter { $0.included && $0.primary == primary && $0.secondary == secondary }
            projected.unallocated_credit_cents = 0
            return projected.components.isEmpty ? nil : projected
        })
    }

    public static func completeMonths(from: String, to: String) -> [String] {
        guard from <= to else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        guard let year = Int(from.prefix(4)), let month = Int(from.dropFirst(5).prefix(2)),
              (1...12).contains(month), let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return [] }
        var date = first, result = [String]()
        // Match the existing 240-month boundary without creating formatters per record.
        for _ in 0..<240 {
            guard let next = calendar.date(byAdding: .month, value: 1, to: date),
                  let end = calendar.date(byAdding: .day, value: -1, to: next) else { break }
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            let e = calendar.dateComponents([.day], from: end)
            let prefix = String(format: "%04d-%02d", c.year!, c.month!)
            let startDay = prefix + "-01", endDay = prefix + String(format: "-%02d", e.day!)
            if startDay > to { break }
            if startDay >= from && endDay <= to { result.append(prefix) }
            date = next
        }
        return result
    }
}
