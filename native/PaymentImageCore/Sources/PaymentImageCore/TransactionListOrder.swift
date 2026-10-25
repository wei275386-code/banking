import Foundation

/// Sort presentation copies only. Evidence and lifecycle event order stay intact.
public enum TransactionListOrder {
    public static func sorted<T>(_ values: [T], amount: (T) -> Int?, date: (T) -> String, id: (T) -> String) -> [T] {
        // Compute aggregate amounts once per row, not on every comparison.
        values.enumerated().map { (value: $0.element, amount: amount($0.element)?.magnitude,
                                   date: date($0.element), id: id($0.element), index: $0.offset) }
            .sorted {
                if $0.amount != $1.amount {
                    guard let left = $0.amount else { return false }
                    guard let right = $1.amount else { return true }
                    return left > right
                }
                if $0.date != $1.date { return $0.date > $1.date }
                if $0.id != $1.id { return $0.id < $1.id }
                return $0.index < $1.index
            }.map(\.value)
    }

    public static func sorted(_ records: [FinancialLifecycle]) -> [FinancialLifecycle] {
        sorted(records, amount: \.transactionListAmount, date: \.date, id: \.id)
    }
}

extension FinancialLifecycle {
    /// Use the amount shown in the transaction row; unknown is distinct from zero.
    public var transactionListAmount: Int? {
        if unallocated_credit_cents > 0 { return unallocated_credit_cents }
        if components.contains(where: { $0.reason.contains("支付金额待确定") }) { return nil }
        if non_consumption { return events.first?.amount_cents }
        return components.reduce(0) { $0 + $1.net_cents }
    }
}
