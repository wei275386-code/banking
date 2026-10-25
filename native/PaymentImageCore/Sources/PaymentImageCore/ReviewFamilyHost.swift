import Foundation
import Darwin

/// Device-local new-household connection. It is not an upgrade/restore anchor,
/// client selection or processor grant. Construction is restricted to the owner.
public struct ReviewFamilyConnection: Sendable {
    public let selection: ReviewFamilyBindingSelection, remote: URL, bookmark: Data?
    fileprivate init(selection: ReviewFamilyBindingSelection, remote: URL, bookmark: Data?) {
        self.selection = selection; self.remote = remote; self.bookmark = bookmark
    }
}

/// A local choice surface over the exact committed Host and retained incoming
/// origins. Its private pins cannot be issued by provider/UI declarations.
public struct ReviewFamilyHostConflictState: Sendable {
    public let options: [String: [String]]
    fileprivate let selection: ReviewFamilyBindingSelection, state: WorkspaceStatePointer, inventoryHash: String
    fileprivate init(selection: ReviewFamilyBindingSelection, state: WorkspaceStatePointer, fields: ReviewCausalFieldCheckpoint) {
        self.selection = selection; self.state = state; self.inventoryHash = fields.inventoryHash
        options = fields.heads.filter { Set($0.value.map { Data($0.value.utf8) }).count > 1 }.mapValues { heads in
            var seen = Set<Data>()
            return heads.map(\.value).filter { seen.insert(Data($0.utf8)).inserted }.sorted { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }
        }
    }
}

/// Production owner for explicit, genuinely new family households. Existing bindings,
/// restores and retained foreign origins require the separate upgrade factories.
/// No marker, cache or externally supplied report can issue this local permit.
public enum ReviewFamilyHost {
    private static func intent(_ paths: WorkspacePaths) -> URL { paths.device.appendingPathComponent("create-family.json") }
    private static func barrier(_ paths: WorkspacePaths) -> URL { paths.device.appendingPathComponent("host-publication-family.json") }
    private static func grant(_ paths: WorkspacePaths) -> URL { paths.device.appendingPathComponent("host-authorization.json") }
    private static func descriptor(_ paths: WorkspacePaths) -> URL { paths.device.appendingPathComponent("family-connection.json") }
    private static func local(_ paths: WorkspacePaths) -> URL { paths.device.appendingPathComponent("family-sync") }

    /// Called by every ordinary native transaction (and mirrored by Python).
    /// The metadata owner alone can resume a frozen initial/publication intent.
    public static func requireNoPendingWrite(paths: WorkspacePaths) throws {
        for file in [intent(paths), barrier(paths)] {
            try WorkspaceIO.rejectSymlinks(file)
            if FileManager.default.fileExists(atPath: file.path) {
                let raw = try WorkspaceIO.read(file), row = try WorkspaceIO.object(raw)
                
                guard file == intent(paths) && row["phase"] as? String == "complete" else {
                    throw WorkspaceError.invalid("请先重试完成家庭同步发布，再保存新的修改。")
                }
            }
        }
    }
    public static func requireProcessor(paths: WorkspacePaths, selection: ReviewFamilyBindingSelection) throws {
        try authorize(paths: paths, selection: selection)
        try requireNoPendingWrite(paths: paths)
        let ready = try WorkspaceIO.string(WorkspaceIO.object(WorkspaceIO.read(grant(paths))), "ready_generation")
        try WorkspaceIO.requireHash(ready)
    }
    public static func requireSettingsWriter(paths: WorkspacePaths) throws {
        if FileManager.default.fileExists(atPath: grant(paths).path) {
            guard let connection = try readConnection(paths: paths) else { throw WorkspaceError.invalid("family local connection missing") }
            try authorize(paths: paths, selection: connection.selection)
            try requireNoPendingWrite(paths: paths)
            try WorkspaceIO.requireHash(WorkspaceIO.string(WorkspaceIO.object(WorkspaceIO.read(grant(paths))), "ready_generation"))
        } else { try HouseholdSettingsState.requireUnbound(paths: paths) }
    }
    /// Local descriptor read never touches a provider or creates authority.
    public static func readConnection(paths: WorkspacePaths) throws -> ReviewFamilyConnection? {
        guard FileManager.default.fileExists(atPath: descriptor(paths).path) else { return nil }
        let raw = try WorkspaceIO.read(descriptor(paths)), row = try WorkspaceIO.object(raw)
        
        guard row["role"] as? String == "host", row["authority"] as? String == "new-binding" else { throw WorkspaceError.invalid("unsupported family connection role") }
        let selection = try selection(raw)
        guard try paths.readPointer().workspaceID == selection.workspaceID else { throw WorkspaceError.invalid("family connection workspace") }
        let path = try WorkspaceIO.string(row, "remote_path")
        guard path.hasPrefix("/"), row["bookmark"] is NSNull || row["bookmark"] is String else { throw WorkspaceError.invalid("family connection location") }
        let bookmark = row["bookmark"] as? String
        guard bookmark == nil || Data(base64Encoded: bookmark!) != nil else { throw WorkspaceError.invalid("family connection bookmark") }
        return .init(selection: selection, remote: WorkspaceIO.lexicalURL(URL(fileURLWithPath: path)), bookmark: bookmark.flatMap { Data(base64Encoded: $0) })
    }
    /// Reauthorize the same household at an explicitly selected provider URL.
    /// Existing local authorization remains the sole source of the host role.
    public static func reconnect(paths: WorkspacePaths, remote: URL, bookmark: Data?) throws -> ReviewFamilyConnection {
        try flowLock(paths: paths) {
            guard let saved = try readConnection(paths: paths) else { throw WorkspaceError.invalid("尚未建立家庭同步。") }
            try saved.selection.validate(marker: ReviewSyncIO.read(remote.appendingPathComponent("family.json"), limit: 4096))
            let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
            defer { withExtendedLifetime(token) {} }
            try authorize(paths: paths, selection: saved.selection)
            let connection = ReviewFamilyConnection(selection: saved.selection, remote: WorkspaceIO.lexicalURL(remote), bookmark: bookmark)
            try authorityLock(paths: paths) { try saveConnection(connection, paths: paths) }
            return connection
        }
    }
    /// Explicit create action only. Never called by reconnect, startup or polling.
    public static func create(paths: WorkspacePaths, remote: URL, bookmark: Data? = nil,
                              failureInjector: ((ReviewFamilyPublicationPoint) throws -> Void)? = nil) throws -> ReviewFamilyConnection {
        try flowLock(paths: paths) {
            let remote = WorkspaceIO.lexicalURL(remote)
            guard remote.isFileURL, remote.path != paths.workspace.path,
                  !remote.path.hasPrefix(paths.workspace.path + "/"), !paths.workspace.path.hasPrefix(remote.path + "/") else { throw WorkspaceError.invalid("同步目录必须独立于本机资料目录。") }
            try WorkspaceIO.rejectSymlinks(remote)
            if !FileManager.default.fileExists(atPath: intent(paths).path), FileManager.default.fileExists(atPath: remote.path) {
                guard try ReviewSyncIO.coordinate(remote, { try FileManager.default.contentsOfDirectory(atPath: $0.path).isEmpty }) else { throw WorkspaceError.invalid("创建家庭同步需要新的空目录。") }
            }
            let connection: ReviewFamilyConnection = try {
                let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
                let state = try paths.readState(); try WorkspaceCompatibility.requireWriter(paths: paths, state: state)
                try WorkspaceBusinessValidator.validateRead(state)
                let device = try ReviewDeviceIdentity.readOrCreate(paths: paths, token: token)
                let value: ReviewFamilyBindingSelection
                if FileManager.default.fileExists(atPath: intent(paths).path) {
                    let raw = try WorkspaceIO.read(intent(paths)), row = try WorkspaceIO.object(raw)
                    value = try selection(raw)
                    guard row["remote_path"] as? String == remote.path, ["creating", "complete"].contains(row["phase"] as? String ?? ""),
                          value.workspaceID == state.pointer.workspaceID, value.hostID == device else { throw WorkspaceError.invalid("必须在原目录重试原家庭绑定。") }
                } else {
                    try HouseholdSettingsState.requireUnbound(paths: paths)
                    try requireFreshIdentity(paths: paths)
                    guard try !FileManager.default.fileExists(atPath: state.file("review/field-state.json").path),
                          try !FileManager.default.fileExists(atPath: state.file("review/revision-inventory.json").path),
                          !(try WorkspaceIO.regularFiles(state.root)).contains(where: { $0.hasPrefix("history/sync-") }) else { throw WorkspaceError.invalid("已有同步历史需先完成升级资格验证。") }
                    let settings = try settings(paths: paths, state: state)
                    value = try .init(workspaceID: state.pointer.workspaceID, bindingID: UUID().uuidString.lowercased(), hostID: device)
                    var row = value.document
                    row["phase"] = "creating"; row["remote_path"] = remote.path
                    row["initial_values"] = try ReviewFieldDocuments.capture(state: state, settings: settings)
                    row["metadata_hash"] = try WorkspaceIO.hash(paths.metadata)
                    try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(row), to: intent(paths))
                }
                let intentRow = try WorkspaceIO.object(WorkspaceIO.read(intent(paths)))
                guard intentRow["metadata_hash"] as? String == (try WorkspaceIO.hash(paths.metadata)) else { throw WorkspaceError.stalePointer }
                try requireFreshIdentity(paths: paths); try rejectOtherSelections(paths: paths)
                let connection = ReviewFamilyConnection(selection: value, remote: remote, bookmark: bookmark)
                try authorityLock(paths: paths) {
                    if FileManager.default.fileExists(atPath: grant(paths).path) { try authorize(paths: paths, selection: value) }
                    else {
                        var row = value.document; row["role"] = "host"; row["authority"] = "new-binding"
                        row["device_id"] = device; row["metadata_hash"] = intentRow["metadata_hash"]; row["ready_generation"] = NSNull()
                        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(row), to: grant(paths))
                    }
                    try saveConnection(connection, paths: paths)
                }
                return connection
            }()
            _ = try publishLocked(paths: paths, connection: connection, failureInjector: failureInjector)
            try HouseholdPendingRequests.adopt(paths: paths, selection: connection.selection)
            return connection
        }
    }
    /// Continues only a saved local host grant. It cannot create a binding for a
    /// directory discovered by startup or repair a missing provider marker.
    public static func publish(paths: WorkspacePaths, incoming: [ReviewNativeRevision] = [], failureInjector: ((ReviewFamilyPublicationPoint) throws -> Void)? = nil) throws -> String {
        try flowLock(paths: paths) {
            guard let connection = try readConnection(paths: paths) else { throw WorkspaceError.invalid("尚未建立 family 家庭同步。") }
            return try publishLocked(paths: paths, connection: connection, incoming: incoming, failureInjector: failureInjector)
        }
    }
    /// Observe recovery under the same flow lock as publication. A caller's
    /// earlier pending-file check cannot describe a concurrent manual retry.
    fileprivate static func publishForDriver(paths: WorkspacePaths, expected: ReviewFamilyConnection,
                                             incoming: [ReviewNativeRevision]) throws -> (generation: String, resumed: Bool) {
        try flowLock(paths: paths) {
            guard let saved = try readConnection(paths: paths), saved.selection == expected.selection,
                  saved.remote.path == expected.remote.path else { throw WorkspaceError.stalePointer }
            let resumed = FileManager.default.fileExists(atPath: barrier(paths).path)
            return (try publishLocked(paths: paths, connection: saved, incoming: incoming, failureInjector: nil), resumed)
        }
    }
    public static func synchronize(paths: WorkspacePaths) async throws -> String {
        guard let connection = try readConnection(paths: paths) else { throw WorkspaceError.invalid("family Host connection missing") }
        let transport = try ReviewFamilyRevisionTransport(remote: connection.remote, cache: local(paths).appendingPathComponent("incoming"), selection: connection.selection)
        _ = try await transport.poll(outgoing: [])
        let incoming = try await transport.cachedRevisions()
        return try await ReviewSyncDetached.run { try publish(paths: paths, incoming: incoming) }
    }
    /// A work backup reads only the local committed state. Pending publication
    /// does not prevent recovery, and no provider or publication head is read.
    internal static func requireWorkBackupSource(paths: WorkspacePaths) throws {
        if let connection = try readConnection(paths: paths) {
            try authorize(paths: paths, selection: connection.selection)
        } else {
            try HouseholdSettingsState.requireUnbound(paths: paths)
        }
    }
    /// Offline backup of the exact current, fully published new-family state.
    /// Restoration selects a client; it never transfers this installation's Host authority.
    public static func exportPublishedBackup(paths: WorkspacePaths, destination: URL) throws {
        try flowLock(paths: paths) {
            let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken(); try token.validate(for: paths)
            guard let connection = try readConnection(paths: paths) else { throw WorkspaceError.invalid("尚未建立 family 家庭同步。") }
            try authorize(paths: paths, selection: connection.selection); try requireNoPendingWrite(paths: paths)
            let target = WorkspaceIO.lexicalURL(destination), source = paths.workspace
            guard destination.isFileURL, target != source, !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/") else { throw WorkspaceError.invalid("备份目录必须独立于本机资料目录。") }
            let cache = try ReviewFamilySnapshotStore(remote: connection.remote, local: local(paths), selection: connection.selection)
            guard let checkpoint = try cache.readCached(contextForGeneration: { _, raw in try context(paths: paths, selection: connection.selection, manifest: raw) }),
                  try WorkspaceIO.object(WorkspaceIO.read(grant(paths)))["ready_generation"] as? String == checkpoint.generation else { throw WorkspaceError.invalid("请先完成家庭发布，再创建备份。") }
            let state = try paths.readState()
            guard let tupleRaw = try ReleaseCanonicalJSON.canonicalFragment(raw: checkpoint.payload.manifest, atObjectKeys: ["state"]) else { throw WorkspaceError.invalid("checkpoint state missing") }
            let tuple = try WorkspaceIO.object(tupleRaw)
            guard tuple["state_id"] as? String == state.pointer.stateID,
                  tuple["state_manifest_hash"] as? String == state.pointer.manifestHash,
                  try WorkspaceIO.integer(tupleRaw, field: "local_revision") == state.pointer.localRevision else {
                throw WorkspaceError.invalid("本机有尚未发布的修改，请先发布后再备份。")
            }
            try WorkspaceBusinessValidator.validateRead(state)
            let settings = try settings(paths: paths, state: state)
            guard try ReviewFieldDocuments.capture(state: state, settings: settings) == checkpoint.payload.fields.causal.values else { throw WorkspaceError.invalid("本机修改尚未完整发布。") }
            try ReviewFamilyClientSession.exportCheckpointBackup(checkpoint: checkpoint, cache: cache, destination: target)
        }
    }
    private static func publishLocked(paths: WorkspacePaths, connection: ReviewFamilyConnection,
                                      incoming: [ReviewNativeRevision] = [], failureInjector: ((ReviewFamilyPublicationPoint) throws -> Void)?) throws -> String {
        let selection = connection.selection
        try authorize(paths: paths, selection: selection)
        let publisher = try ReviewFamilySnapshotPublisher(remote: connection.remote, local: local(paths), selection: selection)
        let permit = ReviewFamilyPublicationPermit(selection: selection, workspace: paths.workspace,
            withAuthority: { body in try authorityLock(paths: paths) { try authorize(paths: paths, selection: selection); try body() } },
            contextForGeneration: { _, raw in try context(paths: paths, selection: selection, manifest: raw) })
        let creating = try WorkspaceIO.object(WorkspaceIO.read(intent(paths)))["phase"] as? String != "complete"
        if creating { try publisher.createBinding(permit: permit) }
        let frozen: ReviewFamilyFrozenPublication = try {
            let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
            try authorize(paths: paths, selection: selection)
            var state = try paths.readState()
            if FileManager.default.fileExists(atPath: barrier(paths).path) {
                let raw = try WorkspaceIO.read(barrier(paths)); try selection.validate(marker: raw)
                
                guard let tuple = try ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: ["state"]) else { throw WorkspaceError.invalid("family publication state missing") }
                let expected = try JSONDecoder().decode(WorkspaceStatePointer.self, from: tuple)
                guard state.pointer == expected else { throw WorkspaceError.stalePointer }
            } else {
                // Persist real already-saved Host origins before inspecting an incoming
                // conflict. Repeated attempts must retain the same local origin.
                state = try capture(paths: paths, state: state, selection: selection, token: token, creating: creating, incoming: [])
                if !incoming.isEmpty { state = try capture(paths: paths, state: state, selection: selection, token: token, creating: false, incoming: incoming) }
                var row = selection.document; row["state"] = state.pointer.document
                try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(row), to: barrier(paths))
            }
            let settings = try settings(paths: paths, state: state)
            let bundle = try bundle(paths: paths, state: state, selection: selection, settings: settings)
            let context = try context(paths: paths, selection: selection, manifest: bundle.manifest, publicationTemplate: true)
            return try publisher.freeze(paths: paths, bundle: bundle, context: context, permit: permit, token: token)
        }()
        let generation = try publisher.publish(frozen, paths: paths, permit: permit, failureInjector: failureInjector)
        // Actual Store/read-proof verification, not a stored boolean or receipt.
        let store = try ReviewFamilySnapshotStore(remote: connection.remote, local: local(paths), selection: selection)
        let verified: ReviewCachedFamilySnapshot
        switch try store.prepare(contextForGeneration: permit.contextForGeneration) {
        case .ready(let value), .unchanged(let value): verified = value
        default: throw WorkspaceError.invalid("首个完整快照尚未通过回读验证，请重试发布。")
        }
        guard verified.generation == generation else { throw WorkspaceError.stalePointer }
        let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken(); try token.validate(for: paths)
        guard try paths.readPointer() == frozen.state else { throw WorkspaceError.stalePointer }
        try authorityLock(paths: paths) {
            try authorize(paths: paths, selection: selection)
            var row = try WorkspaceIO.object(WorkspaceIO.read(grant(paths))); row["ready_generation"] = generation
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(row), to: grant(paths))
            var creation = try WorkspaceIO.object(WorkspaceIO.read(intent(paths))); creation["phase"] = "complete"
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(creation), to: intent(paths))
            try FileManager.default.removeItem(at: barrier(paths))
            try WorkspaceIO.syncDirectory(paths.device)
        }
        return generation
    }
    private static func baseline(paths: WorkspacePaths, state: StateHandle, settings: HouseholdSettingsState, selection: ReviewFamilyBindingSelection) throws -> ReviewSettingsCausalCheckpoint? {
        let fieldFile = try state.file("review/field-state.json")
        if FileManager.default.fileExists(atPath: fieldFile.path) {
            let raw = try WorkspaceIO.read(fieldFile), field = try WorkspaceIO.object(raw)
            guard let storedSeed = field["seed_values"] as? [String: String] else { throw WorkspaceError.invalid("family seed missing") }
            let seed = storedSeed
            let inventory = try WorkspaceIO.read(state.file("review/revision-inventory.json"))
            let rows = try ReleaseCanonicalJSON.canonicalArrayElements(raw: inventory, atObjectKeys: ["entries"]) ?? []
            var objects = [String: Data]()
            let bindings: Set<String> = [selection.bindingID]
            for entry in rows {
                let row = try WorkspaceIO.object(entry), binding = try WorkspaceIO.string(row, "source_binding_id")
                guard binding == selection.bindingID else { throw WorkspaceError.invalid("foreign origin binding") }
                let aliases = [try WorkspaceIO.string(row, "payload_hash")]
                for hash in aliases { try WorkspaceIO.requireHash(hash); objects[hash] = try ReviewSyncIO.read(state.file("history/edits/" + binding + "/" + hash + ".json"), limit: 2 * 1024 * 1024) }
            }
            let origins = try ReviewRevisionOrigin.inventory(inventory, objects: objects, sourceBindings: bindings)
            guard case .ready(let ready) = try ReviewSettingsCausalFields.prepareInventory(seedValues: seed, origins: origins, bindingID: selection.bindingID, context: settings.context),
                  ready.causal.inventory == inventory, try ready.causal.fieldState() == raw else { throw WorkspaceError.invalid("family local full replay differs") }
            return ready
        }
        return nil
    }
    /// Reads retained, validated incoming data only; it never contacts a provider
    /// or turns conflicting settings into a usable business view.
    public static func conflictState(paths: WorkspacePaths) throws -> ReviewFamilyHostConflictState {
        try flowLock(paths: paths) {
            let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken(); try token.validate(for: paths)
            guard let connection = try readConnection(paths: paths) else { throw WorkspaceError.invalid("family Host connection missing") }
            try authorize(paths: paths, selection: connection.selection); try requireNoPendingWrite(paths: paths)
            return try conflictView(paths: paths, state: paths.readState(), connection: connection).choice
        }
    }
    private static func conflictView(paths: WorkspacePaths, state: StateHandle, connection: ReviewFamilyConnection) throws
        -> (choice: ReviewFamilyHostConflictState, baseline: ReviewSettingsCausalCheckpoint, incoming: [ReviewNativeRevision], fields: ReviewCausalFieldCheckpoint) {
        let settings = try settings(paths: paths, state: state)
        guard let baseline = try baseline(paths: paths, state: state, settings: settings, selection: connection.selection),
              baseline.causal.values == (try ReviewFieldDocuments.capture(state: state, settings: settings)) else {
            throw WorkspaceError.invalid("请先发布本机已保存的修改，再核对并发版本。")
        }
        let transport = try ReviewRevisionTransportEngine(remote: connection.remote,
            cache: local(paths).appendingPathComponent("incoming/" + connection.selection.bindingID), context: .init(connection.selection))
        let incoming = try ReviewRevisionTransportEngine.cachedRevisions(cache: transport.cache, context: .init(connection.selection))
        let fields: ReviewCausalFieldCheckpoint
        switch try ReviewSettingsCausalFields.append(incoming, to: baseline, bindingID: connection.selection.bindingID, context: settings.context) {
        case .ready(let ready): fields = ready.causal
        case .conflicted(let conflicted, _): fields = conflicted
        case .waiting: throw WorkspaceError.invalid("等待完整修改 ancestors，再核对并发版本。")
        }
        return (.init(selection: connection.selection, state: state.pointer, fields: fields), baseline, incoming, fields)
    }
    /// All displayed choices are submitted together so settings documents are
    /// pair-validated before any business state or publication is changed.
    public static func resolveConflicts(paths: WorkspacePaths, expected: ReviewFamilyHostConflictState, choices: [String: String]) throws -> StateHandle {
        try flowLock(paths: paths) {
            let token = try WorkspaceCoordinator(paths: paths).acquireWriteToken()
            guard let connection = try readConnection(paths: paths), connection.selection == expected.selection else { throw WorkspaceError.stalePointer }
            try authorize(paths: paths, selection: connection.selection); try requireNoPendingWrite(paths: paths)
            let state = try paths.readState(), view = try conflictView(paths: paths, state: state, connection: connection)
            guard state.pointer == expected.state, view.fields.inventoryHash == expected.inventoryHash,
                  !choices.isEmpty, Set(choices.keys) == Set(view.choice.options.keys),
                  choices.allSatisfy({ key, value in view.choice.options[key]?.contains(where: { Data($0.utf8) == Data(value.utf8) }) == true }) else { throw WorkspaceError.stalePointer }
            let clockFile = paths.device.appendingPathComponent("revision-clock-family.json")
            var clock = view.fields.revisions.map { $0.revision.clock }.max() ?? 0
            if FileManager.default.fileExists(atPath: clockFile.path) {
                let raw = try WorkspaceIO.read(clockFile); try connection.selection.validate(marker: raw)
                let reserved = try WorkspaceIO.integer(raw, field: "reserved_clock")
                guard reserved >= 0, reserved < Int64(Int.max) else { throw WorkspaceError.invalid("family clock exhausted") }; clock = max(clock, Int(reserved))
            }
            guard clock < Int.max else { throw WorkspaceError.invalid("family clock exhausted") }; clock += 1
            let revision = try ReviewNativeRevision(sourceBindingID: connection.selection.bindingID, raw: JSONEncoder().encode(ReviewRevision(id: UUID().uuidString.lowercased(), device: connection.selection.hostID, clock: clock, values: choices,
                bases: choices.mapValues { _ in "null" }, observed: view.fields.observed, parents: view.fields.frontier)))
            let settings = try settings(paths: paths, state: state)
            guard case .ready = try ReviewSettingsCausalFields.append(view.incoming + [revision], to: view.baseline,
                bindingID: connection.selection.bindingID, context: settings.context) else { throw WorkspaceError.invalid("所选设置不能组成完整有效的家庭设置。") }
            var reservation = connection.selection.document; reservation["reserved_clock"] = clock
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(reservation), to: clockFile)
            return try capture(paths: paths, state: state, selection: connection.selection, token: token, creating: false, incoming: view.incoming + [revision])
        }
    }
    private static func capture(paths: WorkspacePaths, state: StateHandle, selection: ReviewFamilyBindingSelection,
                                token: WorkspaceWriteToken, creating: Bool, incoming: [ReviewNativeRevision]) throws -> StateHandle {
        let settings = try settings(paths: paths, state: state), actual = try ReviewFieldDocuments.capture(state: state, settings: settings)
        let baseline = try baseline(paths: paths, state: state, settings: settings, selection: selection)
        var revisions = baseline?.causal.revisions ?? []
        let seed = baseline?.causal.seedValues ?? actual, prior = baseline?.causal
        if creating {
            let row = try WorkspaceIO.object(WorkspaceIO.read(intent(paths)))
            guard let initial = row["initial_values"] as? [String: String], initial == seed, actual == seed, revisions.isEmpty else { throw WorkspaceError.invalid("新家庭首次发布前的资料已改变，请保留资料并核对。") }
        }
        guard incoming.allSatisfy({ $0.origin.sourceBindingID == selection.bindingID }) else { throw WorkspaceError.invalid("foreign native family incoming revision") }
        if let prior, prior.values == actual, incoming.isEmpty { return state }
        var added: ReviewNativeRevision?
        if let prior, prior.values != actual {
            var changes = [String: String](), bases = [String: String]()
            for key in Set(actual.keys).union(prior.values.keys) where actual[key] != prior.values[key] {
                changes[key] = actual[key] ?? "null"; bases[key] = prior.values[key] ?? "null"
            }
            let clockFile = paths.device.appendingPathComponent("revision-clock-family.json")
            var clock = revisions.map { $0.revision.clock }.max() ?? 0
            if FileManager.default.fileExists(atPath: clockFile.path) {
                let raw = try WorkspaceIO.read(clockFile); try selection.validate(marker: raw)
                let reserved = try WorkspaceIO.integer(raw, field: "reserved_clock")
                guard reserved >= 0, reserved < Int64(Int.max) else { throw WorkspaceError.invalid("family clock exhausted") }; clock = max(clock, Int(reserved))
            }
            guard clock < Int.max else { throw WorkspaceError.invalid("family clock exhausted") }; clock += 1
            var reservation = selection.document; reservation["reserved_clock"] = clock
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(reservation), to: clockFile)
            added = try ReviewNativeRevision(sourceBindingID: selection.bindingID, raw: JSONEncoder().encode(ReviewRevision(id: UUID().uuidString.lowercased(), device: selection.hostID, clock: clock, values: changes, bases: bases,
                observed: prior.observed, parents: prior.frontier)))
            revisions.append(added!)
        }
        let replayOrigins = try revisions.map { revision in
            try revision.verifiedOrigin ?? ReviewRevisionOrigin(sourceBindingID: revision.origin.sourceBindingID, sources: Array(revision.rawSources.values))
        }
        guard case .ready(let captured) = try ReviewSettingsCausalFields.prepareInventory(seedValues: seed, origins: replayOrigins, bindingID: selection.bindingID, context: settings.context),
              captured.causal.values == actual else { throw WorkspaceError.invalid("family saved-field capture differs") }
        let checkpoint: ReviewSettingsCausalCheckpoint
        switch try ReviewSettingsCausalFields.append(incoming, to: captured, bindingID: selection.bindingID, context: settings.context) {
        case .ready(let value): checkpoint = value
        case .waiting: throw WorkspaceError.invalid("等待完整客户端修改 ancestors；本机资料与接收缓存已保留。")
        case .conflicted(_, let fields): throw WorkspaceError.invalid("家庭设置存在并发修改，需核对：" + fields.joined(separator: ", "))
        }
        if let prior, prior.inventory == checkpoint.causal.inventory, try prior.fieldState() == checkpoint.causal.fieldState() { return state }
        let appliesBusinessChanges = checkpoint.causal.values != actual
        let tx = try WorkspaceCoordinator(paths: paths).beginFamilyHostMetadata(token: token, expectedPointer: state.pointer)
        do {
            try WorkspaceIO.atomicWrite(checkpoint.causal.fieldState(), to: tx.file("review/field-state.json", token: token))
            try WorkspaceIO.atomicWrite(checkpoint.causal.inventory, to: tx.file("review/revision-inventory.json", token: token))
            for revision in checkpoint.causal.revisions { for (hash, bytes) in revision.rawSources {
                let file = try tx.file("history/edits/" + revision.origin.sourceBindingID + "/" + hash + ".json", token: token)
                if FileManager.default.fileExists(atPath: file.path) { guard try WorkspaceIO.read(file) == bytes else { throw WorkspaceError.invalid("immutable family origin archive changed") } }
                else { try WorkspaceIO.atomicWrite(bytes, to: file) }
            } }
            if appliesBusinessChanges {
                try ReviewFieldDocuments.writeFamily(values: checkpoint.causal.values, settings: checkpoint.settings, transaction: tx, token: token)
                _ = try NativeWorkspaceEffects.record(transaction: tx, token: token)
            }
            _ = try tx.prepare(token: token, validator: { root in
                try WorkspaceBusinessValidator.validate(root)
                if !appliesBusinessChanges { guard try ReviewWorkspaceMembership.currentEntities(root: root) == ReviewWorkspaceMembership.currentEntities(root: state.root) else { throw WorkspaceError.invalid("family capture changed business entities") } }
                let ledger = try WorkspaceIO.read(WorkspaceIO.safeChild(root, "operation-results.json"))
                try ReviewWorkspaceMembership.validate(root: root, ledgerRaw: ledger, workspaceID: selection.workspaceID,
                    stateID: WorkspaceIO.string(WorkspaceIO.object(ledger), "state_id"))
            })
            let committed = try tx.commit(token: token)
            WorkspaceReclamation.collectWhileHoldingWrite(paths: paths, token: token)
            return committed
        } catch {
            if let current = try? paths.readState(), current.pointer.stateID == tx.stateID { return current }
            try? tx.abandon(token: token); throw error
        }
    }
    private static func bundle(paths: WorkspacePaths, state: StateHandle, selection: ReviewFamilyBindingSelection,
                               settings: HouseholdSettingsState) throws -> ReviewCheckpointBundle {
        guard let files = try WorkspaceIO.object(WorkspaceIO.read(state.manifest))["files"] as? [String: String] else { throw WorkspaceError.invalid("family host state file map") }
        func pin(_ path: String) throws -> String {
            guard let hash = files[path] else { throw WorkspaceError.invalid("family host missing state file: " + path) }
            return hash
        }
        var objects = [String: URL](), snapshot = [String: String](), assets = [[String: Any]]()
        for (path, hash) in files { objects[hash] = try state.file(path) }
        let stateHash = state.pointer.manifestHash; objects[stateHash] = state.manifest
        for name in ["financial-review.json", "payment-evidence.json", "field-state.json"] { snapshot[name] = try pin("review/" + name) }
        for mapping in ReviewSettingsFieldDocuments.mappings { snapshot[mapping.snapshotPath] = try pin(mapping.statePath) }
        snapshot["state-manifest.json"] = stateHash; snapshot["request-results.json"] = try pin("operation-results.json")
        let snapshotStatePaths = Set(["review/financial-review.json", "review/payment-evidence.json", "review/field-state.json", "review/revision-inventory.json", "operation-results.json"] + ReviewSettingsFieldDocuments.mappings.map(\.statePath))
        let originalPaths = Set(settings.sources.map(\.path))
        for (path, hash) in files.sorted(by: { $0.key < $1.key }) where !snapshotStatePaths.contains(path) && !path.hasPrefix("history/sync-") {
            // Report references are relative to review; full retained sources,
            // databases and all other state dependencies keep their state path.
            let relative = path.hasPrefix("review/") ? String(path.dropFirst(7)) : path
            let ext = URL(fileURLWithPath: relative).pathExtension.lowercased(), kind: String
            switch ext { case "png", "jpg", "jpeg", "webp", "heic": kind = "image"
            case "txt", "json": kind = "text"; case "pdf": kind = "pdf"; case "csv": kind = "csv"; case "xlsx": kind = "xlsx"
            case "mov", "mp4", "m4v": kind = "video"; default: kind = "review" }
            let original = originalPaths.contains(path) || kind == "video"
            assets.append(["path": relative, "sha256": hash, "kind": kind,
                           "download": original ? "on-demand" : "required", "required_financial": kind != "video",
                           "role": original ? "original" : "preview"])
        }
        func attach(_ raw: Data) throws -> String {
            let hash = WorkspaceIO.digest(raw), file = local(paths).appendingPathComponent("publication-objects/" + hash)
            if FileManager.default.fileExists(atPath: file.path) { guard try WorkspaceIO.read(file) == raw else { throw WorkspaceError.invalid("family immutable bundle object") } }
            else { try WorkspaceIO.atomicWrite(raw, to: file) }
            objects[hash] = file; return hash
        }
        let assetHash = try attach(WorkspaceIO.canonical(["assets": assets]))
        snapshot["asset-manifest.json"] = assetHash
        snapshot["business-proof.json"] = try attach(ReviewClientBusinessProof.build(state: state, selection: selection, settings: settings, assetManifestHash: assetHash))
        guard let results = try WorkspaceIO.object(WorkspaceIO.read(state.operationResults))["results"] as? [[String: Any]] else { throw WorkspaceError.invalid("family host result ledger") }
        let included = try results.filter { $0["outcome"] as? String == "success" }.map { try WorkspaceIO.string($0, "request_id") }.sorted()
        let field = try WorkspaceIO.object(WorkspaceIO.read(state.file("review/field-state.json")))
        let manifest: [String: Any] = ["workspace_id": selection.workspaceID,
            "binding_id": selection.bindingID, "host_id": selection.hostID, "min_reader_version": "1.3.0", "min_writer_version": "1.3.0",
            "sequence": selection.initialSequence, "parent_generation": NSNull(), "state": state.pointer.document,
            "files": snapshot, "revision_frontier": field["frontier"] ?? [], "covered_revision_inventory": try pin("review/revision-inventory.json"),
            "request_results": try pin("operation-results.json"), "asset_manifest": assetHash, "included_requests": included]
        return ReviewCheckpointBundle(manifest: try WorkspaceIO.canonical(manifest), objects: objects)
    }
    private static func context(paths: WorkspacePaths, selection: ReviewFamilyBindingSelection, manifest: Data, publicationTemplate: Bool = false) throws -> ReviewFamilySnapshotContext {
        let cp = try WorkspaceIO.object(manifest)
        guard cp["workspace_id"] as? String == selection.workspaceID, cp["binding_id"] as? String == selection.bindingID else { throw WorkspaceError.invalid("family context binding") }
        let state = try paths.readState(validateFiles: false)
        let settings = try settings(paths: paths, state: state)
        return .init(sourceBindings: [selection.bindingID], settings: settings.context)
    }
    private static func settings(paths: WorkspacePaths, state: StateHandle) throws -> HouseholdSettingsState {
        return try HouseholdSettingsState.read(paths: paths, state: state, currencyCodes: ["CNY"], referencedMemberIDs: [], referencedAccountIDs: [])
    }
    private static func selection(_ raw: Data) throws -> ReviewFamilyBindingSelection {
        let row = try WorkspaceIO.object(raw)
        let value = try ReviewFamilyBindingSelection(workspaceID: WorkspaceIO.string(row, "workspace_id"), bindingID: WorkspaceIO.string(row, "binding_id"),
            hostID: WorkspaceIO.string(row, "host_id"), initialSequence: WorkspaceIO.integer(raw, field: "initial_sequence"))
        try value.validate(marker: raw); return value
    }
    private static func saveConnection(_ connection: ReviewFamilyConnection, paths: WorkspacePaths) throws {
        var row = connection.selection.document; row["role"] = "host"; row["authority"] = "new-binding"
        row["remote_path"] = connection.remote.path; row["bookmark"] = connection.bookmark?.base64EncodedString() as Any? ?? NSNull()
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(row), to: descriptor(paths))
    }
    private static func requireFreshIdentity(paths: WorkspacePaths) throws {
        try WorkspaceCompatibility.requireWriter(paths: paths)
    }
    private static func rejectOtherSelections(paths: WorkspacePaths) throws {
        for name in ["client-active.json", "client-identity.json", "retired-bindings-family.json"] {
            let file = paths.device.appendingPathComponent(name); try WorkspaceIO.rejectSymlinks(file)
            guard !FileManager.default.fileExists(atPath: file.path) else { throw WorkspaceError.invalid("当前 family selection 不是新家庭 Host。") }
        }
    }
    fileprivate static func authorize(paths: WorkspacePaths, selection: ReviewFamilyBindingSelection) throws {
        try WorkspaceCompatibility.requireWriter(paths: paths)
        try requireFreshIdentity(paths: paths); try rejectOtherSelections(paths: paths)
        let raw = try WorkspaceIO.read(grant(paths)), row = try WorkspaceIO.object(raw)
        try selection.validate(marker: raw)
        let identity = try WorkspaceIO.object(WorkspaceIO.read(paths.device.appendingPathComponent("device-identity.json")))
        guard row["role"] as? String == "host", row["authority"] as? String == "new-binding", row["device_id"] as? String == selection.hostID,
              identity["device_id"] as? String == selection.hostID, row["metadata_hash"] as? String == (try WorkspaceIO.hash(paths.metadata)),
              try paths.readPointer().workspaceID == selection.workspaceID else { throw WorkspaceError.invalid("本机新家庭 Host 授权失效。") }
        let creation = try WorkspaceIO.read(intent(paths)); try selection.validate(marker: creation)
        
    }
    private static func authorityLock<T>(paths: WorkspacePaths, _ body: () throws -> T) throws -> T { try lock(paths.device.appendingPathComponent("locks/host-authority-family.lock"), body) }
    private static func flowLock<T>(paths: WorkspacePaths, _ body: () throws -> T) throws -> T { try lock(paths.device.appendingPathComponent("locks/host-flow-family.lock"), body) }
    private static func lock<T>(_ file: URL, _ body: () throws -> T) throws -> T {
        try WorkspaceIO.rejectSymlinks(file); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw WorkspaceError.io("family local authority lock") }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WorkspaceError.busy }; defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// Bounded native Host polling. The retained cursor is a scheduling hint only:
/// every changed state/origin still goes through the complete real publication.
public actor ReviewFamilySyncDriver {
    private let paths: WorkspacePaths, connection: ReviewFamilyConnection
    private let transport: ReviewFamilyRevisionTransport
    private var incoming = [ReviewNativeRevision]()
    private var seen = [String: String]()
    private var loaded = false
    private var publishedState: WorkspaceStatePointer?
    private var generation: String?
    private var sequence: Int64?
    private var dirty = true
    private let scheduler = ReviewHostWriteScheduler()
    #if os(macOS)
    private let requests: ReviewFamilyRequestTransport
    private var processingRequest = false
    #endif
    private var polling = false
    internal private(set) var publicationCount = 0
    public init(paths: WorkspacePaths, connection: ReviewFamilyConnection) throws {
        self.paths = paths; self.connection = connection
        #if os(macOS)
        requests = try ReviewFamilyRequestTransport(remote: connection.remote,
            cache: paths.device.appendingPathComponent("family-host-requests/" + connection.selection.bindingID), selection: connection.selection)
        #endif
        transport = try ReviewFamilyRevisionTransport(remote: connection.remote, cache: paths.device.appendingPathComponent("family-sync/incoming"), selection: connection.selection)
    }
    public func synchronize() async throws -> String {
        guard !polling else { throw WorkspaceError.busy }
        polling = true; defer { polling = false }
        let paths = paths, connection = connection
        let pointer = try await ReviewSyncDetached.run {
            try ReviewFamilyHost.authorize(paths: paths, selection: connection.selection)
            guard let saved = try ReviewFamilyHost.readConnection(paths: paths), saved.selection == connection.selection,
                  saved.remote.path == connection.remote.path else { throw WorkspaceError.stalePointer }
            return try paths.readPointer()
        }
        let result = try await transport.poll(outgoing: [])
        var changed = !loaded
        for revision in result.revisions {
            let id = revision.origin.revisionID, hash = revision.origin.payloadHash
            if let prior = seen[id], prior != hash { throw WorkspaceError.invalid("family incoming revision identity changed") }
            if seen[id] == nil { changed = true }
        }
        if changed {
            dirty = true
            incoming = try await transport.cachedRevisions()
            seen = Dictionary(uniqueKeysWithValues: incoming.map { ($0.origin.revisionID, $0.origin.payloadHash) })
            loaded = true
        }
        let pending = FileManager.default.fileExists(atPath: paths.device.appendingPathComponent("host-publication-family.json").path)
        var sameProviderHead = false
        if let generation, let sequence {
            sameProviderHead = try await ReviewSyncDetached.run {
                let raw = try ReviewSyncIO.read(connection.remote.appendingPathComponent("current.json"), limit: 4096)
                try connection.selection.validate(marker: raw)
                let row = try WorkspaceIO.object(raw)
                return try row["generation"] as? String == generation && WorkspaceIO.integer(raw, field: "sequence") == sequence
            }
        }
        if !dirty, !pending, publishedState == pointer, sameProviderHead, let generation { return generation }
        let incoming = incoming
        let publication = try await scheduler.run(kind: .readySync) {
            try await ReviewSyncDetached.run { try ReviewFamilyHost.publishForDriver(paths: paths, expected: connection, incoming: incoming) }
        }
        let published = publication.generation
        // Pin the actual published tuple, never a later read of the live pointer:
        // a writer can save immediately after publish releases its gate.
        let tuple = try await ReviewSyncDetached.run {
            let file = paths.device.appendingPathComponent("family-sync/" + connection.selection.bindingID + "/snapshots/" + published)
            let raw = try ReviewSyncIO.read(file, limit: 16 * 1024 * 1024)
            guard WorkspaceIO.digest(raw) == published,
                  let state = try ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: ["state"]) else { throw WorkspaceError.invalid("published family state pin") }
            let row = try WorkspaceIO.object(state)
            return try (WorkspaceStatePointer(workspaceID: connection.selection.workspaceID, stateID: WorkspaceIO.string(row, "state_id"),
                localRevision: WorkspaceIO.integer(state, field: "local_revision"), manifestHash: WorkspaceIO.string(row, "state_manifest_hash")),
                WorkspaceIO.integer(raw, field: "sequence"))
        }
        publishedState = tuple.0; sequence = tuple.1; generation = published
        // Resuming an existing frozen publication ignores newly polled incoming
        // origins. Keep the union pending for one fresh capture/publication; only
        // that subsequent non-recovery pass may return to the idle fast path.
        dirty = publication.resumed; publicationCount += 1
        return published
    }
    public func runWriter<T: Sendable>(kind: ReviewHostWriteScheduler.WorkKind,
                                      operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await scheduler.run(kind: kind, operation: operation)
    }
    #if os(macOS)
    public func hasPendingRequests() async throws -> Bool {
        let received = try await requests.poll()
        guard !received.requests.isEmpty else { return false }
        let paths = paths, selection = connection.selection
        return try await ReviewSyncDetached.run {
            try ReviewFamilyHost.requireProcessor(paths: paths, selection: selection)
            let state = try paths.readState()
            try ReviewWorkspaceMembership.validate(state: state)
            let ledger = try WorkspaceIO.object(WorkspaceIO.read(state.operationResults))
            guard let results = ledger["results"] as? [[String: Any]] else { throw WorkspaceError.invalid("request ledger") }
            let indexed = try ReviewFamilyRequestTransport.resultIndex(results)
            return received.requests.contains { request in
                guard let result = indexed[request.id] else { return true }
                return !request.matches(result: result)
            }
        }
    }
    /// Requests are admitted only after all retained originals are available.
    /// Committed operation membership handles retries after a lost receipt.
    public func processRequests(runtime: ProcessorRuntime) async throws {
        guard !processingRequest else { return }
        processingRequest = true; defer { processingRequest = false }
        let received = try await requests.poll()
        for request in received.requests {
            try Task.checkCancellation()
            let paths = paths, selection = connection.selection
            let prepared = try await ReviewSyncDetached.run {
                try ReviewFamilyRequestProcessor.prepare(request: request, paths: paths, selection: selection)
            }
            if prepared.verifiedExistingResult != nil { continue }
            _ = try await scheduler.run(kind: .processor) {
                let token = try await ReviewSyncDetached.run { try WorkspaceCoordinator(paths: paths).acquireWriteToken() }
                return try await ReviewFamilyRequestProcessor.run(prepared: prepared, runtime: runtime, paths: paths, token: token)
            }
            // The next ordinary synchronize publishes the committed ledger.
            dirty = true
            return
        }
    }
    #endif

}
