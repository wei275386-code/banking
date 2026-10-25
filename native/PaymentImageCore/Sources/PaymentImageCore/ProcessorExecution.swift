#if os(macOS)
import Foundation
import Darwin
import CryptoKit

public struct ProcessorExecutionError: LocalizedError, Sendable {
    public enum Reason: String, Sendable { case launch, timedOut, cancelled, failed, invalidResult }
    public let reason: Reason
    public let log: URL
    public let result: ProcessorResult?
    public let detail: String
    public var errorDescription: String? { "\(detail) 日志：\(log.path)" }
}

/// Owns a workspace lease during preflight and execution. It does not own the
/// business transaction, host journal, generation publication, or cloud fencing.
public struct ProcessorExecution: Sendable {
    public enum Operation: String, Sendable { case review, `import`, repair }
    public let runtime: ProcessorRuntime
    private let output: URL
    private let workspace: WorkspacePaths
    private let expectedPointer: WorkspaceStatePointer
    private let workspaceToken: WorkspaceWriteToken?
    public init(runtime: ProcessorRuntime, workspace: WorkspacePaths, state: StateHandle, token: WorkspaceWriteToken? = nil) throws {
        let current = try workspace.readState()
        guard current.pointer == state.pointer else { throw WorkspaceError.stalePointer }
        try ReviewFamilyHost.requireNoPendingWrite(paths: workspace)
        try WorkspaceCompatibility.requireWriter(paths: workspace, state: current)
        if let bundle = runtime.bundleRoot, ProcessorRuntime.isInside(workspace.workspace, root: bundle) {
            throw ProcessorRuntimeError(.invalidDataRoot, "Workspace 不能位于 App bundle 内。")
        }
        try WorkspaceIO.rejectSymlinks(state.root)
        guard WorkspaceIO.lexicalURL(state.root).path == (try workspace.stateRoot(state.pointer.stateID)).path else { throw WorkspaceError.invalid("StateHandle workspace") }
        self.runtime = runtime; self.workspace = workspace; expectedPointer = state.pointer
        workspaceToken = token; output = workspace.processing
    }
    public func run(operation: Operation, input: Data, operationID: String = UUID().uuidString,
                    work: URL? = nil, timeout: TimeInterval = 1800, terminationGrace: TimeInterval = 3) async throws -> ProcessorResult {
        let repair = operation == .repair ? try JSONDecoder().decode(PendingVideoInput.self, from: input) : nil
        let child = try repair?.childIdentity
        let operationID = child?.operationID ?? operationID
        let requestID = child?.requestID ?? operationID
        if let repair {
            guard repair.workspaceID == expectedPointer.workspaceID else { throw WorkspaceError.invalid("repair requires pinned workspace") }
            let state = try workspace.readState()
            guard state.pointer == expectedPointer else { throw WorkspaceError.stalePointer }
            guard try PendingVideoList.contains(repair, state: state) else { throw WorkspaceError.invalid("recording is no longer pending") }
        }
        let fm = FileManager.default
        let work = work ?? output.appendingPathComponent("processor-operations/" + operationID)
        if let bundleRoot = runtime.bundleRoot, ProcessorRuntime.isInside(work, root: bundleRoot) {
            throw ProcessorRuntimeError(.invalidDataRoot, "Processor 工作目录不能位于 App bundle 内。")
        }
        try runtime.validateIntegrity()
        if let bundle = runtime.bundleRoot {
            try WorkspaceCompatibility.requireRuntime(manifestRaw: WorkspaceIO.read(bundle.appendingPathComponent("Contents/Resources/runtime-manifest.json")))
        }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let manifest = work.appendingPathComponent(operation == .review ? "review.json" : "files.json")
        let resultFile = work.appendingPathComponent("processor-result.json")
        var expectedInputHash: String?
        let ready = work.appendingPathComponent("process-group.ready")
        let log = work.appendingPathComponent("processor.log")
        // Never parse a result left by an earlier invocation.
        for file in [resultFile, ready] where fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        try input.write(to: manifest, options: .atomic)
        if let repair {
            expectedInputHash = WorkspaceIO.digest(try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: [repair.inputIdentity], options: [.sortedKeys])))
        } else {
            let paths = operation == .review ? [manifest.path] : try JSONDecoder().decode([String].self, from: input)
            let kinds = ["pdf": "pdf", "csv": "csv", "xlsx": "xlsx", "mov": "video", "mp4": "video", "m4v": "video", "json": "review"]
            let identity = try paths.map { path -> [String: Any] in
                let file = URL(fileURLWithPath: path)
                guard let kind = kinds[file.pathExtension.lowercased()] else { throw WorkspaceError.invalid("unsupported input kind") }
                return ["input_id": path, "sha256": try WorkspaceIO.hash(file), "kind": kind, "required_financial": kind != "video"]
            }
            expectedInputHash = WorkspaceIO.digest(try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])))
        }
        try Data().write(to: log)
        let handle = try FileHandle(forWritingTo: log)
        let token = try workspaceToken ?? WorkspaceCoordinator(paths: workspace).acquireWriteToken()
        try token.validate(for: workspace)
        let current = try workspace.readState()
        guard current.pointer == expectedPointer else { throw WorkspaceError.stalePointer }
        try WorkspaceCompatibility.requireWriter(paths: workspace, state: current)
        let guardHandle = try token.childGuardHandle()
        defer { try? handle.close(); try? guardHandle.close(); withExtendedLifetime(token) {} }
        let process = Process()
        process.executableURL = runtime.python
        process.currentDirectoryURL = runtime.mode == .bundled ? work : runtime.codeRoot
        // Require a new session or an already isolated Process group. FD 0 holds the inherited flock across exec
        // and is also inherited by normal processor descendants.
        let wrapper = "import os,sys\ntry: os.setsid()\nexcept PermissionError:\n if os.getpgrp()!=os.getpid(): raise\nos.set_inheritable(0,True)\nopen(sys.argv[1],'w').write(str(os.getpid()))\nos.execv(sys.executable,[sys.executable]+sys.argv[2:])"
        let entry = operation == .repair ? "workspace_cli.py" : (operation == .review ? "app_review.py" : "import_review_materials.py")
        let launch: [String]
        if let bootstrap = runtime.bootstrap, let bundleRoot = runtime.bundleRoot {
            launch = ["-I", "-B", "-S", bootstrap.path, "--bundle-root", bundleRoot.path, "--entry", entry, "--"]
            process.environment = ProcessInfo.processInfo.environment.filter {
                !$0.key.hasPrefix("PYTHON") && !$0.key.hasPrefix("DYLD") &&
                    !["BANKING_PROCESSOR_PROJECT", "BANKING_PROCESSOR_CONFIG", "BANKING_PROCESSOR_PYTHON", "BANKING_MERCHANT_DB", "BANKING_VIDEO_HELPER"].contains($0.key)
            }
            process.environment?["TMPDIR"] = work.path
        } else { launch = ["-B", runtime.scripts.appendingPathComponent(entry).path] }
        let businessArguments: [String]
        do {
            let pointerFile = work.appendingPathComponent("expected-pointer.json")
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expectedPointer)) as! [String: Any]
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: pointerFile, options: .atomic)
            if let repair {
                businessArguments = ["--workspace", workspace.workspace.path, "--inherited-fd", "0", "repair-input",
                    "--parent-request-id", repair.parentRequestID, "--input-id", repair.inputID,
                    "--expected-pointer-json", pointerFile.path, "--result-file", resultFile.path]
            } else {
                businessArguments = ["--workspace", workspace.workspace.path, "--expected-pointer-json", pointerFile.path,
                                     "--request-id", requestID, "--gate-fd", "0"]
            }
        }
        let inputArguments = operation == .repair ? [] : [
                             operation == .review ? "--review" : "--files-json", manifest.path,
                             "--operation-id", operationID, "--result-file", resultFile.path]
        process.arguments = (runtime.mode == .bundled ? ["-I", "-B", "-S"] : ["-B"]) + ["-c", wrapper, ready.path] + launch + businessArguments + inputArguments
        process.standardInput = guardHandle; process.standardOutput = handle; process.standardError = handle
        func failure(_ reason: ProcessorExecutionError.Reason, _ detail: String, _ result: ProcessorResult? = nil) -> ProcessorExecutionError {
            ProcessorExecutionError(reason: reason, log: log, result: result, detail: detail)
        }
        func committedResult() throws -> ProcessorResult? {
            guard let expectedInputHash else { return nil }
            let active = try workspace.readState()
            let raw = try WorkspaceIO.read(active.operationResults)
            let results = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["results"]) ?? []
            let matches = try results.filter { item in
                let value = try WorkspaceIO.object(item)
                return value["operation_id"] as? String == operationID
            }
            guard !matches.isEmpty else { return nil }
            guard matches.count == 1, let bytes = matches.first else { throw WorkspaceError.invalid("operation result membership") }
            let value = try WorkspaceIO.object(bytes)
            guard value["request_id"] as? String == requestID,
                  value["input_hash"] as? String == expectedInputHash,
                  value["workspace_id"] as? String == expectedPointer.workspaceID,
                  try WorkspaceCoordinator(paths: workspace).recover(operationID: operationID) == .committed(active) else { throw WorkspaceError.invalid("committed input identity") }
            let result = try JSONDecoder().decode(ProcessorResult.self, from: bytes)
            try result.validate(operationID: operationID)
            guard result.hasCommittedChanges else { throw WorkspaceError.invalid("committed result") }
            return result
        }
        guard !Task.isCancelled else { throw failure(.cancelled, "处理已取消，尚未启动处理器。") }
        do { try process.run() } catch { throw failure(.launch, "处理器无法启动：" + error.localizedDescription) }
        let pid = process.processIdentifier
        func signalTree(_ signal: Int32) {
            let isolated = (try? String(contentsOf: ready, encoding: .utf8)) == String(pid)
            if isolated || getpgid(pid) == pid { kill(-pid, signal) }
            if process.isRunning { kill(pid, signal) }
        }
        // Dispatch sleep deliberately does not inherit cancellation, so cleanup
        // can reap the child and release its inherited lock after Task.cancel().
        func pause() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
        }
        func finishTree() async -> Bool {
            signalTree(SIGKILL)
            let limit = ProcessInfo.processInfo.systemUptime + 2
            // SIGKILL delivery is asynchronous. Wait for the isolated group to
            // disappear so a killed descendant cannot briefly retain lock FD 0
            // after the caller receives completion. Bound orphan reaping waits.
            while process.isRunning || kill(-pid, 0) == 0 {
                if ProcessInfo.processInfo.systemUptime >= limit { return false }
                await pause()
            }
            return true
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var stopped: ProcessorExecutionError.Reason?
        while process.isRunning {
            if Task.isCancelled { stopped = .cancelled; break }
            if ProcessInfo.processInfo.systemUptime >= deadline { stopped = .timedOut; break }
            await pause()
        }
        if let stopped {
            signalTree(SIGTERM)
            // The leader can exit before a TERM-resistant descendant. Always
            // finish the group cleanup before releasing the workspace lease.
            let grace = ProcessInfo.processInfo.systemUptime + max(0, terminationGrace)
            while ProcessInfo.processInfo.systemUptime < grace { await pause() }
            let cleaned = await finishTree()
            if cleaned, let result = try await Task.detached(operation: { try committedResult() }).value { return result }
            let uncommitted: Bool
            if cleaned, let active = try? workspace.readState(), active.pointer == expectedPointer {
                uncommitted = (try? WorkspaceCoordinator(paths: workspace).recover(operationID: operationID)) == .uncommitted
            } else { uncommitted = false }
            let detail = uncommitted ? (stopped == .cancelled ? "处理已取消，本次尚未保存业务修改。" : "处理超时，本次尚未保存业务修改。") :
                (stopped == .cancelled ? "处理已取消；既有写入状态未知。" : "处理超时，已停止；既有写入状态未知。")
            throw failure(stopped, detail + (cleaned ? "" : "子进程清理尚未确认。"))
        }
        // A script must not leave a background extractor holding the lease.
        guard await finishTree() else { throw failure(.failed, "子进程清理尚未确认；既有写入状态未知。") }
        if let result = try committedResult() { return result }
        let result: ProcessorResult
        do {
            result = try JSONDecoder().decode(ProcessorResult.self, from: Data(contentsOf: resultFile))
            try result.validate(operationID: operationID)
            let expected: [String]
            if let repair { expected = [repair.inputID] }
            else if operation == .import { expected = try JSONDecoder().decode([String].self, from: input) }
            else { expected = [manifest.path] }
            guard Set(result.inputs.map(\.inputID)) == Set(expected) else { throw CocoaError(.fileReadCorruptFile) }
            do {
                guard result.requestID == requestID, result.workspaceID == expectedPointer.workspaceID else { throw CocoaError(.fileReadCorruptFile) }
            }
        } catch {
            let tail = (try? String(contentsOf: log, encoding: .utf8)).map { String($0.suffix(1600)) } ?? ""
            throw failure(.invalidResult, "处理器结果缺失或无效；既有写入状态未知。" + tail)
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0, result.hasCommittedChanges else {
            throw failure(.failed, "处理未完成：" + result.message, result)
        }
        throw failure(.invalidResult, "处理结果尚未进入当前资料状态。", result)
    }
}
#endif
