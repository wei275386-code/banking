import Foundation
import XCTest
@testable import PaymentImageCore

final class ReviewCausalFieldsTests: XCTestCase {
    func testBatchedFieldCaptureRetainsLargeSyntheticOverridesAndLosslessValues() throws {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = "{\"amount\":9007199254740993,\"decimal\":1.0000000000000000000000001,\"note\":\"合成\\nmetadata\"}"
        let rows = (0..<400).map { "\"synthetic-\($0)\":{\"primary\":\"food\",\"secondary\":\"meal\",\"ignored\":null,\"unknown\":\(metadata)}" }
        try Data(("{" + rows.joined(separator: ",") + "}").utf8).write(to: root.appendingPathComponent("review-overrides.json"))
        try Data("{\"nested\":{\"exact\":1.0000000000000000000000001,\"unset\":null,\"empty\":{}}}".utf8).write(to: root.appendingPathComponent("fire-parameters-user.json"))
        try Data("{\"deferred\":[\"synthetic-0\"]}".utf8).write(to: root.appendingPathComponent("completion-workflow.json"))
        let before = try Dictionary(uniqueKeysWithValues: WorkspaceIO.regularFiles(root).map { ($0, try WorkspaceIO.hash(root.appendingPathComponent($0))) })
        let fields = try ReviewFieldDocuments.capture(review: root)
        XCTAssertEqual(fields.count, 804)
        for index in 0..<400 {
            XCTAssertEqual(fields["override/synthetic-\(index)/unknown"], metadata)
            XCTAssertEqual(fields["override/synthetic-\(index)/@category"], "{\"primary\":\"food\",\"secondary\":\"meal\"}")
        }
        XCTAssertEqual(fields["parameter/nested/exact"], "1.0000000000000000000000001")
        XCTAssertEqual(fields["parameter/nested/empty"], "{}")
        XCTAssertEqual(fields["parameter/nested/unset"], "null")
        let family = try ReviewFieldDocuments.capture(review: root)
        XCTAssertEqual(family["parameter/nested/unset"], "null")
        XCTAssertEqual(family, fields)
        XCTAssertEqual(try Dictionary(uniqueKeysWithValues: WorkspaceIO.regularFiles(root).map { ($0, try WorkspaceIO.hash(root.appendingPathComponent($0))) }), before)
    }
    func testBatchedFieldCaptureStillRejectsMalformedObjectsAndUnsafeComponents() throws {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for raw in ["[]", "{\"safe\":3}", "{\"bad/id\":{}}", "{\"safe\":{\"bad/field\":true}}", "{\"safe\":{\"a\":1,\"a\":2}}"] {
            try Data(raw.utf8).write(to: root.appendingPathComponent("review-overrides.json"))
            XCTAssertThrowsError(try ReviewFieldDocuments.capture(review: root), raw)
        }
    }
    let selection = try! ReviewFamilyBindingSelection(workspaceID: "11111111-1111-4111-8111-111111111111", bindingID: "22222222-2222-4222-8222-222222222222", hostID: "33333333-3333-4333-8333-333333333333")
    func revision(device: String, clock: Int, value: String, parents: [String] = [], observed: [String: Int] = [:]) throws -> ReviewNativeRevision {
        let raw = try JSONEncoder().encode(ReviewRevision(id: UUID().uuidString.lowercased(), device: device, clock: clock,
                                                        values: ["parameter/salary": value], bases: ["parameter/salary": "0"], observed: observed, parents: parents))
        return try ReviewNativeRevision(sourceBindingID: selection.bindingID, raw: raw)
    }
    func checkpoint(_ revisions: [ReviewNativeRevision]) throws -> ReviewCausalFieldCheckpoint {
        guard case .ready(let result) = try ReviewCausalFields.prepare(seedValues: ["parameter/untouched": "9007199254740993"], revisions: revisions, selection: selection) else { throw WorkspaceError.invalid("not ready") }
        return result
    }
    func testConcurrentHeadsRemainAndResolutionUsesRealCausality() throws {
        let a = try revision(device: "A", clock: 1, value: "1.25"), b = try revision(device: "B", clock: 1, value: "2.5")
        let concurrent = try checkpoint([a, b])
        XCTAssertEqual(concurrent.conflicts, ["parameter/salary"])
        XCTAssertEqual(concurrent.heads["parameter/salary"]?.count, 2)
        XCTAssertEqual(concurrent.values["parameter/untouched"], "9007199254740993")
        let resolution = try revision(device: "C", clock: 2, value: "3", parents: [a.revision.id, b.revision.id])
        let resolved = try checkpoint([resolution, b, a])
        XCTAssertTrue(resolved.conflicts.isEmpty); XCTAssertEqual(resolved.values["parameter/salary"], "3")
        XCTAssertEqual(resolved.frontier, [resolution.revision.id])
        XCTAssertEqual(resolved.revisions.count, 3)
    }
    func testMissingParentWaitsAndNativeSourceIdentityCannotAlias() throws {
        let parent = try revision(device: "A", clock: 1, value: "1")
        let child = try revision(device: "B", clock: 2, value: "2", parents: [parent.revision.id])
        if case .waiting(let missing) = try ReviewCausalFields.prepare(seedValues: [:], revisions: [child], selection: selection) { XCTAssertEqual(missing, [parent.revision.id]) }
        else { XCTFail("should wait for parent bytes") }
        XCTAssertEqual(try checkpoint([parent, parent]).revisions.count, 1)
        let changedRaw = try ReleaseCanonicalJSON.replacingObjectMember(raw: parent.raw, key: "values", valueRaw: Data("{\"parameter/salary\":\"99\"}".utf8))
        let conflicting = try ReviewNativeRevision(sourceBindingID: selection.bindingID, raw: changedRaw)
        XCTAssertThrowsError(try checkpoint([parent, conflicting]))
    }
    func testCheckpointInitializationIsNotAUserRevisionAndFullReplayEquivalent() throws {
        let empty = try checkpoint([])
        XCTAssertTrue(empty.revisions.isEmpty); XCTAssertTrue(empty.frontier.isEmpty)
        let a = try revision(device: "A", clock: 1, value: "1.0"), b = try revision(device: "A", clock: 2, value: "2", observed: ["A": 1])
        let first = try checkpoint([a])
        let incrementallyRetained = try checkpoint(first.revisions + [b])
        let full = try checkpoint([b, a])
        XCTAssertEqual(try incrementallyRetained.fieldState(), try full.fieldState())
        XCTAssertEqual(incrementallyRetained.inventory, full.inventory)
        XCTAssertEqual(incrementallyRetained.revisions.count, 2)
    }
    func testClockCollisionAndCrossBindingOriginAreRejected() throws {
        let a = try revision(device: "A", clock: 1, value: "1"), b = try revision(device: "A", clock: 1, value: "2")
        XCTAssertThrowsError(try checkpoint([a, b]))
        let foreign = try ReviewNativeRevision(sourceBindingID: UUID().uuidString.lowercased(), raw: a.raw)
        XCTAssertThrowsError(try checkpoint([foreign]))
    }
}
