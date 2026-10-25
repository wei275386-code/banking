import Foundation
import Darwin

/// Opaque publication boundary for the future local qualification owner. There
/// is deliberately no public initializer or factory from a marker/cache/report
/// hash. The owner must hold its authority mutex while executing the final body.
/// This permit is not processor readiness or a protocol-upgrade anchor.
public struct ReviewFamilyPublicationPermit: Sendable {
    public let selection: ReviewFamilyBindingSelection
    internal let workspace: URL
    internal let withAuthority: @Sendable (() throws -> Void) throws -> Void
    internal let contextForGeneration: @Sendable (String, Data) throws -> ReviewFamilySnapshotContext
    internal init(selection: ReviewFamilyBindingSelection, workspace: URL,
                  withAuthority: @escaping @Sendable (() throws -> Void) throws -> Void,
                  contextForGeneration: @escaping @Sendable (String, Data) throws -> ReviewFamilySnapshotContext) {
        self.selection = selection; self.workspace = WorkspaceIO.lexicalURL(workspace)
        self.withAuthority = withAuthority; self.contextForGeneration = contextForGeneration
    }
}
public enum ReviewFamilyPublicationPoint: Sendable {
    case reserved, objectsUploaded, manifestUploaded, intentSaved, pointerPublished, hostJournalSaved, published
}
public struct ReviewFamilyFrozenPublication: Sendable {
    public let state: WorkspaceStatePointer, selection: ReviewFamilyBindingSelection
    fileprivate let workspace: URL, template: Data, objects: [String: URL], context: ReviewFamilySnapshotContext
    fileprivate let pins: [String: ReviewVerifiedFilePin]
    private let pinnedState: StateHandle
    fileprivate let required: Set<String>
    fileprivate init(state: StateHandle, selection: ReviewFamilyBindingSelection, workspace: URL, template: Data,
                     objects: [String: URL], context: ReviewFamilySnapshotContext, pins: [String: ReviewVerifiedFilePin], required: Set<String>) {
        self.state = state.pointer; self.pinnedState = state; self.selection = selection; self.workspace = workspace; self.template = template
        self.objects = objects; self.context = context; self.pins = pins; self.required = required
    }
}

/// Frozen transport component. Production permit issuance/upgrade lineage and
/// active driver wiring are separate. No callback or Bool is public authority.
public final class ReviewFamilySnapshotPublisher: Sendable {
    public let remote: URL, local: URL, selection: ReviewFamilyBindingSelection
    public let writerVersion: String
    public init(remote: URL, local: URL, selection: ReviewFamilyBindingSelection, writerVersion: String = "1.3.0") throws {
        guard remote.isFileURL, local.isFileURL else { throw WorkspaceError.invalid("family publisher URLs") }
        self.remote = WorkspaceIO.lexicalURL(remote); self.local = WorkspaceIO.lexicalURL(local.appendingPathComponent("" + selection.bindingID + "/publication"))
        self.selection = selection; self.writerVersion = writerVersion
        try WorkspaceIO.rejectSymlinks(self.remote); try WorkspaceIO.rejectSymlinks(self.local)
    }
    public func createBinding(permit: ReviewFamilyPublicationPermit) throws {
        try authorize(permit)
        try permit.withAuthority {
            let marker = remote.appendingPathComponent("family.json")
            if FileManager.default.fileExists(atPath: marker.path) { try validateMarker() }
            else if FileManager.default.fileExists(atPath: remote.path) {
                guard try FileManager.default.contentsOfDirectory(atPath: remote.path).isEmpty else { throw WorkspaceError.invalid("new family binding requires empty provider") }
            }
            try immutable(WorkspaceIO.canonical(selection.document), at: marker)
            for name in ["objects", "snapshots"] { try WorkspaceIO.rejectSymlinks(remote.appendingPathComponent(name)); try FileManager.default.createDirectory(at: remote.appendingPathComponent(name), withIntermediateDirectories: true) }
        }
    }
    /// The caller supplies a frozen manifest template; sequence/parent are assigned
    /// by publication. Every business projection is independently tied to actual
    /// committed state, including full originals and raw origin archive bytes.
    public func freeze(paths: WorkspacePaths, bundle: ReviewCheckpointBundle, context: ReviewFamilySnapshotContext,
                       permit: ReviewFamilyPublicationPermit, token: WorkspaceWriteToken) throws -> ReviewFamilyFrozenPublication {
        try token.validate(for: paths); try authorize(permit)
        guard paths.workspace.path == permit.workspace.path else { throw WorkspaceError.invalid("publication workspace differs from permit") }
        let state = try paths.readState(); try ReviewWorkspaceMembership.validate(state: state); try WorkspaceBusinessValidator.validateRead(state)
        let settings = try HouseholdSettingsState.read(paths: paths, currencyCodes: context.settings.currencyCodes,
            referencedMemberIDs: context.settings.referencedMemberIDs, referencedAccountIDs: context.settings.referencedAccountIDs)
        let cp = try WorkspaceIO.object(bundle.manifest), tuple = cp["state"] as? [String: Any]
        guard state.pointer.workspaceID == selection.workspaceID, tuple?["state_id"] as? String == state.pointer.stateID,
              tuple?["state_manifest_hash"] as? String == state.pointer.manifestHash,
              try WorkspaceIO.integer(WorkspaceIO.canonical(tuple ?? [:]), field: "local_revision") == state.pointer.localRevision else { throw WorkspaceError.invalid("publication template not current state") }
        let stateMap = try WorkspaceIO.object(WorkspaceIO.read(state.manifest))["files"] as! [String: String]
        var objects = bundle.objects, pins = [String: ReviewVerifiedFilePin](), total: Int64 = 0
        func pin(_ file: URL, hash: String, maximum: Int64 = 32 * 1024 * 1024 * 1024) throws {
            if pins[file.path] != nil { return }
            let remaining = 100 * 1024 * 1024 * 1024 - total
            let value = try ReviewVerifiedFilePin.verified(file, hash: hash, maximumBytes: min(maximum, remaining))
            guard value.size <= remaining, pins.count < 100_000 else { throw WorkspaceError.invalid("publication freeze budget") }
            total += value.size; pins[file.path] = value
        }
        try pin(state.manifest, hash: state.pointer.manifestHash, maximum: 16 * 1024 * 1024)
        for (path, hash) in stateMap { try pin(state.file(path), hash: hash) }
        guard let assetHash = cp["asset_manifest"] as? String, let assetFile = objects[assetHash] else { throw WorkspaceError.invalid("publication asset manifest") }
        let assetRaw = try ReviewSyncIO.read(assetFile, limit: ReviewClientBusinessProof.maximumBytes)
        guard let assets = try WorkspaceIO.object(assetRaw)["assets"] as? [[String: Any]] else { throw WorkspaceError.invalid("publication assets") }
        for asset in assets {
            let path = try WorkspaceIO.string(asset, "path"), hash = try WorkspaceIO.string(asset, "sha256")
            guard let actual = [path, "review/" + path].first(where: { stateMap[$0] == hash }) else { throw WorkspaceError.invalid("publication asset not retained in state") }
            objects[hash] = try state.file(actual)
        }
        let generation = WorkspaceIO.digest(bundle.manifest)
        guard case .ready(let payload) = try ReviewFamilySnapshotPayload.prepare(selection: selection, generation: generation, manifest: bundle.manifest,
            objects: objects, sourceBindings: context.sourceBindings, context: context.settings, readerVersion: writerVersion) else { throw WorkspaceError.invalid("publication payload is not ready") }
        guard payload.fields.causal.revisions.allSatisfy({ $0.origin.sourceBindingID == selection.bindingID }) else {
            throw WorkspaceError.invalid("snapshot contains foreign revision context")
        }
        let captured = try ReviewFieldDocuments.capture(state: state, settings: settings)
        guard try WorkspaceIO.canonical(["values": captured]) == WorkspaceIO.canonical(["values": payload.fields.causal.values]) else { throw WorkspaceError.invalid("publication replay differs from committed saved fields") }
        let files = cp["files"] as! [String: String]
        for (path, hash) in files where !["business-proof.json", "asset-manifest.json", "request-results.json", "state-manifest.json"].contains(path) {
            let mapped = ReviewSettingsFieldDocuments.mappings.first(where: { $0.snapshotPath == path })?.statePath ?? "review/" + path
            guard stateMap[mapped] == hash else { throw WorkspaceError.invalid("publication projection not actual state file") }
        }
        guard cp["covered_revision_inventory"] as? String == stateMap["review/revision-inventory.json"],
              cp["request_results"] as? String == stateMap["operation-results.json"],
              let proofHash = files["business-proof.json"], let proofFile = objects[proofHash],
              try WorkspaceIO.read(proofFile) == ReviewClientBusinessProof.build(state: state, selection: selection, settings: settings, assetManifestHash: assetHash) else { throw WorkspaceError.invalid("publication proof differs from actual host membership") }
        for revision in payload.fields.causal.revisions {
            for hash in revision.rawSources.keys {
                let path = "history/edits/" + revision.origin.sourceBindingID + "/" + hash + ".json"
                guard stateMap[path] == hash else { throw WorkspaceError.invalid("publication raw origin not retained in committed archive") }
            }
        }
        let required = payload.requiredObjects.union(payload.optionalOriginalObjects)
        for hash in required { guard let file = objects[hash] else { throw WorkspaceError.invalid("host publication omitted retained original") }; try pin(file, hash: hash) }
        let frozen = ReviewFamilyFrozenPublication(state: state, selection: selection, workspace: paths.workspace,
            template: bundle.manifest, objects: objects, context: context, pins: pins, required: required)
        try revalidate(frozen, paths: paths, permit: permit); return frozen
    }
    /// Prepared intents retry the identical generation/sequence; never allocate a
    /// new root or discard a possible publication. The future owner must settle
    /// this intent before admitting edits or cleanup of its frozen source.
    public func publish(_ frozen: ReviewFamilyFrozenPublication, paths: WorkspacePaths, permit: ReviewFamilyPublicationPermit,
                        failureInjector: ((ReviewFamilyPublicationPoint) throws -> Void)? = nil) throws -> String {
        try revalidate(frozen, paths: paths, permit: permit)
        return try withPublishLock {
            try validateMarker()
            let previous = try providerHead(), known = try localHead(), intent = try readIntent()
            if let previous {
                let reader = try ReviewFamilySnapshotStore(remote: remote, local: local.appendingPathComponent("reader-check"), selection: selection, readerVersion: writerVersion)
                let verified: ReviewCachedFamilySnapshot
                switch try reader.prepare(contextForGeneration: permit.contextForGeneration) {
                case .ready(let cached), .unchanged(let cached): verified = cached
                default: throw WorkspaceError.invalid("publication provider ancestry is not ready")
                }
                guard verified.generation == previous.generation, verified.sequence == previous.sequence,
                      known.map({ verified.sequence > $0.sequence || (verified.sequence == $0.sequence && verified.generation == $0.generation) }) ?? true else { throw WorkspaceError.invalid("publication provider rollback/fork") }
                let cp = try WorkspaceIO.object(verified.payload.manifest), state = cp["state"] as! [String: Any]
                let revision = try WorkspaceIO.integer(WorkspaceIO.canonical(state), field: "local_revision")
                guard frozen.state.localRevision >= revision, frozen.state.localRevision != revision || (state["state_id"] as? String == frozen.state.stateID && state["state_manifest_hash"] as? String == frozen.state.manifestHash) else { throw WorkspaceError.invalid("publication business state rollback") }
            } else if known != nil { throw WorkspaceError.invalid("published family provider pointer disappeared") }
            if let intent, intent.phase == "committed", intent.templateHash == WorkspaceIO.digest(frozen.template),
               previous == Head(generation: intent.generation, sequence: intent.sequence) {
                try revalidate(frozen, paths: paths, permit: permit); return intent.generation
            }
            let sequence: Int64, parent: String?
            if let intent, intent.phase == "prepared" {
                guard intent.templateHash == WorkspaceIO.digest(frozen.template), previous?.generation == intent.generation || previous?.generation == intent.parent else { throw WorkspaceError.invalid("pending publication must settle with its exact frozen source") }
                sequence = intent.sequence; parent = intent.parent
            } else { sequence = try reserve(after: previous?.sequence); parent = previous?.generation }
            var doc = try WorkspaceIO.object(frozen.template); doc["sequence"] = sequence; doc["parent_generation"] = parent as Any? ?? NSNull()
            let raw = try WorkspaceIO.canonical(doc), generation = WorkspaceIO.digest(raw)
            if let intent, intent.phase == "prepared" { guard intent.generation == generation else { throw WorkspaceError.invalid("pending publication bytes differ") } }
            guard try WorkspaceCompatibility.supports(minimumVersion: WorkspaceIO.string(doc, "min_writer_version"), runningVersion: writerVersion),
                  case .ready = try ReviewFamilySnapshotPayload.prepare(selection: selection, generation: generation, manifest: raw,
                    objects: frozen.objects, sourceBindings: frozen.context.sourceBindings, context: frozen.context.settings, readerVersion: writerVersion) else { throw WorkspaceError.invalid("family writer or frozen payload") }
            try failureInjector?(.reserved)
            try ReviewContentObjectIO.copyBatch(frozen.objects.filter { frozen.required.contains($0.key) }, to: remote.appendingPathComponent("objects"))
            try failureInjector?(.objectsUploaded)
            try immutable(raw, at: remote.appendingPathComponent("snapshots/" + generation)); try failureInjector?(.manifestUploaded)
            try permit.withAuthority {
                try revalidateFiles(frozen, paths: paths); try validateMarker()
                guard try providerHead() == previous else { throw WorkspaceError.stalePointer }
                try saveIntent(generation: generation, sequence: sequence, parent: parent, templateHash: WorkspaceIO.digest(frozen.template), phase: "prepared")
                try failureInjector?(.intentSaved)
                try Task.checkCancellation()
                var pointer = selection.document; pointer["generation"] = generation; pointer["sequence"] = sequence
                if previous?.generation != generation { try ReviewSyncIO.coordinate(remote.appendingPathComponent("current.json"), write: true) { _ in
                    try validateMarker()
                    // Already inside this pointer's write coordination. A nested
                    // coordinated read of the same item waits on our own claim.
                    guard try providerHead(coordinated: false) == previous else { throw WorkspaceError.stalePointer }
                    try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pointer), to: remote.appendingPathComponent("current.json"))
                } }
                try failureInjector?(.pointerPublished)
                try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pointer), to: local.appendingPathComponent("published-snapshot.json"))
                try failureInjector?(.hostJournalSaved)
                try saveIntent(generation: generation, sequence: sequence, parent: parent, templateHash: WorkspaceIO.digest(frozen.template), phase: "committed")
            }
            try failureInjector?(.published)
            do {
                try permit.withAuthority { _ = try ReviewFamilyReclamation.collect(remote: remote, selection: selection, expectedGeneration: generation) }
            } catch {
                try? WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["status": "deferred", "message": error.localizedDescription]),
                    to: local.appendingPathComponent("reclamation-status.json"))
            }
            return generation
        }
    }
    private func authorize(_ permit: ReviewFamilyPublicationPermit) throws {
        guard permit.selection == selection else { throw WorkspaceError.invalid("publication permit selection") }; try permit.withAuthority({})
    }
    private func revalidate(_ frozen: ReviewFamilyFrozenPublication, paths: WorkspacePaths, permit: ReviewFamilyPublicationPermit) throws {
        try authorize(permit); guard permit.workspace.path == paths.workspace.path else { throw WorkspaceError.invalid("publication permit workspace") }; try revalidateFiles(frozen, paths: paths)
    }
    private func revalidateFiles(_ frozen: ReviewFamilyFrozenPublication, paths: WorkspacePaths) throws {
        guard frozen.selection == selection, frozen.workspace.path == paths.workspace.path, try paths.readPointer() == frozen.state else { throw WorkspaceError.stalePointer }
        for (path, pin) in frozen.pins { try Task.checkCancellation(); guard try ReviewVerifiedFilePin.read(URL(fileURLWithPath: path)) == pin else { throw WorkspaceError.stalePointer } }
    }
    private struct Head: Equatable { let generation: String, sequence: Int64 }
    private struct Intent { let generation: String, sequence: Int64, parent: String?, templateHash: String, phase: String }
    private func readHead(_ file: URL, coordinated: Bool = true) throws -> Head {
        let raw = try coordinated ? ReviewSyncIO.read(file, limit: 4096) : WorkspaceIO.read(file, limit: 4096)
        try selection.validate(marker: raw)
        let doc = try WorkspaceIO.object(raw), generation = try WorkspaceIO.string(doc, "generation"); try WorkspaceIO.requireHash(generation)
        let sequence = try WorkspaceIO.integer(raw, field: "sequence"); guard sequence >= selection.initialSequence else { throw WorkspaceError.invalid("family publication pointer sequence") }; return Head(generation: generation, sequence: sequence)
    }
    private func providerHead(coordinated: Bool = true) throws -> Head? { try optionalHead(remote.appendingPathComponent("current.json"), coordinated: coordinated) }
    private func localHead() throws -> Head? { try optionalHead(local.appendingPathComponent("published-snapshot.json")) }
    private func optionalHead(_ file: URL, coordinated: Bool = true) throws -> Head? { do { return try readHead(file, coordinated: coordinated) } catch { if ReviewSyncIO.isMissing(error) { return nil }; throw error } }
    private func validateMarker() throws { try selection.validate(marker: ReviewSyncIO.read(remote.appendingPathComponent("family.json"), limit: 4096)) }
    private func reserve(after sequence: Int64?) throws -> Int64 {
        let file = local.appendingPathComponent("publication-sequence.json")
        var previous = max(sequence ?? selection.initialSequence - 1, selection.initialSequence - 1)
        if FileManager.default.fileExists(atPath: file.path) { let raw = try ReviewSyncIO.read(file, limit: 4096); try selection.validate(marker: raw); previous = max(previous, try WorkspaceIO.integer(raw, field: "reserved_sequence")) }
        guard previous < Int64.max else { throw WorkspaceError.invalid("publication sequence exhausted") }
        var doc = selection.document; doc["reserved_sequence"] = previous + 1; try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(doc), to: file); return previous + 1
    }
    private func saveIntent(generation: String, sequence: Int64, parent: String?, templateHash: String, phase: String) throws {
        var doc = selection.document; doc["generation"] = generation; doc["sequence"] = sequence
        doc["parent_generation"] = parent as Any? ?? NSNull(); doc["template_hash"] = templateHash; doc["phase"] = phase
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(doc), to: local.appendingPathComponent("publication-intent.json"))
    }
    private func readIntent() throws -> Intent? {
        let file = local.appendingPathComponent("publication-intent.json")
        let raw: Data
        do { raw = try ReviewSyncIO.read(file, limit: 4096) } catch { if ReviewSyncIO.isMissing(error) { return nil }; throw error }
        try selection.validate(marker: raw)
        let doc = try WorkspaceIO.object(raw), head = try readHead(file), hash = try WorkspaceIO.string(doc, "template_hash"), phase = try WorkspaceIO.string(doc, "phase")
        try WorkspaceIO.requireHash(hash); guard ["prepared", "committed"].contains(phase), let parent = doc["parent_generation"], parent is NSNull || parent is String else { throw WorkspaceError.invalid("publication intent") }
        if let parent = parent as? String { try WorkspaceIO.requireHash(parent) }
        return Intent(generation: head.generation, sequence: head.sequence, parent: parent as? String, templateHash: hash, phase: phase)
    }
    private func immutable(_ raw: Data, at file: URL) throws {
        try WorkspaceIO.rejectSymlinks(file)
        if FileManager.default.fileExists(atPath: file.path) { guard try ReviewSyncIO.read(file, limit: ReviewClientBusinessProof.maximumBytes) == raw else { throw WorkspaceError.invalid("immutable publication collision") } }
        else { try WorkspaceIO.atomicWrite(raw, to: file) }
    }
    private func withPublishLock<T>(_ body: () throws -> T) throws -> T {
        try WorkspaceIO.rejectSymlinks(local); try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let file = local.appendingPathComponent("publish-family.lock"); try WorkspaceIO.rejectSymlinks(file)
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw WorkspaceError.io("family publication mutex") }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WorkspaceError.busy }; defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
