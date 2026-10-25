import Foundation
import Darwin

/// Startup health checks and current task recovery.
public enum WorkspaceHealth {
    public struct Report: Sendable {
        public let state: StateHandle
        public let pointer: WorkspaceStatePointer
        public let writable: Bool
        public let runtimeVerified: Bool
        public let processorEligible: Bool
        public let journalDispositions: [String: String]
        public var processorHealthQualified: Bool { writable && runtimeVerified && processorEligible }
    }

    public static func inspect(paths: WorkspacePaths,
                               businessValidator: (StateHandle) throws -> Void,
                               runtimeValidator: (() throws -> Void)? = nil) throws -> Report {
        let state = try paths.readViewingState()
        try businessValidator(state)
        let compatibility = try WorkspaceCompatibility.decision(paths: paths, state: state)
        let viewing = try WorkspaceCompatibility.isViewingCopy(paths: paths)
        let processorEligible = !viewing
        if let runtimeValidator { try runtimeValidator() }
        let ledger = try WorkspaceIO.object(WorkspaceIO.read(state.operationResults))
        let operations = Set((ledger["results"] as? [[String: Any]] ?? []).compactMap { $0["operation_id"] as? String })
        var dispositions = [String: String]()
        if FileManager.default.fileExists(atPath: paths.journals.path) {
            for name in try WorkspaceIO.regularFiles(paths.journals) {
                guard !name.contains("/"), name.hasSuffix(".json") else { throw WorkspaceError.invalid("task journal path") }
                let raw = try WorkspaceIO.read(WorkspaceIO.safeChild(paths.journals, name)), doc = try WorkspaceIO.object(raw)
                
                guard doc["workspace_id"] as? String == state.pointer.workspaceID,
                      let phase = doc["phase"] as? String, ["processing", "prepared", "committed", "failed", "cancelled", "needsReview", "no-op"].contains(phase) else {
                    throw WorkspaceError.invalid("task journal contract")
                }
                let journalStateID = try WorkspaceIO.string(doc, "state_id")
                try WorkspaceIO.requireUUID(journalStateID, field: "journal state")
                let context = doc["operation"] as? [String: Any], result = doc["result"] as? [String: Any]
                let operation = doc["operation_id"] as? String ?? context?["operation_id"] as? String ?? result?["operation_id"] as? String ??
                    (context == nil && result == nil ? journalStateID : "")
                guard !operation.isEmpty else { throw WorkspaceError.invalid("task journal operation") }
                var targetPointer: WorkspaceStatePointer?
                if let target = doc["target_pointer"] as? [String: Any] {
                    let targetRaw = try WorkspaceIO.canonical(target)
                    
                    targetPointer = try JSONDecoder().decode(WorkspaceStatePointer.self, from: targetRaw)
                    guard let targetPointer, targetPointer.workspaceID == state.pointer.workspaceID, targetPointer.localRevision >= 0 else { throw WorkspaceError.invalid("task journal target workspace") }
                    try WorkspaceIO.requireUUID(targetPointer.stateID, field: "journal target state")
                    try WorkspaceIO.requireHash(targetPointer.manifestHash)
                }
                if let expected = doc["expected_pointer"] as? [String: Any] {
                    let expectedPointer = try JSONDecoder().decode(WorkspaceStatePointer.self, from: WorkspaceIO.canonical(expected))
                    guard expectedPointer.workspaceID == state.pointer.workspaceID, expectedPointer.localRevision >= 0 else { throw WorkspaceError.invalid("task journal workspace") }
                    try WorkspaceIO.requireUUID(expectedPointer.stateID, field: "journal expected state")
                    try WorkspaceIO.requireHash(expectedPointer.manifestHash)
                } else {
                    guard targetPointer?.localRevision == 0, targetPointer?.stateID == doc["state_id"] as? String else { throw WorkspaceError.invalid("task journal initial recovery point") }
                }
                // A retry's no-op journal cannot use its self-reported target
                // pointer as proof that its operation is in the current ledger.
                // Initial non-operation transactions retain their pointer proof.
                let included = operations.contains(operation) || (phase != "no-op" && targetPointer == state.pointer)
                dispositions[name] = !viewing && included ? "included-current" :
                    (phase == "no-op" ? "no-op-never-replay" :
                        (phase == "needsReview" ? "needs-review" : (["failed", "cancelled"].contains(phase) ? "uncommitted-terminal" : "uncommitted-recoverable")))
            }
        }
        return Report(state: state, pointer: state.pointer, writable: compatibility.writable && !viewing,
                      runtimeVerified: runtimeValidator != nil, processorEligible: processorEligible, journalDispositions: dispositions)
    }

    #if os(macOS)
    // Foundation.Process may already make the child its own process-group
    // leader. Accept that isolated group; reject a failed setsid in any other
    // group so timeout cleanup can never signal the App's group.
    static let runtimeSelfTestWrapper = "import os,sys\ntry: os.setsid()\nexcept PermissionError:\n if os.getpgrp()!=os.getpid(): raise\nos.execv(sys.executable,[sys.executable]+sys.argv[1:])"

    /// First-run functional self-test of this launched App's verified runtime.
    /// The running App supplies its own verified runtime.
    public static func selfTest(runtime: ProcessorRuntime, timeout: TimeInterval = 20) throws {
        guard timeout > 2, timeout <= 20, runtime.mode == .bundled,
              let bundle = runtime.bundleRoot, let bootstrap = runtime.bootstrap,
              ProcessorRuntime.canonicalAppRoot(bundle) == ProcessorRuntime.canonicalAppRoot(Bundle.main.bundleURL),
              bundle.pathExtension == "app" else { throw WorkspaceError.invalid("runtime health requires the launched App") }
        try runtime.validateIntegrity()
        _ = try WorkspaceCompatibility.runningVersion()
        let manifest = bundle.appendingPathComponent("Contents/Resources/runtime-manifest.json")
        let before = try WorkspaceIO.digest(WorkspaceIO.read(manifest))
        try WorkspaceCompatibility.requireRuntime(manifestRaw: WorkspaceIO.read(manifest))
        let process = Process(), output = Pipe(), finished = DispatchSemaphore(value: 0)
        process.executableURL = runtime.python
        // All descendants remain in one group, including the helper's self-test.
        let wrapper = runtimeSelfTestWrapper
        process.arguments = ["-I", "-B", "-S", "-c", wrapper, "-I", "-B", "-S", bootstrap.path,
                             "--bundle-root", bundle.path, "--entry", "runtime_doctor.py", "--", "--bundle-root", bundle.path]
        process.environment = ["PATH": try SystemToolLocations.searchPath()]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout - 2) != .success {
            kill(-process.processIdentifier, SIGTERM); process.terminate()
            if finished.wait(timeout: .now() + 1) != .success {
                kill(-process.processIdentifier, SIGKILL); kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw WorkspaceError.invalid("runtime self-test timed out")
        }
        let raw = try output.fileHandleForReading.readToEnd() ?? Data()
        guard process.terminationStatus == 0, raw.count <= 1024 * 1024 else { throw WorkspaceError.invalid("runtime self-test failed") }
        let document = try WorkspaceIO.object(raw)
        let success = try ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: ["ok"])
        guard success == Data("true".utf8),
              document["runtime_version"] as? String == WorkspaceCompatibility.runtimeVersion,
              let checks = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["checks"]), !checks.isEmpty else {
            throw WorkspaceError.invalid("runtime self-test report")
        }
        for check in checks {
            guard try ReleaseCanonicalJSON.canonicalFragment(raw: check, atObjectKeys: ["ok"]) == Data("true".utf8) else {
                throw WorkspaceError.invalid("runtime self-test probe")
            }
        }
        guard try WorkspaceIO.digest(WorkspaceIO.read(manifest)) == before else { throw WorkspaceError.invalid("runtime changed during health check") }
        try runtime.validateIntegrity()
    }
    #endif

}
