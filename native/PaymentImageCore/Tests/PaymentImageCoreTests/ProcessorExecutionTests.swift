#if os(macOS)
import XCTest
import Darwin
@testable import PaymentImageCore

@MainActor final class ProcessorExecutionTests: XCTestCase {
    private func fixture(_ mode: String = "success") throws -> (URL, URL, ProcessorRuntime) {
        let root = try TestPlatform.temporaryDirectory().appendingPathComponent("processor-test-" + UUID().uuidString)
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let repository64 = Data(repository.path.utf8).base64EncodedString()
        try FileManager.default.removeItem(at: output)
        let create = Process()
        create.executableURL = try TestPlatform.python()
        create.arguments = ["-B", "-c", "import sys;sys.path.insert(0,sys.argv[1]);from scripts.workspace_initialization import create_workspace;create_workspace(sys.argv[2])", repository.path, output.path]
        try create.run(); create.waitUntilExit()
        guard create.terminationStatus == 0 else { throw WorkspaceError.invalid("synthetic workspace creation") }
        try Data("synthetic material".utf8).write(to: output.appendingPathComponent("material.mp4"))
        let source = """
        import argparse,json,os,sys,time,fcntl,subprocess,base64,uuid
        from pathlib import Path
        sys.path.insert(0,base64.b64decode('\(repository64)').decode())
        from scripts.processor_result import execute_workspace
        p=argparse.ArgumentParser()
        for name in ['workspace','expected-pointer-json','request-id','gate-fd','cancel-file','timeout-seconds','review','files-json','operation-id','result-file']: p.add_argument('--'+name)
        a=p.parse_args(); out=Path(a.workspace); mode='\(mode)'
        assert os.fstat(0).st_ino == os.stat(out/'device/locks/maintenance.lock').st_ino
        fcntl.flock(0,fcntl.LOCK_EX|fcntl.LOCK_NB)
        (out/'runtime.txt').write_text(sys.executable+'\\n'+os.getcwd())
        if mode == 'hang':
            child=subprocess.Popen([sys.executable,str(Path(__file__).with_name('heartbeat.py')),str(out/'heartbeat')])
            (out/'child.pid').write_text(str(child.pid)); time.sleep(60)
        if mode == 'corrupt': Path(a.result_file).write_text('{broken'); sys.exit(0)
        if mode == 'missing': sys.exit(0)
        ids=json.loads(Path(a.files_json).read_text()) if a.files_json else [a.review]
        expected=json.loads(Path(a.expected_pointer_json).read_text())
        if mode in ['wrong-id','wrong-input','committed','exit-failed']:
            result={'version':2,'workspace_id':expected['workspace_id'],'state_id':str(uuid.uuid4()),'result_digest':'0'*64,
                    'request_id':a.request_id,'operation_id':a.operation_id,'phase':'committed','outcome':'success',
                    'message':'synthetic external receipt without committed membership',
                    'inputs':[{'input_id':v,'outcome':'success'} for v in ids]}
            if mode=='wrong-id': result['operation_id']='other'
            if mode=='wrong-input': result['inputs']=[]
            Path(a.result_file).write_text(json.dumps(result)); sys.exit(7 if mode=='exit-failed' else 0)
        def action(transaction, retained):
            if mode=='failed': raise ValueError('synthetic processing failure')
            if mode=='partial': return {'pending_video_sources':[{'input_id':ids[0],'reason':'unsupported_video_layout'}]}
            return {}
        result,status=execute_workspace(a.workspace,expected,a.operation_id,a.request_id,a.result_file,action,
            [{'path':v,'input_id':v} for v in ids],inherited_fd=int(a.gate_fd))
        print('synthetic stdout');sys.exit(status)
        """
        for name in ["app_review.py", "import_review_materials.py"] {
            try Data(source.utf8).write(to: root.appendingPathComponent("scripts/" + name))
        }
        let heartbeat = """
        import signal,time,sys,fcntl
        from pathlib import Path
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        fcntl.flock(0,fcntl.LOCK_EX|fcntl.LOCK_NB)
        while True:
            Path(sys.argv[1]).write_text(str(time.monotonic()))
            time.sleep(0.02)
        """
        try Data(heartbeat.utf8).write(to: root.appendingPathComponent("scripts/heartbeat.py"))
        return (root, output, try ProcessorRuntime(project: root, python: TestPlatform.python()))
    }
    private func run(_ runtime: ProcessorRuntime, _ output: URL, id: String = UUID().uuidString,
                     timeout: Double = 3) async throws -> ProcessorResult {
        let paths = try WorkspacePaths(workspace: output)
        let executor = try ProcessorExecution(runtime: runtime, workspace: paths, state: paths.readState())
        return try await executor.run(operation: .import, input: JSONEncoder().encode([output.appendingPathComponent("material.mp4").path]),
                                      operationID: id, timeout: timeout, terminationGrace: 0.15)
    }
    private func assertLeaseReleased(_ output: URL) throws {
        let token = try WorkspaceCoordinator(paths: WorkspacePaths(workspace: output)).acquireWriteToken()
        withExtendedLifetime(token) {}
    }
    func testDevelopmentRuntimeKeepsPhysicalCodePathAcrossConfigResolution() throws {
        let (root, _, runtime) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(runtime.codeRoot.path, root.path)
        try WorkspaceIO.rejectSymlinks(runtime.codeRoot)
        let config = root.appendingPathComponent("runtime.json")
        try JSONEncoder().encode(["project": root.path, "python": runtime.python.path]).write(to: config)
        let resolved = try ProcessorRuntime.resolve(environment: ["BANKING_PROCESSOR_CONFIG": config.path])
        XCTAssertEqual(resolved, runtime)
        try WorkspaceIO.rejectSymlinks(resolved.codeRoot)
    }
    func testBothOperationsUseResolvedRuntimeAndTypedResult() async throws {
        let (root, output, runtime) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("runtime.json")
        try JSONEncoder().encode(["project": root.path, "python": runtime.python.path]).write(to: config)
        let resolved = try ProcessorRuntime.resolve(project: root, environment: ["BANKING_PROCESSOR_CONFIG": config.path])
        XCTAssertEqual(resolved, runtime)
        let imported = try await run(resolved, output)
        XCTAssertTrue(imported.isFullySuccessful)
        let firstRuntime = try String(contentsOf: output.appendingPathComponent("runtime.txt"), encoding: .utf8)
        let paths = try WorkspacePaths(workspace: output)
        let executor = try ProcessorExecution(runtime: resolved, workspace: paths, state: paths.readState())
        let reviewed = try await executor.run(operation: .review, input: Data("{}".utf8))
        XCTAssertTrue(reviewed.isFullySuccessful)
        let actual = try String(contentsOf: output.appendingPathComponent("runtime.txt"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("runtime.txt"), encoding: .utf8), firstRuntime)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: String(actual[0])))
        let cwdIdentity = try FileManager.default.attributesOfItem(atPath: String(actual[1]))
        let expectedIdentity = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(cwdIdentity[.systemFileNumber] as? NSNumber, expectedIdentity[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(cwdIdentity[.systemNumber] as? NSNumber, expectedIdentity[.systemNumber] as? NSNumber)
    }
    func testDevelopmentConfigIsSharedAndInvalidConfigFailsClosed() throws {
        let (root, _, runtime) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config/processor-location.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(["project": "..", "python": runtime.python.path]).write(to: config)
        XCTAssertEqual(try ProcessorRuntime.resolve(project: root, environment: [:]), runtime)
        try Data("{}".utf8).write(to: config)
        XCTAssertThrowsError(try ProcessorRuntime.resolve(project: root, environment: [:]))
    }
    func testBundleConfigUsesTheSameRuntimeAsDevelopment() throws {
        let (root, _, runtime) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Processor.bundle")
        let resources = folder.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.processor", "CFBundlePackageType": "BNDL"], format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("Contents/Info.plist"))
        try JSONEncoder().encode(["project": root.path, "python": runtime.python.path])
            .write(to: resources.appendingPathComponent("processor-location.json"))
        let bundle = try XCTUnwrap(Bundle(url: folder))
        XCTAssertEqual(try ProcessorRuntime.resolve(project: root.appendingPathComponent("invalid"), bundle: bundle, environment: [:]), runtime)
    }
    func testLaunchFailureReleasesLease() async throws {
        let (root, output, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("invalid-python")
        try Data("invalid executable".utf8).write(to: invalid)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: invalid.path)
        let runtime = try ProcessorRuntime(project: root, python: invalid)
        do { _ = try await run(runtime, output); XCTFail("Expected launch failure") }
        catch let error as ProcessorExecutionError { XCTAssertEqual(error.reason, .launch) }
        try assertLeaseReleased(output)
    }
    func testFailedAndExitFailureNeverAuthorizeSuccess() async throws {
        for mode in ["failed", "exit-failed"] {
            let (root, output, runtime) = try fixture(mode)
            defer { try? FileManager.default.removeItem(at: root) }
            do { _ = try await run(runtime, output); XCTFail("Expected failure") }
            catch let error as ProcessorExecutionError {
                XCTAssertEqual(error.reason, .failed)
                XCTAssertNotNil(error.result)
                XCTAssertTrue(FileManager.default.fileExists(atPath: error.log.path))
            }
            try assertLeaseReleased(output)
        }
    }
    func testCorruptMissingStaleAndMismatchedResultsFailClosed() async throws {
        for mode in ["corrupt", "missing", "wrong-id", "wrong-input", "committed"] {
            let (root, output, runtime) = try fixture(mode)
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID().uuidString
            let work = output.appendingPathComponent("processor-operations/" + id)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try Data("stale result".utf8).write(to: work.appendingPathComponent("processor-result.json"))
            do { _ = try await run(runtime, output, id: id); XCTFail("Expected invalid result") }
            catch let error as ProcessorExecutionError { XCTAssertEqual(error.reason, .invalidResult) }
            try assertLeaseReleased(output)
        }
    }
    func testPartialProcessorResultNeverClaimsFullSuccess() async throws {
        let (root, output, runtime) = try fixture("partial")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let result = try await run(runtime, output, id: id)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.phase, "committed")
        XCTAssertFalse(result.isFullySuccessful)
        XCTAssertEqual(result.inputs.first?.error?.code, "unsupported_video_layout")
        try assertLeaseReleased(output)
    }
    func testTimeoutKillsDescendantAndReleasesInheritedLease() async throws {
        let (root, output, runtime) = try fixture("hang")
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await run(runtime, output, timeout: 0.8); XCTFail("Expected timeout") }
        catch let error as ProcessorExecutionError { XCTAssertEqual(error.reason, .timedOut) }
        try assertLeaseReleased(output)
        let heartbeat = output.appendingPathComponent("heartbeat")
        let stopped = try Data(contentsOf: heartbeat)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(try Data(contentsOf: heartbeat), stopped)
    }
    func testCancellationReapsChildAndReleasesLease() async throws {
        let (root, output, runtime) = try fixture("hang")
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { try await self.run(runtime, output) }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: output.appendingPathComponent("child.pid").path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertThrowsError(try WorkspaceCoordinator(paths: WorkspacePaths(workspace: output)).acquireWriteToken())
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch let error as ProcessorExecutionError { XCTAssertEqual(error.reason, .cancelled) }
        try assertLeaseReleased(output)
    }
}
#endif
