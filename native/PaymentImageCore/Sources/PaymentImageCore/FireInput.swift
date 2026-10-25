import Foundation

/// Numeric storage preserves unset separately from an explicitly entered zero.
/// The numeric projection exists for the existing math API; readiness gates must
/// run before that projection is used for a financial conclusion.
@propertyWrapper public struct FireInput<Value: Codable & Sendable & Equatable & AdditiveArithmetic>: Codable, Sendable, Equatable {
    private var input: Value?
    public init(wrappedValue: Value) { input = wrappedValue }
    public init(_ input: Value?) { self.input = input }
    public var wrappedValue: Value {
        get { input ?? .zero }
        set { input = newValue }
    }
    public var projectedValue: Value? {
        get { input }
        set { input = newValue }
    }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        input = try value.decodeNil() ? nil : value.decode(Value.self)
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        if let input { try value.encode(input) } else { try value.encodeNil() }
    }
}
/// A cleared budget leaf remains a JSON null through rebase/merge. Public
/// numeric access omits those leaves instead of treating them as zero budgets.
@propertyWrapper public struct FireBudgetMap: Codable, Sendable, Equatable {
    private var input: [String: Double?]
    public init(wrappedValue: [String: Double]) { input = wrappedValue.mapValues { $0 } }
    public var wrappedValue: [String: Double] {
        get { input.compactMapValues { $0 } }
        set {
            for key in input.keys where newValue[key] == nil { input[key] = .some(nil) }
            for (key, value) in newValue { input[key] = .some(value) }
        }
    }
    public init(from decoder: Decoder) throws { input = try [String: Double?](from: decoder) }
    public func encode(to encoder: Encoder) throws { try input.encode(to: encoder) }
}

extension FireParameters {
    public static func emptyInputs() throws -> FireParameters {
        try JSONDecoder().decode(Self.self, from: Data(#"{"baseYear":null,"birthYear":null,"targetAge":null,"currentFireAssets":null,"afterTaxSalary":null,"annualContribution":null,"annualHardCap":null,"expenseModes":{},"expenseBreakdown":{},"buckets":{"safetyBucket":null,"parentMedicalBucket":null,"elderCareEnabled":false,"elderCareBucket":null,"otherBuckets":null,"includeBuckets":false},"investing":{"withdrawalRate":0.035,"annualReturn":null,"inflation":null,"maxDrawdown":null},"branches":{"housing":{"enabled":false,"year":null,"totalPrice":null,"downPaymentRatio":null,"loanRate":null,"loanYears":null,"fees":null,"renovation":null,"annualMaintenance":null,"reduceRent":false,"minLiquidAssets":null,"ownerHomeCountsAsFireAsset":false},"children":{"enabled":false,"count":null,"birthYear":null,"annualCost":null,"educationBucket":null,"incomeImpact":null}}}"#.utf8))
    }
    private var inputObject: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private func inputValue(_ path: String, in object: [String: Any]) -> Any? {
        path.split(separator: "/").reduce(object as Any?) { ($0 as? [String: Any])?[String($1)] }
    }
    private var baseInputPaths: [String] {
        ["baseYear", "birthYear", "targetAge", "currentFireAssets", "afterTaxSalary", "annualContribution",
         "annualHardCap", "expenseModes/normal", "investing/withdrawalRate", "investing/annualReturn", "investing/inflation"] +
        (buckets.includeBuckets ? ["buckets/safetyBucket", "buckets/parentMedicalBucket", "buckets/otherBuckets"] +
            (buckets.elderCareEnabled ? ["buckets/elderCareBucket"] : []) : [])
    }
    public var missingRequiredInputs: [String] {
        guard let object = inputObject else { return baseInputPaths }
        var required = baseInputPaths
        if branches.housing.enabled {
            required += ["year", "totalPrice", "downPaymentRatio", "loanRate", "loanYears", "fees", "renovation", "annualMaintenance", "minLiquidAssets"].map { "branches/housing/" + $0 }
            if branches.housing.reduceRent { required.append("branches/housing/annualRentReduction") }
        }
        if branches.children.enabled {
            required += ["count", "birthYear", "annualCost", "educationBucket", "incomeImpact"].map { "branches/children/" + $0 }
        }
        return required.filter { inputValue($0, in: object).map { $0 is NSNull } ?? true }
    }
    public var needsBaseInput: Bool {
        guard let object = inputObject else { return true }
        return validationMessage(includeBranches: false) != nil || baseInputPaths.contains { inputValue($0, in: object).map { $0 is NSNull } ?? true }
    }
    public var hasUnsetInputs: Bool {
        guard let object = inputObject else { return true }
        func hasNull(_ value: Any) -> Bool {
            if value is NSNull { return true }
            return (value as? [String: Any])?.values.contains(where: hasNull) ?? false
        }
        return hasNull(object)
    }
    public var inputValidationMessage: String? { validationMessage(includeBranches: true) }
    private func validationMessage(includeBranches: Bool) -> String? {
        guard let object = inputObject else { return "参数必须是有限数值。" }
        func number(_ path: String) -> Double? { inputValue(path, in: object) as? Double }
        func outside(_ path: String, _ range: ClosedRange<Double>) -> Bool { number(path).map { !range.contains($0) } ?? false }
        if outside("baseYear", 1900...2100) || outside("birthYear", 1900...Double(baseYear >= 1900 ? baseYear : 2100)) || outside("targetAge", 20...100) {
            return "请检查基础年份、出生年份和目标年龄。"
        }
        if outside("investing/withdrawalRate", Double.leastNonzeroMagnitude...0.15) ||
            outside("investing/annualReturn", (-1 + Double.ulpOfOne)...Double.greatestFiniteMagnitude) ||
            outside("investing/inflation", (-1 + Double.ulpOfOne)...Double.greatestFiniteMagnitude) ||
            outside("investing/maxDrawdown", 0...1) || (includeBranches && outside("branches/housing/downPaymentRatio", 0...1)) {
            return "请检查提取率、收益率、通胀和首付比例。"
        }
        func negative(_ value: Any, path: String = "") -> Bool {
            if !includeBranches && path.hasPrefix("branches/") { return false }
            if let dictionary = value as? [String: Any] {
                return dictionary.contains { negative($0.value, path: path.isEmpty ? $0.key : path + "/" + $0.key) }
            }
            if ["investing/annualReturn", "investing/inflation"].contains(path) { return false }
            return (value as? Double).map { $0 < 0 } ?? false
        }
        if negative(object) { return "金额、预算和数量不能为负数。" }
        if includeBranches && branches.housing.enabled && (outside("branches/housing/year", Double(baseYear >= 1900 ? baseYear : 1900)...2100) || outside("branches/housing/loanYears", 1...40)) {
            return "请检查购房年份和贷款期限。"
        }
        if includeBranches && (outside("branches/children/count", 0...5) || (branches.children.enabled && outside("branches/children/birthYear", Double(baseYear >= 1900 ? baseYear : 1900)...2100))) {
            return "请检查子女数量和计划年份。"
        }
        return nil
    }
}

