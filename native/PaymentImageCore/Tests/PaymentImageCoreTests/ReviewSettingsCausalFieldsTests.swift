import XCTest
import Foundation
@testable import PaymentImageCore

@MainActor final class ReviewSettingsCausalFieldsTests: XCTestCase {
    let binding = "22222222-2222-4222-8222-222222222222"
    let profileKey = "settings/family-profile", policiesKey = "settings/account-policies"
    private func fixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "household-settings-golden", withExtension: "json", subdirectory: "Fixtures")))
    }
    private func fragment(_ raw: Data, _ key: String) throws -> Data { try XCTUnwrap(ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: [key])) }
    private func context(members: [String] = ["member-a"], accounts: [String] = ["account-a"]) -> HouseholdSettingsContext {
        .init(registeredSourceIDs: ["source-a", "source-b"], currencyCodes: ["CNY", "USD"], referencedMemberIDs: members, referencedAccountIDs: accounts)
    }
    private func settings() throws -> HouseholdSettings {
        let f = try fixture()
        return try .init(profileData: fragment(f, "profile"), policiesData: fragment(f, "policies"), context: context())
    }
    private func profile(_ name: String) throws -> String {
        String(decoding: try ReleaseCanonicalJSON.replacingObjectMember(raw: settings().profileData, key: "household_name", valueRaw: JSONEncoder().encode(name)), as: UTF8.self)
    }
    private func revision(_ values: [String: String], device: String, clock: Int = 1, parents: [String] = [], bases: [String: String] = [:]) throws -> ReviewNativeRevision {
        let raw = try JSONEncoder().encode(ReviewRevision(id: UUID().uuidString.lowercased(), device: device, clock: clock,
            values: values, bases: bases, observed: [:], parents: parents))
        return try .init(sourceBindingID: binding, raw: raw)
    }
    private func prepare(_ revisions: [ReviewNativeRevision], seed: [String: String]? = nil,
                         context: HouseholdSettingsContext? = nil) throws -> ReviewSettingsCausalPreparation {
        try ReviewSettingsCausalFields.prepare(seedValues: seed ?? ReviewSettingsFieldDocuments.values(settings()), revisions: revisions,
            bindingID: binding, context: context ?? self.context())
    }
    private func ready(_ result: ReviewSettingsCausalPreparation) throws -> ReviewSettingsCausalCheckpoint {
        guard case .ready(let value) = result else { throw WorkspaceError.invalid("expected qualified settings") }; return value
    }
    private func selection() throws -> ReviewFamilyBindingSelection {
        try .init(workspaceID: "11111111-1111-4111-8111-111111111111", bindingID: binding, hostID: "33333333-3333-4333-8333-333333333333")
    }
    func testFamilyBaselineCreatesNoUserOriginAndRequiresCompleteValidSeedPair() throws {
        let empty = try ready(prepare([]))
        XCTAssertTrue(empty.causal.revisions.isEmpty); XCTAssertTrue(empty.causal.heads.isEmpty)
        XCTAssertEqual(empty.settings.profileData, try settings().profileData)
        var seed = try ReviewSettingsFieldDocuments.values(settings()); seed.removeValue(forKey: profileKey)
        XCTAssertThrowsError(try prepare([], seed: seed))
        seed = try ReviewSettingsFieldDocuments.values(settings()); seed["settings/unknown"] = "{\"schema_version\":1}"
        XCTAssertThrowsError(try prepare([], seed: seed))
        seed = try ReviewSettingsFieldDocuments.values(settings()); seed[profileKey] = "{\"schema_version\":1}"
        XCTAssertThrowsError(try prepare([], seed: seed))
    }
    func testAToBToAAndEqualValueDistinctOriginsPreserveEveryRawOperation() throws {
        let a = try revision([profileKey: profile("A")], device: "a")
        let b = try revision([profileKey: profile("B")], device: "b", clock: 2, parents: [a.revision.id])
        let back = try revision([profileKey: profile("A")], device: "a", clock: 3, parents: [b.revision.id])
        let full = try ready(prepare([back, b, a])).causal
        XCTAssertEqual(full.values[profileKey], try profile("A")); XCTAssertEqual(full.revisions.count, 3)
        XCTAssertEqual(full.frontier, [back.revision.id]); XCTAssertEqual(full.revisions.map(\.raw), [a.raw, b.raw, back.raw])
        let same = try revision([profileKey: profile("A")], device: "other")
        let equal = try ready(prepare([a, same])).causal
        XCTAssertEqual(equal.heads[profileKey]?.count, 2); XCTAssertEqual(equal.revisions.count, 2); XCTAssertTrue(equal.conflicts.isEmpty)
        XCTAssertEqual(Set(equal.revisions.map { $0.origin.payloadHash }), [WorkspaceIO.digest(a.raw), WorkspaceIO.digest(same.raw)])
    }
    func testConcurrentDocumentsRemainConflictedUntilExplicitCausalResolution() throws {
        let a = try revision([profileKey: profile("A")], device: "a"), b = try revision([profileKey: profile("B")], device: "b")
        guard case .conflicted(let checkpoint, let fields) = try prepare([b, a]) else { return XCTFail("must not expose a chosen settings winner") }
        XCTAssertEqual(fields, [profileKey]); XCTAssertEqual(checkpoint.heads[profileKey]?.count, 2)
        let resolved = try revision([profileKey: profile("Resolved")], device: "resolver", clock: 2, parents: [a.revision.id, b.revision.id])
        let result = try ready(prepare([b, resolved, a]))
        XCTAssertEqual(result.settings.householdName, "Resolved"); XCTAssertEqual(result.causal.heads[profileKey]?.count, 1)
        XCTAssertEqual(result.causal.revisions.count, 3)
    }
    func testPairReferencesValidateTogetherAfterReplayAndHistoricalRefsUseCurrentPair() throws {
        let s = try settings()
        var profile = try WorkspaceIO.object(s.profileData), members = try XCTUnwrap(profile["members"] as? [[String: Any]])
        members.append(["id": "member-new", "display_name": "New mock", "status": "active"]); profile["members"] = members
        var policy = try WorkspaceIO.object(s.policiesData), accounts = try XCTUnwrap(policy["accounts"] as? [[String: Any]])
        accounts.append(["id": "account-new", "display_name": "New mock", "owner_member_id": "member-new", "currency": "CNY", "status": "active"]); policy["accounts"] = accounts
        let p = try revision([profileKey: String(decoding: WorkspaceIO.canonical(profile), as: UTF8.self)], device: "profile")
        let a = try revision([policiesKey: String(decoding: WorkspaceIO.canonical(policy), as: UTF8.self)], device: "policy")
        XCTAssertThrowsError(try prepare([a]))
        let current = try ready(prepare([a, p], context: context(members: ["member-new"], accounts: ["account-new"])))
        XCTAssertEqual(current.settings.accounts.last?.ownerMemberID, "member-new")
    }
    func testDeletingUnusedSeedIdentityIsRejectedForRemoteRevisions() throws {
        let s = try settings()
        var profile = try WorkspaceIO.object(s.profileData), members = try XCTUnwrap(profile["members"] as? [[String: Any]])
        members.append(["id": "unused", "display_name": "Retained mock", "status": "inactive"]); profile["members"] = members
        var seed = ReviewSettingsFieldDocuments.values(s); seed[profileKey] = String(decoding: try WorkspaceIO.canonical(profile), as: UTF8.self)
        let deletion = try revision([profileKey: String(decoding: s.profileData, as: UTF8.self)], device: "delete")
        XCTAssertThrowsError(try prepare([deletion], seed: seed))
    }
    func testSettingsValueGrammarAndInvalidUnconflictedPairFailClosed() throws {
        for value in ["null", "{}", "{\"schema_version\":2}", try profile("A") + "\n"] {
            XCTAssertThrowsError(try revision([profileKey: value], device: "bad"))
        }
        XCTAssertThrowsError(try revision(["settings/unknown": "{\"schema_version\":1}"], device: "bad"))
        XCTAssertThrowsError(try revision([profileKey: "{\"schema_version\":1}"], device: "bad"))
        let s = try settings()
        var policy = try WorkspaceIO.object(s.policiesData), accounts = try XCTUnwrap(policy["accounts"] as? [[String: Any]])
        accounts[0]["owner_member_id"] = "not-present"; policy["accounts"] = accounts
        let invalidReference = try revision([policiesKey: String(decoding: WorkspaceIO.canonical(policy), as: UTF8.self)], device: "bad")
        XCTAssertThrowsError(try prepare([invalidReference]))
        let valid = try revision([policiesKey: String(decoding: s.policiesData, as: UTF8.self)], device: "valid")
        guard case .conflicted = try prepare([invalidReference, valid]) else { return XCTFail("unqualified conflicting reference must remain pending, never ready") }
    }
    func testMissingParentsWaitAndForeignBindingRejects() throws {
        let missing = UUID().uuidString.lowercased()
        let orphan = try revision([profileKey: profile("A")], device: "a", clock: 2, parents: [missing])
        guard case .waiting(let ids) = try prepare([orphan]) else { return XCTFail("invented ancestor") }
        XCTAssertEqual(ids, [missing])
        let foreign = try ReviewNativeRevision(sourceBindingID: UUID().uuidString.lowercased(), raw: orphan.raw)
        XCTAssertThrowsError(try prepare([foreign]))
    }
    func testCanonicalEquivalentStringsWithDifferentBytesAreRealConflicts() throws {
        let a = try revision([profileKey: profile("é")], device: "a"), b = try revision([profileKey: profile("e\u{301}")], device: "b")
        guard case .conflicted(let cp, _) = try prepare([a, b]) else { return XCTFail("Unicode normalization must not merge document identities") }
        let conflict = try XCTUnwrap(ReleaseCanonicalJSON.canonicalFragment(raw: cp.fieldState(), atObjectKeys: ["conflicts", profileKey]))
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalArrayElements(raw: conflict, atObjectKeys: [])?.count, 2)
        let oldA = try revision(["parameter/label": "\"é\""], device: "a")
        let oldB = try revision(["parameter/label": "\"e\u{301}\""], device: "b")
        guard case .ready(let old) = try ReviewCausalFields.prepare(seedValues: [:], revisions: [oldA, oldB], selection: selection()) else { return XCTFail("v3 missing") }
        XCTAssertEqual(old.conflicts, ["parameter/label"])
    }
}
