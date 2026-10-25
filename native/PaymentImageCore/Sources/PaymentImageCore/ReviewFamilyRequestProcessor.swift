#if os(macOS)
import Foundation

public struct ReviewPreparedFamilyRequest: Sendable {
    public let request: ReviewFamilyRequest
    public let state: StateHandle
    public let input: Data
    public let work: URL
    public let inputHash: String
    public let verifiedExistingResult: ProcessorResult?
    internal let inputIdentities: Data
}

/// The driver owns scheduler.run(.processor) and its token. This bridge cannot
/// create host authority, grant readiness, schedule itself or publish a result.
public enum ReviewFamilyRequestProcessor {
    public static func prepare(request: ReviewFamilyRequest, paths: WorkspacePaths,
                               selection: ReviewFamilyBindingSelection) throws -> ReviewPreparedFamilyRequest {
        guard request.selection == selection else { throw WorkspaceError.invalid("processor request selection") }
        try ReviewFamilyHost.requireProcessor(paths: paths, selection: selection)
        let state = try paths.readState()
        try WorkspaceCompatibility.requireWriter(paths: paths, state: state)
        try ReviewWorkspaceMembership.validate(state: state)
        try ReviewFamilyRequestTransport.validateObjects(request)
        let work = try WorkspaceIO.safeChild(paths.device, "request-processor-work/" + request.id)
        let input: Data, inputs: [[String: Any]]
        if request.kind == .review {
            input = request.payload
            inputs = [["input_id": work.appendingPathComponent("review.json").path,
                       "sha256": request.payloadHash, "kind": "review", "required_financial": true]]
        } else {
            var originals = [String](), identities = [[String: Any]]()
            for (index, file) in request.files.enumerated() {
                let staged = try WorkspaceIO.safeChild(request.cache, "staged/" + request.id + "/" + String(index) + "/" + file.name)
                try ReviewContentObjectIO.copy(request.cache.appendingPathComponent("objects/" + file.sha256), to: staged, hash: file.sha256)
                originals.append(staged.path)
                identities.append(["input_id": staged.path, "sha256": file.sha256, "kind": file.kind, "required_financial": file.kind != "video"])
            }
            input = try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: originals, options: [.withoutEscapingSlashes]))
            inputs = identities
        }
        let identity = try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: inputs, options: [.sortedKeys, .withoutEscapingSlashes]))
        let hash = WorkspaceIO.digest(identity)
        let existing = try committed(request: request, state: state, paths: paths, inputHash: hash, identities: identity)
        guard try paths.readPointer() == state.pointer else { throw WorkspaceError.stalePointer }
        return .init(request: request, state: state, input: input, work: work, inputHash: hash,
                     verifiedExistingResult: existing, inputIdentities: identity)
    }
    public static func run(prepared: ReviewPreparedFamilyRequest, runtime: ProcessorRuntime,
                           paths: WorkspacePaths, token: WorkspaceWriteToken,
                           timeout: TimeInterval = 1800) async throws -> ProcessorResult {
        try token.validate(for: paths)
        try runtime.validateIntegrity()
        try ReviewFamilyHost.requireProcessor(paths: paths, selection: prepared.request.selection)
        let current = try paths.readState()
        try WorkspaceCompatibility.requireWriter(paths: paths, state: current)
        try ReviewWorkspaceMembership.validate(state: current)
        if let result = try committed(request: prepared.request, state: current, paths: paths,
                                      inputHash: prepared.inputHash, identities: prepared.inputIdentities) {
            try journal("committed", request: prepared.request, paths: paths, state: current)
            return result
        }
        guard current.pointer == prepared.state.pointer else { throw WorkspaceError.stalePointer }
        if Task.isCancelled {
            try journal("cancelled", request: prepared.request, paths: paths)
            throw CancellationError()
        }
        try ReviewFamilyRequestTransport.validateObjects(prepared.request)
        try journal("processing", request: prepared.request, paths: paths)
        do {
            let processor = try ProcessorExecution(runtime: runtime, workspace: paths, state: current, token: token)
            _ = try await processor.run(operation: prepared.request.kind == .review ? .review : .import,
                                        input: prepared.input, operationID: prepared.request.id, work: prepared.work, timeout: timeout)
            let active = try paths.readState()
            guard let result = try committed(request: prepared.request, state: active, paths: paths,
                                             inputHash: prepared.inputHash, identities: prepared.inputIdentities) else { throw WorkspaceError.invalid("request result is not currently committed") }
            try journal("committed", request: prepared.request, paths: paths, state: active)
            return result
        } catch {
            // Cancellation or lost subprocess receipt after commit cannot
            // revoke actual current membership or run the transaction again.
            let active = try paths.readState()
            if let result = try committed(request: prepared.request, state: active, paths: paths,
                                          inputHash: prepared.inputHash, identities: prepared.inputIdentities) {
                try journal("committed", request: prepared.request, paths: paths, state: active)
                return result
            }
            let recovery = try WorkspaceCoordinator(paths: paths).recover(operationID: prepared.request.id)
            let phase: String
            if case .uncommitted = recovery, active.pointer == prepared.state.pointer {
                phase = error is CancellationError || (error as? ProcessorExecutionError)?.reason == .cancelled ? "cancelled" : "failed"
            } else { phase = "needsReview" }
            try journal(phase, request: prepared.request, paths: paths)
            throw error
        }
    }
    private static func committed(request: ReviewFamilyRequest, state: StateHandle, paths: WorkspacePaths,
                                  inputHash: String, identities: Data) throws -> ProcessorResult? {
        try ReviewWorkspaceMembership.validate(state: state)
        let ledger = try WorkspaceIO.read(state.operationResults)
        let results = try ReleaseCanonicalJSON.canonicalArrayElements(raw: ledger, atObjectKeys: ["results"]) ?? []
        let matches = try results.filter { raw in
            let doc = try WorkspaceIO.object(raw)
            return doc["request_id"] as? String == request.id || doc["operation_id"] as? String == request.id
        }
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1, let raw = matches.first else { throw WorkspaceError.invalid("duplicate request result") }
        let doc = try WorkspaceIO.object(raw)
        guard request.matches(result: doc), doc["input_hash"] as? String == inputHash,
              let inputRows = try ReleaseCanonicalJSON.canonicalArrayElements(raw: raw, atObjectKeys: ["inputs"]) else { throw WorkspaceError.invalid("request result input identity differs") }
        var projected = [Data]()
        for row in inputRows {
            var value = [String: Any]()
            let input = try WorkspaceIO.object(row)
            for key in ["input_id", "sha256", "kind", "required_financial"] { guard let field = input[key] else { throw WorkspaceError.invalid("request ledger input") }; value[key] = field }
            projected.append(try WorkspaceIO.canonical(value))
        }
        var canonicalInputs = Data("[".utf8)
        for (index, row) in projected.enumerated() { if index > 0 { canonicalInputs.append(Data(",".utf8)) }; canonicalInputs.append(row) }
        canonicalInputs.append(Data("]".utf8))
        guard canonicalInputs == identities,
              try WorkspaceCoordinator(paths: paths).recover(operationID: request.id) == .committed(state) else { throw WorkspaceError.invalid("request ledger does not prove transaction") }
        let result = try JSONDecoder().decode(ProcessorResult.self, from: raw)
        try result.validate(operationID: request.id)
        guard result.hasCommittedChanges else { throw WorkspaceError.invalid("request was not committed") }
        return result
    }
    private static func journal(_ phase: String, request: ReviewFamilyRequest, paths: WorkspacePaths, state: StateHandle? = nil) throws {
        var doc: [String: Any] = ["workspace_id": request.selection.workspaceID,
            "binding_id": request.selection.bindingID, "request_id": request.id, "request_envelope_sha256": WorkspaceIO.digest(request.raw),
            "phase": phase, "state": NSNull(), "receipt_is_not_business_proof": true]
        if let state { doc["state"] = state.pointer.document }
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(doc), to: paths.device.appendingPathComponent("request-processor-journals/" + request.id + ".json"))
    }
}
#endif
