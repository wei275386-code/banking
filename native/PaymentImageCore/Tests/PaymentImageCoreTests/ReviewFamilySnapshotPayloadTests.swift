import Foundation
import XCTest
import CSQLite
@testable import PaymentImageCore

@MainActor final class ReviewFamilySnapshotPayloadTests: XCTestCase {
    struct Packet {
        let fixture: CurrentWorkspaceFixtures.Fixture, selection: ReviewFamilyBindingSelection
        var manifest: [String: Any], objects: [String: URL], bindings: Set<String>
        let origins: [ReviewRevisionOrigin]
        func raw() throws -> Data { try WorkspaceIO.canonical(manifest) }
        func file(_ path: String) throws -> Data { try WorkspaceIO.read(objects[(manifest["files"] as! [String: String])[path]!]!) }
        mutating func attach(_ bytes: Data) throws -> String {
            let hash = WorkspaceIO.digest(bytes), file = fixture.paths.workspace.appendingPathComponent("payload-objects/" + hash)
            try WorkspaceIO.atomicWrite(bytes, to: file); objects[hash] = file; return hash
        }
        mutating func set(_ path: String, _ bytes: Data) throws {
            var files = manifest["files"] as! [String: String]; files[path] = try attach(bytes); manifest["files"] = files
        }
        mutating func resealLedger(_ bytes: Data) throws {
            try set("request-results.json", bytes); manifest["request_results"] = WorkspaceIO.digest(bytes)
            var proof = try WorkspaceIO.object(file("business-proof.json")); proof["request_results"] = WorkspaceIO.digest(bytes)
            try set("business-proof.json", WorkspaceIO.canonical(proof))
            try resealStateFile("operation-results.json", hash: WorkspaceIO.digest(bytes))
        }
        mutating func resealStateFile(_ path: String, hash: String) throws {
            var state = try WorkspaceIO.object(file("state-manifest.json")), files = state["files"] as! [String: String]
            files[path] = hash; state["files"] = files
            let stateRaw = try WorkspaceIO.canonical(state); try set("state-manifest.json", stateRaw)
            var tuple = manifest["state"] as! [String: Any]; tuple["state_manifest_hash"] = WorkspaceIO.digest(stateRaw); manifest["state"] = tuple
            var proof = try WorkspaceIO.object(file("business-proof.json")); proof["state_manifest_hash"] = WorkspaceIO.digest(stateRaw)
            try set("business-proof.json", WorkspaceIO.canonical(proof))
        }
    }
    func context() -> HouseholdSettingsContext { .init(registeredSourceIDs: ["source-a", "source-b"], currencyCodes: ["CNY", "USD"], referencedMemberIDs: [], referencedAccountIDs: []) }
    func make(heads: Bool = false) throws -> Packet {
        let f = try CurrentWorkspaceFixtures.make(), initial = try f.paths.readState()
        let golden = try ReviewFamilyRevisionTransportTests().settings()
        let selection = try ReviewFamilyBindingSelection(workspaceID: initial.pointer.workspaceID, bindingID: UUID().uuidString.lowercased(), hostID: f.selection.hostID, initialSequence: 7)
        var sources = [[String: String]]()
        for (index, id) in ["source-a", "source-b"].enumerated() {
            let bytes = Data("mock-source-\(index)".utf8), hash = WorkspaceIO.digest(bytes), path = "sources/" + hash + "/mock.csv"
            try WorkspaceIO.atomicWrite(bytes, to: initial.file(path)); sources.append(["id": id, "path": path, "sha256": hash, "platform": "mock"])
        }
        try WorkspaceIO.atomicWrite(golden.profileData, to: initial.file("config/family-profile.json"))
        try WorkspaceIO.atomicWrite(golden.policiesData, to: initial.file("config/account-policies.json"))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["sources": sources]), to: initial.file("config/review-import-sources.json"))
        var files = [String: String]()
        for path in try WorkspaceIO.regularFiles(initial.root) where path != "state-manifest.json" { files[path] = try WorkspaceIO.hash(initial.file(path)) }
        let stateRaw = try WorkspaceIO.canonical(["workspace_id": initial.pointer.workspaceID, "state_id": initial.pointer.stateID, "local_revision": initial.pointer.localRevision, "files": files])
        try WorkspaceIO.atomicWrite(stateRaw, to: initial.manifest)
        let pointer = WorkspaceStatePointer(workspaceID: initial.pointer.workspaceID, stateID: initial.pointer.stateID, localRevision: initial.pointer.localRevision, manifestHash: WorkspaceIO.digest(stateRaw))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pointer.document), to: f.paths.activeState)
        var origins = [ReviewRevisionOrigin](); let bindings: Set<String> = [selection.bindingID]
        if heads {
            let profile = try ReleaseCanonicalJSON.replacingObjectMember(raw: golden.profileData, key: "household_name", valueRaw: Data("\"Changed mock\"".utf8))
            let raw = try JSONEncoder().encode(ReviewRevision(id: UUID().uuidString.lowercased(), device: "family-mock", clock: 2, values: ["settings/family-profile": String(decoding: profile, as: UTF8.self)], bases: [:], observed: [:], parents: origins.map { $0.key.revisionID }))
            origins.append(try ReviewRevisionOrigin(sourceBindingID: selection.bindingID, sources: [raw]))
            let token = try WorkspaceCoordinator(paths: f.paths).acquireWriteToken()
            let tx = try WorkspaceCoordinator(paths: f.paths).begin(token: token, expectedPointer: f.paths.readPointer())
            try WorkspaceIO.atomicWrite(profile, to: tx.file("config/family-profile.json", token: token))
            var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(try tx.file("banking.sqlite3", token: token).path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, "UPDATE facts SET amount=9007199254740993 WHERE id='record'", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
            XCTAssertTrue(try NativeWorkspaceEffects.record(transaction: tx, token: token))
            _ = try tx.prepare(token: token, validator: CurrentWorkspaceFixtures.validateBusiness); _ = try tx.commit(token: token)
        }
        guard case .ready(let fields) = try ReviewSettingsCausalFields.prepareInventory(seedValues: ReviewSettingsFieldDocuments.values(golden), origins: origins, bindingID: selection.bindingID, context: context()) else { throw WorkspaceError.invalid("fixture replay") }
        // Assemble synthetic committed metadata explicitly, without granting a
        // writer or activating a household connection.
        let assembled = try f.paths.readState()
        try WorkspaceIO.atomicWrite(fields.causal.fieldState(), to: assembled.file("review/field-state.json"))
        try WorkspaceIO.atomicWrite(fields.causal.inventory, to: assembled.file("review/revision-inventory.json"))
        var stateDocument = try WorkspaceIO.object(WorkspaceIO.read(assembled.manifest)), allFiles = stateDocument["files"] as! [String: String]
        allFiles["review/field-state.json"] = try WorkspaceIO.hash(assembled.file("review/field-state.json"))
        allFiles["review/revision-inventory.json"] = WorkspaceIO.digest(fields.causal.inventory); stateDocument["files"] = allFiles
        let sealed = try WorkspaceIO.canonical(stateDocument); try WorkspaceIO.atomicWrite(sealed, to: assembled.manifest)
        let sealedPointer = WorkspaceStatePointer(workspaceID: assembled.pointer.workspaceID, stateID: assembled.pointer.stateID, localRevision: assembled.pointer.localRevision, manifestHash: WorkspaceIO.digest(sealed))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(sealedPointer.document), to: f.paths.activeState)
        let state = try f.paths.readState(), settings = try HouseholdSettingsState.read(paths: f.paths, currencyCodes: ["CNY", "USD"], referencedMemberIDs: [], referencedAccountIDs: [])
        var packet = Packet(fixture: f, selection: selection, manifest: [:], objects: [:], bindings: bindings, origins: origins)
        var assets = [[String: Any]]()
        func references(_ value: Any) throws {
            if let doc = value as? [String: Any] {
                if let path = doc["path"] as? String, let hash = doc["sha256"] as? String, !assets.contains(where: { $0["path"] as? String == path }) {
                    let file = try WorkspaceIO.safeChild(state.review, path); packet.objects[hash] = file
                    assets.append(["path": path, "sha256": hash, "kind": "image", "download": "required", "required_financial": false])
                }
                for child in doc.values { try references(child) }
            } else if let array = value as? [Any] { for child in array { try references(child) } }
        }
        for name in ["financial-review.json", "payment-evidence.json"] { try references(WorkspaceIO.object(WorkspaceIO.read(state.review.appendingPathComponent(name)))) }
        for source in sources { assets.append(["path": source["path"]!, "sha256": source["sha256"]!, "kind": "csv", "download": "on-demand", "required_financial": true, "role": "original"]) }
        let assetHash = try packet.attach(WorkspaceIO.canonical(["assets": assets]))
        let proof = try ReviewClientBusinessProof.build(state: state, selection: selection, settings: settings, assetManifestHash: assetHash)
        var snapshot = [String: String]()
        for name in ["financial-review.json", "payment-evidence.json"] { snapshot[name] = try packet.attach(WorkspaceIO.read(state.review.appendingPathComponent(name))) }
        snapshot["family-profile.json"] = try packet.attach(settings.settings.profileData); snapshot["account-policies.json"] = try packet.attach(settings.settings.policiesData)
        snapshot["field-state.json"] = try packet.attach(fields.causal.fieldState()); snapshot["state-manifest.json"] = try packet.attach(WorkspaceIO.read(state.manifest))
        snapshot["business-proof.json"] = try packet.attach(proof); snapshot["request-results.json"] = try packet.attach(WorkspaceIO.read(state.operationResults)); snapshot["asset-manifest.json"] = assetHash
        let inventory = try packet.attach(fields.causal.inventory)
        for origin in origins { for bytes in origin.sources.values { _ = try packet.attach(bytes) } }
        let ledger = try WorkspaceIO.object(WorkspaceIO.read(state.operationResults)), results = ledger["results"] as! [[String: Any]]
        packet.manifest = ["workspace_id": selection.workspaceID, "binding_id": selection.bindingID, "host_id": selection.hostID,
            "sequence": 7, "parent_generation": NSNull(), "min_reader_version": "1.3.0", "min_writer_version": "1.3.0", "files": snapshot,
            "revision_frontier": fields.causal.frontier, "covered_revision_inventory": inventory, "included_requests": results.filter { $0["outcome"] as? String == "success" }.map { $0["request_id"] as! String },
            "request_results": snapshot["request-results.json"]!, "asset_manifest": assetHash,
            "state": ["state_id": state.pointer.stateID, "local_revision": state.pointer.localRevision, "state_manifest_hash": state.pointer.manifestHash]]
        return packet
    }
    func prepare(_ packet: Packet, readerVersion: String = "1.3.0") throws -> ReviewFamilyPayloadPreparation {
        let raw = try packet.raw()
        return try ReviewFamilySnapshotPayload.prepare(selection: packet.selection, generation: WorkspaceIO.digest(raw), manifest: raw, objects: packet.objects, sourceBindings: packet.bindings, context: context(), readerVersion: readerVersion)
    }
    func ready(_ packet: Packet) throws -> ReviewValidatedFamilyPayload {
        guard case .ready(let value) = try prepare(packet) else { throw WorkspaceError.invalid("expected ready payload") }; return value
    }
    func testBaselineWithNoSettingsLedgerHeadStillRequiresBothDocumentsAndDoesNotWrite() throws {
        let p = try make(); defer { p.fixture.remove() }
        let before = try p.fixture.paths.readPointer(), names = try WorkspaceIO.regularFiles(p.fixture.paths.workspace)
        let value = try ready(p), proof = try WorkspaceIO.object(p.file("business-proof.json"))
        XCTAssertEqual((proof["documents"] as? [Any])?.count, 0); XCTAssertEqual((proof["settings_documents"] as? [Any])?.count, 2)
        XCTAssertEqual(value.fields.settings.profileData, try p.file("family-profile.json")); XCTAssertTrue(value.coveredRevisions.isEmpty)
        XCTAssertEqual(value.optionalOriginalObjects.count, 2); XCTAssertTrue(value.optionalOriginalObjects.allSatisfy { p.objects[$0] == nil })
        XCTAssertEqual(try p.fixture.paths.readPointer(), before); XCTAssertEqual(try WorkspaceIO.regularFiles(p.fixture.paths.workspace), names)
    }
    func testSettingsHeadAndLosslessDatabaseRowKeepCurrentRawOrigins() throws {
        let p = try make(heads: true); defer { p.fixture.remove() }
        let value = try ready(p), proof = try WorkspaceIO.object(p.file("business-proof.json")), docs = proof["documents"] as! [[String: Any]]
        let head = try XCTUnwrap(docs.first { $0["path"] as? String == "config/family-profile.json" })
        XCTAssertEqual(head["snapshot_path"] as? String, "family-profile.json"); XCTAssertNil(head["raw_base64"])
        XCTAssertTrue(String(decoding: try p.file("business-proof.json"), as: UTF8.self).contains("9007199254740993"))
        XCTAssertEqual(value.coveredRevisions.count, 1); XCTAssertEqual(value.successfulRequests.count, 1)
        for origin in p.origins { for hash in origin.sourceHashes { XCTAssertTrue(value.requiredObjects.contains(hash)) } }
        let dbHash = try WorkspaceIO.hash(p.fixture.paths.readState().file("banking.sqlite3")); XCTAssertNil(p.objects[dbHash])
        var incomplete = p; incomplete.bindings = []; XCTAssertThrowsError(try prepare(incomplete))
    }
    func testResealedProofNegativesReachMembershipAndSettingsMapping() throws {
        let p = try make(heads: true); defer { p.fixture.remove() }
        let original = try WorkspaceIO.object(p.file("business-proof.json"))
        for kind in 0..<8 {
            var copy = p, proof = original
            switch kind {
            case 0: proof["settings_documents"] = []
            case 1: proof["protocol_version"] = 5
            case 2: proof["purpose"] = "invalid"
            case 3: proof["documents"] = []
            case 4:
                var docs = proof["documents"] as! [[String: Any]], row = docs.firstIndex { $0["path"] as? String == "config/family-profile.json" }!
                docs[row]["snapshot_path"] = "account-policies.json"; proof["documents"] = docs
            case 5:
                var docs = proof["documents"] as! [[String: Any]], row = docs.firstIndex { $0["path"] as? String == "config/family-profile.json" }!
                docs[row].removeValue(forKey: "snapshot_path"); docs[row]["raw_base64"] = try p.file("family-profile.json").base64EncodedString(); proof["documents"] = docs
            case 6:
                var dbs = proof["databases"] as! [[String: Any]], tables = dbs[0]["tables"] as! [[String: Any]], rows = tables[0]["rows"] as! [[String: Any]], doc = rows[0]["document"] as! [String: Any]
                doc["amount"] = 999; rows[0]["document"] = doc; tables[0]["rows"] = rows; dbs[0]["tables"] = tables; proof["databases"] = dbs
            default: proof["unknown"] = true
            }
            try copy.set("business-proof.json", WorkspaceIO.canonical(proof)); XCTAssertThrowsError(try prepare(copy), "probe \(kind)")
        }
        XCTAssertNoThrow(try ready(p))
    }
    func testResealedLedgerDigestCannotInventCurrentSettingsMembership() throws {
        var p = try make(heads: true); defer { p.fixture.remove() }
        var ledger = try WorkspaceIO.object(p.file("request-results.json")), results = ledger["results"] as! [[String: Any]], result = results[0], effects = result["membership"] as! [[String: Any]]
        let index = effects.firstIndex { $0["entity_key"] as? String == "document:config/family-profile.json" }!
        effects[index]["digest"] = String(repeating: "a", count: 64); result["membership"] = effects
        let business = try ReleaseCanonicalJSON.removingObjectMembers(raw: WorkspaceIO.canonical(result), keys: ["result_digest", "result_generation", "phase"])
        result["result_digest"] = WorkspaceIO.digest(business); results[0] = result; ledger["results"] = results
        try p.resealLedger(WorkspaceIO.canonical(ledger)); XCTAssertThrowsError(try prepare(p))
    }
    func testFullReplayRejectsResealedFieldsAndSettingsFourWayMismatch() throws {
        let p = try make(); defer { p.fixture.remove() }
        var copy = p
        let changed = try ReleaseCanonicalJSON.replacingObjectMember(raw: p.file("family-profile.json"), key: "household_name", valueRaw: Data("\"Forged\"".utf8))
        try copy.set("family-profile.json", changed); XCTAssertThrowsError(try prepare(copy))
        for key in ["values", "observed", "seed_values"] {
            copy = p; var fields = try WorkspaceIO.object(p.file("field-state.json"))
            if key == "observed" { fields[key] = ["invented-device": 1] }
            else { var values = fields[key] as! [String: String]; values["parameter/invented"] = "42"; fields[key] = values }
            let raw = try WorkspaceIO.canonical(fields); try copy.set("field-state.json", raw)
            try copy.resealStateFile("review/field-state.json", hash: WorkspaceIO.digest(raw))
            XCTAssertThrowsError(try prepare(copy)) { error in
                guard case WorkspaceError.invalid(let detail) = error else { return XCTFail("unexpected \(error)") }
                XCTAssertTrue(detail.contains("complete causal replay"), detail)
            }
        }
    }
    func testMissingRawOriginWaitsAndCorruptOriginRejectsWithoutDroppingWork() throws {
        let p = try make(heads: true); defer { p.fixture.remove() }
        let hash = p.origins[0].sourceHashes[0]; var copy = p; copy.objects.removeValue(forKey: hash)
        guard case .waiting(let missing, let ancestors) = try prepare(copy) else { return XCTFail("missing raw origin became covered") }
        XCTAssertEqual(missing, [hash]); XCTAssertTrue(ancestors.isEmpty)
        copy = p; copy.objects[hash] = copy.objects[(copy.manifest["files"] as! [String: String])["account-policies.json"]!]
        XCTAssertThrowsError(try prepare(copy)); XCTAssertEqual(try ready(p).coveredRevisions.count, 1)
    }
    func testVersionIdentityRequestAndAssetGuardsRejectResealedPackets() throws {
        let p = try make(heads: true); defer { p.fixture.remove() }
        for (key, value) in [("min_reader_version", "99.0.0" as Any), ("min_writer_version", "1.1.0" as Any), ("host_id", UUID().uuidString.lowercased() as Any), ("included_requests", [] as Any)] {
            var copy = p; copy.manifest[key] = value; XCTAssertThrowsError(try prepare(copy), key)
        }
        XCTAssertThrowsError(try prepare(p, readerVersion: "1.1.0"))
        var copy = p, assets = try WorkspaceIO.object(p.file("asset-manifest.json")), rows = assets["assets"] as! [[String: Any]]
        rows[0]["sha256"] = String(repeating: "a", count: 64); assets["assets"] = rows
        let bytes = try WorkspaceIO.canonical(assets); try copy.set("asset-manifest.json", bytes); copy.manifest["asset_manifest"] = WorkspaceIO.digest(bytes)
        var proof = try WorkspaceIO.object(copy.file("business-proof.json")); proof["asset_manifest"] = WorkspaceIO.digest(bytes); try copy.set("business-proof.json", WorkspaceIO.canonical(proof))
        XCTAssertThrowsError(try prepare(copy))
    }
    func testMissingParentsAndSettingsConflictsRemainUnready() throws {
        let p = try make(); defer { p.fixture.remove() }
        for conflict in [false, true] {
            var copy = p, edits = [ReviewRevisionOrigin]()
            for index in 0..<(conflict ? 2 : 1) {
                let profile = try ReleaseCanonicalJSON.replacingObjectMember(raw: p.file("family-profile.json"), key: "household_name", valueRaw: JSONEncoder().encode("Concurrent \(index)"))
                let raw = try JSONEncoder().encode(ReviewRevision(id: UUID().uuidString.lowercased(), device: "mock-\(index)", clock: 1,
                    values: ["settings/family-profile": String(decoding: profile, as: UTF8.self)], bases: [:], observed: [:], parents: conflict ? [] : [UUID().uuidString.lowercased()]))
                edits.append(try .init(sourceBindingID: p.selection.bindingID, sources: [raw])); _ = try copy.attach(raw)
            }
            let inventory = try ReviewRevisionOrigin.inventoryBytes(edits), hash = try copy.attach(inventory)
            copy.manifest["covered_revision_inventory"] = hash
            try copy.resealStateFile("review/revision-inventory.json", hash: hash)
            switch try prepare(copy) {
            case .waiting(let hashes, let ancestors): XCTAssertFalse(conflict); XCTAssertTrue(hashes.isEmpty); XCTAssertEqual(ancestors, Set(edits[0].revision.parents!))
            case .conflicted(let keys): XCTAssertTrue(conflict); XCTAssertEqual(keys, ["settings/family-profile"])
            case .ready: XCTFail("unready payload acquired a validated result")
            }
        }
    }
}
