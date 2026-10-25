import Foundation
import XCTest
@testable import PaymentImageCore

@MainActor final class ReviewFamilyClientSessionTests: XCTestCase {
    func client(_ host: WorkspacePaths) throws -> WorkspacePaths {
        try WorkspacePaths(workspace: host.workspace.deletingLastPathComponent().appendingPathComponent("family-client-" + UUID().uuidString.lowercased()))
    }
    func connect(_ paths: WorkspacePaths, remote: URL) throws -> ReviewFamilyClientHandle {
        _ = try ReviewFamilyClientSession.connect(paths: paths, remote: remote, bookmark: nil)
        return try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: paths))
    }
    func change(_ root: URL, name: String? = nil, salary: Int? = nil) throws {
        if let name {
            let file = root.appendingPathComponent("family-profile.json")
            try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.replacingObjectMember(raw: WorkspaceIO.read(file), key: "household_name", valueRaw: JSONEncoder().encode(name)), to: file)
        }
        if let salary { try WorkspaceIO.atomicWrite(Data("{\"afterTaxSalary\":\(salary)}".utf8), to: root.appendingPathComponent("fire-parameters-user.json")) }
    }
    func testOptionalOriginalIsPinnedDownloadedOfflineAndRetainedByClientBackup() throws {
        let owner = ReviewFamilyHostTests(), f = try owner.fixture(), remote = owner.remote(f)
        let client = try client(f.paths), restored = try self.client(f.paths)
        let package = remote.deletingLastPathComponent().appendingPathComponent("material-backup-" + UUID().uuidString)
        defer { f.remove(); for url in [remote, client.workspace, restored.workspace, package] { try? FileManager.default.removeItem(at: url) } }
        let bytes = Data("synthetic original,42\n".utf8), hash = WorkspaceIO.digest(bytes)
        let path = "sources/" + hash + "/original.csv"
        try HouseholdWorkBackupTests().edit(f.paths) { tx, token in
            try WorkspaceIO.atomicWrite(bytes, to: tx.file(path, token: token))
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["sources": [["id": "synthetic-original", "path": path, "sha256": hash, "platform": "alipay"]]]), to: tx.file("config/review-import-sources.json", token: token))
        }
        _ = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        let handle = try connect(client, remote: remote)
        XCTAssertTrue(handle.checkpoint.payload.optionalOriginalObjects.contains(hash))
        XCTAssertFalse(FileManager.default.fileExists(atPath: handle.review.appendingPathComponent(path).path))
        XCTAssertThrowsError(try ReviewFamilyClientSession.material(paths: client, expected: handle, path: path, hash: String(repeating: "0", count: 64)))
        let file = try ReviewFamilyClientSession.material(paths: client, expected: handle, path: path, hash: hash)
        XCTAssertEqual(try WorkspaceIO.read(file), bytes)
        XCTAssertEqual(try ReviewFamilyClientSession.read(paths: client)?.version, handle.version)
        try FileManager.default.removeItem(at: remote)
        XCTAssertEqual(try ReviewFamilyClientSession.material(paths: client, expected: handle, path: path, hash: hash), file)
        try ReviewFamilyClientSession.exportSelectedBackup(paths: client, destination: package)
        let recovered = try ReviewFamilyClientSession.restoreSelectedBackup(package: package, destination: restored.workspace)
        let copied = try ReviewFamilyClientSession.material(paths: restored, expected: recovered, path: path, hash: hash)
        XCTAssertEqual(try WorkspaceIO.read(copied), bytes)
        XCTAssertThrowsError(try ReviewFamilyHost.readConnection(paths: restored))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.metadata.path))
    }
    func testFamilyClientBackupRestoresOfflineQueueAndFreshIdentityThenSyncs() async throws {
        let owner = ReviewFamilyHostTests(), f = try owner.fixture(), remote = owner.remote(f)
        let original = try client(f.paths), restored = try client(f.paths)
        let package = f.paths.workspace.deletingLastPathComponent().appendingPathComponent("client-backup-" + UUID().uuidString)
        defer { f.remove(); for root in [remote, original.workspace, restored.workspace, package] { try? FileManager.default.removeItem(at: root) } }
        _ = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        var handle = try connect(original, remote: remote)
        (_, handle) = try ReviewFamilyClientSession.edit(paths: original, expected: handle) { root, _ in try self.change(root, name: "Offline household", salary: 0) }
        let originalQueue = try ReviewRevisionOrigin.inventoryBytes(handle.queue)
        let originalIdentity = try WorkspaceIO.read(original.device.appendingPathComponent("device-identity.json"))
        try ReviewFamilyClientSession.exportSelectedBackup(paths: original, destination: package)
        let manifest = try WorkspaceIO.read(package.appendingPathComponent("manifest.json"))
        var recovered = try ReviewFamilyClientSession.restoreSelectedBackup(package: package, destination: restored.workspace)
        XCTAssertEqual(try ReviewRevisionOrigin.inventoryBytes(recovered.queue), originalQueue)
        XCTAssertEqual(recovered.settings.profileData, handle.settings.profileData)
        XCTAssertEqual(recovered.fields.causal.values["parameter/afterTaxSalary"], "0")
        XCTAssertNotEqual(try WorkspaceIO.read(restored.device.appendingPathComponent("device-identity.json")), originalIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.device.appendingPathComponent("host-authorization.json").path))
        XCTAssertNil(try ReviewFamilyClientSession.readConnection(paths: restored)?.bookmark)
        XCTAssertNotEqual(try ReviewFamilyClientSession.readConnection(paths: restored)?.remote, remote)
        XCTAssertEqual(try ReviewFamilyClientSession.readConnection(paths: restored)?.requiresReconnection, true)
        do { try await ReviewFamilyClientSession.transfer(paths: restored); XCTFail("restore must not transfer before explicit reconnect") } catch { }
        XCTAssertThrowsError(try ReviewFamilyClientSession.prepareRefresh(paths: restored))
        (_, recovered) = try ReviewFamilyClientSession.edit(paths: restored, expected: recovered) { root, _ in try self.change(root, salary: 42) }
        XCTAssertEqual(recovered.queue.count, handle.queue.count + 1)
        let priorIDs = Set(handle.queue.map { $0.key.revisionID })
        let newOrigin = try XCTUnwrap(recovered.queue.first { !priorIDs.contains($0.key.revisionID) })
        let restoredIdentity = try WorkspaceIO.object(WorkspaceIO.read(restored.device.appendingPathComponent("device-identity.json")))
        XCTAssertEqual(newOrigin.revision.device, restoredIdentity["device_id"] as? String)
        XCTAssertFalse(handle.queue.contains { $0.revision.device == newOrigin.revision.device })
        let highWater = restored.device.appendingPathComponent("family-sync/client/" + handle.selection.bindingID + "/cached-snapshot.json")
        XCTAssertEqual(try WorkspaceIO.object(WorkspaceIO.read(highWater))["generation"] as? String, handle.checkpoint.generation)
        _ = try ReviewFamilyClientSession.connect(paths: restored, remote: remote, bookmark: nil)
        try await ReviewFamilyClientSession.transfer(paths: restored)
        _ = try await ReviewFamilyHost.synchronize(paths: f.paths)
        recovered = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: restored))
        XCTAssertEqual(recovered.checkpoint.payload.fields.causal.values["parameter/afterTaxSalary"], "42")
        XCTAssertEqual(recovered.settings.householdName, "Offline household")
        XCTAssertEqual(try WorkspaceIO.read(package.appendingPathComponent("manifest.json")), manifest)
    }
    func testFamilyClientBackupRejectsCorruptionAuthorityAndExistingDestination() throws {
        let owner = ReviewFamilyHostTests(), f = try owner.fixture(), remote = owner.remote(f)
        let original = try client(f.paths), restored = try client(f.paths)
        let package = f.paths.workspace.deletingLastPathComponent().appendingPathComponent("client-backup-" + UUID().uuidString)
        defer { f.remove(); for root in [remote, original.workspace, restored.workspace, package] { try? FileManager.default.removeItem(at: root) } }
        _ = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        var handle = try connect(original, remote: remote)
        (_, handle) = try ReviewFamilyClientSession.edit(paths: original, expected: handle) { root, _ in try self.change(root, salary: 7) }
        try ReviewFamilyClientSession.exportSelectedBackup(paths: original, destination: package)
        let manifestFile = package.appendingPathComponent("manifest.json"), manifest = try WorkspaceIO.read(manifestFile)
        var row = try WorkspaceIO.object(manifest), files = try XCTUnwrap(row["files"] as? [String: String])
        let originPath = try XCTUnwrap(files.keys.first { $0.contains("/origins/") }), object = try WorkspaceIO.safeChild(package.appendingPathComponent("payload"), originPath)
        let originalRaw = try WorkspaceIO.read(object)
        try WorkspaceIO.atomicWrite(Data("{}".utf8), to: object)
        XCTAssertThrowsError(try ReviewFamilyClientSession.restoreSelectedBackup(package: package, destination: restored.workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.workspace.path))
        try WorkspaceIO.atomicWrite(originalRaw, to: object)
        let grantPath = "device/host-authorization.json", grant = Data("{}".utf8)
        try WorkspaceIO.atomicWrite(grant, to: package.appendingPathComponent("payload/" + grantPath))
        files[grantPath] = WorkspaceIO.digest(grant); row["files"] = files
        let forged = try WorkspaceIO.canonical(row)
        try WorkspaceIO.atomicWrite(forged, to: manifestFile)
        try WorkspaceIO.atomicWrite(Data((WorkspaceIO.digest(forged) + "\n").utf8), to: package.appendingPathComponent("manifest.sha256"))
        XCTAssertThrowsError(try ReviewFamilyClientSession.restoreSelectedBackup(package: package, destination: restored.workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.workspace.path))
        XCTAssertThrowsError(try ReviewFamilyClientSession.restoreSelectedBackup(package: package, destination: original.workspace))
        XCTAssertEqual(try ReviewFamilyClientSession.read(paths: original)?.version, handle.version)
    }
    func testRestartedTransportPages129OriginsIntoHostCheckpoint() async throws {
        let owner = ReviewFamilyHostTests(), f = try owner.fixture(), remote = owner.remote(f)
        defer { f.remove(); try? FileManager.default.removeItem(at: remote) }
        let connection = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        let cache = f.paths.workspace.deletingLastPathComponent().appendingPathComponent("paged-client-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: cache) }
        var queue = [ReviewNativeRevision](), parents = [String]()
        for clock in 1...129 {
            let id = String(format: "00000000-0000-4000-8000-%012d", clock)
            let raw = try JSONEncoder().encode(ReviewRevision(id: id, device: "synthetic-paged-client", clock: clock,
                values: ["parameter/afterTaxSalary": String(clock)], bases: [:], observed: [:], parents: parents))
            queue.append(try .init(sourceBindingID: connection.selection.bindingID, raw: raw))
            parents = [id]
        }
        var uploaded = Set<String>()
        for _ in 0..<2 {
            // The production client also creates a new transport for every transfer.
            let restarted = try ReviewFamilyRevisionTransport(remote: remote, cache: cache, selection: connection.selection)
            let page = try await restarted.poll(outgoing: queue)
            XCTAssertEqual(page.uploadedRevisionIDs.count, 128)
            uploaded.formUnion(page.uploadedRevisionIDs)
        }
        XCTAssertEqual(uploaded, Set(queue.map { $0.revision.id }))
        for _ in 0..<2 { _ = try await ReviewFamilyHost.synchronize(paths: f.paths) }
        let store = try owner.reader(f, connection)
        guard case .ready(let checkpoint) = try store.prepareNewFamily() else { return XCTFail("paged Host checkpoint") }
        XCTAssertEqual(Set(checkpoint.payload.fields.causal.revisions.map { $0.revision.id }), uploaded)
        XCTAssertEqual(checkpoint.payload.fields.causal.values["parameter/afterTaxSalary"], "129")
        for revision in queue {
            XCTAssertEqual(try WorkspaceIO.read(remote.appendingPathComponent("objects/" + revision.origin.payloadHash)), revision.raw)
        }
    }
    func testFamilyConflictHostChoicePreservesOriginsAndRejectsStaleChoice() async throws {
        let owner = ReviewFamilyHostTests(), f = try owner.fixture(), remote = owner.remote(f), offline = remote.appendingPathExtension("offline")
        let a = try client(f.paths), b = try client(f.paths)
        defer { f.remove(); for path in [remote, offline, a.workspace, b.workspace] { try? FileManager.default.removeItem(at: path) } }
        _ = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        var first = try connect(a, remote: remote), second = try connect(b, remote: remote)
        (_, first) = try ReviewFamilyClientSession.edit(paths: a, expected: first) { root, _ in try self.change(root, name: "A") }
        (_, second) = try ReviewFamilyClientSession.edit(paths: b, expected: second) { root, _ in try self.change(root, name: "B") }
        do {
            let token = try WorkspaceCoordinator(paths: f.paths).acquireWriteToken()
            let tx = try WorkspaceCoordinator(paths: f.paths).begin(token: token, expectedPointer: f.paths.readPointer())
            let file = try tx.file("config/family-profile.json", token: token)
            try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.replacingObjectMember(raw: WorkspaceIO.read(file), key: "household_name", valueRaw: Data("\"Host\"".utf8)), to: file)
            _ = try NativeWorkspaceEffects.record(transaction: tx, token: token)
            _ = try tx.prepare(token: token, validator: WorkspaceBusinessValidator.validate); _ = try tx.commit(token: token)
        }
        let head = try WorkspaceIO.read(remote.appendingPathComponent("current.json"))
        try await ReviewFamilyClientSession.transfer(paths: a); try await ReviewFamilyClientSession.transfer(paths: b)
        do { _ = try await ReviewFamilyHost.synchronize(paths: f.paths); XCTFail("settings conflict") } catch { }
        let captured = try f.paths.readPointer(), choice = try ReviewFamilyHost.conflictState(paths: f.paths)
        XCTAssertEqual(choice.options["settings/family-profile"]?.count, 3)
        do { _ = try await ReviewFamilyHost.synchronize(paths: f.paths); XCTFail("still conflicted") } catch { }
        XCTAssertEqual(try f.paths.readPointer(), captured, "already-saved Host origin is not regenerated on retry")
        XCTAssertThrowsError(try ReviewFamilyHost.resolveConflicts(paths: f.paths, expected: choice, choices: ["settings/family-profile": "{} "]))
        (_, first) = try ReviewFamilyClientSession.edit(paths: a, expected: first) { root, _ in try self.change(root, name: "C") }
        try await ReviewFamilyClientSession.transfer(paths: a)
        do { _ = try await ReviewFamilyHost.synchronize(paths: f.paths); XCTFail("new conflict") } catch { }
        let current = try ReviewFamilyHost.conflictState(paths: f.paths)
        let value = try XCTUnwrap(current.options["settings/family-profile"]?.first { (try? WorkspaceIO.object(Data($0.utf8))["household_name"] as? String) == "Host" })
        XCTAssertThrowsError(try ReviewFamilyHost.resolveConflicts(paths: f.paths, expected: choice, choices: ["settings/family-profile": value]))
        XCTAssertEqual(try f.paths.readPointer(), captured)
        try FileManager.default.moveItem(at: remote, to: offline)
        _ = try ReviewFamilyHost.resolveConflicts(paths: f.paths, expected: current, choices: ["settings/family-profile": value])
        XCTAssertTrue(try ReviewFamilyHost.conflictState(paths: f.paths).options.isEmpty)
        XCTAssertEqual(try WorkspaceIO.read(offline.appendingPathComponent("current.json")), head)
        try FileManager.default.moveItem(at: offline, to: remote)
        _ = try await ReviewFamilyHost.synchronize(paths: f.paths)
        first = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: a)); second = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: b))
        XCTAssertEqual(first.settings.householdName, "Host"); XCTAssertEqual(second.settings.householdName, "Host")
        XCTAssertEqual(first.checkpoint.payload.fields.causal.revisions.count, 5)
        XCTAssertEqual(first.queue.count, 2); XCTAssertEqual(second.queue.count, 1)
        XCTAssertTrue(first.conflicts.isEmpty); try ReviewWorkspaceMembership.validate(state: f.paths.readState())
    }
    func testFamilyConflictClientChoosingDisplayedValueCreatesOriginAndSurvivesOfflineRestart() async throws {
        let owner = ReviewFamilyHostTests(), f = try owner.fixture(), remote = owner.remote(f), offline = remote.appendingPathExtension("offline")
        let a = try client(f.paths), b = try client(f.paths)
        defer { f.remove(); for path in [remote, offline, a.workspace, b.workspace] { try? FileManager.default.removeItem(at: path) } }
        _ = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        var first = try connect(a, remote: remote), second = try connect(b, remote: remote)
        (_, first) = try ReviewFamilyClientSession.edit(paths: a, expected: first) { root, _ in try self.change(root, salary: 0) }
        (_, second) = try ReviewFamilyClientSession.edit(paths: b, expected: second) { root, _ in try self.change(root, salary: 7) }
        try await ReviewFamilyClientSession.transfer(paths: a); try await ReviewFamilyClientSession.transfer(paths: b)
        _ = try await ReviewFamilyHost.synchronize(paths: f.paths)
        first = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: a))
        let key = "parameter/afterTaxSalary", chosen = try XCTUnwrap(first.fields.causal.values[key]), before = first
        XCTAssertEqual(first.conflicts[key]?.count, 2)
        try FileManager.default.moveItem(at: remote, to: offline)
        XCTAssertThrowsError(try ReviewFamilyClientSession.resolveConflicts(paths: a, expected: first, choices: [key: "99"]))
        first = try ReviewFamilyClientSession.resolveConflicts(paths: a, expected: first, choices: [key: chosen])
        XCTAssertEqual(first.queue.count, before.queue.count + 1); XCTAssertTrue(first.conflicts.isEmpty)
        XCTAssertEqual(try ReviewFamilyClientSession.read(paths: a)?.version, first.version)
        XCTAssertThrowsError(try ReviewFamilyClientSession.resolveConflicts(paths: a, expected: before, choices: [key: chosen]))
        try FileManager.default.moveItem(at: offline, to: remote)
        try await ReviewFamilyClientSession.transfer(paths: a)
        _ = try await ReviewFamilyHost.synchronize(paths: f.paths)
        second = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: b))
        XCTAssertEqual(second.fields.causal.values[key], chosen); XCTAssertTrue(second.conflicts.isEmpty)
        XCTAssertEqual(second.checkpoint.payload.fields.causal.revisions.count, 3)
        XCTAssertEqual(try ReviewFamilyClientSession.read(paths: a)?.queue.count, 2)
    }
    func testOfflineEditsABARestartAndEqualValuedIndependentOriginsReachHostCheckpoint() async throws {
        let owner = ReviewFamilyHostTests(), f = try owner.fixture(), remote = owner.remote(f), offline = remote.appendingPathExtension("offline")
        let c = try client(f.paths), d = try client(f.paths)
        defer { f.remove(); for path in [remote, offline, c.workspace, d.workspace] { try? FileManager.default.removeItem(at: path) } }
        _ = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        var handle = try connect(c, remote: remote), other = try connect(d, remote: remote)
        let baseline = handle.checkpoint.generation
        try FileManager.default.moveItem(at: remote, to: offline)
        (_, handle) = try ReviewFamilyClientSession.edit(paths: c, expected: handle) { root, _ in try self.change(root, name: "B", salary: 0) }
        (_, handle) = try ReviewFamilyClientSession.edit(paths: c, expected: handle) { root, _ in try self.change(root, name: "", salary: 10) }
        (_, handle) = try ReviewFamilyClientSession.edit(paths: c, expected: handle) { root, _ in try self.change(root, salary: 0) }
        (_, other) = try ReviewFamilyClientSession.edit(paths: d, expected: other) { root, _ in try self.change(root, salary: 0) }
        let origins = handle.queue, ids = origins.map { $0.key.revisionID }
        handle = try XCTUnwrap(ReviewFamilyClientSession.read(paths: c))
        XCTAssertEqual(handle.queue.map { $0.key.revisionID }, ids); XCTAssertEqual(handle.settings.householdName, "")
        XCTAssertEqual(handle.fields.causal.values["parameter/afterTaxSalary"], "0"); XCTAssertEqual(handle.queue.count, 3)
        XCTAssertEqual(handle.checkpoint.generation, baseline)
        try FileManager.default.moveItem(at: offline, to: remote)
        try await ReviewFamilyClientSession.transfer(paths: c); try await ReviewFamilyClientSession.transfer(paths: d)
        let generation = try await ReviewFamilyHost.synchronize(paths: f.paths)
        handle = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: c))
        XCTAssertEqual(handle.checkpoint.generation, generation); XCTAssertEqual(handle.checkpoint.payload.fields.causal.revisions.count, 4)
        XCTAssertEqual(handle.fields.causal.values["parameter/afterTaxSalary"], "0")
        XCTAssertEqual(handle.queue.map { $0.key.revisionID }, ids)
        for origin in origins { for (hash, bytes) in origin.sources {
            XCTAssertEqual(try WorkspaceIO.read(f.paths.readState().file("history/edits/" + handle.selection.bindingID + "/" + hash + ".json")), bytes)
        } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.device.appendingPathComponent("host-authorization.json").path))
        try ReviewWorkspaceMembership.validate(state: f.paths.readState())
    }
    func testPointerCASAndCacheHighWaterCannotReplaceSelectedQueueOrDamagedOrigins() throws {
        let owner = ReviewFamilyHostTests(), f = try owner.fixture(), remote = owner.remote(f), c = try client(f.paths)
        defer { f.remove(); for path in [remote, c.workspace] { try? FileManager.default.removeItem(at: path) } }
        let connection = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        let old = try connect(c, remote: remote)
        let (_, edited) = try ReviewFamilyClientSession.edit(paths: c, expected: old) { root, _ in try self.change(root, salary: 0) }
        XCTAssertThrowsError(try ReviewFamilyClientSession.edit(paths: c, expected: old) { root, _ in try self.change(root, salary: 9) })
        let version = edited.version
        XCTAssertThrowsError(try ReviewFamilyClientSession.edit(paths: c, expected: edited) { root, _ in try WorkspaceIO.atomicWrite(Data("{}".utf8), to: root.appendingPathComponent("family-profile.json")) })
        XCTAssertEqual(try ReviewFamilyClientSession.read(paths: c)?.version, version)
        do {
            let token = try WorkspaceCoordinator(paths: f.paths).acquireWriteToken(), tx = try WorkspaceCoordinator(paths: f.paths).begin(token: token, expectedPointer: f.paths.readPointer())
            try WorkspaceIO.atomicWrite(Data("{\"afterTaxSalary\":7}".utf8), to: tx.file("review/fire-parameters-user.json", token: token))
            _ = try NativeWorkspaceEffects.record(transaction: tx, token: token); _ = try tx.prepare(token: token, validator: WorkspaceBusinessValidator.validate); _ = try tx.commit(token: token)
        }
        _ = try ReviewFamilyHost.publish(paths: f.paths)
        let cache = try ReviewFamilySnapshotStore(remote: remote, local: c.device.appendingPathComponent("family-sync/client"), selection: connection.selection)
        _ = try cache.prepareNewFamily()
        XCTAssertEqual(try ReviewFamilyClientSession.read(paths: c)?.version, version)
        guard case .ready(let prepared) = try ReviewFamilyClientSession.prepareRefresh(paths: c) else { return XCTFail("new checkpoint prepared") }
        let (_, latest) = try ReviewFamilyClientSession.edit(paths: c, expected: edited) { root, _ in try self.change(root, salary: 5) }
        XCTAssertThrowsError(try ReviewFamilyClientSession.commitRefresh(paths: c, prepared: prepared))
        XCTAssertEqual(try ReviewFamilyClientSession.read(paths: c)?.version, latest.version)
        let hash = try XCTUnwrap(edited.queue.first?.primaryHash)
        try WorkspaceIO.atomicWrite(Data("{}".utf8), to: c.device.appendingPathComponent("client-edits/" + connection.selection.bindingID + "/origins/" + hash))
        XCTAssertThrowsError(try ReviewFamilyClientSession.read(paths: c))
    }
    func testSettingsConflictRetainsBothQueuesAndRejectsHostOrCrossBindingClientSelection() async throws {
        let owner = ReviewFamilyHostTests(), f = try owner.fixture(), remote = owner.remote(f), c = try client(f.paths), d = try client(f.paths)
        defer { f.remove(); for path in [remote, c.workspace, d.workspace] { try? FileManager.default.removeItem(at: path) } }
        _ = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        var a = try connect(c, remote: remote), b = try connect(d, remote: remote)
        (_, a) = try ReviewFamilyClientSession.edit(paths: c, expected: a) { root, _ in try self.change(root, name: "A") }
        (_, b) = try ReviewFamilyClientSession.edit(paths: d, expected: b) { root, _ in try self.change(root, name: "B") }
        let pointer = try f.paths.readPointer(), head = try WorkspaceIO.read(remote.appendingPathComponent("current.json"))
        try await ReviewFamilyClientSession.transfer(paths: c); try await ReviewFamilyClientSession.transfer(paths: d)
        do { _ = try await ReviewFamilyHost.synchronize(paths: f.paths); XCTFail("settings conflict must wait") } catch { }
        XCTAssertEqual(try f.paths.readPointer(), pointer); XCTAssertEqual(try WorkspaceIO.read(remote.appendingPathComponent("current.json")), head)
        XCTAssertEqual(try ReviewFamilyClientSession.read(paths: c)?.version, a.version); XCTAssertEqual(try ReviewFamilyClientSession.read(paths: d)?.version, b.version)
        do {
            XCTAssertThrowsError(try ReviewFamilyClientSession.connect(paths: f.paths, remote: remote, bookmark: nil))
        }
        let identity = c.device.appendingPathComponent("device-identity.json"), originalIdentity = try WorkspaceIO.read(identity)
        try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.replacingObjectMember(raw: originalIdentity, key: "device_id", valueRaw: Data("99".utf8)), to: identity)
        XCTAssertThrowsError(try ReviewFamilyClientSession.read(paths: c))
        try WorkspaceIO.atomicWrite(originalIdentity, to: identity)
        var marker = try WorkspaceIO.object(WorkspaceIO.read(remote.appendingPathComponent("family.json"))); marker["binding_id"] = UUID().uuidString.lowercased()
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(marker), to: remote.appendingPathComponent("family.json"))
        do {
            XCTAssertThrowsError(try ReviewFamilyClientSession.connect(paths: c, remote: remote, bookmark: nil))
        }
        XCTAssertEqual(try ReviewFamilyClientSession.read(paths: c)?.version, a.version)
    }
}
