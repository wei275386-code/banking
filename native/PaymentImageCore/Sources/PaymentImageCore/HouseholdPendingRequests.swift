import Foundation

/// Portable unfinished work contains input identity, never a provider connection
/// or a device permission. A new explicit family connection supplies its binding.
internal enum HouseholdPendingRequests {
    static func root(_ paths: WorkspacePaths) -> URL { paths.workspace.appendingPathComponent("data/pending-requests") }

    static func export(paths: WorkspacePaths, destination: URL) throws -> [String: String] {
        let workspaceID = try paths.readPointer().workspaceID
        if FileManager.default.fileExists(atPath: root(paths).path) {
            let selection = try ReviewFamilyBindingSelection(workspaceID: workspaceID, bindingID: workspaceID, hostID: workspaceID)
            for request in try requests(root(paths), selection: selection) { try retain(request, to: destination) }
        }
        if let connection = try ReviewFamilyHost.readConnection(paths: paths) {
            let cache = paths.device.appendingPathComponent("family-host-requests/" + connection.selection.bindingID)
            try ReviewFamilyRequestTransport.withOutboxLock(cache) {
                let state = try paths.readState()
                let ledger = try WorkspaceIO.object(WorkspaceIO.read(state.operationResults))
                let results = try ReviewFamilyRequestTransport.resultIndex(ledger["results"] as! [[String: Any]])
                let files = try ReviewFamilyRequestTransport.backupFiles(cache: cache, selection: connection.selection)
                for name in files.keys.filter({ $0.hasPrefix("envelopes/") }).sorted() {
                    let request = try ReviewFamilyRequestTransport.load(String(name.dropFirst("envelopes/".count)), cache: cache, selection: connection.selection)
                    if let result = results[request.id] {
                        guard request.matches(result: result) else { throw WorkspaceError.invalid("pending request/result identity collision") }
                        continue
                    }
                    try retain(request, to: destination)
                }
            }
        }
        guard FileManager.default.fileExists(atPath: destination.path) else { return [:] }
        return try Dictionary(uniqueKeysWithValues: WorkspaceIO.regularFiles(destination).map { path in
            (path, try WorkspaceIO.hash(WorkspaceIO.safeChild(destination, path)))
        })
    }

    static func adopt(paths: WorkspacePaths, selection: ReviewFamilyBindingSelection) throws {
        let source = root(paths)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
        defer { withExtendedLifetime(token) {} }
        try ReviewFamilyHost.requireProcessor(paths: paths, selection: selection)
        let cache = paths.device.appendingPathComponent("family-host-requests/" + selection.bindingID)
        for request in try requests(source, selection: selection) {
            try ReviewFamilyRequestTransport.adopt(request, cache: cache)
        }
        try FileManager.default.removeItem(at: source)
        try WorkspaceIO.syncDirectory(source.deletingLastPathComponent())
    }

    static func validate(_ source: URL, workspaceID: String) throws {
        let selection = try ReviewFamilyBindingSelection(workspaceID: workspaceID, bindingID: workspaceID, hostID: workspaceID)
        _ = try requests(source, selection: selection)
    }

    private static func requests(_ source: URL, selection: ReviewFamilyBindingSelection) throws -> [ReviewFamilyRequest] {
        let paths = try WorkspaceIO.regularFiles(source)
        guard paths.count <= 100_000 else { throw WorkspaceError.invalid("pending request file budget") }
        var retained = Set<String>(), result = [ReviewFamilyRequest]()
        for name in paths.filter({ $0.hasPrefix("envelopes/") }).sorted() {
            let raw = try WorkspaceIO.read(WorkspaceIO.safeChild(source, name), limit: Int64(ReviewFamilyRequestTransport.metadataLimit))
            var row = try WorkspaceIO.object(raw)
            guard Set(row.keys) == ["workspace_id", "request_id", "author_device_id", "kind", "created_at", "payload_hash", "files"] else {
                throw WorkspaceError.invalid("portable request fields")
            }
            row["binding_id"] = selection.bindingID
            let hash = try WorkspaceIO.string(row, "payload_hash"); try WorkspaceIO.requireHash(hash)
            let payloadPath = "objects/" + hash
            let payload = try WorkspaceIO.read(WorkspaceIO.safeChild(source, payloadPath), limit: Int64(ReviewFamilyRequestTransport.payloadLimit))
            let request = try ReviewFamilyRequest(raw: WorkspaceIO.canonical(row), payload: payload, cache: source, selection: selection)
            guard name == "envelopes/" + request.id + ".json" else { throw WorkspaceError.invalid("portable request filename") }
            try ReviewFamilyRequestTransport.validateObjects(request)
            retained.insert(name); retained.insert(payloadPath)
            for file in request.files { retained.insert("objects/" + file.sha256) }
            result.append(request)
        }
        guard retained == Set(paths) else { throw WorkspaceError.invalid("unreferenced portable request file") }
        return result
    }

    private static func retain(_ request: ReviewFamilyRequest, to destination: URL) throws {
        var row = try WorkspaceIO.object(request.raw); row.removeValue(forKey: "binding_id")
        let raw = try WorkspaceIO.canonical(row)
        let envelope = destination.appendingPathComponent("envelopes/" + request.id + ".json")
        if FileManager.default.fileExists(atPath: envelope.path) {
            guard try WorkspaceIO.read(envelope) == raw else { throw WorkspaceError.invalid("portable request identity collision") }
        }
        for hash in Set([request.payloadHash] + request.files.map(\.sha256)) {
            try ReviewContentObjectIO.copy(request.cache.appendingPathComponent("objects/" + hash),
                to: destination.appendingPathComponent("objects/" + hash), hash: hash)
        }
        try WorkspaceIO.atomicWrite(raw, to: envelope)
    }
}
