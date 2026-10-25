import Foundation

/// Canonical current JSON, parsed from raw bytes without
/// Foundation's lossy NSNumber or canonically-equivalent String dictionary keys.
/// Input encoding detection follows Python json.loads(bytes), including UTF BOMs.
/// Output is UTF-8. This is the release_contracts Decimal codec, not RFC 8785.
public enum ReleaseCanonicalJSON {
    public enum ContractError: Error, Equatable, LocalizedError {
        case invalidJSON(String)
        case resourceLimit(String)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let reason): return "Invalid release JSON: " + reason
            case .resourceLimit(let reason): return "Release JSON resource limit: " + reason
            }
        }
    }

    /// Deliberate untrusted-input limits, stricter than Python's platform-dependent
    /// recursion/memory limits. Within these limits the bytes are identical. Integer
    /// digits match CPython's default 4,300-digit conversion ceiling; decimals never
    /// pass through Int/Double. Exponent magnitude is capped at 9e17 so coefficient
    /// length/fraction arithmetic has ample Int64 headroom, even for hostile tokens.
    public static let maximumInputBytes = 16 * 1024 * 1024
    public static let maximumDepth = 128
    public static let maximumNumberTokenBytes = 1024 * 1024
    public static let maximumIntegerDigits = 4_300
    public static let maximumOutputBytes = 64 * 1024 * 1024

    public static func canonicalize(raw: Data, inputLimit: Int = maximumInputBytes) throws -> Data {
        let budget = Budget(inputLimit: inputLimit)
        let value = try parse(raw, budget: budget)
        return try encode(value, budget: budget)
    }

    /// Look up an object-only path with exact UTF-8 keys. Number fragments retain
    /// their integer/decimal kind, so Int(String(...)) rejects 1.0 and 1e0 headers.
    /// Missing keys or a non-object intermediate return nil; malformed input throws.
    public static func canonicalFragment(raw: Data, atObjectKeys keys: [String], inputLimit: Int = maximumInputBytes) throws -> Data? {
        let budget = Budget(inputLimit: inputLimit)
        guard let value = lookup(try parse(raw, budget: budget), keys: keys) else { return nil }
        return try encode(value, budget: budget)
    }

    /// Canonical array element fragments in their original order. Unknown fields,
    /// large integers and decimal kind survive subsequent fragment operations.
    public static func canonicalArrayElements(raw: Data, atObjectKeys keys: [String], inputLimit: Int = maximumInputBytes) throws -> [Data]? {
        let budget = Budget(inputLimit: inputLimit)
        guard let value = lookup(try parse(raw, budget: budget), keys: keys),
              case .array(let elements) = value else { return nil }
        return try elements.map { try encode($0, budget: budget) }
    }

    /// Keys of a strict object, for validating dictionaries consumed by Swift.
    /// Unknown lossless documents may retain distinct canonically-equivalent keys.
    public static func canonicalObjectKeys(raw: Data) throws -> [String] {
        guard case .object(let members) = try parse(raw, budget: Budget()) else {
            throw ContractError.invalidJSON("expected object")
        }
        return members.map(\.key)
    }

    /// Decode a dynamic object once without folding canonically equivalent keys.
    /// This avoids reparsing a large source-owner map separately for every key.
    public static func canonicalObjectEntries(raw: Data) throws -> [(key: String, value: Data)] {
        let budget = Budget()
        guard case .object(let members) = try parse(raw, budget: budget) else {
            throw ContractError.invalidJSON("expected object")
        }
        return try members.map { ($0.key, try encode($0.value, budget: budget)) }
    }

    /// Replace or insert one exact UTF-8 root key; preserve every other member's
    /// semantic value. Both raw documents are strictly parsed before encoding.
    public static func replacingObjectMember(raw: Data, key: String, valueRaw: Data, inputLimit: Int = maximumInputBytes) throws -> Data {
        let budget = Budget(inputLimit: inputLimit, inputDocuments: 2)
        guard case .object(var members) = try parse(raw, budget: budget) else {
            throw ContractError.invalidJSON("replacement requires root object")
        }
        let replacement = try parse(valueRaw, budget: budget)
        if let index = members.firstIndex(where: { exact($0.key, key) }) { members[index].value = replacement }
        else { members.append(Member(key: key, value: replacement)) }
        return try encode(.object(members), budget: budget)
    }

    /// Remove the specified root keys using exact UTF-8 comparisons. Set<String>
    /// is suitable for the release contract's ASCII exclusion fields; document
    /// members are never collected in a String dictionary or compared canonically.
    public static func removingObjectMembers(raw: Data, keys: Set<String>) throws -> Data {
        let budget = Budget()
        guard case .object(let members) = try parse(raw, budget: budget) else {
            throw ContractError.invalidJSON("removal requires root object")
        }
        let remaining = members.filter { member in !keys.contains(where: { exact(member.key, $0) }) }
        return try encode(.object(remaining), budget: budget)
    }

    /// Apply only changes made by a typed model to the original lossless JSON.
    /// Unknown fields and unchanged decimal tokens stay in the raw document.
    /// Stable-ID arrays preserve unknown fields when their members move.
    public static func applyingModelChanges(raw: Data, before: Data, after: Data, inputLimit: Int = maximumInputBytes) throws -> Data {
        let original = try parse(raw, budget: Budget(inputLimit: inputLimit))
        let previous = try parse(before, budget: Budget(inputLimit: inputLimit))
        let next = try parse(after, budget: Budget(inputLimit: inputLimit))
        func same(_ a: Value, _ b: Value) throws -> Bool {
            try encode(a, budget: Budget()) == encode(b, budget: Budget())
        }
        func member(_ values: [Member], _ key: String) -> Value? {
            values.first { exact($0.key, key) }?.value
        }
        func identity(_ value: Value) -> Data? {
            guard case .object(let object) = value,
                  case .string(let id)? = member(object, "id"), !id.isEmpty else { return nil }
            return Data(id.utf8)
        }
        func index(_ values: [Value]) throws -> [Data: Value]? {
            guard !values.isEmpty else { return [:] }
            var result = [Data: Value]()
            var swiftIDs = Set<String>()
            for value in values {
                guard let key = identity(value) else { return nil }
                guard swiftIDs.insert(String(decoding: key, as: UTF8.self)).inserted,
                      result.updateValue(value, forKey: key) == nil else {
                    throw ContractError.invalidJSON("duplicate effective model identity")
                }
            }
            return result
        }
        func patch(_ original: Value, _ previous: Value, _ next: Value) throws -> Value {
            if try same(previous, next) { return original }
            if case .object(var rawMembers) = original,
               case .object(let oldMembers) = previous, case .object(let newMembers) = next {
                for old in oldMembers where member(newMembers, old.key) == nil {
                    rawMembers.removeAll { exact($0.key, old.key) }
                }
                for new in newMembers {
                    let old = member(oldMembers, new.key)
                    if let old, try same(old, new.value) { continue }
                    if let offset = rawMembers.firstIndex(where: { exact($0.key, new.key) }) {
                        rawMembers[offset].value = try old.map { try patch(rawMembers[offset].value, $0, new.value) } ?? new.value
                    } else { rawMembers.append(new) }
                }
                return .object(rawMembers)
            }
            if case .array(let rawValues) = original, case .array(let oldValues) = previous,
               case .array(let newValues) = next,
               let rawIndex = try index(rawValues), let oldIndex = try index(oldValues),
               try index(newValues) != nil {
                return .array(try newValues.map { new in
                    guard let id = identity(new), let old = oldIndex[id], let raw = rawIndex[id] else { return new }
                    return try patch(raw, old, new)
                })
            }
            if case .array(let values) = original,
               values.contains(where: { if case .object = $0 { return true }; return false }),
               !(try same(original, previous)) {
                throw ContractError.invalidJSON("changed object array needs a lossless stable identity")
            }
            return next
        }
        return try encode(patch(original, previous, next), budget: Budget())
    }

    /// Recursive user-object overlay without Foundation number transcoding.
    public static func mergingObjects(raw: Data, changes: Data) throws -> Data {
        func merge(_ old: Value, _ next: Value) -> Value {
            guard case .object(var members) = old, case .object(let changes) = next else { return next }
            for change in changes {
                if let offset = members.firstIndex(where: { exact($0.key, change.key) }) {
                    members[offset].value = merge(members[offset].value, change.value)
                } else { members.append(change) }
            }
            return .object(members)
        }
        return try encode(merge(parse(raw, budget: Budget()), parse(changes, budget: Budget())), budget: Budget())
    }

    private indirect enum Value {
        case null, bool(Bool), number(Number), string(String), array([Value]), object([Member])
    }
    private struct Member {
        let key: String
        var value: Value
    }
    private struct Number {
        let canonical: String
        let isOne: Bool
    }
    private final class Budget {
        let inputLimit: Int
        let totalInputLimit: Int, nodeLimit: Int
        init(inputLimit: Int = maximumInputBytes, inputDocuments: Int = 1) {
            self.inputLimit = inputLimit
            totalInputLimit = max(64 * 1024 * 1024, inputLimit * inputDocuments)
            nodeLimit = inputLimit > maximumInputBytes ? 2_000_000 * inputDocuments : 1_000_000
        }
        var parsedBytes = 0
        var nodes = 0
        var encodedBytes = 0
        func input(_ size: Int) throws {
            guard size <= inputLimit else { throw ContractError.resourceLimit("input bytes") }
            guard size <= totalInputLimit - parsedBytes else { throw ContractError.resourceLimit("embedded JSON bytes") }
            parsedBytes += size
        }
        func node() throws {
            guard nodes < nodeLimit else { throw ContractError.resourceLimit("JSON nodes") }
            nodes += 1
        }
        func output(_ size: Int) throws {
            guard size <= 256 * 1024 * 1024 - encodedBytes else { throw ContractError.resourceLimit("cumulative encoding bytes") }
            encodedBytes += size
        }
    }

    private static func parse(_ data: Data, budget: Budget, detectEncoding: Bool = true) throws -> Value {
        try budget.input(data.count)
        var parser = Parser(bytes: detectEncoding ? try inputUTF8(data) : Array(data), budget: budget)
        let result = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.offset == parser.bytes.count else { throw ContractError.invalidJSON("trailing data") }
        return result
    }

    /// Python's byte-input encoding detection, with explicit validation instead
    /// of a replacement-character decoder. Transcoding is at most 1.5x input.
    private static func inputUTF8(_ data: Data) throws -> [UInt8] {
        let raw = Array(data)
        var width = 1, littleEndian = false, start = 0
        if raw.starts(with: [0, 0, 0xFE, 0xFF]) { width = 4; start = 4 }
        else if raw.starts(with: [0xFF, 0xFE, 0, 0]) { width = 4; littleEndian = true; start = 4 }
        else if raw.starts(with: [0xFE, 0xFF]) { width = 2; start = 2 }
        else if raw.starts(with: [0xFF, 0xFE]) { width = 2; littleEndian = true; start = 2 }
        else if raw.starts(with: [0xEF, 0xBB, 0xBF]) { return Array(raw.dropFirst(3)) }
        else if raw.count >= 4 {
            if raw[0] == 0 { width = raw[1] == 0 ? 4 : 2 }
            else if raw[1] == 0 { width = raw[2] == 0 && raw[3] == 0 ? 4 : 2; littleEndian = true }
        } else if raw.count == 2 {
            if raw[0] == 0 { width = 2 }
            else if raw[1] == 0 { width = 2; littleEndian = true }
        }
        if width == 1 { return raw }
        guard (raw.count - start) % width == 0 else { throw ContractError.invalidJSON("truncated Unicode input") }
        var decoded: [UInt8] = []
        var index = start
        func unit(at index: Int) -> UInt32 {
            var value: UInt32 = 0
            if littleEndian {
                for byte in raw[index..<(index + width)].reversed() { value = value * 256 + UInt32(byte) }
            } else {
                for byte in raw[index..<(index + width)] { value = value * 256 + UInt32(byte) }
            }
            return value
        }
        while index < raw.count {
            var scalar = unit(at: index); index += width
            if width == 2 && (0xD800...0xDBFF).contains(scalar) {
                guard index < raw.count else { throw ContractError.invalidJSON("unpaired input surrogate") }
                let second = unit(at: index); index += width
                guard (0xDC00...0xDFFF).contains(second) else { throw ContractError.invalidJSON("unpaired input surrogate") }
                scalar = 0x10000 + (scalar - 0xD800) * 0x400 + second - 0xDC00
            }
            guard let unicode = UnicodeScalar(scalar) else { throw ContractError.invalidJSON("invalid input Unicode scalar") }
            decoded.append(contentsOf: String(unicode).utf8)
        }
        return decoded
    }

    private struct Parser {
        let bytes: [UInt8]
        let budget: Budget
        var offset = 0
        var peek: UInt8? { offset < bytes.count ? bytes[offset] : nil }
        mutating func whitespace() {
            while let byte = peek, byte == 32 || byte == 9 || byte == 10 || byte == 13 { offset += 1 }
        }
        mutating func consume(_ byte: UInt8) throws {
            guard peek == byte else { throw ContractError.invalidJSON("unexpected token at byte \(offset)") }
            offset += 1
        }
        mutating func literal(_ text: String) throws {
            for byte in text.utf8 { try consume(byte) }
        }
        mutating func value(depth: Int) throws -> Value {
            guard depth <= maximumDepth else { throw ContractError.resourceLimit("JSON depth") }
            try budget.node()
            whitespace()
            guard let first = peek else { throw ContractError.invalidJSON("missing value") }
            switch first {
            case 110: try literal("null"); return .null
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 34: return .string(try string())
            case 91:
                offset += 1; whitespace()
                var children: [Value] = []
                if peek == 93 { offset += 1; return .array(children) }
                while true {
                    children.append(try value(depth: depth + 1)); whitespace()
                    if peek == 93 { offset += 1; return .array(children) }
                    try consume(44)
                }
            case 123:
                offset += 1; whitespace()
                var members: [Member] = []
                // Swift String equality/hash normalizes Unicode. Data does not.
                // Array hashes every byte; Foundation Data hashing may cluster
                // long manifest paths that share the same namespace prefix.
                var keys = Set<[UInt8]>()
                if peek == 125 { offset += 1; return .object(members) }
                while true {
                    whitespace()
                    let key = try string()
                    guard keys.insert(Array(key.utf8)).inserted else { throw ContractError.invalidJSON("duplicate JSON key") }
                    whitespace(); try consume(58)
                    members.append(Member(key: key, value: try value(depth: depth + 1)))
                    whitespace()
                    if peek == 125 { offset += 1; return .object(members) }
                    try consume(44)
                }
            case 45, 48...57: return .number(try number())
            default: throw ContractError.invalidJSON("unexpected value at byte \(offset)")
            }
        }

        mutating func string() throws -> String {
            try consume(34)
            var decoded: [UInt8] = []
            while let byte = peek {
                offset += 1
                if byte == 34 {
                    guard String(bytes: decoded, encoding: .utf8) != nil else { throw ContractError.invalidJSON("invalid UTF-8 string") }
                    // Foundation's encoding initializer strips a leading BOM.
                    // A BOM inside a JSON string is content, not an encoding
                    // marker: retain it after strict UTF-8 validation.
                    return String(decoding: decoded, as: UTF8.self)
                }
                guard byte >= 32 else { throw ContractError.invalidJSON("unescaped string control") }
                if byte != 92 { decoded.append(byte); continue }
                guard let escaped = peek else { throw ContractError.invalidJSON("unfinished escape") }
                offset += 1
                switch escaped {
                case 34, 92, 47: decoded.append(escaped)
                case 98: decoded.append(8)
                case 102: decoded.append(12)
                case 110: decoded.append(10)
                case 114: decoded.append(13)
                case 116: decoded.append(9)
                case 117:
                    let first = try hexQuad()
                    var scalar = first
                    if (0xD800...0xDBFF).contains(first) {
                        guard offset + 1 < bytes.count, bytes[offset] == 92, bytes[offset + 1] == 117 else {
                            throw ContractError.invalidJSON("unpaired high surrogate")
                        }
                        try consume(92); try consume(117)
                        let second = try hexQuad()
                        guard (0xDC00...0xDFFF).contains(second) else { throw ContractError.invalidJSON("unpaired high surrogate") }
                        scalar = 0x10000 + (first - 0xD800) * 0x400 + second - 0xDC00
                    } else if (0xDC00...0xDFFF).contains(first) {
                        throw ContractError.invalidJSON("unpaired low surrogate")
                    }
                    guard let unicode = UnicodeScalar(scalar) else { throw ContractError.invalidJSON("invalid Unicode scalar") }
                    decoded.append(contentsOf: String(unicode).utf8)
                default: throw ContractError.invalidJSON("invalid string escape")
                }
            }
            throw ContractError.invalidJSON("unfinished string")
        }
        mutating func hexQuad() throws -> UInt32 {
            var result: UInt32 = 0
            for _ in 0..<4 {
                guard let byte = peek else { throw ContractError.invalidJSON("unfinished Unicode escape") }
                offset += 1
                let digit: UInt32
                switch byte {
                case 48...57: digit = UInt32(byte - 48)
                case 65...70: digit = UInt32(byte - 55)
                case 97...102: digit = UInt32(byte - 87)
                default: throw ContractError.invalidJSON("invalid Unicode escape")
                }
                result = result * 16 + digit
            }
            return result
        }

        mutating func number() throws -> Number {
            let start = offset
            let negative = peek == 45
            if negative { offset += 1 }
            let integerStart = offset
            if peek == 48 { offset += 1 }
            else {
                guard let byte = peek, (49...57).contains(byte) else { throw ContractError.invalidJSON("invalid number") }
                while let byte = peek, (48...57).contains(byte) { offset += 1 }
            }
            let integerEnd = offset
            var fractionStart = offset, fractionEnd = offset
            var decimal = false
            if peek == 46 {
                decimal = true; offset += 1; fractionStart = offset
                while let byte = peek, (48...57).contains(byte) { offset += 1 }
                fractionEnd = offset
                guard fractionEnd > fractionStart else { throw ContractError.invalidJSON("missing fraction digits") }
            }
            var exponent: Int64 = 0
            if peek == 101 || peek == 69 {
                decimal = true; offset += 1
                let exponentNegative = peek == 45
                if peek == 45 || peek == 43 { offset += 1 }
                let exponentStart = offset
                while let byte = peek, (48...57).contains(byte) {
                    let digit = Int64(byte - 48)
                    guard exponent <= (999_999_999_999_999_999 - digit) / 10 else {
                        throw ContractError.resourceLimit("decimal exponent magnitude")
                    }
                    exponent = exponent * 10 + digit; offset += 1
                }
                guard offset > exponentStart else { throw ContractError.invalidJSON("missing exponent digits") }
                if exponentNegative { exponent = -exponent }
            }
            guard offset - start <= maximumNumberTokenBytes else { throw ContractError.resourceLimit("number token bytes") }
            if !decimal {
                guard integerEnd - integerStart <= maximumIntegerDigits else { throw ContractError.resourceLimit("integer digits") }
                let token = String(decoding: bytes[integerStart..<integerEnd], as: UTF8.self)
                return Number(canonical: (negative && token != "0" ? "-" : "") + token, isOne: !negative && token == "1")
            }
            var digits = Array(bytes[integerStart..<integerEnd])
            digits.append(contentsOf: bytes[fractionStart..<fractionEnd])
            exponent -= Int64(fractionEnd - fractionStart)
            guard let first = digits.firstIndex(where: { $0 != 48 }) else {
                return Number(canonical: negative ? "-0.0" : "0.0", isOne: false)
            }
            var end = digits.count
            while end > first + 1 && digits[end - 1] == 48 { end -= 1; exponent += 1 }
            let coefficient = String(decoding: digits[first..<end], as: UTF8.self)
            let position = Int64(end - first) + exponent
            let prefix = negative ? "-" : ""
            let canonical: String
            if position > 21 || position <= -6 {
                let tail = String(coefficient.dropFirst())
                canonical = prefix + String(coefficient.prefix(1)) + "." + (tail.isEmpty ? "0" : tail) + "e" + String(position - 1)
            } else if position <= 0 {
                canonical = prefix + "0." + String(repeating: "0", count: Int(-position)) + coefficient
            } else if position >= Int64(coefficient.utf8.count) {
                canonical = prefix + coefficient + String(repeating: "0", count: Int(position) - coefficient.utf8.count) + ".0"
            } else {
                let index = coefficient.index(coefficient.startIndex, offsetBy: Int(position))
                canonical = prefix + String(coefficient[..<index]) + "." + String(coefficient[index...])
            }
            return Number(canonical: canonical, isOne: !negative && coefficient == "1" && exponent == 0)
        }
    }

    private static func scalarLess(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }
    private static func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    private static func lookup(_ root: Value, keys: [String]) -> Value? {
        var value = root
        for key in keys {
            guard case .object(let members) = value,
                  let member = members.first(where: { exact($0.key, key) }) else { return nil }
            value = member.value
        }
        return value
    }

    private static func encode(_ value: Value, budget: Budget) throws -> Data {
        var encoder = Encoder(budget: budget)
        try encoder.value(value, depth: 0)
        return encoder.bytes
    }
    private struct Encoder {
        let budget: Budget
        var bytes = Data()
        mutating func append(_ bytes: [UInt8]) throws {
            guard bytes.count <= maximumOutputBytes - self.bytes.count else { throw ContractError.resourceLimit("canonical output bytes") }
            try budget.output(bytes.count)
            self.bytes.append(contentsOf: bytes)
        }
        mutating func text(_ text: String) throws { try append(Array(text.utf8)) }
        mutating func string(_ string: String) throws {
            try text("\"")
            // JSON mandatory escapes only; '/' and all non-ASCII scalars stay UTF-8.
            var run: [UInt8] = []
            for byte in string.utf8 {
                let escape: String?
                switch byte {
                case 34: escape = "\\\""
                case 92: escape = "\\\\"
                case 8: escape = "\\b"
                case 9: escape = "\\t"
                case 10: escape = "\\n"
                case 12: escape = "\\f"
                case 13: escape = "\\r"
                case 0...31: escape = String(format: "\\u%04x", byte)
                default: escape = nil
                }
                if let escape {
                    if !run.isEmpty { try append(run); run.removeAll(keepingCapacity: true) }
                    try text(escape)
                } else { run.append(byte) }
            }
            try append(run); try text("\"")
        }
        mutating func value(_ value: Value, depth: Int) throws {
            guard depth <= maximumDepth else { throw ContractError.resourceLimit("encoding depth") }
            switch value {
            case .null: try text("null")
            case .bool(let flag): try text(flag ? "true" : "false")
            case .number(let number): try text(number.canonical)
            case .string(let text): try string(text)
            case .array(let children):
                try text("[")
                for (index, child) in children.enumerated() {
                    if index > 0 { try text(",") }
                    try self.value(child, depth: depth + 1)
                }
                try text("]")
            case .object(let members):
                try text("{")
                for (index, member) in members.sorted(by: { scalarLess($0.key, $1.key) }).enumerated() {
                    if index > 0 { try text(",") }
                    try string(member.key); try text(":"); try self.value(member.value, depth: depth + 1)
                }
                try text("}")
            }
        }
    }

}
