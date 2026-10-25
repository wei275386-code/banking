import Foundation
import XCTest
@testable import PaymentImageCore

final class ReviewWorkspaceMembershipTests: XCTestCase {
    let workspaceID = "11111111-1111-4111-8111-111111111111"
    let stateID = "22222222-2222-4222-8222-222222222222"
    func root() throws -> URL {
        let canonical = try TestPlatform.temporaryDirectory().path
        let root = URL(fileURLWithPath: canonical + "/membership-test-" + UUID().uuidString)
        try WorkspaceIO.atomicWrite(Data("{\"records\":[{\"id\":\"record-a\",\"amount\":2}]}".utf8), to: root.appendingPathComponent("review/financial-review.json"))
        return root
    }
    func result(_ operation: String, effects: [[String: Any]], inputs: [[String: Any]] = []) throws -> Data {
        let identity = inputs.map { ["input_id": $0["input_id"]!, "sha256": $0["sha256"]!, "kind": $0["kind"]!, "required_financial": $0["required_financial"]!] }
        func hash(_ value: Any) throws -> String { WorkspaceIO.digest(try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))) }
        var effects = effects
        for input in inputs {
            for stage in input["completed_stages"] as? [String] ?? [] {
                let key = "input-stage:" + (try hash([operation, input["input_id"]!, stage]))
                effects.append(["key": key, "kind": "input-stage", "digest": try hash(["input_id": input["input_id"]!, "sha256": input["sha256"]!, "stage": stage])])
            }
        }
        var result: [String: Any] = ["workspace_id": workspaceID, "operation_id": operation, "request_id": operation,
                                    "input_hash": try hash(identity), "algorithm_version": "test",
                                    "phase": "committed", "outcome": "success", "inputs": inputs, "state_id": stateID,
                                    "result_generation": NSNull(), "membership": effects]
        result["result_digest"] = WorkspaceIO.digest(try ReleaseCanonicalJSON.removingObjectMembers(raw: WorkspaceIO.canonical(result), keys: ["result_digest", "result_generation", "phase"]))
        return try WorkspaceIO.canonical(result)
    }
    func validate(_ root: URL, _ results: [Data]) throws {
        let raw = try WorkspaceIO.canonical(["state_id": stateID, "results": []])
        let array = Data("[".utf8) + results.enumerated().reduce(into: Data()) { bytes, item in
            if item.offset > 0 { bytes.append(Data(",".utf8)) }; bytes.append(item.element)
        } + Data("]".utf8)
        let ledger = try ReleaseCanonicalJSON.replacingObjectMember(raw: raw, key: "results", valueRaw: array)
        try ReviewWorkspaceMembership.validate(root: root, ledgerRaw: ledger, workspaceID: workspaceID, stateID: stateID)
    }
    func testActualRecordAndEarlierSupersessionAllowLegitimateEdit() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let entities = try ReviewWorkspaceMembership.currentEntities(root: root)
        let old: [String: Any] = ["key": "old", "entity_key": "record:record-a", "kind": "record", "digest": String(repeating: "b", count: 64)]
        let new: [String: Any] = ["key": "new", "entity_key": "record:record-a", "kind": "record", "digest": entities["record:record-a"]!, "supersedes": ["old"]]
        try validate(root, [result("old-op", effects: [old]), result("new-op", effects: [new])])
        XCTAssertThrowsError(try validate(root, [result("old-op", effects: [old])]))
    }
    func testGlobalDuplicateSelfLaterAndCrossEntityEdgesAreRejected() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let entities = try ReviewWorkspaceMembership.currentEntities(root: root)
        let effect: [String: Any] = ["key": "effect", "entity_key": "record:record-a", "kind": "record", "digest": entities["record:record-a"]!]
        XCTAssertThrowsError(try validate(root, [result("one", effects: [effect]), result("two", effects: [effect])]))
        var selfEdge = effect; selfEdge["supersedes"] = ["effect"]
        XCTAssertThrowsError(try validate(root, [result("self", effects: [selfEdge])]))
        var earlier = effect; earlier["supersedes"] = ["later"]
        var later = effect; later["key"] = "later"; later["supersedes"] = ["effect"]
        XCTAssertThrowsError(try validate(root, [result("one", effects: [earlier]), result("two", effects: [later])]))
        var mismatch = effect; mismatch["key"] = "other"; mismatch["entity_key"] = "document:review/financial-review.json"; mismatch["supersedes"] = ["effect"]
        XCTAssertThrowsError(try validate(root, [result("one", effects: [effect]), result("two", effects: [mismatch])]))
    }
    func testTombstoneRequiresPriorEntityExactDigestAndActualAbsence() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let entity = "record:removed", digest = WorkspaceIO.digest(try WorkspaceIO.canonical(["entity": entity, "deleted": true]))
        let old: [String: Any] = ["key": "old", "entity_key": entity, "kind": "record", "digest": String(repeating: "b", count: 64)]
        var deleted: [String: Any] = ["key": "removed", "entity_key": entity, "kind": "tombstone", "digest": digest]
        XCTAssertThrowsError(try validate(root, [result("deleted", effects: [deleted])]))
        deleted["supersedes"] = ["old"]
        try validate(root, [result("old", effects: [old]), result("deleted", effects: [deleted])])
        deleted["digest"] = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try validate(root, [result("old", effects: [old]), result("deleted", effects: [deleted])]))
        deleted["digest"] = digest
        try WorkspaceIO.atomicWrite(Data("{\"records\":[{\"id\":\"removed\"}]}".utf8), to: root.appendingPathComponent("review/financial-review.json"))
        XCTAssertThrowsError(try validate(root, [result("old", effects: [old]), result("deleted", effects: [deleted])]))
    }
    func testRetainedInputRequiresActualSourceBytesNotReceiptHash() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let entities = try ReviewWorkspaceMembership.currentEntities(root: root)
        let effect: [String: Any] = ["key": "effect", "entity_key": "record:record-a", "kind": "record", "digest": entities["record:record-a"]!]
        let source = Data("real retained input".utf8)
        let sourcePath = "sources/" + WorkspaceIO.digest(source) + "/source.pdf"
        let input: [String: Any] = ["input_id": "input", "sha256": WorkspaceIO.digest(source), "kind": "pdf", "required_financial": true,
                                   "retained": true, "outcome": "success", "completed_stages": ["retained", "projected"], "source_path": sourcePath]
        let r = try result("one", effects: [effect], inputs: [input])
        XCTAssertThrowsError(try validate(root, [r]))
        try WorkspaceIO.atomicWrite(source, to: root.appendingPathComponent(sourcePath))
        try validate(root, [r])
        try WorkspaceIO.atomicWrite(Data("changed".utf8), to: root.appendingPathComponent(sourcePath))
        XCTAssertThrowsError(try validate(root, [r]))
    }
    func testUnkeyedEffectAndConcurrentUnexplainedBusinessHeadsAreRejected() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let digest = try XCTUnwrap(ReviewWorkspaceMembership.currentEntities(root: root)["record:record-a"])
        let unkeyed: [String: Any] = ["key": "invented", "kind": "record", "digest": digest]
        XCTAssertThrowsError(try validate(root, [result("one", effects: [unkeyed])]))
        let one: [String: Any] = ["key": "one", "entity_key": "record:record-a", "kind": "record", "digest": digest]
        let two: [String: Any] = ["key": "two", "entity_key": "record:record-a", "kind": "record", "digest": digest]
        XCTAssertThrowsError(try validate(root, [result("one", effects: [one]), result("two", effects: [two])]))
    }
}
