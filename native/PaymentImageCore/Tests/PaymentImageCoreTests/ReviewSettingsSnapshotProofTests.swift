import XCTest
import Foundation
@testable import PaymentImageCore

final class ReviewSettingsSnapshotProofTests: XCTestCase {
    private func fixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "settings-snapshot-golden", withExtension: "json", subdirectory: "Fixtures")))
    }
    private func fragment(_ raw: Data, _ key: String) throws -> Data {
        try XCTUnwrap(ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: [key]))
    }
    private func object(_ raw: Data) throws -> [String: Data] {
        Dictionary(uniqueKeysWithValues: try ReleaseCanonicalJSON.canonicalObjectEntries(raw: raw).map { ($0.key, $0.value) })
    }
    private func replace(_ raw: Data, path: [String], value: Data, remove: Bool = false) throws -> Data {
        guard let key = path.first else { return value }
        if raw.first == 91 {
            var rows = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: []))
            let index = try XCTUnwrap(Int(key))
            if path.count == 1 && remove { rows.remove(at: index) }
            else { rows[index] = try replace(rows[index], path: Array(path.dropFirst()), value: value, remove: remove) }
            return Data(("[" + rows.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]").utf8)
        }
        if path.count == 1 && remove {
            let entries = try ReleaseCanonicalJSON.canonicalObjectEntries(raw: raw).filter { Data($0.key.utf8) != Data(key.utf8) }
            let pieces = try entries.map { String(decoding: try JSONEncoder().encode($0.key), as: UTF8.self) + ":" + String(decoding: $0.value, as: UTF8.self) }
            return try ReleaseCanonicalJSON.canonicalize(raw: Data(("{" + pieces.joined(separator: ",") + "}").utf8))
        }
        let child = path.count == 1 ? value : try replace(fragment(raw, key), path: Array(path.dropFirst()), value: value, remove: remove)
        return try ReleaseCanonicalJSON.replacingObjectMember(raw: raw, key: key, valueRaw: child)
    }
    private func context(_ fixture: Data) throws -> HouseholdSettingsContext {
        let value = try JSONDecoder().decode([String: [String]].self, from: fragment(fixture, "context"))
        return HouseholdSettingsContext(registeredSourceIDs: value["registered_source_ids"]!, currencyCodes: value["currency_codes"]!,
            referencedMemberIDs: value["referenced_member_ids"]!, referencedAccountIDs: value["referenced_account_ids"]!)
    }
    private func pins(_ fixture: Data, generation: String) throws -> ReviewSettingsSnapshotPins {
        let values = try JSONDecoder().decode([String: String].self, from: fragment(fixture, "pins"))
        return try ReviewSettingsSnapshotPins(workspaceID: values["workspace_id"]!, bindingID: values["binding_id"]!, hostID: values["host_id"]!, generation: generation)
    }
    private func seal(_ packet: Data) throws -> [String: Data] {
        var parts = try object(packet)
        let stateHash = try JSONEncoder().encode(WorkspaceIO.digest(parts["state_manifest"]!))
        parts["checkpoint"] = try replace(parts["checkpoint"]!, path: ["state", "state_manifest_hash"], value: stateHash)
        parts["business_proof"] = try replace(parts["business_proof"]!, path: ["state_manifest_hash"], value: stateHash)
        for (part, path) in [("state_manifest", "state-manifest.json"), ("business_proof", "business-proof.json"), ("field_state", "field-state.json")] {
            parts["checkpoint"] = try replace(parts["checkpoint"]!, path: ["files", path], value: JSONEncoder().encode(WorkspaceIO.digest(parts[part]!)))
        }
        return parts
    }
    private func validate(_ parts: [String: Data], fixture: Data, generation: String? = nil,
                          overrideContext: HouseholdSettingsContext? = nil) throws -> HouseholdSettings {
        let docs = try object(parts["snapshot_documents"]!)
        let values = try JSONDecoder().decode([String: String].self, from: parts["replayed_values"]!)
        let conflicts = try JSONDecoder().decode([String].self, from: parts["replayed_conflict_keys"]!)
        return try ReviewSettingsSnapshotProof.validate(pins: pins(fixture, generation: generation ?? WorkspaceIO.digest(parts["checkpoint"]!)),
            checkpointRaw: parts["checkpoint"]!, stateManifestRaw: parts["state_manifest"]!, businessProofRaw: parts["business_proof"]!,
            fieldStateRaw: parts["field_state"]!, snapshotDocuments: docs, replayedValues: values, replayedConflictKeys: Set(conflicts),
            context: overrideContext ?? context(fixture))
    }
    func testSharedBaselineWholeDocumentCodec() throws {
        let fixture = try fixture(), base = try fragment(fixture, "base"), settings = try validate(seal(base), fixture: fixture)
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalize(raw: JSONEncoder().encode(ReviewSettingsFieldDocuments.values(settings))), try fragment(base, "replayed_values"))
    }
    func testSharedResealedAdversarialVectorsRejectInnerMismatch() throws {
        let fixture = try fixture(), base = try fragment(fixture, "base")
        let cases = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: fixture, atObjectKeys: ["invalid_cases"]))
        for raw in cases {
            let name = try JSONDecoder().decode(String.self, from: fragment(raw, "name"))
            let mutations = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["mutations"]) ?? [raw]
            var packet = base
            for mutation in mutations {
                let row = try object(mutation), target = try JSONDecoder().decode(String.self, from: row["target"]!), path = try JSONDecoder().decode([String].self, from: row["path"]!)
                packet = try replace(packet, path: [target] + path, value: row["value"]!, remove: row["remove"] == Data("true".utf8))
            }
            // Fixture decoding may itself reject a null field, so include the
            // whole validation expression in this assertion.
            XCTAssertThrowsError(try validate(seal(packet), fixture: fixture), name)
        }
    }
    func testGenerationAndRawMetadataTamperingFail() throws {
        let fixture = try fixture(), base = try fragment(fixture, "base")
        for part in ["checkpoint", "state_manifest", "business_proof", "field_state"] {
            var parts = try seal(base)
            parts[part] = try replace(parts[part]!, path: ["extra_tamper"], value: Data("true".utf8))
            let oldGeneration = WorkspaceIO.digest(try seal(base)["checkpoint"]!)
            XCTAssertThrowsError(try validate(parts, fixture: fixture, generation: oldGeneration), part)
        }
        XCTAssertThrowsError(try validate(seal(base), fixture: fixture, generation: String(repeating: "f", count: 64)))
    }
    func testNoncanonicalDuplicateAndNullMetadataRejectAfterRehashing() throws {
        let fixture = try fixture(), base = try fragment(fixture, "base")
        for (part, path) in [("checkpoint", ""), ("state_manifest", "state-manifest.json"), ("business_proof", "business-proof.json"), ("field_state", "field-state.json")] {
            for index in 0..<3 {
                var parts = try seal(base)
                parts[part] = index == 0 ? parts[part]! + Data("\n".utf8) : Data((index == 1 ? "{\"duplicate\":1,\"duplicate\":2}" : "null").utf8)
                if part != "checkpoint" {
                    parts["checkpoint"] = try replace(parts["checkpoint"]!, path: ["files", path], value: JSONEncoder().encode(WorkspaceIO.digest(parts[part]!)))
                }
                XCTAssertThrowsError(try validate(parts, fixture: fixture), part)
            }
        }
    }
    func testBaselineAndExplicitOrdinarySettingsHeadsBothValidate() throws {
        let fixture = try fixture(), base = try fragment(fixture, "base"), settings = try validate(seal(base), fixture: fixture)
        let rows = ReviewSettingsFieldDocuments.proofRows(settings)
        let heads = rows.map { ["path": $0["state_path"]!, "snapshot_path": $0["snapshot_path"]!, "sha256": $0["sha256"]!] }
        var packet = try replace(base, path: ["business_proof", "documents"], value: ReleaseCanonicalJSON.canonicalize(raw: JSONEncoder().encode(heads)))
        packet = try replace(packet, path: ["business_proof", "settings_documents"], value: ReleaseCanonicalJSON.canonicalize(raw: JSONEncoder().encode(Array(rows.reversed()))))
        XCTAssertEqual(try validate(seal(packet), fixture: fixture).profileData, settings.profileData)
        packet = try replace(packet, path: ["business_proof", "documents"], value: ReleaseCanonicalJSON.canonicalize(raw: JSONEncoder().encode(heads + [heads[0]])))
        XCTAssertThrowsError(try validate(seal(packet), fixture: fixture))
    }
    func testBusinessContextStillGatesMatchingHashes() throws {
        let fixture = try fixture(), base = try fragment(fixture, "base")
        let missingSources = HouseholdSettingsContext(registeredSourceIDs: [], currencyCodes: ["CNY"], referencedMemberIDs: [], referencedAccountIDs: [])
        XCTAssertThrowsError(try validate(seal(base), fixture: fixture, overrideContext: missingSources))
    }
    func testInputSizeAndDepthAreBounded() throws {
        let fixture = try fixture(), base = try fragment(fixture, "base")
        for raw in [Data(repeating: 32, count: 16 * 1024 * 1024 + 1), Data((String(repeating: "[", count: 130) + "0" + String(repeating: "]", count: 130)).utf8)] {
            var parts = try seal(base); parts["checkpoint"] = raw
            XCTAssertThrowsError(try validate(parts, fixture: fixture))
        }
    }
    func testInitialGenerationCanFollowUnusedSequenceReservations() throws {
        let fixture = try fixture(), base = try fragment(fixture, "base")
        let packet = try replace(base, path: ["checkpoint", "sequence"], value: Data("7".utf8))
        XCTAssertNoThrow(try validate(seal(packet), fixture: fixture))
    }
    func testStrictHashChecksPreserveValidExternalPinsAndExtraFileMaps() throws {
        let fixture = try fixture(), validHash = String(repeating: "abcdef0123456789", count: 4)
        var packet = try fragment(fixture, "base")
        packet = try replace(packet, path: ["checkpoint", "sequence"], value: Data("2".utf8))
        packet = try replace(packet, path: ["checkpoint", "parent_generation"], value: JSONEncoder().encode(validHash))
        let parent: [String: Any] = ["workspace_id": "11111111-1111-4111-8111-111111111111",
            "state_id": "previous-mock-state", "local_revision": 6, "state_manifest_hash": validHash]
        packet = try replace(packet, path: ["state_manifest", "parent_pointer"], value: WorkspaceIO.canonical(parent))
        for key in ["checkpoint", "state_manifest"] {
            packet = try replace(packet, path: [key, "files", "mock/retained.json"], value: JSONEncoder().encode(validHash))
        }
        XCTAssertNoThrow(try validate(seal(packet), fixture: fixture))
    }
}
