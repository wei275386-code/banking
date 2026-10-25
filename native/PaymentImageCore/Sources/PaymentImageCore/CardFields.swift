import Foundation

public struct CardFields: Codable, Sendable {
    public let amountCents: Int?
    public let status: String?
    public let orderedMinute: String?
    public let reviewReasons: [String]

    public static func parse(_ lines: [TextLine]) -> CardFields {
        let price = try! NSRegularExpression(pattern: "[¥￥]\\s*([0-9]+(?:\\.[0-9]{1,2})?)(?![0-9.])")
        let stamp = try! NSRegularExpression(pattern: "下单(?:时间)?\\s*[:：]\\s*([0-9]{4}-[0-9]{2}-[0-9]{2})\\s+([0-9]{2}:[0-9]{2})")
        var amounts = Set<Int>()
        var statuses = Set<String>()
        let accepted = ["已完成", "支付成功", "已退款", "已取消"]
        for line in lines {
            let text = line.text as NSString
            if line.visionBox.x > 0.6 {
                for match in price.matches(in: line.text, range: NSRange(location: 0, length: text.length)) {
                    if let value = exactCents(text.substring(with: match.range(at: 1))) { amounts.insert(value) }
                }
            }
            if line.visionBox.x > 0.6 && line.visionBox.y > 0.65 {
                for state in accepted where line.text.trimmingCharacters(in: .whitespaces) == state {
                    statuses.insert(state)
                }
            }
            // Vision can merge the merchant and right-aligned status into one
            // line. Accept a suffix only when its actual character boxes
            // independently occupy the status region; never guess from text.
            for state in accepted where line.text.hasSuffix(state) {
                let suffix = Array(line.characters.suffix(state.count))
                if suffix.map(\.text).joined() == state,
                   suffix.allSatisfy({ $0.visionBox.map { $0.x > 0.6 && $0.y > 0.65 } ?? false }) {
                    statuses.insert(state)
                }
            }
        }
        let all = lines.map(\.text).joined(separator: "\n") as NSString
        let dates = Set(stamp.matches(in: all as String, range: NSRange(location: 0, length: all.length)).map {
            all.substring(with: $0.range(at: 1)) + " " + all.substring(with: $0.range(at: 2))
        })
        let date = dates.count == 1 ? dates.first : nil
        var reasons = [String]()
        if amounts.count != 1 { reasons.append(amounts.isEmpty ? "金额缺失" : "金额存在多个候选") }
        if statuses.count != 1 { reasons.append(statuses.isEmpty ? "状态缺失或未知" : "状态冲突") }
        if date == nil { reasons.append("下单时间缺失或冲突") }
        else if !validMinute(date!) { reasons.append("下单日期或时间无效") }
        return CardFields(amountCents: amounts.count == 1 ? amounts.first : nil,
                          status: statuses.count == 1 ? statuses.first : nil,
                          orderedMinute: date.flatMap { validMinute($0) ? $0 : nil }, reviewReasons: reasons)
    }

    public static func exactCents(_ value: String) -> Int? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts[0].utf8.allSatisfy({ (48...57).contains($0) }),
              let whole = Int(parts[0]) else { return nil }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= 2, fraction.utf8.allSatisfy({ (48...57).contains($0) }),
              parts.count == 1 || !fraction.isEmpty else { return nil }
        let suffix = fraction.isEmpty ? 0 : Int(fraction.padding(toLength: 2, withPad: "0", startingAt: 0))!
        let (base, overflow) = whole.multipliedReportingOverflow(by: 100)
        guard !overflow else { return nil }
        let (total, additionOverflow) = base.addingReportingOverflow(suffix)
        return additionOverflow ? nil : total
    }

    private static func validMinute(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
    }
}
