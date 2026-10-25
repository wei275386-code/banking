#if os(macOS)
import XCTest
import Foundation
import Darwin
@testable import PaymentImageCore

final class WorkspaceMaintenanceExecutorTests: XCTestCase {
    private var repository: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
    private func directory() throws -> URL {
        let path = try TestPlatform.temporaryDirectory().path
        let url = URL(fileURLWithPath: path + "/maintenance-test-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func runtime(project: URL) throws -> ProcessorRuntime {
        #if !DEBUG
        throw XCTSkip("Development process fixtures require the Debug profile; packaged runtime is covered by release QA.")
        #else
        let python = try TestPlatform.python()
        return try ProcessorRuntime(project: project, python: python)
        #endif
    }
    private func project(at root: URL, script: String) throws -> URL {
        let project = URL(fileURLWithPath: root.path + "/code")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: project.appendingPathComponent("scripts/workspace_cli.py"))
        return project
    }
    func testNewDestinationIsNeverOverwritten() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let project = try project(at: root, script: "raise Exception('must not run')")
        let marker = root.appendingPathComponent("stable.txt"); try Data("stable".utf8).write(to: marker)
        do {
            _ = try await WorkspaceMaintenanceExecutor(runtime: runtime(project: project)).run(.init(command: .create, workspace: root))
            XCTFail("existing destination accepted")
        } catch let error as WorkspaceError {
            guard case .invalid(let message) = error else { return XCTFail("wrong refusal: " + error.localizedDescription) }
            XCTAssertTrue(message.contains("目标已存在"))
            XCTAssertEqual(try Data(contentsOf: marker), Data("stable".utf8))
        }
    }
    func testWorkCannotTruncateBusinessFilesOrReuseAnotherJobDirectory() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let project = try project(at: root, script: "raise Exception('must not run')")
        let executor = try WorkspaceMaintenanceExecutor(runtime: runtime(project: project))
        let destination = URL(fileURLWithPath: root.path + "/new")
        do { _ = try await executor.run(.init(command: .create, workspace: destination), work: destination); XCTFail("overlapping work") }
        catch let error as WorkspaceError { XCTAssertTrue(error.localizedDescription.contains("overlaps")) }
        let work = URL(fileURLWithPath: root.path + "/owned-job")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let log = URL(fileURLWithPath: work.path + "/maintenance.log"); try Data("owned".utf8).write(to: log)
        do { _ = try await executor.run(.init(command: .create, workspace: destination), work: work); XCTFail("reused work") }
        catch let error as WorkspaceError { XCTAssertTrue(error.localizedDescription.contains("already exists")) }
        XCTAssertEqual(try Data(contentsOf: log), Data("owned".utf8))
    }
    func testCommittedCreateWinsAfterMissingExternalReceiptAndTimeout() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let entry = Data(repository.appendingPathComponent("scripts/workspace_cli.py").path.utf8).base64EncodedString()
        let project = try project(at: root, script: """
        import subprocess,sys,pathlib,time,base64
        result = subprocess.run([sys.executable,base64.b64decode('\(entry)').decode()]+sys.argv[1:])
        if result.returncode: sys.exit(result.returncode)
        pathlib.Path(sys.argv[sys.argv.index('--result-file')+1]).unlink()
        time.sleep(30)
        """)
        let destination = URL(fileURLWithPath: root.path + "/new-workspace")
        let result: WorkspaceMaintenanceResult
        do {
            result = try await WorkspaceMaintenanceExecutor(runtime: runtime(project: project)).run(
                .init(command: .create, workspace: destination), work: URL(fileURLWithPath: root.path + "/work"), timeout: 3, terminationGrace: 0.05)
        } catch let error as WorkspaceMaintenanceError {
            XCTFail((try? String(contentsOf: error.log, encoding: .utf8)) ?? "missing test diagnostics")
            throw error
        }
        XCTAssertEqual(result.receipt.outcome, "success")
        XCTAssertEqual(result.state?.pointer, try WorkspacePaths(workspace: destination).readState().pointer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/work/receipt.json"))
        let receiptFile = URL(fileURLWithPath: destination.path + "/device/maintenance-receipts/" + result.receipt.receiptID + ".json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptFile.path))
        let token = try WorkspaceCoordinator(paths: WorkspacePaths(workspace: destination)).acquireWriteToken()
        withExtendedLifetime(token) {}
    }
    func testCancellationReapsTermResistantGroupAndBoundsLogs() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let script = """
        import subprocess,sys,pathlib,time
        child=subprocess.Popen([sys.executable,'-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)'])
        pathlib.Path(sys.argv[sys.argv.index('--result-file')+1]).with_name('child.pid').write_text(str(child.pid))
        sys.stdout.write('x' * (3 * 1024 * 1024));sys.stdout.flush()
        time.sleep(60)
        """
        let project = try project(at: root, script: script)
        let executor = try WorkspaceMaintenanceExecutor(runtime: runtime(project: project))
        let work = URL(fileURLWithPath: root.path + "/work")
        let operation = Task { try await executor.run(.init(command: .create, workspace: URL(fileURLWithPath: root.path + "/new")), work: work, terminationGrace: 0.05) }
        let pidFile = work.appendingPathComponent("child.pid")
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: pidFile.path), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
        try await Task.sleep(for: .milliseconds(200)); operation.cancel()
        do { _ = try await operation.value; XCTFail("cancel returned success") }
        catch let error as WorkspaceMaintenanceError {
            XCTAssertEqual(error.reason, .cancelled)
            let bytes = try Data(contentsOf: error.log)
            XCTAssertLessThanOrEqual(bytes.count, 1024 * 1024 + 128)
        }
        let pid = try Int32(String(contentsOf: pidFile, encoding: .utf8)).unwrap()
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/new"))
    }
    @MainActor func testDoctorValidatesPinnedCurrentBusinessStateWithoutChangingIt() async throws {
        let f = try ReviewFamilyHostTests().fixture(); defer { f.remove() }
        let python = try TestPlatform.python(), runtime = try ProcessorRuntime(project: repository, python: python)
        let state = try f.paths.readState(), before = try WorkspaceIO.read(f.paths.activeState)
        let result = try await WorkspaceMaintenanceExecutor(runtime: runtime).run(.init(command: .doctor, workspace: f.paths.workspace, expectedPointer: state.pointer))
        XCTAssertEqual(result.state?.pointer, state.pointer)
        XCTAssertEqual(result.receipt.outcome, "success")
        XCTAssertEqual(try WorkspaceIO.read(f.paths.activeState), before)
        XCTAssertEqual(result.receipt.command, "doctor")
    }
    func testReceiptRejectsDifferentCallerAndContradictorySuccess() throws {
        let request = WorkspaceMaintenanceRequest(command: .create, workspace: try TestPlatform.temporaryDirectory().appendingPathComponent("new-maintenance-request-" + UUID().uuidString))
        let id = UUID().uuidString.lowercased()
        var receipt: [String: Any] = ["receipt_id": id, "command": "create", "outcome": "success", "exit_code": 0,
            "workspace_id": NSNull(), "state": NSNull(), "source": NSNull(), "destination": NSNull(), "artifact": NSNull(),
            "verification": ["state_verified": true], "result": [:], "error": NSNull()]
        XCTAssertThrowsError(try WorkspaceMaintenanceReceipt.decode(WorkspaceIO.canonical(receipt), request: request, receiptID: UUID().uuidString))
        receipt["verification"] = ["state_verified": 1]
        XCTAssertThrowsError(try WorkspaceMaintenanceReceipt.decode(WorkspaceIO.canonical(receipt), request: request, receiptID: id))
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped { guard let value = self else { throw WorkspaceError.invalid("test value") }; return value }
}
#endif
