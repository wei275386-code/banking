import Foundation
import Darwin

public struct ReviewFamilyRequest: Sendable {
    public enum Kind: String, Sendable { case review, `import` }
    public struct File: Sendable {
        public let name: String
        public let sha256: String
        public let bytes: Int64
        public let kind: String
        internal var document: [String: Any] { ["name": name, "sha256": sha256, "bytes": bytes, "kind": kind] }
    }
    public let id: String
    public let kind: Kind
    public let authorDeviceID: String
    public let createdAtRaw: String
    public let payloadHash: String
    public let payload: Data
    public let files: [File]
    public let raw: Data
    public let cache: URL
    internal let selection: ReviewFamilyBindingSelection

    internal init(raw: Data, payload: Data, cache: URL, selection: ReviewFamilyBindingSelection) throws {
        guard raw.count <= ReviewFamilyRequestTransport.metadataLimit,
              payload.count <= ReviewFamilyRequestTransport.payloadLimit,
              try ReleaseCanonicalJSON.canonicalize(raw: raw) == raw,
              try ReleaseCanonicalJSON.canonicalize(raw: payload) == payload else { throw WorkspaceError.invalid("request canonical metadata") }
        let doc = try WorkspaceIO.object(raw)
        guard Set(doc.keys) == ["workspace_id", "binding_id", "request_id", "author_device_id", "kind", "created_at", "payload_hash", "files"],
              doc["workspace_id"] as? String == selection.workspaceID, doc["binding_id"] as? String == selection.bindingID,
              let kind = Kind(rawValue: try WorkspaceIO.string(doc, "kind")), let entries = doc["files"] as? [[String: Any]], entries.count <= 1024 else { throw WorkspaceError.invalid("request envelope") }
        id = try WorkspaceIO.string(doc, "request_id"); authorDeviceID = try WorkspaceIO.string(doc, "author_device_id")
        try WorkspaceIO.requireUUID(id, field: "request_id"); try WorkspaceIO.requireUUID(authorDeviceID, field: "author_device_id")
        guard id == id.lowercased(), authorDeviceID == authorDeviceID.lowercased() else { throw WorkspaceError.invalid("request UUID canonical spelling") }
        createdAtRaw = try WorkspaceIO.string(doc, "created_at")
        guard createdAtRaw.count <= 64, ISO8601DateFormatter().date(from: createdAtRaw) != nil else { throw WorkspaceError.invalid("request creation time") }
        payloadHash = try WorkspaceIO.string(doc, "payload_hash"); try WorkspaceIO.requireHash(payloadHash)
        guard WorkspaceIO.digest(payload) == payloadHash else { throw WorkspaceError.invalid("request payload hash") }
        var names = Set<String>(), parsed = [File]()
        for entry in entries {
            guard Set(entry.keys) == ["name", "sha256", "bytes", "kind"] else { throw WorkspaceError.invalid("request file fields") }
            let name = try WorkspaceIO.string(entry, "name"), hash = try WorkspaceIO.string(entry, "sha256"), fileKind = try WorkspaceIO.string(entry, "kind")
            guard name.utf8.count <= 255, !name.contains("/"), names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw WorkspaceError.invalid("request filename collision") }
            _ = try WorkspaceIO.safeChild(cache, name); try WorkspaceIO.requireHash(hash)
            let size = try WorkspaceIO.integer(WorkspaceIO.canonical(entry), field: "bytes")
            guard size <= ReviewFamilyRequestTransport.originalLimit, Self.fileKind(name) == fileKind else { throw WorkspaceError.invalid("request original kind/size") }
            parsed.append(File(name: name, sha256: hash, bytes: size, kind: fileKind))
        }
        if kind == .review {
            let review = try WorkspaceIO.object(payload)
            guard parsed.isEmpty, Set(review.keys).isSubset(of: ["dataset_id", "decisions", "expected_projection", "metadata"]),
                  review["dataset_id"] is String, review["decisions"] is [String: Any] else { throw WorkspaceError.invalid("review payload") }
        } else {
            guard !parsed.isEmpty, payload == (try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: parsed.map(\.document), options: [.sortedKeys, .withoutEscapingSlashes]))) else { throw WorkspaceError.invalid("import payload differs from originals") }
        }
        self.kind = kind; self.files = parsed; self.payload = payload; self.raw = raw; self.cache = cache; self.selection = selection
    }
    internal static func fileKind(_ name: String) -> String? {
        ["pdf": "pdf", "csv": "csv", "xlsx": "xlsx", "mov": "video", "mp4": "video", "m4v": "video"][URL(fileURLWithPath: name).pathExtension.lowercased()]
    }
    internal func matches(result: [String: Any]) -> Bool {
        guard result["request_id"] as? String == id, result["operation_id"] as? String == id,
              result["workspace_id"] as? String == selection.workspaceID, result["phase"] as? String == "committed",
              let inputs = result["inputs"] as? [[String: Any]] else { return false }
        let expected = kind == .review ? ["review:" + payloadHash] : files.map { $0.kind + ":" + $0.sha256 }
        let actual = inputs.compactMap { input -> String? in
            guard let kind = input["kind"] as? String, let hash = input["sha256"] as? String else { return nil }
            return kind + ":" + hash
        }
        return actual.count == inputs.count && actual.sorted() == expected.sorted()
    }
}

public struct ReviewFamilyRequestTransportPoll: Sendable {
    public let requests: [ReviewFamilyRequest]
    public let waitingObjectHashes: Set<String>
    public let invalidRequestIDs: Set<String>
    public let uploadedRequestIDs: Set<String>
}

/// Current request queue. Offline intent and verified committed results are separate.
public actor ReviewFamilyRequestTransport {
    internal static let metadataLimit = 1024 * 1024
    internal static let payloadLimit = 16 * 1024 * 1024
    internal static let originalLimit: Int64 = 32 * 1024 * 1024 * 1024
    public let remote: URL?, cache: URL, selection: ReviewFamilyBindingSelection
    private let readerPaths: WorkspacePaths?
    private var scanOffset = 0, uploadOffset = 0
    private var polling = false
    private var verifiedTransferStamps = [String: [String]]()
    internal private(set) var transferVerificationPasses = 0
    public init(remote: URL?, cache: URL, selection: ReviewFamilyBindingSelection, readerPaths: WorkspacePaths? = nil) throws {
        guard cache.isFileURL, remote?.isFileURL != false else { throw WorkspaceError.invalid("request transport URLs") }
        self.remote = remote.map(WorkspaceIO.lexicalURL); self.cache = WorkspaceIO.lexicalURL(cache)
        self.selection = selection; self.readerPaths = readerPaths
        try WorkspaceIO.rejectSymlinks(self.cache)
        if let provider = self.remote {
            try WorkspaceIO.rejectSymlinks(provider)
            guard provider.path != self.cache.path, !self.cache.path.hasPrefix(provider.path + "/"), !provider.path.hasPrefix(self.cache.path + "/") else { throw WorkspaceError.invalid("request cache must be outside provider") }
        }
    }
    public func enqueueReview(payload: Data, authorDeviceID: String, requestID: String = UUID().uuidString.lowercased()) async throws -> ReviewFamilyRequest {
        let cache = cache, selection = selection
        return try await ReviewSyncDetached.run {
            let canonical = try ReleaseCanonicalJSON.canonicalize(raw: payload)
            return try Self.enqueue(payload: canonical, files: [], originals: [], kind: .review, author: authorDeviceID, id: requestID, cache: cache, selection: selection)
        }
    }
    public func enqueueImport(files: [URL], authorDeviceID: String, requestID: String = UUID().uuidString.lowercased()) async throws -> ReviewFamilyRequest {
        let cache = cache, selection = selection
        return try await ReviewSyncDetached.run {
            guard !files.isEmpty, files.count <= 1024 else { throw WorkspaceError.invalid("request file count") }
            let entries = try files.map { file -> ReviewFamilyRequest.File in
                try WorkspaceIO.rejectSymlinks(file)
                let name = file.lastPathComponent
                guard let kind = ReviewFamilyRequest.fileKind(name) else { throw WorkspaceError.invalid("request import file kind") }
                let size = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard size.isRegularFile == true, let bytes = size.fileSize, bytes >= 0, Int64(bytes) <= Self.originalLimit else { throw WorkspaceError.invalid("request original size") }
                return .init(name: name, sha256: try ReviewContentObjectIO.hash(file, maximumBytes: Self.originalLimit), bytes: Int64(bytes), kind: kind)
            }
            let payload = try ReleaseCanonicalJSON.canonicalize(raw: JSONSerialization.data(withJSONObject: entries.map(\.document), options: [.sortedKeys, .withoutEscapingSlashes]))
            return try Self.enqueue(payload: payload, files: entries, originals: files, kind: .import, author: authorDeviceID, id: requestID, cache: cache, selection: selection)
        }
    }
    public func cancel(requestID: String) async throws {
        try await reconcileCurrent()
        let cache = cache
        try await ReviewSyncDetached.run {
            try WorkspaceIO.requireUUID(requestID, field: "request_id")
            _ = try Self.read(cache.appendingPathComponent("envelopes/" + requestID + ".json"), limit: Self.metadataLimit)
            try Self.writeLocalIntent("cancelled", id: requestID, cache: cache)
        }
    }
    public func retry(requestID: String) async throws {
        try await reconcileCurrent()
        let cache = cache, selection = selection
        try await ReviewSyncDetached.run {
            try WorkspaceIO.requireUUID(requestID, field: "request_id")
            let request = try Self.load(requestID + ".json", cache: cache, selection: selection, verifyOriginals: false)
            if try !Self.preservesVerifiedOutcome(requestID, cache: cache) {
                try Self.validateObjects(request)
                try Self.writeLocalIntent("queued", id: requestID, cache: cache)
            }
        }
    }
    public func localStatuses() async throws -> [String: String] {
        try await reconcileCurrent()
        let cache = cache
        return try await ReviewSyncDetached.run {
            var result = [String: String]()
            for name in try Self.names(cache.appendingPathComponent("envelopes")) {
                let id = String(name.dropLast(5)); try WorkspaceIO.requireUUID(id, field: "request filename")
                result[id] = try Self.status(id, cache: cache) ?? "received"
            }
            return result
        }
    }
    public func cachedRequests(limit: Int = 128) async throws -> [ReviewFamilyRequest] {
        guard (1...1024).contains(limit) else { throw WorkspaceError.invalid("request cache bound") }
        try await reconcileCurrent()
        let cache = cache, selection = selection
        return try await ReviewSyncDetached.run {
            var requests = [ReviewFamilyRequest]()
            for name in try Self.names(cache.appendingPathComponent("envelopes")) {
                if requests.count >= limit { break }
                let id = String(name.dropLast(5))
                if ["cancelled", "included", "needsReview"].contains(try Self.status(id, cache: cache) ?? "") { continue }
                requests.append(try Self.load(name, cache: cache, selection: selection))
            }
            return requests
        }
    }
    public func poll(limit: Int = 128, uploadOnly: Bool = false) async throws -> ReviewFamilyRequestTransportPoll {
        guard let remote else { throw WorkspaceError.invalid("offline request transport has no provider") }
        guard (1...1024).contains(limit), !polling else { throw WorkspaceError.busy }
        polling = true; defer { polling = false }
        try await reconcileCurrent()
        let cache = cache, selection = selection, scan = scanOffset, upload = uploadOffset, stamps = verifiedTransferStamps
        let persistIncoming = true
        let result = try await ReviewSyncDetached.run { try Self.pollIO(remote: remote, cache: cache, selection: selection, scan: scan, upload: upload, limit: limit, persistIncoming: persistIncoming, uploadOnly: uploadOnly, verifiedStamps: stamps) }
        scanOffset = result.1; uploadOffset = result.2; verifiedTransferStamps = result.3; transferVerificationPasses += result.4; return result.0
    }
    private func reconcileCurrent() async throws {
        let cache = cache, selection = selection
        guard let paths = readerPaths else {
            try await ReviewSyncDetached.run {
                try Self.withOutboxLock(cache) {
                    for name in try Self.names(cache.appendingPathComponent("envelopes")) {
                        let id = String(name.dropLast(5))
                        if ["included", "needsReview"].contains(try Self.status(id, cache: cache) ?? "") {
                            try Self.writeStatus("queued", id: id, cache: cache)
                        }
                    }
                }
            }
            return
        }
        try await ReviewSyncDetached.run {
            guard let handle = try ReviewFamilyClientSession.read(paths: paths), handle.selection == selection else { throw WorkspaceError.stalePointer }
            let ledger = try WorkspaceIO.object(WorkspaceIO.read(handle.checkpoint.file("request-results.json")))
            guard let results = ledger["results"] as? [[String: Any]] else { throw WorkspaceError.invalid("request result ledger") }
            let indexed = try Self.resultIndex(results)
            try Self.withOutboxLock(cache) {
                for name in try Self.names(cache.appendingPathComponent("envelopes")) {
                    let request = try Self.load(name, cache: cache, selection: selection, verifyOriginals: false)
                    if let result = indexed[request.id], request.matches(result: result) {
                        let outcome = result["outcome"] as? String
                        if outcome == "success", handle.checkpoint.payload.successfulRequests.contains(request.id) {
                            try Self.writeStatus("included", id: request.id, cache: cache, generation: handle.checkpoint.generation, resultDigest: WorkspaceIO.string(result, "result_digest"))
                        } else if outcome == "partial" {
                            try Self.writeStatus("needsReview", id: request.id, cache: cache, generation: handle.checkpoint.generation, resultDigest: WorkspaceIO.string(result, "result_digest"))
                        }
                    } else if ["included", "needsReview"].contains(try Self.status(request.id, cache: cache) ?? "") {
                        try Self.writeStatus("queued", id: request.id, cache: cache)
                    }
                }
                guard let end = try ReviewFamilyClientSession.read(paths: paths), end.selection == selection,
                      end.checkpoint.generation == handle.checkpoint.generation else { throw WorkspaceError.stalePointer }
            }
        }
    }
    /// Called while the outbox mutex is held by the backup owner.
    internal static func backupFiles(cache: URL, selection: ReviewFamilyBindingSelection) throws -> [String: URL] {
        var files = [String: URL]()
        for name in try names(cache.appendingPathComponent("envelopes")) {
            let request = try load(name, cache: cache, selection: selection)
            files["envelopes/" + name] = cache.appendingPathComponent("envelopes/" + name)
            files["objects/" + request.payloadHash] = cache.appendingPathComponent("objects/" + request.payloadHash)
            for file in request.files { files["objects/" + file.sha256] = cache.appendingPathComponent("objects/" + file.sha256) }
            if try status(request.id, cache: cache) != nil {
                files["outbox-status/" + name] = cache.appendingPathComponent("outbox-status/" + name)
            }
        }
        guard files.count <= 100_000 else { throw WorkspaceError.invalid("request backup file count") }
        return files
    }
    /// Restore an already validated logical task into a newly authorized queue.
    internal static func adopt(_ request: ReviewFamilyRequest, cache: URL) throws {
        try validateObjects(request)
        for hash in Set([request.payloadHash] + request.files.map(\.sha256)) {
            try ReviewContentObjectIO.copy(request.cache.appendingPathComponent("objects/" + hash),
                to: cache.appendingPathComponent("objects/" + hash), hash: hash)
        }
        try withOutboxLock(cache) {
            let file = cache.appendingPathComponent("envelopes/" + request.id + ".json")
            if FileManager.default.fileExists(atPath: file.path) {
                guard try WorkspaceIO.read(file) == request.raw else { throw WorkspaceError.invalid("restored request identity collision") }
            } else { try WorkspaceIO.atomicWrite(request.raw, to: file) }
            if try status(request.id, cache: cache) == nil { try writeStatus("queued", id: request.id, cache: cache) }
        }
    }
    private static func objectStamp(_ file: URL, maximumBytes: Int64) throws -> [String] {
        try WorkspaceIO.rejectSymlinks(file)
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw WorkspaceError.invalid("request capture regular object budget") }
        return [String(info.st_dev), String(info.st_ino), String(info.st_size), String(info.st_mtimespec.tv_sec),
                String(info.st_mtimespec.tv_nsec), String(info.st_ctimespec.tv_sec), String(info.st_ctimespec.tv_nsec)]
    }
    private static func enqueue(payload: Data, files: [ReviewFamilyRequest.File], originals: [URL], kind: ReviewFamilyRequest.Kind, author: String, id: String, cache: URL, selection: ReviewFamilyBindingSelection) throws -> ReviewFamilyRequest {
        try WorkspaceIO.requireUUID(id, field: "request_id"); try WorkspaceIO.requireUUID(author, field: "author_device_id")
        let file = cache.appendingPathComponent("envelopes/" + id + ".json")
        // Retrying the same immutable request preserves its original timestamp.
        let existing = FileManager.default.fileExists(atPath: file.path) ? try read(file, limit: metadataLimit) : nil
        let created = try existing.map { try WorkspaceIO.string(WorkspaceIO.object($0), "created_at") } ?? ISO8601DateFormatter().string(from: Date())
        let raw = try WorkspaceIO.canonical(["workspace_id": selection.workspaceID, "binding_id": selection.bindingID,
            "request_id": id, "author_device_id": author, "kind": kind.rawValue, "created_at": created,
            "payload_hash": WorkspaceIO.digest(payload), "files": files.map(\.document)])
        let request = try ReviewFamilyRequest(raw: raw, payload: payload, cache: cache, selection: selection)
        for (entry, original) in zip(files, originals) { try ReviewContentObjectIO.copy(original, to: cache.appendingPathComponent("objects/" + entry.sha256), hash: entry.sha256, maximumBytes: originalLimit) }
        try immutable(payload, at: cache.appendingPathComponent("objects/" + request.payloadHash), limit: payloadLimit)
        try withOutboxLock(cache) {
            try immutable(raw, at: file, limit: metadataLimit)
            if try status(id, cache: cache) == nil { try writeStatus("queued", id: id, cache: cache) }
        }
        return request
    }
    private static func copyForTransfer(_ source: URL, to target: URL, hash: String, maximumBytes: Int64,
                                        verified: inout [String: [String]], passes: inout Int) throws {
        let sourceKey = hash + ":" + source.path, targetKey = hash + ":" + target.path
        let before = try objectStamp(source, maximumBytes: maximumBytes)
        let priorTarget = try? objectStamp(target, maximumBytes: maximumBytes)
        if verified[sourceKey] == before, let priorTarget, verified[targetKey] == priorTarget { return }
        passes += 1
        // An existing destination proves only its own bytes. A changed source
        // must be verified before its new stamp can become a scheduling hint.
        // A new destination is verified during the single streaming copy.
        if priorTarget != nil, verified[sourceKey] != before {
            try ReviewContentObjectIO.verify(source, hash: hash, maximumBytes: maximumBytes)
        }
        try ReviewContentObjectIO.copy(source, to: target, hash: hash, maximumBytes: maximumBytes)
        guard try objectStamp(source, maximumBytes: maximumBytes) == before else { throw WorkspaceError.stalePointer }
        // Only an in-memory scheduling hint. Processing, source freeze and
        // reader membership never use this cache as semantic proof.
        if verified.count >= 8192 { verified.removeAll(keepingCapacity: true) }
        verified[sourceKey] = before; verified[targetKey] = try objectStamp(target, maximumBytes: maximumBytes)
    }
    private static func pollIO(remote: URL, cache: URL, selection: ReviewFamilyBindingSelection, scan: Int, upload: Int, limit: Int, persistIncoming: Bool, uploadOnly: Bool,
                               verifiedStamps: [String: [String]]) throws -> (ReviewFamilyRequestTransportPoll, Int, Int, [String: [String]], Int) {
        var verified = verifiedStamps, passes = 0
        try selection.validate(marker: read(remote.appendingPathComponent("family.json"), limit: 4096))
        var uploaded = Set<String>(), waiting = Set<String>(), invalid = Set<String>(), requests = [ReviewFamilyRequest]()
        var outgoing = [String]()
        for name in try names(cache.appendingPathComponent("envelopes")) {
            do { if ["queued", "uploaded"].contains(try status(String(name.dropLast(5)), cache: cache) ?? "") { outgoing.append(name) } }
            catch { if error is CancellationError { throw error }; invalid.insert(name) }
        }
        for name in window(outgoing, offset: upload, limit: limit) {
            try Task.checkCancellation()
            do {
                let request = try load(name, cache: cache, selection: selection, verifyOriginals: false)
                try ReviewSyncIO.coordinate(remote, write: true) { _ in
                    try immutable(request.raw, at: remote.appendingPathComponent("requests/" + name), limit: metadataLimit)
                }
                for entry in request.files {
                    let source = cache.appendingPathComponent("objects/" + entry.sha256)
                    guard try objectStamp(source, maximumBytes: entry.bytes)[2] == String(entry.bytes) else { throw WorkspaceError.invalid("upload original byte count") }
                    try copyForTransfer(source, to: remote.appendingPathComponent("objects/" + entry.sha256), hash: entry.sha256, maximumBytes: entry.bytes, verified: &verified, passes: &passes)
                }
                try immutable(request.payload, at: remote.appendingPathComponent("objects/" + request.payloadHash), limit: payloadLimit)
                uploaded.insert(request.id)
            } catch { if error is CancellationError { throw error }; invalid.insert(name) }
        }
        let incoming = uploadOnly ? [] : try names(remote.appendingPathComponent("requests"))
        for name in window(incoming, offset: scan, limit: limit) {
            try Task.checkCancellation()
            do {
                let raw = try read(WorkspaceIO.safeChild(remote.appendingPathComponent("requests"), name), limit: metadataLimit), doc = try WorkspaceIO.object(raw)
                let hash = try WorkspaceIO.string(doc, "payload_hash"); try WorkspaceIO.requireHash(hash)
                let target = cache.appendingPathComponent("objects/" + hash)
                do { try copyForTransfer(remote.appendingPathComponent("objects/" + hash), to: target, hash: hash, maximumBytes: Int64(payloadLimit), verified: &verified, passes: &passes) }
                catch { if ReviewSyncIO.isMissing(error) || !FileManager.default.fileExists(atPath: remote.appendingPathComponent("objects/" + hash).path) { waiting.insert(hash); continue }; throw error }
                let payload = try read(target, limit: payloadLimit)
                let request = try ReviewFamilyRequest(raw: raw, payload: payload, cache: cache, selection: selection)
                guard name == request.id + ".json" else { throw WorkspaceError.invalid("request envelope filename") }
                var missing = false
                for entry in request.files {
                    do {
                        let source = remote.appendingPathComponent("objects/" + entry.sha256)
                        guard try objectStamp(source, maximumBytes: entry.bytes)[2] == String(entry.bytes) else { throw WorkspaceError.invalid("incoming original byte count") }
                        try copyForTransfer(source, to: cache.appendingPathComponent("objects/" + entry.sha256), hash: entry.sha256, maximumBytes: entry.bytes, verified: &verified, passes: &passes)
                    }
                    catch { if ReviewSyncIO.isMissing(error) || !FileManager.default.fileExists(atPath: remote.appendingPathComponent("objects/" + entry.sha256).path) { waiting.insert(entry.sha256); missing = true; continue }; throw error }
                }
                if missing { continue }
                if persistIncoming {
                    try withOutboxLock(cache) {
                        try immutable(raw, at: cache.appendingPathComponent("envelopes/" + name), limit: metadataLimit)
                    }
                }
                if !["cancelled", "included", "needsReview"].contains(try status(request.id, cache: cache) ?? "") { requests.append(request) }
            } catch { if error is CancellationError { throw error }; invalid.insert(name) }
        }
        return (.init(requests: requests, waitingObjectHashes: waiting, invalidRequestIDs: invalid, uploadedRequestIDs: uploaded), scan + min(limit, incoming.count), upload + min(limit, outgoing.count), verified, passes)
    }
    internal static func load(_ name: String, cache: URL, selection: ReviewFamilyBindingSelection, verifyOriginals: Bool = true) throws -> ReviewFamilyRequest {
        let raw = try read(WorkspaceIO.safeChild(cache.appendingPathComponent("envelopes"), name), limit: metadataLimit), doc = try WorkspaceIO.object(raw)
        let hash = try WorkspaceIO.string(doc, "payload_hash"); try WorkspaceIO.requireHash(hash)
        let request = try ReviewFamilyRequest(raw: raw, payload: read(cache.appendingPathComponent("objects/" + hash), limit: payloadLimit), cache: cache, selection: selection)
        guard name == request.id + ".json" else { throw WorkspaceError.invalid("cached request ID") }
        if verifyOriginals { try validateObjects(request) }; return request
    }
    internal static func validateObjects(_ request: ReviewFamilyRequest) throws {
        for entry in request.files {
            let file = request.cache.appendingPathComponent("objects/" + entry.sha256)
            try WorkspaceIO.rejectSymlinks(file)
            let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard info.isRegularFile == true, info.fileSize == Int(entry.bytes) else { throw WorkspaceError.invalid("request original bytes") }
            try ReviewContentObjectIO.verify(file, hash: entry.sha256, maximumBytes: entry.bytes)
        }
    }
    private static func window(_ names: [String], offset: Int, limit: Int) -> [String] {
        guard !names.isEmpty else { return [] }; return (0..<min(limit, names.count)).map { names[(offset % names.count + $0) % names.count] }
    }
    internal static func read(_ file: URL, limit: Int) throws -> Data { try WorkspaceIO.rejectSymlinks(file); return try ReviewSyncIO.read(file, limit: limit) }
    private static func names(_ root: URL) throws -> [String] {
        try WorkspaceIO.rejectSymlinks(root)
        if !FileManager.default.fileExists(atPath: root.path) { return [] }
        let names = try ReviewSyncIO.coordinate(root) { try FileManager.default.contentsOfDirectory(atPath: $0.path).sorted() }
        guard names.count <= 100000 else { throw WorkspaceError.invalid("request directory resource limit") }
        return names
    }
    private static func immutable(_ bytes: Data, at file: URL, limit: Int) throws {
        guard bytes.count <= limit else { throw WorkspaceError.invalid("request metadata size limit") }
        try WorkspaceIO.rejectSymlinks(file); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ReviewSyncIO.coordinate(file.deletingLastPathComponent(), write: true) { parent in
            let target = parent.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) { guard try read(target, limit: limit) == bytes else { throw WorkspaceError.invalid("immutable request collision") } }
            else { try WorkspaceIO.atomicWrite(bytes, to: target); try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path) }
        }
    }
    private static func status(_ id: String, cache: URL) throws -> String? {
        let path = cache.appendingPathComponent("outbox-status/" + id + ".json")
        if !FileManager.default.fileExists(atPath: path.path) { return nil }
        let raw = try read(path, limit: 4096), doc = try WorkspaceIO.object(raw)
        guard Set(doc.keys) == ["request_id", "status", "generation", "result_digest"],
              doc["request_id"] as? String == id, let status = doc["status"] as? String, ["queued", "uploaded", "cancelled", "included", "needsReview"].contains(status) else { throw WorkspaceError.invalid("local request status") }
        return status
    }
    // Called after actual-reader reconciliation. A terminal partial has the
    // same generation/result pin as inclusion; stale UI actions preserve it.
    // An unqualified needsReview result remains explicitly retryable.
    internal static func preservesVerifiedOutcome(_ id: String, cache: URL) throws -> Bool {
        guard let state = try status(id, cache: cache) else { return false }
        if state == "included" { return true }
        guard state == "needsReview" else { return false }
        let pin = try WorkspaceIO.object(read(cache.appendingPathComponent("outbox-status/" + id + ".json"), limit: 4096))
        guard let generation = pin["generation"] as? String, let digest = pin["result_digest"] as? String else { return false }
        try WorkspaceIO.requireHash(generation); try WorkspaceIO.requireHash(digest)
        return true
    }
    internal static func writeLocalIntent(_ value: String, id: String, cache: URL) throws {
        guard ["queued", "cancelled"].contains(value) else { throw WorkspaceError.invalid("local request intent") }
        try withOutboxLock(cache) {
            if try !preservesVerifiedOutcome(id, cache: cache) { try writeStatus(value, id: id, cache: cache) }
        }
    }
    private static func status(_ value: String, id: String, cache: URL, generation: String? = nil, resultDigest: String? = nil) throws {
        try withOutboxLock(cache) {
            try writeStatus(value, id: id, cache: cache, generation: generation, resultDigest: resultDigest)
        }
    }
    private static func writeStatus(_ value: String, id: String, cache: URL, generation: String? = nil, resultDigest: String? = nil) throws {
        if value == "included" { try WorkspaceIO.requireHash(generation ?? ""); try WorkspaceIO.requireHash(resultDigest ?? "") }
        let file = cache.appendingPathComponent("outbox-status/" + id + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            let old = try WorkspaceIO.object(read(file, limit: 4096))
            if old["request_id"] as? String == id, old["status"] as? String == value,
               old["generation"] as? String == generation, old["result_digest"] as? String == resultDigest { return }
        }
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["request_id": id, "status": value,
            "generation": generation.map { $0 as Any } ?? NSNull(), "result_digest": resultDigest.map { $0 as Any } ?? NSNull()]), to: file)
    }
    internal static func successfulResults(_ results: [[String: Any]]) throws -> [String: [String: Any]] {
        try resultIndex(results).filter { $0.value["outcome"] as? String == "success" }
    }
    internal static func resultIndex(_ results: [[String: Any]]) throws -> [String: [String: Any]] {
        var indexed = [String: [String: Any]]()
        for result in results {
            let id = try WorkspaceIO.string(result, "request_id")
            guard indexed[id] == nil else { throw WorkspaceError.invalid("duplicate request result identity") }
            indexed[id] = result
        }
        return indexed
    }
    internal static func withOutboxLock<T>(_ cache: URL, _ action: () throws -> T) throws -> T {
        try WorkspaceIO.rejectSymlinks(cache)
        // The mutex remains at the same inode while an entire prepared cache
        // is atomically renamed into place.
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = cache.deletingLastPathComponent().appendingPathComponent("." + cache.lastPathComponent + ".request-outbox.lock")
        try WorkspaceIO.rejectSymlinks(file)
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw WorkspaceError.io("request outbox lock") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceError.invalid("request outbox lock regular file") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw WorkspaceError.busy }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try action()
    }
}
