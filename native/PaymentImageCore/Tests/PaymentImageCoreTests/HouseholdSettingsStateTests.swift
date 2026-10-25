import XCTest
import Foundation
import CSQLite
@testable import PaymentImageCore

final class HouseholdSettingsStateTests: XCTestCase {
    private func fixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "household-settings-golden", withExtension: "json", subdirectory: "Fixtures")))
    }
    private func fragment(_ raw: Data, _ key: String) throws -> Data {
        try XCTUnwrap(ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: [key]))
    }
    private func seal(_ paths: WorkspacePaths) throws {
        let pointer = try paths.readPointer(), root = try paths.stateRoot(pointer.stateID)
        var files = [String: String]()
        for name in try WorkspaceIO.regularFiles(root) where name != "state-manifest.json" {
            files[name] = try WorkspaceIO.hash(WorkspaceIO.safeChild(root, name))
        }
        let raw = try WorkspaceIO.canonical(["workspace_id": pointer.workspaceID, "state_id": pointer.stateID,
            "local_revision": pointer.localRevision, "files": files])
        try WorkspaceIO.atomicWrite(raw, to: root.appendingPathComponent("state-manifest.json"))
        let updated = WorkspaceStatePointer(workspaceID: pointer.workspaceID, stateID: pointer.stateID,
            localRevision: pointer.localRevision, manifestHash: WorkspaceIO.digest(raw))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(updated.document), to: paths.activeState)
    }
    private func create(fixtureData: Data? = nil, mutate: ((inout [String: Data]) throws -> Void)? = nil) throws -> WorkspacePaths {
        let paths = try WorkspacePaths(workspace: TestPlatform.temporaryDirectory().appendingPathComponent("settings-state-" + UUID().uuidString))
        let workspace = UUID().uuidString.lowercased(), state = UUID().uuidString.lowercased(), root = try paths.stateRoot(state)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["workspace_id": workspace, "created_at": "2026-10-22T00:00:00Z"]), to: paths.metadata)
        let pointer = WorkspaceStatePointer(workspaceID: workspace, stateID: state, localRevision: 0, manifestHash: String(repeating: "0", count: 64))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pointer.document), to: paths.activeState)
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("banking.sqlite3").path, &db) == SQLITE_OK else { throw WorkspaceError.invalid("mock db") }
        let result = sqlite3_exec(db, "CREATE TABLE records(id TEXT PRIMARY KEY);", nil, nil, nil); sqlite3_close(db)
        guard result == SQLITE_OK else { throw WorkspaceError.invalid("mock schema") }
        let f = try fixtureData ?? fixture(), context = try JSONDecoder().decode([String: [String]].self, from: fragment(f, "context"))
        var sources = [[String: String]]()
        for (index, id) in context["registered_source_ids"]!.enumerated() {
            let path = "inputs/mock-\(index).csv", bytes = Data("mock-source-\(index)".utf8)
            try WorkspaceIO.atomicWrite(bytes, to: WorkspaceIO.safeChild(root, path))
            sources.append(["id": id, "path": path, "platform": "mock-platform", "sha256": WorkspaceIO.digest(bytes)])
        }
        var docs = ["config/family-profile.json": try fragment(f, "profile"), "config/account-policies.json": try fragment(f, "policies"),
            "config/review-import-sources.json": try WorkspaceIO.canonical(["sources": sources]),
            "review/financial-review.json": Data("{\"records\":[]}".utf8), "review/payment-evidence.json": Data("{}".utf8),
            "review/coverage.json": Data("{}".utf8),
            "operation-results.json": try WorkspaceIO.canonical(["state_id": state, "results": []])]
        try mutate?(&docs)
        for (path, raw) in docs { try WorkspaceIO.atomicWrite(raw, to: WorkspaceIO.safeChild(root, path)) }
        try seal(paths)
        return paths
    }
    private func read(_ paths: WorkspacePaths, currencies: [String] = ["CNY", "USD"], members: [String] = ["member-a"], accounts: [String] = ["account-a"]) throws -> HouseholdSettingsState {
        try .read(paths: paths, currencyCodes: currencies, referencedMemberIDs: members, referencedAccountIDs: accounts)
    }
    func testReadPinsCommittedSettingsRegistryAndSourcesWithoutWriting() throws {
        let paths = try create(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let before = try paths.readPointer(), snapshot = try read(paths)
        XCTAssertEqual(snapshot.pointer, before); XCTAssertEqual(snapshot.dependencies.count, 5)
        XCTAssertEqual(snapshot.settings.profileData, try fragment(fixture(), "profile"))
        XCTAssertEqual(try paths.readPointer(), before)
    }
    func testRenameDeactivateAndAddRetainIDsWithoutWriting() throws {
        let paths = try create(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let snapshot = try read(paths), before = try paths.readState()
        var profile = try WorkspaceIO.object(snapshot.settings.profileData), members = try XCTUnwrap(profile["members"] as? [[String: Any]])
        members[0]["display_name"] = "Renamed mock"; members[0]["status"] = "inactive"
        members.append(["id": "member-new", "display_name": "New mock", "status": "active"]); profile["members"] = members
        let plan = try snapshot.prepareEdit(profileData: WorkspaceIO.canonical(profile), policiesData: snapshot.settings.policiesData)
        XCTAssertEqual(try plan.revalidate(paths: paths).members[0].status, "inactive")
        XCTAssertEqual(try paths.readPointer(), before.pointer)
        XCTAssertEqual(try WorkspaceIO.read(before.file("config/family-profile.json")), snapshot.settings.profileData)
    }
    func testDeletingUnusedBaselineMemberOrAccountIsRejected() throws {
        let paths = try create { docs in
            let raw = docs["config/family-profile.json"]!
            var profile = try WorkspaceIO.object(raw), members = try XCTUnwrap(profile["members"] as? [[String: Any]])
            members.append(["id": "never-used", "display_name": "Extra mock", "status": "inactive"])
            profile["members"] = members; docs["config/family-profile.json"] = try WorkspaceIO.canonical(profile)
            var policy = try WorkspaceIO.object(docs["config/account-policies.json"]!), accounts = try XCTUnwrap(policy["accounts"] as? [[String: Any]])
            accounts.append(["id": "unused-account", "display_name": "Extra mock", "owner_member_id": NSNull(), "currency": "CNY", "status": "inactive"])
            policy["accounts"] = accounts; docs["config/account-policies.json"] = try WorkspaceIO.canonical(policy)
        }
        defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let snapshot = try read(paths)
        XCTAssertThrowsError(try snapshot.prepareEdit(profileData: fragment(fixture(), "profile"), policiesData: snapshot.settings.policiesData))
        XCTAssertThrowsError(try snapshot.prepareEdit(profileData: snapshot.settings.profileData, policiesData: fragment(fixture(), "policies")))
    }
    func testRegistryRequiresExplicitUniqueIDsAndManifestRetention() throws {
        let mutations: [(inout [[String: Any]]) -> Void] = [
            { $0[0].removeValue(forKey: "id") }, { $0[1]["id"] = "source-a" },
            { $0[0]["sha256"] = String(repeating: "0", count: 64) },
            { $0[0]["sha256"] = String(repeating: "0", count: 64) + "\n" },
            { $0[0]["path"] = "../outside" }, { $0[0]["path"] = "inputs/missing.csv" },
            { $0[1]["path"] = $0[0]["path"]; $0[1]["sha256"] = $0[0]["sha256"] }
        ]
        for change in mutations {
            let paths = try create { docs in
                var registry = try WorkspaceIO.object(docs["config/review-import-sources.json"]!), rows = try XCTUnwrap(registry["sources"] as? [[String: Any]])
                change(&rows); registry["sources"] = rows; docs["config/review-import-sources.json"] = try WorkspaceIO.canonical(registry)
            }
            defer { try? FileManager.default.removeItem(at: paths.workspace) }
            XCTAssertThrowsError(try read(paths))
        }
    }
    func testAbsentPartialNoncanonicalAndChangedSettingsReject() throws {
        for missing in [["config/family-profile.json"], ["config/account-policies.json"], ["config/family-profile.json", "config/account-policies.json"]] {
            let paths = try create { docs in for path in missing { docs.removeValue(forKey: path) } }
            defer { try? FileManager.default.removeItem(at: paths.workspace) }
            XCTAssertThrowsError(try read(paths))
        }
        let paths = try create { $0["config/family-profile.json"]!.append(Data("\n".utf8)) }
        defer { try? FileManager.default.removeItem(at: paths.workspace) }
        XCTAssertThrowsError(try read(paths))
        let state = try paths.readState()
        try WorkspaceIO.atomicWrite(Data("{}".utf8), to: state.file("config/family-profile.json"))
        XCTAssertThrowsError(try read(paths))
    }
    func testPlanRejectsOtherWorkspaceAndAdvancedPointer() throws {
        let paths = try create(), other = try create()
        defer { try? FileManager.default.removeItem(at: paths.workspace); try? FileManager.default.removeItem(at: other.workspace) }
        let snapshot = try read(paths), plan = try snapshot.prepareEdit(profileData: snapshot.settings.profileData, policiesData: snapshot.settings.policiesData)
        XCTAssertThrowsError(try plan.revalidate(paths: other))
        do {
            let coordinator = WorkspaceCoordinator(paths: paths), token = try coordinator.acquireWriteToken()
            let transaction = try coordinator.begin(token: token, expectedPointer: paths.readPointer())
            var profile = try WorkspaceIO.object(snapshot.settings.profileData); profile["household_name"] = "Later mock state"
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(profile), to: transaction.file("config/family-profile.json", token: token))
            _ = try transaction.prepare(token: token); _ = try transaction.commit(token: token)
        }
        XCTAssertThrowsError(try plan.revalidate(paths: paths))
        XCTAssertEqual(snapshot.pointer.localRevision, 0)
    }
    func testCapabilitiesAndHistoricalReferencesRemainExplicit() throws {
        let paths = try create(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        XCTAssertThrowsError(try read(paths, currencies: ["EUR"]))
        XCTAssertThrowsError(try read(paths, members: ["unknown"]))
        XCTAssertThrowsError(try read(paths, accounts: ["unknown"]))
    }
    func testRegistryAndRetainedIDsPreserveExactUnicodeIdentity() throws {
        let f = try fragment(fixture(), "unicode"), paths = try create(fixtureData: f)
        defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let snapshot = try read(paths, members: [], accounts: [])
        XCTAssertEqual(snapshot.settings.sourceOwners.count, 2)
        XCTAssertNotEqual(Data(snapshot.settings.sourceOwners[0].sourceID.utf8), Data(snapshot.settings.sourceOwners[1].sourceID.utf8))
        var rows = try XCTUnwrap(ReleaseCanonicalJSON.canonicalArrayElements(raw: snapshot.settings.profileData, atObjectKeys: ["members"]))
        rows.removeLast()
        let profile = try ReleaseCanonicalJSON.replacingObjectMember(raw: snapshot.settings.profileData, key: "members",
            valueRaw: Data(("[" + rows.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]").utf8))
        XCTAssertThrowsError(try snapshot.prepareEdit(profileData: profile, policiesData: snapshot.settings.policiesData))
    }
    func testExplicitCommittedConfigAndReviewCaptureUsesSamePointerAndBytes() throws {
        let paths = try create(); defer { try? FileManager.default.removeItem(at: paths.workspace) }
        let snapshot = try read(paths), state = try paths.readState()
        let values = try ReviewFieldDocuments.capture(state: state, settings: snapshot)
        XCTAssertEqual(values, ReviewSettingsFieldDocuments.values(snapshot.settings))
        XCTAssertTrue(try ReviewFieldDocuments.capture(review: state.review).isEmpty)
        let other = try create(); defer { try? FileManager.default.removeItem(at: other.workspace) }
        XCTAssertThrowsError(try ReviewFieldDocuments.capture(state: other.readState(), settings: snapshot))
        try WorkspaceIO.atomicWrite(Data("{}".utf8), to: state.file("config/family-profile.json"))
        XCTAssertThrowsError(try ReviewFieldDocuments.capture(state: state, settings: snapshot))
    }
}
