import XCTest
import Foundation
import CSQLite
@testable import PaymentImageCore

final class WorkspaceHealthTests: XCTestCase {
    enum Injected: Error { case stop }
    private func fixture() throws -> (URL, WorkspacePaths) {
        let canonicalTemporary = try TestPlatform.temporaryDirectory().path
        let directory = URL(fileURLWithPath: canonicalTemporary + "/upgrade-test-" + UUID().uuidString)
        let paths = try WorkspacePaths(workspace: URL(fileURLWithPath: directory.path + "/workspace"))
        let workspace = UUID().uuidString.lowercased(), state = UUID().uuidString.lowercased()
        let root = try paths.stateRoot(state)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["workspace_id": workspace, "created_at": "2026-10-14T00:00:00Z"]), to: paths.metadata)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("banking.sqlite3").path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE facts(id TEXT PRIMARY KEY, amount INTEGER); INSERT INTO facts VALUES('old',42)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        for name in WorkspaceIO.requiredFiles where name != "banking.sqlite3" {
            let value: [String: Any] = name == "operation-results.json" ? ["state_id": state, "results": []] :
                (name == "review/financial-review.json" ? ["records": []] : [:])
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(value), to: WorkspaceIO.safeChild(root, name))
        }
        var hashes = [String: String]()
        for name in WorkspaceIO.requiredFiles { hashes[name] = try WorkspaceIO.hash(WorkspaceIO.safeChild(root, name)) }
        let manifest = try WorkspaceIO.canonical(["workspace_id": workspace, "state_id": state,
                                                  "local_revision": 0, "files": hashes])
        try WorkspaceIO.atomicWrite(manifest, to: root.appendingPathComponent("state-manifest.json"))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(WorkspaceStatePointer(workspaceID: workspace, stateID: state,
            localRevision: 0, manifestHash: WorkspaceIO.digest(manifest)).document), to: paths.activeState)
        try WorkspaceIO.atomicWrite(Data("pending-original-and-bookmark".utf8), to: paths.device.appendingPathComponent("unknown/preferences.bin"))
        return (directory, paths)
    }

    func testUnknownContractsAndNewerWriterFailClosed() throws {
        let version = try WorkspaceCompatibility.evaluate(minimumWriter: "2.0.0", runningVersion: "1.3.0")
        XCTAssertTrue(version.readable); XCTAssertFalse(version.writable)
        XCTAssertFalse(try WorkspaceCompatibility.supports(minimumVersion: "1.10.0", runningVersion: "1.3.0"))
        XCTAssertThrowsError(try WorkspaceCompatibility.supports(minimumVersion: "1.01.0"))
        let (directory, paths) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        var metadata = try WorkspaceIO.object(WorkspaceIO.read(paths.metadata)); metadata["min_writer_version"] = "2.0.0"
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(metadata), to: paths.metadata)
        XCTAssertNoThrow(try paths.readViewingState())
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        XCTAssertThrowsError(try WorkspaceCoordinator(paths: paths).begin(token: token, expectedPointer: paths.readPointer()))
    }

    func testViewingCopyRequiresMembershipAndHashes() throws {
        let (directory, paths) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = try paths.readState()
        // Strict JSON can remain readable in an unqualified legacy viewing copy.
        try WorkspaceIO.atomicWrite(Data("{\"state_id\":\"wrong\",\"results\":[]}".utf8), to: state.operationResults)
        var manifest = try WorkspaceIO.object(WorkspaceIO.read(state.manifest))
        var files = try XCTUnwrap(manifest["files"] as? [String: String]); files["operation-results.json"] = try WorkspaceIO.hash(state.operationResults)
        manifest["files"] = files
        let raw = try WorkspaceIO.canonical(manifest)
        try WorkspaceIO.atomicWrite(raw, to: state.manifest)
        let pointer = WorkspaceStatePointer(workspaceID: state.pointer.workspaceID, stateID: state.pointer.stateID,
            localRevision: 0, manifestHash: WorkspaceIO.digest(raw))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pointer.document), to: paths.activeState)
        var metadata = try WorkspaceIO.object(WorkspaceIO.read(paths.metadata)); metadata["access"] = "viewing"
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(metadata), to: paths.metadata)
        XCTAssertThrowsError(try paths.readViewingState()); XCTAssertThrowsError(try paths.readState())
        XCTAssertThrowsError(try WorkspaceCompatibility.requireWriter(paths: paths, state: state))
        try WorkspaceIO.atomicWrite(Data("tampered".utf8), to: state.database)
        XCTAssertThrowsError(try paths.readViewingState())
    }

    func testFirstRunRequiresRuntimeHealthAndPropagatesFailure() throws {
        let (directory, paths) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let health = try WorkspaceHealth.inspect(paths: paths, businessValidator: { _ in })
        XCTAssertFalse(health.runtimeVerified); XCTAssertFalse(health.processorHealthQualified)
        XCTAssertTrue(try WorkspaceHealth.inspect(paths: paths, businessValidator: { _ in }, runtimeValidator: {}).processorHealthQualified)
        XCTAssertThrowsError(try WorkspaceHealth.inspect(paths: paths, businessValidator: { _ in }, runtimeValidator: { throw Injected.stop }))
    }

    func testPythonInitialJournalWithNullExpectedPointerIsQualified() throws {
        let (directory, paths) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let pointer = try paths.readPointer()
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["workspace_id": pointer.workspaceID,
            "state_id": pointer.stateID, "expected_pointer": NSNull(), "target_pointer": pointer.document,
            "phase": "committed", "result": NSNull(), "operation": NSNull()]), to: paths.journals.appendingPathComponent(pointer.stateID + ".json"))
        let health = try WorkspaceHealth.inspect(paths: paths, businessValidator: { _ in })
        XCTAssertEqual(health.journalDispositions[pointer.stateID + ".json"], "included-current")
    }

    #if os(macOS)
    private func actualRetryFixture() throws -> (URL, WorkspacePaths, URL) {
        let python = try TestPlatform.python()
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("explicit development Python unavailable") }
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent("native-retry-health-" + UUID().uuidString)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = python
        process.arguments = ["-B", "-c", """
        import sys
        from pathlib import Path
        sys.path.insert(0,sys.argv[1])
        from scripts.workspace_initialization import create_workspace
        from scripts.workspace_state import MaintenanceGate, _read
        from scripts.processor_result import execute_workspace
        root=Path(sys.argv[2]); paths=create_workspace(root/'workspace')
        expected=paths.read_pointer()
        original=root/'review.json'; original.write_bytes(b'{}')
        def action(transaction,retained):
            report=_read(transaction.review/'financial-review.json')
            report['summary']['test_journal_value']=17
            transaction.write_json('review/financial-review.json',report)
            return {}
        with MaintenanceGate(paths).acquire('native-health') as token:
            result,code=execute_workspace(paths.workspace,expected,'actual-operation','actual-request',None,
                action,[{'path':str(original),'kind':'review'}],token=token)
        assert code==0,result
        def never_replay(*args): raise AssertionError('included operation replayed')
        with MaintenanceGate(paths).acquire('native-health-retry') as token:
            repeated,code=execute_workspace(paths.workspace,expected,'actual-operation','actual-request',None,
                never_replay,[{'path':str(original),'kind':'review'}],token=token)
        assert code==0 and repeated==result
        assert any(_read(p)['phase']=='no-op' for p in paths.journals.glob('*.json'))
        """, project.path, root.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        do {
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ActualRetryFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
            }
            let paths = try WorkspacePaths(workspace: root.appendingPathComponent("workspace"))
            let journals = try FileManager.default.contentsOfDirectory(at: paths.journals, includingPropertiesForKeys: nil)
            let journal = try XCTUnwrap(journals.first { try WorkspaceIO.object(WorkspaceIO.read($0))["phase"] as? String == "no-op" })
            return (root, paths, journal)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func testActualPythonRetryNoOpQualifiesFromCurrentLedgerWithoutReplayOrJournalRewrite() throws {
        let (root, paths, journal) = try actualRetryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = try WorkspaceIO.read(journal), pointer = try paths.readPointer()
        let ledger = try WorkspaceIO.read(paths.readState().operationResults)
        let report = try WorkspaceHealth.inspect(paths: paths, businessValidator: { try WorkspaceBusinessValidator.validate($0.root) })
        XCTAssertEqual(report.journalDispositions[journal.lastPathComponent], "included-current")
        XCTAssertEqual(try WorkspaceIO.read(journal), raw)
        XCTAssertEqual(try paths.readPointer(), pointer)
        XCTAssertEqual(try WorkspaceIO.read(paths.readState().operationResults), ledger)
    }

    func testNoOpCannotClaimCurrentInclusionWithOnlyItsTargetPointer() throws {
        let (root, paths, journal) = try actualRetryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pointer = try paths.readPointer(), ledger = try WorkspaceIO.read(paths.readState().operationResults)
        var doc = try WorkspaceIO.object(WorkspaceIO.read(journal))
        doc["operation_id"] = "absent-operation"; doc["target_pointer"] = pointer.document
        var context = try XCTUnwrap(doc["operation"] as? [String: Any]); context["operation_id"] = "absent-operation"; doc["operation"] = context
        if var result = doc["result"] as? [String: Any] { result["operation_id"] = "absent-operation"; doc["result"] = result }
        let raw = try WorkspaceIO.canonical(doc); try WorkspaceIO.atomicWrite(raw, to: journal)
        let report = try WorkspaceHealth.inspect(paths: paths, businessValidator: { try WorkspaceBusinessValidator.validate($0.root) })
        XCTAssertEqual(report.journalDispositions[journal.lastPathComponent], "no-op-never-replay")
        XCTAssertEqual(try WorkspaceIO.read(journal), raw)
        XCTAssertEqual(try paths.readPointer(), pointer)
        XCTAssertEqual(try WorkspaceIO.read(paths.readState().operationResults), ledger)
    }
    #endif
}
