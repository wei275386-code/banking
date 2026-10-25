import XCTest
@testable import PaymentImageCore

#if os(macOS)
final class WorkspaceRuntimeQualificationTests: XCTestCase {
    func testRuntimeSelfTestLaunchesFromFoundationProcessInItsOwnGroup() throws {
        let python = try TestPlatform.python()
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("System Python unavailable") }
        let process = Process(), output = Pipe(), finished = DispatchSemaphore(value: 0)
        process.executableURL = python
        process.arguments = ["-I", "-B", "-S", "-c", WorkspaceHealth.runtimeSelfTestWrapper,
            "-I", "-B", "-S", "-c",
            "import json,os,sys; print(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp(),'isolated':sys.flags.isolated,'bytecode_writes':not sys.dont_write_bytecode,'input_inherited':os.get_inheritable(0)}))"]
        process.environment = ["PATH": try SystemToolLocations.searchPath()]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            XCTFail("Runtime self-test wrapper did not finish")
            return
        }
        XCTAssertEqual(process.terminationStatus, 0, "A Foundation child already leading its group must survive setsid EPERM")
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        XCTAssertEqual(document["pid"] as? Int, document["pgid"] as? Int)
        XCTAssertEqual(document["isolated"] as? Int, 1)
        XCTAssertEqual(document["bytecode_writes"] as? Bool, false)
        XCTAssertEqual(document["input_inherited"] as? Bool, true)
    }
    func testSourceRunnerCannotReadAPackagedQualificationManifest() throws {
        guard Bundle.main.bundleURL.pathExtension.lowercased() != "app" else { throw XCTSkip("This test requires a source test runner.") }
        XCTAssertThrowsError(try WorkspaceRuntimeQualification.launchedManifestSHA256())
    }
    func testAppVersionMustAgreeWithCompiledCapability() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "local.synthetic.upgrade", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "9.0.0", "CFBundleVersion": "99"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertThrowsError(try WorkspaceCompatibility.runningVersion(bundle: bundle))
        XCTAssertEqual(try WorkspaceCompatibility.runningVersion(bundle: Bundle(for: Self.self)), WorkspaceCompatibility.appVersion)
    }
    actor Counter {
        private var calls = 0
        func increment() { calls += 1 }
        func count() -> Int { calls }
    }
    func testConcurrentRequestsReuseProofAndInvalidationOrManifestChangeRunsAgain() async {
        let cache = WorkspaceRuntimeQualification(), calls = Counter()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let key = WorkspaceRuntimeQualification.Identity(workspace: parent.appendingPathComponent("workspace").path,
            workspaceID: "identity", bundle: parent.appendingPathComponent("App.app").path, manifestSHA256: "first")
        let work: @Sendable () async -> WorkspaceRuntimeQualification.Result = {
            await calls.increment()
            try? await Task.sleep(for: .milliseconds(20))
            return .qualified(manifestSHA256: "first")
        }
        async let first = cache.qualification(identity: key, worker: work)
        async let second = cache.qualification(identity: key, worker: work)
        let proofs = await (first, second)
        XCTAssertEqual(proofs.0, proofs.1)
        let once = await calls.count(); XCTAssertEqual(once, 1)
        let changed = WorkspaceRuntimeQualification.Identity(workspace: key.workspace, workspaceID: key.workspaceID, bundle: key.bundle, manifestSHA256: "second")
        _ = await cache.qualification(identity: changed, worker: work)
        await cache.invalidate(workspace: URL(fileURLWithPath: key.workspace))
        _ = await cache.qualification(identity: key, worker: work)
        let total = await calls.count(); XCTAssertEqual(total, 3)
    }
    func testFailureIsCachedWithoutBecomingSuccess() async {
        let cache = WorkspaceRuntimeQualification(), calls = Counter()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let key = WorkspaceRuntimeQualification.Identity(workspace: parent.appendingPathComponent("workspace").path,
            workspaceID: "identity", bundle: parent.appendingPathComponent("App.app").path, manifestSHA256: "hash")
        let first = await cache.qualification(identity: key) {
            await calls.increment(); return .failure("probe failed")
        }
        let second = await cache.qualification(identity: key) {
            await calls.increment(); return .qualified(manifestSHA256: "hash")
        }
        XCTAssertEqual(first, .failure("probe failed")); XCTAssertEqual(second, first)
        let count = await calls.count(); XCTAssertEqual(count, 1)
    }
}
#endif
