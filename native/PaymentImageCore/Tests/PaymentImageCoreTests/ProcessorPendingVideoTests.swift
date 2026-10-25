import XCTest
import Foundation
@testable import PaymentImageCore

final class ProcessorPendingVideoTests: XCTestCase {
    private let workspaceID = "f1e2d3c4-b5a6-4789-8abc-0123456789ab"
    private let parentID = "11223344-5566-4788-99aa-bbccddeeff00"
    private func pending(_ id: String = "資料/recording:a.mov") -> PendingVideoInput {
        PendingVideoInput(workspaceID: workspaceID, parentRequestID: parentID, inputID: id,
            sha256: String(repeating: "a", count: 64), sourcePath: "sources/" + String(repeating: "a", count: 64) + "/recording.mov",
            requiredFinancial: false, reason: "unsupported_video_layout")
    }
    private func input(_ value: PendingVideoInput, completed: Bool) -> [String: Any] {
        value.inputIdentity.merging(["source_path": value.sourcePath, "retained": true,
            "completed_stages": completed ? ["retained", "projected"] : ["retained"],
            "outcome": completed ? "success" : "pending", "reason": value.reason]) { _, new in new }
    }
    private func parent(_ values: [PendingVideoInput]) -> [String: Any] {
        ["workspace_id": workspaceID, "request_id": parentID, "phase": "committed", "outcome": "partial",
         "inputs": values.map { input($0, completed: false) }]
    }
    private func child(_ value: PendingVideoInput) throws -> [String: Any] {
        let identity = try value.childIdentity
        let key = WorkspaceIO.digest(try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: [parentID, value.inputID, "projected"], options: [.withoutEscapingSlashes])))
        let digest = WorkspaceIO.digest(try WorkspaceIO.canonical(["input_id": value.inputID, "sha256": value.sha256, "stage": "projected"]))
        return ["workspace_id": workspaceID, "parent_request_id": parentID, "request_id": identity.requestID,
            "operation_id": identity.operationID, "phase": "committed", "outcome": "success",
            "inputs": [input(value, completed: true)], "membership": [["kind": "input-stage", "key": "input-stage:" + key, "digest": digest]]]
    }
    private func list(_ results: [[String: Any]], limit: Int = 100) throws -> PendingVideoList {
        try PendingVideoList.parse(raw: WorkspaceIO.canonical(["results": results]), workspaceID: workspaceID, limit: limit)
    }
    func testChildIdentityMatchesPythonUnicodeDelimiterGolden() throws {
        let identity = try pending().childIdentity
        // Generated independently by scripts.workspace_repair.child_identity.
        XCTAssertEqual(identity.requestID, "048405be-95e6-54ae-832f-4bcd1f337d25")
        XCTAssertEqual(identity.operationID, "9dd72edd-c56a-5f7e-9d75-7e0f053887b0")
    }
    func testOnlyExactCompletedSourceAndParentProofSuppressesPending() throws {
        let value = pending(), original = parent([value]), resolved = try child(value)
        XCTAssertEqual(try list([original]).items, [value])
        XCTAssertEqual(try list([original, resolved]).total, 0)
        for mutation in ["source", "hash", "parent", "stage", "request", "operation", "failed", "required"] {
            var incorrect = resolved
            var inputs = incorrect["inputs"] as! [[String: Any]]
            switch mutation {
            case "source": inputs[0]["source_path"] = value.sourcePath + ".different"
            case "hash": inputs[0]["sha256"] = String(repeating: "b", count: 64)
            case "parent": incorrect["parent_request_id"] = UUID().uuidString
            case "stage": incorrect["membership"] = []
            case "request": incorrect["request_id"] = UUID().uuidString
            case "operation": incorrect["operation_id"] = UUID().uuidString
            case "failed": incorrect["outcome"] = "failed"
            case "required": inputs[0]["required_financial"] = true
            default: XCTFail("unknown case")
            }
            incorrect["inputs"] = inputs
            XCTAssertEqual(try list([original, incorrect]).items, [value], mutation)
        }
    }
    func testVisibleListIsBoundedAndKeepsTotalForLaterRefresh() throws {
        let values = (0..<105).map { pending(FileManager.default.temporaryDirectory.appendingPathComponent("original/recording-\($0).mov").path) }
        let result = try list([parent(values)])
        XCTAssertEqual(result.total, 105); XCTAssertEqual(result.items.count, 100)
        XCTAssertEqual(result.items, Array(values.prefix(100)))
        XCTAssertEqual(try list([parent(values)], limit: 0).items, [])
    }
    func testAbortedV2UnknownInputIsDiagnosticWithoutCommitAuthority() throws {
        let raw: [String: Any] = ["workspace_id": workspaceID, "operation_id": parentID, "request_id": parentID,
            "state_id": NSNull(), "result_digest": String(repeating: "a", count: 64), "phase": "failed", "outcome": "failed",
            "message": "录屏仍需确认", "inputs": [["input_id": "recording.mov", "outcome": "unknown"]]]
        let result = try JSONDecoder().decode(ProcessorResult.self, from: WorkspaceIO.canonical(raw))
        XCTAssertNoThrow(try result.validate(operationID: parentID)); XCTAssertFalse(result.hasCommittedChanges)
        var forged = raw; forged["phase"] = "committed"; forged["outcome"] = "success"; forged["state_id"] = parentID
        let claimed = try JSONDecoder().decode(ProcessorResult.self, from: WorkspaceIO.canonical(forged))
        XCTAssertThrowsError(try claimed.validate(operationID: parentID))
    }
}
