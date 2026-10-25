import Foundation
import CryptoKit

/// One retained recording whose projected stage is still absent. The original
/// input selection is display-only; repairs always reopen sourcePath in state.
public struct PendingVideoInput: Codable, Sendable, Equatable, Identifiable {
    public let workspaceID: String
    public let parentRequestID: String
    public let inputID: String
    public let sha256: String
    public let sourcePath: String
    public let requiredFinancial: Bool
    public let reason: String
    public var id: String { parentRequestID + ":" + inputID }
    public var displayName: String { URL(fileURLWithPath: inputID).lastPathComponent }
    public var reasonMessage: String {
        ["unsupported_video_layout": "录屏布局尚不支持", "unconfirmed_video_fields": "录屏字段尚待确认"][reason] ?? reason
    }
    public var childIdentity: (requestID: String, operationID: String) {
        get throws {
            let raw = try JSONSerialization.data(withJSONObject: [workspaceID, parentRequestID, inputID, "projected"], options: [.withoutEscapingSlashes])
            let key = WorkspaceIO.digest(try ReleaseCanonicalJSON.canonicalize(raw: raw))
            guard var namespace = UUID(uuidString: workspaceID)?.uuid else { throw WorkspaceError.invalid("repair workspace UUID") }
            func uuid(_ name: String) -> String {
                var raw = withUnsafeBytes(of: &namespace) { Data($0) }; raw.append(Data(name.utf8))
                var bytes = Array(Insecure.SHA1.hash(data: raw).prefix(16))
                bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
                let hex = bytes.map { String(format: "%02x", $0) }.joined()
                return [String(hex.prefix(8)), String(hex.dropFirst(8).prefix(4)), String(hex.dropFirst(12).prefix(4)), String(hex.dropFirst(16).prefix(4)), String(hex.dropFirst(20))].joined(separator: "-")
            }
            return (uuid("request:" + key), uuid("operation:" + key))
        }
    }
    internal var inputIdentity: [String: Any] {
        ["input_id": inputID, "sha256": sha256, "kind": "video", "required_financial": requiredFinancial]
    }
}

public struct PendingVideoList: Sendable, Equatable {
    public let items: [PendingVideoInput]
    public let total: Int
    /// Caller passes a manifest- and membership-verified pinned handle. Work
    /// stays off the UI thread; only the bounded list reaches view state.
    public static func load(state: StateHandle, limit: Int = 100) throws -> PendingVideoList {
        try parse(raw: WorkspaceIO.read(state.operationResults), workspaceID: state.pointer.workspaceID, limit: limit)
    }
    public static func contains(_ input: PendingVideoInput, state: StateHandle) throws -> Bool {
        try parse(raw: WorkspaceIO.read(state.operationResults), workspaceID: state.pointer.workspaceID, limit: 1, matching: input).items == [input]
    }
    internal static func parse(raw: Data, workspaceID: String, limit: Int = 100, matching: PendingVideoInput? = nil) throws -> PendingVideoList {
        let ledger = try WorkspaceIO.object(raw)
        guard let results = ledger["results"] as? [[String: Any]] else { throw WorkspaceError.invalid("pending ledger") }
        var children = [String: [[String: Any]]]()
        for result in results {
            if let parent = result["parent_request_id"] as? String { children[parent, default: []].append(result) }
        }
        var items = [PendingVideoInput](), total = 0
        for parent in results where parent["outcome"] as? String == "partial" && parent["phase"] as? String == "committed" {
            guard parent["workspace_id"] as? String == workspaceID, let request = parent["request_id"] as? String,
                  let inputs = parent["inputs"] as? [[String: Any]] else { continue }
            for input in inputs where input["kind"] as? String == "video" && input["outcome"] as? String == "pending" {
                guard input["retained"] as? Bool == true, input["completed_stages"] as? [String] == ["retained"],
                      let id = input["input_id"] as? String, let hash = input["sha256"] as? String,
                      let source = input["source_path"] as? String, source.hasPrefix("sources/" + hash + "/"),
                      let required = input["required_financial"] as? Bool else { throw WorkspaceError.invalid("pending source identity") }
                let pending = PendingVideoInput(workspaceID: workspaceID, parentRequestID: request, inputID: id,
                    sha256: hash, sourcePath: source, requiredFinancial: required, reason: input["reason"] as? String ?? "等待解析")
                if let matching, pending != matching { continue }
                let identity = try pending.childIdentity
                let stageKey = "input-stage:" + WorkspaceIO.digest(try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: [request, id, "projected"], options: [.withoutEscapingSlashes])))
                let stageDigest = WorkspaceIO.digest(try WorkspaceIO.canonical(["input_id": id, "sha256": hash, "stage": "projected"]))
                let resolved = (children[request] ?? []).contains { child in
                    guard child["workspace_id"] as? String == workspaceID, child["phase"] as? String == "committed",
                          child["outcome"] as? String == "success", child["request_id"] as? String == identity.requestID,
                          child["operation_id"] as? String == identity.operationID,
                          let inputs = child["inputs"] as? [[String: Any]], inputs.count == 1, let selected = inputs.first,
                          selected["input_id"] as? String == id, selected["sha256"] as? String == hash,
                          selected["kind"] as? String == "video", selected["required_financial"] as? Bool == required,
                          selected["source_path"] as? String == source, selected["retained"] as? Bool == true,
                          selected["outcome"] as? String == "success", selected["completed_stages"] as? [String] == ["retained", "projected"],
                          let effects = child["membership"] as? [[String: Any]] else { return false }
                    let stages = effects.filter { $0["kind"] as? String == "input-stage" }
                    return stages.count == 1 && stages[0]["key"] as? String == stageKey && stages[0]["digest"] as? String == stageDigest
                }
                if !resolved { total += 1; if items.count < max(0, limit) { items.append(pending) } }
            }
        }
        return PendingVideoList(items: items, total: total)
    }
}

/// Machine result from the business script, not proof of an atomic state commit.
public struct ProcessorResult: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable { case success, partial, failed, cancelled }
    public struct Input: Codable, Sendable, Equatable {
        public struct Failure: Codable, Sendable, Equatable {
            public let code: String
            public let message: String
        }
        public let inputID: String
        public let outcome: String
        public let error: Failure?
        enum CodingKeys: String, CodingKey { case inputID = "input_id", outcome, error, reason }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            inputID = try values.decode(String.self, forKey: .inputID)
            outcome = try values.decode(String.self, forKey: .outcome)
            error = try values.decodeIfPresent(Failure.self, forKey: .error) ?? values.decodeIfPresent(String.self, forKey: .reason).map { reason in
                Failure(code: reason, message: ["unsupported_video_layout": "录屏布局尚不支持，素材已保留。", "unconfirmed_video_fields": "录屏字段尚待确认，素材已保留。"][reason] ?? reason)
            }
        }
        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(inputID, forKey: .inputID); try values.encode(outcome, forKey: .outcome)
            try values.encodeIfPresent(error, forKey: .error)
        }
    }
    public let workspaceID: String?
    public let stateID: String?
    public let resultDigest: String?
    public let requestID: String?
    public let operationID: String
    // An open string allows later phase vocabulary. Only known applied phases
    // can authorize success. Version 1 does not implement committed semantics.
    public let phase: String
    public let outcome: Outcome
    public let message: String
    public let inputs: [Input]
    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", stateID = "state_id", resultDigest = "result_digest", requestID = "request_id"
        case operationID = "operation_id", phase, outcome, message, inputs
    }
    public var isFullySuccessful: Bool {
        hasCommittedChanges && outcome == .success && inputs.allSatisfy { $0.outcome == "success" && $0.error == nil }
    }
    public var hasCommittedChanges: Bool {
        phase == "committed" && (outcome == .success || outcome == .partial) && workspaceID != nil && stateID != nil && resultDigest != nil && requestID != nil
    }
    public func validate(operationID expected: String) throws {
        // Aborted operations can retain an input before its action fails. Such inputs
        // remain unknown, while the top-level result explains the failure.
        let aborted = stateID == nil &&
            ((phase == "failed" && outcome == .failed) || (phase == "cancelled" && outcome == .cancelled))
        guard operationID == expected, !phase.isEmpty,
              Set(inputs.map(\.inputID)).count == inputs.count,
              inputs.allSatisfy({ !$0.inputID.isEmpty && ["success", "failed", "unknown", "pending"].contains($0.outcome) &&
                  ($0.outcome == "success" ? $0.error == nil : ($0.error != nil || (aborted && $0.outcome == "unknown"))) }),
              outcome != .success || isFullySuccessful,
              outcome != .partial || (hasCommittedChanges && inputs.contains { $0.outcome != "success" })
        else { throw CocoaError(.fileReadCorruptFile) }
    }
}
