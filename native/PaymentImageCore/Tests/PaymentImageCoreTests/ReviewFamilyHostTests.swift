import Foundation
import XCTest
@testable import PaymentImageCore

@MainActor final class ReviewFamilyHostTests: XCTestCase {
    enum Crash: Error { case injected }
    func fixture() throws -> CurrentWorkspaceFixtures.Fixture {
        let f = try CurrentWorkspaceFixtures.make()
        let token = try WorkspaceCoordinator(paths: f.paths).acquireWriteToken()
        let tx = try WorkspaceCoordinator(paths: f.paths).begin(token: token, expectedPointer: f.paths.readPointer())
        try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.canonicalize(raw: Data(#"{"household_name":"","members":[]}"#.utf8)), to: tx.file("config/family-profile.json", token: token))
        try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.canonicalize(raw: Data(#"{"accounts":[],"routes":[],"aliases":[],"source_owners":{},"unknown_account_policy":{"mode":"needs_review","exclusion_member_ids":[]}}"#.utf8)), to: tx.file("config/account-policies.json", token: token))
        let empty = try ParameterDocument.encoding(FireParameters.emptyInputs())
        try WorkspaceIO.atomicWrite(empty, to: tx.file("config/fire-parameters.json", token: token))
        let reportFile = try tx.file("review/financial-review.json", token: token)
        try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.replacingObjectMember(raw: WorkspaceIO.read(reportFile), key: "fire_parameters", valueRaw: empty), to: reportFile)
        _ = try NativeWorkspaceEffects.record(transaction: tx, token: token)
        _ = try tx.prepare(token: token, validator: WorkspaceBusinessValidator.validate)
        _ = try tx.commit(token: token)
        return f
    }
    func remote(_ f: CurrentWorkspaceFixtures.Fixture) -> URL {
        f.paths.workspace.deletingLastPathComponent().appendingPathComponent("new-family-" + UUID().uuidString.lowercased())
    }
    func reader(_ f: CurrentWorkspaceFixtures.Fixture, _ connection: ReviewFamilyConnection) throws -> ReviewFamilySnapshotStore {
        try .init(remote: connection.remote, local: f.paths.workspace.appendingPathComponent("test-reader"), selection: connection.selection)
    }
    func context(_ connection: ReviewFamilyConnection) -> ReviewFamilySnapshotContext {
        .init(sourceBindings: [connection.selection.bindingID], settings: .init(registeredSourceIDs: [], currencyCodes: ["CNY"], referencedMemberIDs: [], referencedAccountIDs: []))
    }
    func testProductionCreateEditPublishAndOfflineReaderPreserveMembership() throws {
        let f = try fixture(), remote = remote(f)
        defer { f.remove(); try? FileManager.default.removeItem(at: remote) }
        let before = try f.paths.readState(), ledger = try WorkspaceIO.object(WorkspaceIO.read(before.operationResults))["results"] as! [[String: Any]]
        let connection = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        let store = try reader(f, connection)
        guard case .ready(let initial) = try store.prepare(contextForGeneration: { _, _ in self.context(connection) }) else { return XCTFail("complete initial reader") }
        XCTAssertTrue(initial.payload.fields.causal.revisions.isEmpty)
        XCTAssertEqual(initial.payload.fields.settings.householdName, "")
        XCTAssertEqual(try WorkspaceIO.canonical(["results": ledger]), try WorkspaceIO.canonical(["results": try WorkspaceIO.object(WorkspaceIO.read(f.paths.readState().operationResults))["results"]!]))
        try ReviewFamilyHost.requireSettingsWriter(paths: f.paths)
        do {
            let token = try WorkspaceCoordinator(paths: f.paths).acquireWriteToken()
            let tx = try WorkspaceCoordinator(paths: f.paths).begin(token: token, expectedPointer: f.paths.readPointer())
            let file = try tx.file("config/family-profile.json", token: token)
            try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.replacingObjectMember(raw: WorkspaceIO.read(file), key: "household_name", valueRaw: Data("\"New synthetic household\"".utf8)), to: file)
            try WorkspaceIO.atomicWrite(Data("{\"afterTaxSalary\":0}".utf8), to: tx.file("review/fire-parameters-user.json", token: token))
            _ = try NativeWorkspaceEffects.record(transaction: tx, token: token)
            _ = try tx.prepare(token: token, validator: WorkspaceBusinessValidator.validate); _ = try tx.commit(token: token)
        }
        let next = try ReviewFamilyHost.publish(paths: f.paths)
        guard case .ready(let updated) = try store.prepare(contextForGeneration: { _, _ in self.context(connection) }) else { return XCTFail("updated reader") }
        XCTAssertEqual(updated.generation, next)
        XCTAssertEqual(updated.payload.fields.settings.householdName, "New synthetic household")
        XCTAssertEqual(updated.payload.fields.causal.values["parameter/afterTaxSalary"], "0")
        XCTAssertEqual(updated.payload.fields.causal.revisions.count, 1)
        let repeatGeneration = try ReviewFamilyHost.publish(paths: f.paths)
        XCTAssertEqual(repeatGeneration, next)
        try FileManager.default.removeItem(at: remote)
        XCTAssertEqual(try store.readCached(contextForGeneration: { _, _ in self.context(connection) })?.generation, next)
        try ReviewWorkspaceMembership.validate(state: f.paths.readState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.device.appendingPathComponent("client-active.json").path))
    }
    func testPreparedPublicationCrashLocksWritesAndRetriesSameBindingAndGeneration() throws {
        for point in [ReviewFamilyPublicationPoint.intentSaved, .pointerPublished] {
            let f = try fixture(), remote = remote(f)
            defer { f.remove(); try? FileManager.default.removeItem(at: remote) }
            XCTAssertThrowsError(try ReviewFamilyHost.create(paths: f.paths, remote: remote, failureInjector: { if $0 == point { throw Crash.injected } }))
            let creation = try WorkspaceIO.object(WorkspaceIO.read(f.paths.device.appendingPathComponent("create-family.json")))
            let binding = creation["binding_id"] as! String
            let intent = f.paths.device.appendingPathComponent("family-sync/" + binding + "/publication/publication-intent.json")
            let pending = try WorkspaceIO.object(WorkspaceIO.read(intent))["generation"] as! String
            let pointer = try f.paths.readPointer()
            do {
                let token = try WorkspaceCoordinator(paths: f.paths).acquireWriteToken()
                XCTAssertThrowsError(try WorkspaceCoordinator(paths: f.paths).begin(token: token, expectedPointer: pointer))
            }
            let connection = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
            XCTAssertEqual(connection.selection.bindingID, binding)
            XCTAssertEqual(try f.paths.readPointer(), pointer)
            XCTAssertEqual(try WorkspaceIO.object(WorkspaceIO.read(remote.appendingPathComponent("current.json")))["generation"] as? String, pending)
            try ReviewFamilyHost.requireNoPendingWrite(paths: f.paths)
        }
    }
    func testIncompleteWorkspaceAndRevokedDeviceCannotAcquireAuthority() throws {
        let f = try CurrentWorkspaceFixtures.make(), remote = remote(f)
        defer { f.remove(); try? FileManager.default.removeItem(at: remote) }
        XCTAssertThrowsError(try ReviewFamilyHost.create(paths: f.paths, remote: remote))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.device.appendingPathComponent("host-authorization.json").path))
        let fresh = try fixture(), target = self.remote(fresh)
        defer { fresh.remove(); try? FileManager.default.removeItem(at: target) }
        _ = try ReviewFamilyHost.create(paths: fresh.paths, remote: target)
        let pointer = try WorkspaceIO.read(target.appendingPathComponent("current.json"))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["device_id": UUID().uuidString.lowercased()]), to: fresh.paths.device.appendingPathComponent("device-identity.json"))
        XCTAssertThrowsError(try ReviewFamilyHost.publish(paths: fresh.paths))
        XCTAssertEqual(try WorkspaceIO.read(target.appendingPathComponent("current.json")), pointer)
    }
    func testFamilyHostBackupOfflineRestoresPublishedStateAsClient() throws {
        let f = try fixture(), remote = remote(f)
        let parent = f.paths.workspace.deletingLastPathComponent()
        let package = parent.appendingPathComponent("host-backup-" + UUID().uuidString.lowercased())
        let restored = parent.appendingPathComponent("restored-host-" + UUID().uuidString.lowercased())
        defer { f.remove(); for url in [remote, package, restored] { try? FileManager.default.removeItem(at: url) } }
        let connection = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        do {
            let token = try WorkspaceCoordinator(paths: f.paths).acquireWriteToken()
            let tx = try WorkspaceCoordinator(paths: f.paths).begin(token: token, expectedPointer: f.paths.readPointer())
            let file = try tx.file("config/family-profile.json", token: token)
            try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.replacingObjectMember(raw: WorkspaceIO.read(file), key: "household_name", valueRaw: Data("\"Synthetic backup household\"".utf8)), to: file)
            _ = try NativeWorkspaceEffects.record(transaction: tx, token: token)
            _ = try tx.prepare(token: token, validator: WorkspaceBusinessValidator.validate); _ = try tx.commit(token: token)
        }
        let generation = try ReviewFamilyHost.publish(paths: f.paths)
        let pointer = try f.paths.readPointer(), ledger = try WorkspaceIO.read(f.paths.readState().operationResults)
        try FileManager.default.removeItem(at: remote)
        try ReviewFamilyHost.exportPublishedBackup(paths: f.paths, destination: package)
        XCTAssertEqual(try f.paths.readPointer(), pointer)
        let result = try ReviewFamilyClientSession.restoreSelectedBackup(package: package, destination: restored)
        XCTAssertEqual(result.selection, connection.selection)
        XCTAssertEqual(result.checkpoint.generation, generation)
        XCTAssertEqual(WorkspaceIO.digest(result.checkpoint.payload.manifest), result.checkpoint.generation)
        XCTAssertEqual(result.settings.householdName, "Synthetic backup household")
        XCTAssertEqual(try WorkspaceIO.read(result.checkpoint.file("request-results.json")), ledger)
        let paths = try WorkspacePaths(workspace: restored)
        XCTAssertTrue(try XCTUnwrap(ReviewFamilyClientSession.readConnection(paths: paths)).requiresReconnection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.device.appendingPathComponent("host-authorization.json").path))
        XCTAssertNotEqual(try WorkspaceIO.object(WorkspaceIO.read(paths.device.appendingPathComponent("device-identity.json")))["device_id"] as? String, connection.selection.hostID)
        XCTAssertThrowsError(try ReviewFamilyHost.requireSettingsWriter(paths: paths))
        let names = try WorkspaceIO.regularFiles(package)
        XCTAssertFalse(names.contains { $0.contains("host-authorization") || $0.contains("sync-connection") || $0.contains("device-identity") })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix(".host-backup-projection-") })
    }
    func testFamilyHostBackupRejectsUnpublishedStateDamagedCacheAndUnsafeDestination() throws {
        let f = try fixture(), remote = remote(f), parent = f.paths.workspace.deletingLastPathComponent()
        let package = parent.appendingPathComponent("rejected-host-backup-" + UUID().uuidString.lowercased())
        defer { f.remove(); for url in [remote, package] { try? FileManager.default.removeItem(at: url) } }
        let connection = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        XCTAssertThrowsError(try ReviewFamilyHost.exportPublishedBackup(paths: f.paths, destination: f.paths.workspace.appendingPathComponent("nested-backup")))
        do {
            let token = try WorkspaceCoordinator(paths: f.paths).acquireWriteToken()
            let tx = try WorkspaceCoordinator(paths: f.paths).begin(token: token, expectedPointer: f.paths.readPointer())
            try WorkspaceIO.atomicWrite(Data("{\"afterTaxSalary\":42}".utf8), to: tx.file("review/fire-parameters-user.json", token: token))
            _ = try NativeWorkspaceEffects.record(transaction: tx, token: token)
            _ = try tx.prepare(token: token, validator: WorkspaceBusinessValidator.validate); _ = try tx.commit(token: token)
        }
        XCTAssertThrowsError(try ReviewFamilyHost.exportPublishedBackup(paths: f.paths, destination: package)) { error in
            XCTAssertTrue(error.localizedDescription.contains("尚未发布"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        let generation = try ReviewFamilyHost.publish(paths: f.paths), pointer = try f.paths.readPointer()
        let manifest = f.paths.device.appendingPathComponent("family-sync/" + connection.selection.bindingID + "/snapshots/" + generation)
        try WorkspaceIO.atomicWrite(Data("{}".utf8), to: manifest)
        XCTAssertThrowsError(try ReviewFamilyHost.exportPublishedBackup(paths: f.paths, destination: package))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        XCTAssertEqual(try f.paths.readPointer(), pointer)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix(".host-backup-projection-") })
    }
    func testFamilyHostDriverRetainsLateOriginAfterFrozenPublicationRetry() async throws {
        let f = try fixture(), remote = remote(f), helpers = ReviewFamilyClientSessionTests()
        let client = try helpers.client(f.paths)
        defer { f.remove(); for url in [remote, client.workspace] { try? FileManager.default.removeItem(at: url) } }
        let connection = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        let initial = try helpers.connect(client, remote: remote)
        let (_, edited) = try ReviewFamilyClientSession.edit(paths: client, expected: initial) { root, _ in
            try helpers.change(root, name: "Late synthetic household")
        }
        let lateOrigin = try XCTUnwrap(edited.queue.first)
        do {
            let token = try WorkspaceCoordinator(paths: f.paths).acquireWriteToken()
            let tx = try WorkspaceCoordinator(paths: f.paths).begin(token: token, expectedPointer: f.paths.readPointer())
            try WorkspaceIO.atomicWrite(Data("{\"afterTaxSalary\":42}".utf8), to: tx.file("review/fire-parameters-user.json", token: token))
            _ = try NativeWorkspaceEffects.record(transaction: tx, token: token)
            _ = try tx.prepare(token: token, validator: WorkspaceBusinessValidator.validate); _ = try tx.commit(token: token)
        }
        XCTAssertThrowsError(try ReviewFamilyHost.publish(paths: f.paths, failureInjector: { if $0 == .intentSaved { throw Crash.injected } }))
        let intent = f.paths.device.appendingPathComponent("family-sync/" + connection.selection.bindingID + "/publication/publication-intent.json")
        let frozen = try WorkspaceIO.string(WorkspaceIO.object(WorkspaceIO.read(intent)), "generation")
        try await ReviewFamilyClientSession.transfer(paths: client)
        let driver = try ReviewFamilySyncDriver(paths: f.paths, connection: connection)
        let recovered = try await driver.synchronize()
        XCTAssertEqual(recovered, frozen, "finish the frozen publication without changing its contents")
        var handle = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: client))
        XCTAssertFalse(handle.checkpoint.payload.fields.causal.revisions.contains { $0.origin.revisionID == lateOrigin.key.revisionID })
        XCTAssertEqual(handle.checkpoint.payload.fields.causal.values["parameter/afterTaxSalary"], "42")
        let next = try await driver.synchronize()
        XCTAssertNotEqual(next, frozen, "late origin must remain pending after frozen recovery")
        handle = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: client))
        XCTAssertEqual(handle.checkpoint.payload.fields.settings.householdName, "Late synthetic household")
        let incorporated = try XCTUnwrap(handle.checkpoint.payload.fields.causal.revisions.first { $0.origin.revisionID == lateOrigin.key.revisionID })
        XCTAssertEqual(incorporated.origin.sourceBindingID, lateOrigin.key.sourceBindingID)
        XCTAssertEqual(incorporated.origin.payloadHash, lateOrigin.primaryHash)
        XCTAssertEqual(incorporated.rawSources, lateOrigin.sources)
        XCTAssertEqual(handle.checkpoint.payload.fields.causal.values["parameter/afterTaxSalary"], "42")
        let count = await driver.publicationCount
        let idle = try await driver.synchronize(), afterIdle = await driver.publicationCount
        XCTAssertEqual(idle, next); XCTAssertEqual(count, 2); XCTAssertEqual(afterIdle, count)
    }
}
