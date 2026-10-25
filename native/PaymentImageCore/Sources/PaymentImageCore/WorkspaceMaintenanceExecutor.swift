#if os(macOS)
import Foundation
import Darwin

public struct WorkspaceMaintenanceRequest: Sendable {
    public enum Command: String, Sendable { case create, doctor }
    public let command: Command
    public let workspace: URL
    public let expectedPointer: WorkspaceStatePointer?
    public init(command: Command, workspace: URL, expectedPointer: WorkspaceStatePointer? = nil) {
        self.command = command; self.workspace = workspace; self.expectedPointer = expectedPointer
    }
    public var createsWorkspace: Bool { command == .create }
    var receiptCommand: String { command.rawValue }
    func arguments(resultFile: URL) -> [String] {
        ["--workspace", workspace.path, "create", "--result-file", resultFile.path]
    }
}
public struct WorkspaceMaintenanceReceipt: Decodable, Sendable {
    public struct State: Decodable, Sendable {
        public let stateID: String
        public let localRevision: Int64
        public let manifestHash: String
        enum CodingKeys: String, CodingKey { case stateID = "state_id", localRevision = "local_revision", manifestHash = "state_manifest_hash" }
    }
    public struct Location: Decodable, Sendable {
        public let kind: String
        public let path: String
        public let output: String?
        public let manifestHash: String?
        public let pointer: WorkspaceStatePointer?
        enum CodingKeys: String, CodingKey { case kind, path, output, pointer; case manifestHash = "manifest_sha256" }
    }
    public struct Artifact: Decodable, Sendable {
        public let path: String
        public let sha256: String
        public let kind: String
    }
    public struct Failure: Decodable, Sendable { public let code: String; public let message: String }
    public struct Details: Decodable, Sendable {
        public let kind: String?
        public let processorEligible: Bool?
        enum CodingKeys: String, CodingKey {
            case kind, processorEligible = "processor_eligible"
        }
    }
    public let receiptID: String
    public let command: String
    public let outcome: String
    public let exitCode: Int32
    public let workspaceID: String?
    public let state: State?
    public let source: Location?
    public let destination: Location?
    public let artifact: Artifact?
    public let error: Failure?
    public let result: Details
    enum CodingKeys: String, CodingKey {
        case receiptID = "receipt_id", exitCode = "exit_code", workspaceID = "workspace_id"
        case command, outcome, state, source, destination, artifact, error, result
    }

    static func decode(_ bytes: Data, request: WorkspaceMaintenanceRequest, receiptID: String? = nil) throws -> Self {
        guard bytes.count <= 4 * 1024 * 1024 else { throw WorkspaceError.invalid("maintenance receipt too large") }
        let document = try WorkspaceIO.object(bytes)
        guard document["verification"] is [String: Any], document["result"] is [String: Any] else { throw WorkspaceError.invalid("maintenance verification receipt") }
        let receipt = try JSONDecoder().decode(Self.self, from: bytes)
        guard UUID(uuidString: receipt.receiptID) != nil,
              receiptID == nil || receipt.receiptID == receiptID,
              receipt.command == request.receiptCommand,
              ["success", "failed", "needsReview"].contains(receipt.outcome),
              [Int32(0), 1, 2].contains(receipt.exitCode),
              (receipt.outcome == "success" && receipt.exitCode == 0) ||
                (receipt.outcome == "failed" && receipt.exitCode == 1) ||
                (receipt.outcome == "needsReview" && receipt.exitCode == 2) else { throw WorkspaceError.invalid("maintenance receipt identity") }
        if receipt.outcome == "success" {
            guard try ReleaseCanonicalJSON.canonicalFragment(raw: bytes, atObjectKeys: ["verification", "state_verified"]) == Data("true".utf8),
                  receipt.error == nil else { throw WorkspaceError.invalid("maintenance success verification") }
        }
        if let workspaceID = receipt.workspaceID { try WorkspaceIO.requireUUID(workspaceID, field: "receipt workspace_id") }
        if let state = receipt.state {
            try WorkspaceIO.requireUUID(state.stateID, field: "receipt state_id")
            guard state.localRevision >= 0, validHash(state.manifestHash) else { throw WorkspaceError.invalid("maintenance state tuple") }
        }
        if let artifact = receipt.artifact { guard validHash(artifact.sha256) else { throw WorkspaceError.invalid("maintenance artifact hash") } }
        return receipt
    }
    private static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct WorkspaceMaintenanceResult: Sendable {
    public let receipt: WorkspaceMaintenanceReceipt
    public let state: StateHandle?
    public let log: URL
}
public struct WorkspaceMaintenanceError: LocalizedError, Sendable {
    public enum Reason: String, Sendable { case launch, cancelled, timedOut, failed, needsReview, invalidResult }
    public let reason: Reason
    public let log: URL
    public let detail: String
    public var errorDescription: String? { detail + " 日志：" + log.path }
}

public struct WorkspaceMaintenanceExecutor: Sendable {
    public let runtime: ProcessorRuntime
    public init(runtime: ProcessorRuntime) { self.runtime = runtime }
    public func run(_ request: WorkspaceMaintenanceRequest, work: URL? = nil,
                    timeout: TimeInterval = 1800, terminationGrace: TimeInterval = 3) async throws -> WorkspaceMaintenanceResult {
        try runtime.validateIntegrity()
        if let bundle = runtime.bundleRoot {
            try WorkspaceCompatibility.requireRuntime(manifestRaw: WorkspaceIO.read(bundle.appendingPathComponent("Contents/Resources/runtime-manifest.json")))
            guard !ProcessorRuntime.isInside(request.workspace, root: bundle) else { throw WorkspaceError.invalid("business data inside App") }
        }
        try WorkspaceIO.rejectSymlinks(request.workspace)
        let fm = FileManager.default
        if request.createsWorkspace, fm.fileExists(atPath: request.workspace.path) { throw WorkspaceError.invalid("目标已存在，请选择新的保存位置。") }
        let base = try work ?? AppStorageLocations.forCurrentProcess().maintenanceURL()
        try WorkspaceIO.rejectSymlinks(base)
        let target = WorkspaceIO.lexicalURL(request.workspace), job = WorkspaceIO.lexicalURL(base)
        guard target != job, !job.path.hasPrefix(target.path + "/"), !target.path.hasPrefix(job.path + "/") else { throw WorkspaceError.invalid("maintenance work overlaps business data") }
        if let bundle = runtime.bundleRoot, ProcessorRuntime.isInside(base, root: bundle) { throw WorkspaceError.invalid("maintenance work inside App") }
        guard !fm.fileExists(atPath: base.path) else { throw WorkspaceError.invalid("maintenance work directory already exists") }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let paths = try WorkspacePaths(workspace: request.workspace)
        if let expected = request.expectedPointer, try paths.readPointer() != expected { throw WorkspaceError.stalePointer }
        let receiptID = UUID().uuidString.lowercased(), resultFile = base.appendingPathComponent("receipt.json")
        let log = base.appendingPathComponent("maintenance.log")
        if request.command == .doctor {
            let state = try paths.readState()
            try WorkspaceBusinessValidator.validateRead(state)
            try ReviewWorkspaceMembership.validate(state: state)
            guard try paths.readPointer() == state.pointer else { throw WorkspaceError.stalePointer }
            let writable = try WorkspaceCompatibility.decision(paths: paths, state: state).writable
            let row: [String: Any] = ["receipt_id": receiptID, "command": "doctor", "outcome": "success", "exit_code": 0,
                "workspace_id": state.pointer.workspaceID, "state": state.pointer.document,
                "source": ["kind": "workspace", "path": paths.workspace.path], "destination": NSNull(), "artifact": NSNull(), "error": NSNull(),
                "verification": ["state_verified": true], "result": ["processor_eligible": writable]]
            let raw = try WorkspaceIO.canonical(row)
            try WorkspaceIO.atomicWrite(raw, to: resultFile); try WorkspaceIO.atomicWrite(Data("Current committed business state verified.\n".utf8), to: log)
            return .init(receipt: try WorkspaceMaintenanceReceipt.decode(raw, request: request, receiptID: receiptID), state: state, log: log)
        }
        let ready = base.appendingPathComponent("process-group.ready"), cancelFile = base.appendingPathComponent("cancel")
        let output = try MaintenanceOutput(log: log)
        let stdout = Pipe(), stderr = Pipe()
        stdout.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil
            try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close(); output.close()
        }
        let arguments = request.arguments(resultFile: resultFile) + ["--receipt-id", receiptID, "--cancel-file", cancelFile.path, "--timeout-seconds", String(max(0, timeout))]
        let launch: [String]
        if let bootstrap = runtime.bootstrap, let bundle = runtime.bundleRoot {
            launch = ["-I", "-B", "-S", bootstrap.path, "--bundle-root", bundle.path, "--entry", "workspace_cli.py", "--"]
        } else { launch = ["-B", runtime.scripts.appendingPathComponent("workspace_cli.py").path] }
        let wrapper = "import os,sys\ntry: os.setsid()\nexcept PermissionError:\n if os.getpgrp()!=os.getpid(): raise\nopen(sys.argv[1],'w').write(str(os.getpid()))\nos.execv(sys.executable,[sys.executable]+sys.argv[2:])"
        let process = Process()
        process.executableURL = runtime.python
        process.arguments = (runtime.mode == .bundled ? ["-I", "-B", "-S"] : ["-B"]) + ["-c", wrapper, ready.path] + launch + arguments
        process.currentDirectoryURL = runtime.mode == .bundled ? base : runtime.codeRoot
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { throw WorkspaceError.io("trusted maintenance home") }
        process.environment = ["HOME": String(cString: home), "PATH": try SystemToolLocations.searchPath(),
                               "TMPDIR": base.path, "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = stdout; process.standardError = stderr
        func failure(_ reason: WorkspaceMaintenanceError.Reason, _ detail: String) -> WorkspaceMaintenanceError {
            WorkspaceMaintenanceError(reason: reason, log: log, detail: detail)
        }
        guard !Task.isCancelled else { throw failure(.cancelled, "操作已取消，尚未启动。") }
        do { try process.run() } catch { throw failure(.launch, "资料维护未启动：" + error.localizedDescription) }
        let pid = process.processIdentifier
        func signal(_ value: Int32) {
            if (try? String(contentsOf: ready, encoding: .utf8)) == String(pid) || getpgid(pid) == pid { kill(-pid, value) }
            if process.isRunning { kill(pid, value) }
        }
        func pause() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var stopped: WorkspaceMaintenanceError.Reason?
        while process.isRunning {
            if Task.isCancelled { stopped = .cancelled; break }
            if ProcessInfo.processInfo.systemUptime >= deadline { stopped = .timedOut; break }
            await pause()
        }
        if stopped != nil {
            try? WorkspaceIO.atomicWrite(Data("cancel\n".utf8), to: cancelFile)
            // Give the backend a brief opportunity to observe its prepublish
            // cancellation hook before escalating to process-group signals.
            let cooperative = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < cooperative { await pause() }
            signal(SIGTERM)
            let grace = ProcessInfo.processInfo.systemUptime + max(0, terminationGrace)
            while ProcessInfo.processInfo.systemUptime < grace { await pause() }
        }
        // Reap the entire isolated group before interpreting any completion.
        signal(SIGKILL)
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning || kill(-pid, 0) == 0 {
            guard ProcessInfo.processInfo.systemUptime < cleanupDeadline else { throw failure(.needsReview, "子进程停止尚未确认；请检查目标资料状态，勿重复覆盖。") }
            await pause()
        }
        // A durable creation receipt can survive a lost stdout file or timeout.
        let localReceipt = paths.device.appendingPathComponent("maintenance-receipts/" + receiptID + ".json")
        for file in [resultFile, localReceipt] where fm.fileExists(atPath: file.path) {
            let receipt = try WorkspaceMaintenanceReceipt.decode(WorkspaceIO.read(file), request: request, receiptID: receiptID)
            if receipt.outcome == "success" {
                guard receipt.destination?.path == paths.workspace.path, receipt.destination?.kind == "workspace",
                      let workspaceID = receipt.workspaceID, let tuple = receipt.state else { throw failure(.invalidResult, "创建结果缺少账本身份。") }
                let expected = WorkspaceStatePointer(workspaceID: workspaceID, stateID: tuple.stateID, localRevision: tuple.localRevision, manifestHash: tuple.manifestHash)
                let state = try paths.readState()
                guard state.pointer == expected else { throw WorkspaceError.stalePointer }
                try WorkspaceBusinessValidator.validateRead(state)
                try ReviewWorkspaceMembership.validate(state: state)
                return .init(receipt: receipt, state: state, log: log)
            }
        }
        if let stopped { throw failure(stopped, stopped == .cancelled ? "操作已取消。" : "操作超时。") }
        throw failure(.failed, "资料创建未完成；原有资料保留。")
    }
}

private final class MaintenanceOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var remaining = 1024 * 1024
    init(log: URL) throws { try Data().write(to: log); handle = try FileHandle(forWritingTo: log) }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard remaining > 0, !data.isEmpty else { return }
        let part = data.prefix(remaining); try? handle.write(contentsOf: part); remaining -= part.count
        if remaining == 0 { try? handle.write(contentsOf: Data("\n[诊断输出已截断至 1 MiB]\n".utf8)) }
    }
    func close() { lock.lock(); defer { lock.unlock() }; try? handle.close() }
}
#endif
