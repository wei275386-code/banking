import XCTest
import Foundation
@testable import PaymentImageCore

final class HouseholdSettingsTests: XCTestCase {
    private func fixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "household-settings-golden", withExtension: "json", subdirectory: "Fixtures")))
    }
    private func fragment(_ bytes: Data, _ key: String) throws -> Data {
        try XCTUnwrap(ReleaseCanonicalJSON.canonicalFragment(raw: bytes, atObjectKeys: [key]))
    }
    private func array(_ bytes: Data, _ key: String) throws -> [Data] {
        try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: bytes, atObjectKeys: [key]))
    }
    private func context(_ fixture: Data) throws -> HouseholdSettingsContext {
        let values = try JSONDecoder().decode([String: [String]].self, from: fragment(fixture, "context"))
        return HouseholdSettingsContext(registeredSourceIDs: values["registered_source_ids"]!, currencyCodes: values["currency_codes"]!,
            referencedMemberIDs: values["referenced_member_ids"]!, referencedAccountIDs: values["referenced_account_ids"]!)
    }
    private func settings(_ fixture: Data) throws -> HouseholdSettings {
        try HouseholdSettings(profileData: fragment(fixture, "profile"), policiesData: fragment(fixture, "policies"), context: context(fixture))
    }
    private func check(_ settings: HouseholdSettings, _ cases: [Data], file: StaticString = #filePath, line: UInt = #line) throws {
        for row in cases {
            let values = try JSONDecoder().decode([String: String].self, from: fragment(row, "input"))
            let input = HouseholdFundingInput(platform: values["platform"], sourceID: values["source_id"], sourceAccountID: values["source_account_id"],
                sourceAccountName: values["source_account_name"], paymentChannel: values["payment_channel"])
            let result = try ReleaseCanonicalJSON.canonicalize(raw: JSONEncoder().encode(settings.resolveFunding(input)))
            let name = String(decoding: try fragment(row, "name"), as: UTF8.self)
            XCTAssertEqual(result, try fragment(row, "expected"), name, file: file, line: line)
        }
    }
    func testSharedGoldenScopesPriorityAmbiguityUnknownsAndImmutableBytes() throws {
        let raw = try fixture(), settings = try settings(raw)
        try check(settings, array(raw, "cases"))
        XCTAssertEqual(settings.profileData, try fragment(raw, "profile"))
        XCTAssertEqual(settings.policiesData, try fragment(raw, "policies"))
    }
    func testRuleOrderNeverBreaksTiesOrChangesOutcome() throws {
        let raw = try fixture()
        var policy = try fragment(raw, "policies")
        for kind in ["routes", "aliases"] {
            let rows = try array(policy, kind).reversed().map { String(decoding: $0, as: UTF8.self) }
            policy = try ReleaseCanonicalJSON.replacingObjectMember(raw: policy, key: kind, valueRaw: Data(("[" + rows.joined(separator: ",") + "]").utf8))
        }
        let settings = try HouseholdSettings(profileData: fragment(raw, "profile"), policiesData: policy, context: context(raw))
        try check(settings, array(raw, "cases"))
    }
    func testSameTargetRulesDoNotCreateFalseConflict() throws {
        let raw = try fixture(), policy = try fragment(raw, "policies")
        var routes = try array(policy, "routes")
        routes.append(try ReleaseCanonicalJSON.replacingObjectMember(raw: routes[0], key: "id", valueRaw: Data("\"route-a-copy\"".utf8)))
        let modified = try ReleaseCanonicalJSON.replacingObjectMember(raw: policy, key: "routes",
            valueRaw: Data(("[" + routes.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]").utf8))
        let settings = try HouseholdSettings(profileData: fragment(raw, "profile"), policiesData: modified, context: context(raw))
        let result = try settings.resolveFunding(.init(platform: "platform-a", sourceAccountName: "Mock card"))
        XCTAssertEqual(result.status, "resolved"); XCTAssertEqual(result.accountID, "account-a")
        XCTAssertEqual(result.matchedRuleIDs, ["route-a", "route-a-copy"])
    }
    func testTwoHouseholdsUseTheirOwnPolicyForSameFundingInput() throws {
        let raw = try fixture(), first = try settings(raw), policy = try fragment(raw, "policies")
        var rows = try array(policy, "routes")
        rows[0] = try ReleaseCanonicalJSON.replacingObjectMember(raw: rows[0], key: "target_account_id", valueRaw: Data("\"account-b\"".utf8))
        let secondPolicy = try ReleaseCanonicalJSON.replacingObjectMember(raw: policy, key: "routes",
            valueRaw: Data(("[" + rows.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]").utf8))
        let secondProfile = try ReleaseCanonicalJSON.replacingObjectMember(raw: fragment(raw, "profile"), key: "household_name", valueRaw: Data("\"Second mock household\"".utf8))
        let second = try HouseholdSettings(profileData: secondProfile, policiesData: secondPolicy, context: context(raw))
        let input = HouseholdFundingInput(platform: "platform-a", sourceAccountName: "Mock card")
        XCTAssertEqual(try first.resolveFunding(input).accountID, "account-a")
        XCTAssertEqual(try second.resolveFunding(input).accountID, "account-b")
        XCTAssertEqual(try first.resolveFunding(input).accountID, "account-a")
    }
    func testSharedInvalidBusinessAndShapePairsFailClosed() throws {
        let raw = try fixture(), context = try context(raw)
        for row in try array(raw, "invalid_cases") {
            let name = String(decoding: try fragment(row, "name"), as: UTF8.self)
            XCTAssertThrowsError(try HouseholdSettings(profileData: fragment(row, "profile"), policiesData: fragment(row, "policies"), context: context),
                name)
        }
    }
    func testUnicodeOpaqueIDsAndDynamicSourceKeysRemainByteDistinct() throws {
        let raw = try fragment(fixture(), "unicode"), settings = try settings(raw)
        XCTAssertEqual(settings.members.count, 2); XCTAssertEqual(settings.sourceOwners.count, 2)
        XCTAssertNotEqual(Data(settings.members[0].id.utf8), Data(settings.members[1].id.utf8))
        XCTAssertNotEqual(Data(settings.sourceOwners[0].sourceID.utf8), Data(settings.sourceOwners[1].sourceID.utf8))
        try check(settings, array(raw, "cases"))
        XCTAssertEqual(settings.policiesData, try fragment(raw, "policies"))
    }
    func testHistoricalReferencesCannotBeDroppedAndContextIsExplicit() throws {
        let raw = try fixture(), valid = try context(raw)
        for context in [
            HouseholdSettingsContext(registeredSourceIDs: valid.registeredSourceIDs, currencyCodes: valid.currencyCodes,
                referencedMemberIDs: valid.referencedMemberIDs + ["historical-missing"], referencedAccountIDs: valid.referencedAccountIDs),
            HouseholdSettingsContext(registeredSourceIDs: valid.registeredSourceIDs, currencyCodes: valid.currencyCodes,
                referencedMemberIDs: valid.referencedMemberIDs, referencedAccountIDs: valid.referencedAccountIDs + ["historical-missing"]),
            HouseholdSettingsContext(registeredSourceIDs: ["source-a", "source-a"], currencyCodes: valid.currencyCodes,
                referencedMemberIDs: [], referencedAccountIDs: []),
            HouseholdSettingsContext(registeredSourceIDs: valid.registeredSourceIDs, currencyCodes: [], referencedMemberIDs: [], referencedAccountIDs: [])] {
            XCTAssertThrowsError(try HouseholdSettings(profileData: fragment(raw, "profile"), policiesData: fragment(raw, "policies"), context: context))
        }
    }
    func testDuplicateJSONKeysAndInvalidFieldTypesRejected() throws {
        let raw = try fixture(), context = try context(raw), profile = try fragment(raw, "profile"), policy = try fragment(raw, "policies")
        for token in ["1.0", "true", "[]"] {
            let malformed = try ReleaseCanonicalJSON.replacingObjectMember(raw: profile, key: "household_name", valueRaw: Data(token.utf8))
            XCTAssertThrowsError(try HouseholdSettings(profileData: malformed, policiesData: policy, context: context))
        }
        XCTAssertThrowsError(try HouseholdSettings(profileData: Data("{\"schema_version\":1}".utf8), policiesData: policy, context: context))
    }
    func testEmptyHouseholdHasNoPrivateDefaultsOrFunding() throws {
        let profile = Data("{\"household_name\":\"\",\"members\":[]}".utf8)
        let policy = Data("{\"accounts\":[],\"aliases\":[],\"routes\":[],\"source_owners\":{},\"unknown_account_policy\":{\"mode\":\"needs_review\",\"exclusion_member_ids\":[]}}".utf8)
        let settings = try HouseholdSettings(profileData: profile, policiesData: policy,
            context: .init(registeredSourceIDs: [], currencyCodes: ["CNY"], referencedMemberIDs: [], referencedAccountIDs: []))
        XCTAssertTrue(settings.members.isEmpty); XCTAssertTrue(settings.accounts.isEmpty)
        XCTAssertEqual(try settings.resolveFunding(.init(platform: "mock", sourceAccountName: "Unmapped")).status, "needs_review")
    }
}
