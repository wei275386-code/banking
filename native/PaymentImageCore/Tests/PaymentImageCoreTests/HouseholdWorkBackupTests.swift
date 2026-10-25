import Foundation
import XCTest
@testable import PaymentImageCore

@MainActor final class HouseholdWorkBackupTests: XCTestCase {
    func location(_ prefix: String) throws -> URL {
        try TestPlatform.temporaryDirectory().appendingPathComponent(prefix + UUID().uuidString.lowercased())
    }
    func edit(_ paths: WorkspacePaths, _ body: (WorkspaceTransaction, WorkspaceWriteToken) throws -> Void) throws {
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        let transaction = try WorkspaceCoordinator(paths: paths).begin(token: token, expectedPointer: paths.readPointer())
        try body(transaction, token)
        _ = try NativeWorkspaceEffects.record(transaction: transaction, token: token)
        _ = try transaction.prepare(token: token, validator: WorkspaceBusinessValidator.validate)
        _ = try transaction.commit(token: token)
    }
    func testOfflineUnpublishedHostRestoresWorkAndCreatesIndependentSync() throws {
        let helper = ReviewFamilyHostTests(), f = try helper.fixture()
        let remote = helper.remote(f), package = try location("work-backup-"), destination = try location("work-restore-"), newRemote = try location("new-work-sync-")
        defer { f.remove(); for url in [remote, package, destination, newRemote] { try? FileManager.default.removeItem(at: url) } }
        let connection = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        let rules = Data(#"{"rules":[],"private_extension":{"note":"synthetic household rule"}}"#.utf8)
        let original = Data("date,amount\n2026-01-01,42\n".utf8)
        let originalPath = "sources/" + WorkspaceIO.digest(original) + "/original.csv"
        try edit(f.paths) { transaction, token in
            try WorkspaceIO.atomicWrite(rules, to: transaction.file("review/classification-rules.json", token: token))
            try WorkspaceIO.atomicWrite(original, to: transaction.file(originalPath, token: token))
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["sources": [["id": "synthetic-source", "platform": "wechat", "path": originalPath, "sha256": WorkspaceIO.digest(original)]]]), to: transaction.file("config/review-import-sources.json", token: token))
            let file = try transaction.file("config/family-profile.json", token: token)
            try WorkspaceIO.atomicWrite(ReleaseCanonicalJSON.replacingObjectMember(raw: WorkspaceIO.read(file), key: "household_name", valueRaw: Data("\"Saved but not published\"".utf8)), to: file)
        }
        let before = try f.paths.readState(), oldLedger = try WorkspaceIO.read(before.operationResults)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: before.file(originalPath).path)
        try FileManager.default.removeItem(at: remote)
        try HouseholdWorkBackup.export(paths: f.paths, destination: package, expectedPointer: before.pointer)
        XCTAssertEqual(try f.paths.readPointer(), before.pointer)
        XCTAssertTrue(try HouseholdWorkBackup.recognizes(package))
        let paths = try HouseholdWorkBackup.restore(package: package, destination: destination)
        let state = try paths.readState()
        XCTAssertEqual(state.pointer.workspaceID, before.pointer.workspaceID)
        XCTAssertNotEqual(state.pointer.stateID, before.pointer.stateID)
        XCTAssertEqual(try WorkspaceIO.read(state.file(originalPath)), original)
        XCTAssertEqual(try WorkspaceIO.read(state.file("review/classification-rules.json")), rules)
        XCTAssertEqual(try ReleaseCanonicalJSON.canonicalFragment(raw: WorkspaceIO.read(state.operationResults), atObjectKeys: ["results"]), try ReleaseCanonicalJSON.canonicalFragment(raw: oldLedger, atObjectKeys: ["results"]))
        XCTAssertNil(try ReviewFamilyHost.readConnection(paths: paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.device.appendingPathComponent("restore-status.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try state.file("review/field-state.json").path))
        XCTAssertEqual(try WorkspaceIO.regularFiles(paths.states).filter { $0.hasSuffix("state-manifest.json") }.count, 1)
        try WorkspaceCompatibility.requireWriter(paths: paths, state: state)
        try ReviewWorkspaceMembership.validate(state: state)
        #if os(macOS)
        let code = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = try ProcessorRuntime(project: code, python: TestPlatform.python())
        _ = try ProcessorExecution(runtime: runtime, workspace: paths, state: state)
        #endif
        try edit(paths) { transaction, token in
            try WorkspaceIO.atomicWrite(Data("{\"afterTaxSalary\":123}".utf8), to: transaction.file("review/fire-parameters-user.json", token: token))
        }
        let fresh = try ReviewFamilyHost.create(paths: paths, remote: newRemote)
        XCTAssertNotEqual(fresh.selection.bindingID, connection.selection.bindingID)
        XCTAssertNotEqual(fresh.selection.hostID, connection.selection.hostID)
        let reader = try helper.reader(f, fresh)
        guard case .ready(let published) = try reader.prepare(contextForGeneration: { _, _ in
            .init(sourceBindings: [fresh.selection.bindingID], settings: .init(registeredSourceIDs: ["synthetic-source"], currencyCodes: ["CNY"], referencedMemberIDs: [], referencedAccountIDs: []))
        }) else { return XCTFail("Restored work must publish and reopen as a new family baseline") }
        XCTAssertEqual(published.payload.fields.settings.householdName, "Saved but not published")
        XCTAssertEqual(published.payload.fields.causal.values["parameter/afterTaxSalary"], "123")
        XCTAssertEqual(try f.paths.readPointer(), before.pointer)
    }
    func testPendingPublicationCanBeBackedUpWithoutProviderOrOldFreeze() throws {
        let helper = ReviewFamilyHostTests(), f = try helper.fixture()
        let remote = helper.remote(f), package = try location("interrupted-backup-"), destination = try location("interrupted-restore-")
        defer { f.remove(); for url in [remote, package, destination] { try? FileManager.default.removeItem(at: url) } }
        XCTAssertThrowsError(try ReviewFamilyHost.create(paths: f.paths, remote: remote, failureInjector: { if $0 == .intentSaved { throw ReviewFamilyHostTests.Crash.injected } }))
        XCTAssertThrowsError(try ReviewFamilyHost.requireNoPendingWrite(paths: f.paths))
        try FileManager.default.removeItem(at: remote)
        try HouseholdWorkBackup.export(paths: f.paths, destination: package)
        let restored = try HouseholdWorkBackup.restore(package: package, destination: destination)
        try ReviewFamilyHost.requireNoPendingWrite(paths: restored)
        try edit(restored) { transaction, token in
            try WorkspaceIO.atomicWrite(Data("{\"afterTaxSalary\":7}".utf8), to: transaction.file("review/fire-parameters-user.json", token: token))
        }
    }
    func testPendingHostTaskRestoresWithoutConnectionAndAdoptsOnlyExplicitNewBinding() async throws {
        let helper = ReviewFamilyHostTests(), f = try helper.fixture()
        let remote = helper.remote(f), package = try location("pending-backup-"), destination = try location("pending-restore-"), newRemote = try location("pending-new-family-")
        defer { f.remove(); for url in [remote, package, destination, newRemote] { try? FileManager.default.removeItem(at: url) } }
        let connection = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        let cache = f.paths.device.appendingPathComponent("family-host-requests/" + connection.selection.bindingID)
        let queue = try ReviewFamilyRequestTransport(remote: nil, cache: cache, selection: connection.selection)
        let original = f.paths.device.appendingPathComponent("pending.csv")
        let bytes = Data("date,amount\n2026-01-01,42\n".utf8)
        try WorkspaceIO.atomicWrite(bytes, to: original)
        let request = try await queue.enqueueImport(files: [original], authorDeviceID: UUID().uuidString.lowercased())
        try FileManager.default.removeItem(at: remote)
        try HouseholdWorkBackup.export(paths: f.paths, destination: package)
        let restored = try HouseholdWorkBackup.restore(package: package, destination: destination)
        XCTAssertNil(try ReviewFamilyHost.readConnection(paths: restored))
        let portable = HouseholdPendingRequests.root(restored)
        let row = try WorkspaceIO.object(WorkspaceIO.read(portable.appendingPathComponent("envelopes/" + request.id + ".json")))
        XCTAssertNil(row["binding_id"])
        XCTAssertEqual(try WorkspaceIO.read(portable.appendingPathComponent("objects/" + request.files[0].sha256)), bytes)
        let fresh = try ReviewFamilyHost.create(paths: restored, remote: newRemote)
        XCTAssertNotEqual(fresh.selection.bindingID, connection.selection.bindingID)
        XCTAssertNotEqual(fresh.selection.hostID, connection.selection.hostID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: portable.path))
        let newCache = restored.device.appendingPathComponent("family-host-requests/" + fresh.selection.bindingID)
        let newQueue = try ReviewFamilyRequestTransport(remote: nil, cache: newCache, selection: fresh.selection)
        let requests = try await newQueue.cachedRequests()
        XCTAssertEqual(requests.map(\.id), [request.id])
        XCTAssertEqual(requests.first?.authorDeviceID, request.authorDeviceID)
        XCTAssertEqual(requests.first?.payload, request.payload)
        XCTAssertEqual(requests.first?.selection, fresh.selection)
        XCTAssertEqual(try WorkspaceIO.read(newCache.appendingPathComponent("objects/" + request.files[0].sha256)), bytes)
        let status = try await newQueue.localStatuses()
        XCTAssertEqual(status[request.id], "queued")
    }
    func testViewingCopyRetainsBusinessBytesAndCannotBecomeWriterOrHost() throws {
        let f = try ReviewFamilyHostTests().fixture()
        let package = try location("viewing-backup-"), destination = try location("viewing-restore-"), remote = try location("viewing-provider-")
        defer { f.remove(); for url in [package, destination, remote] { try? FileManager.default.removeItem(at: url) } }
        let before = try f.paths.readState()
        let financial = try WorkspaceIO.read(before.file("review/financial-review.json"))
        try HouseholdWorkBackup.export(paths: f.paths, destination: package, readOnly: true)
        let restored = try HouseholdWorkBackup.restore(package: package, destination: destination)
        let state = try restored.readState()
        XCTAssertEqual(state.pointer.workspaceID, before.pointer.workspaceID)
        XCTAssertEqual(try WorkspaceIO.read(state.file("review/financial-review.json")), financial)
        XCTAssertTrue(try WorkspaceCompatibility.isViewingCopy(paths: restored))
        XCTAssertThrowsError(try WorkspaceCompatibility.requireWriter(paths: restored, state: state))
        XCTAssertThrowsError(try ReviewFamilyHost.create(paths: restored, remote: remote))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.device.appendingPathComponent("host-authorization.json").path))
    }
    func testCorruptionMissingFilesAndExistingDestinationNeverPublishOrOverwrite() throws {
        let f = try ReviewFamilyHostTests().fixture()
        let package = try location("invalid-backup-"), destination = try location("invalid-restore-")
        defer { f.remove(); for url in [package, destination] { try? FileManager.default.removeItem(at: url) } }
        try HouseholdWorkBackup.export(paths: f.paths, destination: package)
        XCTAssertThrowsError(try HouseholdWorkBackup.export(paths: f.paths, destination: package))
        let file = package.appendingPathComponent("payload/review/financial-review.json")
        let original = try WorkspaceIO.read(file)
        try WorkspaceIO.atomicWrite(Data("{}".utf8), to: file)
        XCTAssertThrowsError(try HouseholdWorkBackup.restore(package: package, destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try WorkspaceIO.atomicWrite(original, to: file)
        try FileManager.default.removeItem(at: package.appendingPathComponent("payload/review/preview.png"))
        XCTAssertThrowsError(try HouseholdWorkBackup.restore(package: package, destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertThrowsError(try HouseholdWorkBackup.restore(package: package, destination: destination))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }
    func testViewingCopiesClientsAndFutureVersionsCannotBecomeWorkingHouseholds() throws {
        let f = try ReviewFamilyHostTests().fixture()
        let package = try location("version-backup-"), destination = try location("version-restore-")
        defer { f.remove(); for url in [package, destination] { try? FileManager.default.removeItem(at: url) } }
        var access = try WorkspaceIO.object(WorkspaceIO.read(f.paths.metadata)); access["access"] = "viewing"
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(access), to: f.paths.metadata)
        XCTAssertThrowsError(try HouseholdWorkBackup.export(paths: f.paths, destination: package))
        access["access"] = "writable"; try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(access), to: f.paths.metadata)
        try HouseholdWorkBackup.export(paths: f.paths, destination: package)
        let file = package.appendingPathComponent("manifest.json")
        var row = try WorkspaceIO.object(WorkspaceIO.read(file))
        var metadata = row["workspace"] as! [String: Any]
        metadata["min_writer_version"] = "999.0.0"; row["workspace"] = metadata
        let raw = try WorkspaceIO.canonical(row)
        try WorkspaceIO.atomicWrite(raw, to: file)
        try WorkspaceIO.atomicWrite(Data((WorkspaceIO.digest(raw) + "\n").utf8), to: package.appendingPathComponent("manifest.sha256"))
        XCTAssertThrowsError(try HouseholdWorkBackup.restore(package: package, destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    #if os(macOS)
    func testRestoredHouseholdImportsNewStatementAndRecomputesWithActualProcessor() async throws {
        let root = try location("actual-work-backup-")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let code = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let python = try TestPlatform.python()
        let original = try WorkspacePaths(workspace: root.appendingPathComponent("original"))
        let process = Process(), log = root.appendingPathComponent("initialize.log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.executableURL = python; process.currentDirectoryURL = code
        process.arguments = ["-B", "-c", "import sys; from scripts.workspace_initialization import create_workspace; create_workspace(sys.argv[1])", original.workspace.path]
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        let initializationLog = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0, initializationLog)
        let runtime = try ProcessorRuntime(project: code, python: python)
        func statement(_ name: String, day: String, amount: String) throws -> URL {
            let file = root.appendingPathComponent(name + ".csv")
            let csv = "交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注\n" +
                day + " 10:00:00,餐饮美食,Synthetic cafe,,Synthetic coffee,支出," + amount + ",余额,交易成功," + name + ",merchant-" + name + ",\n"
            try Data(csv.utf8).write(to: file)
            return file
        }
        let first = try statement("synthetic-before", day: "2026-01-01", amount: "60.00")
        let imported = try await ProcessorExecution(runtime: runtime, workspace: original, state: original.readState()).run(operation: .import, input: JSONEncoder().encode([first.path]), timeout: 60)
        XCTAssertEqual(imported.phase, "committed")
        let before = try original.readState()
        let firstReport = try WorkspaceIO.object(WorkspaceIO.read(before.file("review/financial-review.json")))
        let originalIDs = Set((firstReport["records"] as! [[String: Any]]).map { $0["id"] as! String })
        XCTAssertEqual(originalIDs.count, 1)
        let package = root.appendingPathComponent("package")
        try HouseholdWorkBackup.export(paths: original, destination: package)
        let restored = try HouseholdWorkBackup.restore(package: package, destination: root.appendingPathComponent("restored"))
        let second = try statement("synthetic-after", day: "2026-01-02", amount: "25.00")
        let continued = try await ProcessorExecution(runtime: runtime, workspace: restored, state: restored.readState()).run(operation: .import, input: JSONEncoder().encode([second.path]), timeout: 60)
        XCTAssertEqual(continued.phase, "committed")
        let evidence = try WorkspaceIO.object(WorkspaceIO.read(restored.readState().file("review/payment-evidence.json")))
        let review = try WorkspaceIO.canonical(["dataset_id": evidence["dataset_id"]!, "decisions": [String: String]()])
        let recomputed = try await ProcessorExecution(runtime: runtime, workspace: restored, state: restored.readState()).run(operation: .review, input: review, timeout: 60)
        XCTAssertEqual(recomputed.phase, "committed")
        let after = try restored.readState()
        let report = try WorkspaceIO.object(WorkspaceIO.read(after.file("review/financial-review.json")))
        let ids = Set((report["records"] as! [[String: Any]]).map { $0["id"] as! String })
        XCTAssertEqual(ids.count, 2); XCTAssertTrue(originalIDs.isSubset(of: ids))
        try ReviewWorkspaceMembership.validate(state: after)
        XCTAssertEqual(try original.readPointer(), before.pointer)
    }
    #endif
    func testCancelledExportLeavesNoPartialPackage() async throws {
        let f = try ReviewFamilyHostTests().fixture(), package = try location("cancelled-backup-")
        defer { f.remove(); try? FileManager.default.removeItem(at: package) }
        let work = Task { try HouseholdWorkBackup.export(paths: f.paths, destination: package) }
        work.cancel()
        do { try await work.value; XCTFail("cancelled backup must not be published") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
    }
}
