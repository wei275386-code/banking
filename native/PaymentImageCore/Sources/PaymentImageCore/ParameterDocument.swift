import Foundation

public enum ParameterDocument {
    public static func encoding(_ parameters: FireParameters) throws -> Data {
        var document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parameters)) as! [String: Any]
        document["status"] = parameters.needsInput ? "needs_input" : "ready"
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }
    /// Preserve unexposed settings from the original model on every native save.
    public static func merging(base: Data, changes: Data) throws -> Data {
        func merge(_ old: Any, _ next: Any) -> Any {
            guard var dictionary = old as? [String: Any], let values = next as? [String: Any] else { return next }
            for (key, value) in values { dictionary[key] = dictionary[key].map { merge($0, value) } ?? value }
            return dictionary
        }
        let result = merge(try JSONSerialization.jsonObject(with: base), try JSONSerialization.jsonObject(with: changes))
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    /// Carry only edited leaves onto a newer synced model. Unedited remote leaves survive.
    public static func rebasing(original: Data, draft: Data, onto base: Data) throws -> Data {
        func diff(_ old: [String: Any], _ next: [String: Any]) throws -> [String: Any] {
            var changes = [String: Any]()
            for key in Set(old.keys).union(next.keys) {
                if let oldChild = old[key] as? [String: Any], let newChild = next[key] as? [String: Any] {
                    let nested = try diff(oldChild, newChild)
                    if !nested.isEmpty { changes[key] = nested }
                } else {
                    let previous = try ReviewSyncIO.json(old[key] ?? NSNull())
                    let edited = try ReviewSyncIO.json(next[key] ?? NSNull())
                    if previous != edited { changes[key] = next[key] ?? NSNull() }
                }
            }
            return changes
        }
        guard let old = try JSONSerialization.jsonObject(with: original) as? [String: Any], let next = try JSONSerialization.jsonObject(with: draft) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return try merging(base: base, changes: ReviewSyncIO.json(diff(old, next)))
    }
}
