import Foundation
import XCTest
@testable import PaymentImageCore

/// Internal test issuer only. No production qualification factory is supplied
/// by this test owner, and public clients cannot construct the opaque permit.
final class PublicationTestOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    func revoke(_ value: Bool) { lock.lock(); revoked = value; lock.unlock() }
    func authorized(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !revoked else { throw WorkspaceError.invalid("test local authority revoked") }; try body()
    }
}
@MainActor final class ReviewFamilySnapshotPublisherTests: XCTestCase {
    typealias Packet = ReviewFamilySnapshotPayloadTests.Packet
    enum Crash: Error { case injected }
    func make() throws -> Packet {
        var p = try ReviewFamilySnapshotPayloadTests().make(heads: true)
        let state = try p.fixture.paths.readState()
        for origin in p.origins {
            for (hash, bytes) in origin.sources {
                let path = "history/edits/" + origin.key.sourceBindingID + "/" + hash + ".json"
                try WorkspaceIO.atomicWrite(bytes, to: state.file(path))
            }
        }
        var doc = try WorkspaceIO.object(WorkspaceIO.read(state.manifest)), files = [String: String]()
        for path in try WorkspaceIO.regularFiles(state.root) where path != "state-manifest.json" { files[path] = try WorkspaceIO.hash(state.file(path)) }
        doc["files"] = files; let raw = try WorkspaceIO.canonical(doc); try WorkspaceIO.atomicWrite(raw, to: state.manifest)
        let pointer = WorkspaceStatePointer(workspaceID: state.pointer.workspaceID, stateID: state.pointer.stateID, localRevision: state.pointer.localRevision, manifestHash: WorkspaceIO.digest(raw))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pointer.document), to: p.fixture.paths.activeState)
        try p.set("state-manifest.json", raw)
        p.manifest["state"] = ["state_id": pointer.stateID, "local_revision": pointer.localRevision, "state_manifest_hash": pointer.manifestHash]
        let settings = try HouseholdSettingsState.read(paths: p.fixture.paths, currencyCodes: ["CNY", "USD"], referencedMemberIDs: [], referencedAccountIDs: [])
        let proof = try ReviewClientBusinessProof.build(state: p.fixture.paths.readState(), selection: p.selection, settings: settings, assetManifestHash: p.manifest["asset_manifest"] as! String)
        try p.set("business-proof.json", proof)
        return p
    }
    func context(_ p: Packet) -> ReviewFamilySnapshotContext { .init(sourceBindings: p.bindings, settings: ReviewFamilySnapshotPayloadTests().context()) }
    func publisher(_ p: Packet, writerVersion: String = "1.3.0") throws -> ReviewFamilySnapshotPublisher {
        try .init(remote: p.fixture.paths.workspace.appendingPathComponent("family-host-provider"), local: p.fixture.paths.device.appendingPathComponent("family-host"), selection: p.selection, writerVersion: writerVersion)
    }
    func permit(_ p: Packet, owner: PublicationTestOwner) throws -> ReviewFamilyPublicationPermit {
        let context = context(p)
        return .init(selection: p.selection, workspace: p.fixture.paths.workspace,
            withAuthority: { body in try owner.authorized(body) }, contextForGeneration: { _, _ in context })
    }
    func freeze(_ p: Packet, publisher: ReviewFamilySnapshotPublisher, permit: ReviewFamilyPublicationPermit) throws -> ReviewFamilyFrozenPublication {
        let token = try WorkspaceCoordinator(paths: p.fixture.paths).acquireWriteToken()
        return try publisher.freeze(paths: p.fixture.paths, bundle: .init(manifest: p.raw(), objects: p.objects), context: context(p), permit: permit, token: token)
    }
    func testStateFreezePublishesOriginalsAndCurrentOriginsAndReaderReopens() throws {
        let p = try make(); defer { p.fixture.remove() }
        let publisher = try publisher(p), owner = PublicationTestOwner(), permit = try permit(p, owner: owner)
        try publisher.createBinding(permit: permit)
        let frozen = try freeze(p, publisher: publisher, permit: permit), old = try p.fixture.paths.readPointer()
        let generation = try publisher.publish(frozen, paths: p.fixture.paths, permit: permit)
        let reader = try ReviewFamilySnapshotStore(remote: publisher.remote, local: p.fixture.paths.device.appendingPathComponent("host-reader"), selection: p.selection)
        guard case .ready(let cached) = try reader.prepare(contextForGeneration: { _, _ in self.context(p) }) else { return XCTFail("published generation not readable") }
        XCTAssertEqual(cached.generation, generation); XCTAssertEqual(cached.payload.coveredRevisions.count, 1)
        for hash in cached.payload.optionalOriginalObjects { XCTAssertTrue(FileManager.default.fileExists(atPath: publisher.remote.appendingPathComponent("objects/" + hash).path)) }
        for origin in p.origins { for hash in origin.sourceHashes { XCTAssertEqual(try WorkspaceIO.read(publisher.remote.appendingPathComponent("objects/" + hash)), origin.sources[hash]) } }
        XCTAssertEqual(try p.fixture.paths.readPointer(), old)
        XCTAssertEqual(try publisher.publish(frozen, paths: p.fixture.paths, permit: permit), generation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.fixture.paths.device.appendingPathComponent("host-authorization.json").path))
    }
    func testRevokedPermitCannotCreateOrPublishAndRevocationAtBarrierKeepsPointerAbsent() throws {
        let p = try make(); defer { p.fixture.remove() }
        let publisher = try publisher(p), owner = PublicationTestOwner(), permit = try permit(p, owner: owner)
        owner.revoke(true); XCTAssertThrowsError(try publisher.createBinding(permit: permit))
        XCTAssertFalse(FileManager.default.fileExists(atPath: publisher.remote.path))
        owner.revoke(false); try publisher.createBinding(permit: permit); let frozen = try freeze(p, publisher: publisher, permit: permit)
        XCTAssertThrowsError(try publisher.publish(frozen, paths: p.fixture.paths, permit: permit, failureInjector: { if $0 == .objectsUploaded { owner.revoke(true) } }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: publisher.remote.appendingPathComponent("current.json").path))
        owner.revoke(false)
        let hash = try publisher.publish(frozen, paths: p.fixture.paths, permit: permit)
        let manifest = try WorkspaceIO.read(publisher.remote.appendingPathComponent("snapshots/" + hash))
        XCTAssertEqual(try WorkspaceIO.integer(manifest, field: "sequence"), 8)
    }
    func testFailureBeforeAndAfterPointerRetriesIdenticalPendingGeneration() throws {
        for point in [ReviewFamilyPublicationPoint.intentSaved, .pointerPublished, .hostJournalSaved] {
            let p = try make(); defer { p.fixture.remove() }
            let publisher = try publisher(p), owner = PublicationTestOwner(), permit = try permit(p, owner: owner)
            try publisher.createBinding(permit: permit); let frozen = try freeze(p, publisher: publisher, permit: permit)
            XCTAssertThrowsError(try publisher.publish(frozen, paths: p.fixture.paths, permit: permit, failureInjector: { if $0 == point { throw Crash.injected } }))
            let intent = try WorkspaceIO.object(WorkspaceIO.read(publisher.local.appendingPathComponent("publication-intent.json")))
            let expected = intent["generation"] as! String
            let actual = try publisher.publish(frozen, paths: p.fixture.paths, permit: permit)
            XCTAssertEqual(actual, expected); XCTAssertEqual(try WorkspaceIO.integer(WorkspaceIO.read(publisher.local.appendingPathComponent("publication-sequence.json")), field: "reserved_sequence"), 7)
            XCTAssertEqual(try publisher.publish(frozen, paths: p.fixture.paths, permit: permit), expected)
        }
    }
    func testPreIntentFailureSpendsSequenceButDoesNotInventUserRevision() throws {
        let p = try make(); defer { p.fixture.remove() }
        let publisher = try publisher(p), owner = PublicationTestOwner(), permit = try permit(p, owner: owner)
        try publisher.createBinding(permit: permit); let frozen = try freeze(p, publisher: publisher, permit: permit)
        XCTAssertThrowsError(try publisher.publish(frozen, paths: p.fixture.paths, permit: permit, failureInjector: { if $0 == .manifestUploaded { throw Crash.injected } }))
        let hash = try publisher.publish(frozen, paths: p.fixture.paths, permit: permit), raw = try WorkspaceIO.read(publisher.remote.appendingPathComponent("snapshots/" + hash))
        XCTAssertEqual(try WorkspaceIO.integer(raw, field: "sequence"), 8); XCTAssertTrue(try WorkspaceIO.object(raw)["parent_generation"] is NSNull)
        XCTAssertEqual(try WorkspaceIO.object(raw)["revision_frontier"] as? [String], p.manifest["revision_frontier"] as? [String])
    }
    func testFrozenFileABAAndDifferentPointerRejectBeforeUpload() throws {
        let p = try make(); defer { p.fixture.remove() }
        let publisher = try publisher(p), owner = PublicationTestOwner(), permit = try permit(p, owner: owner)
        try publisher.createBinding(permit: permit); let frozen = try freeze(p, publisher: publisher, permit: permit)
        let file = try p.fixture.paths.readState().file("config/family-profile.json"), bytes = try WorkspaceIO.read(file)
        try WorkspaceIO.atomicWrite(bytes, to: file)
        XCTAssertThrowsError(try publisher.publish(frozen, paths: p.fixture.paths, permit: permit))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: publisher.remote.appendingPathComponent("objects").path).isEmpty)
    }
    func testMissingCommittedOriginArchiveCannotFreeze() throws {
        let p = try make(); defer { p.fixture.remove() }
        let publisher = try publisher(p), owner = PublicationTestOwner(), good = try permit(p, owner: owner)
        let origin = p.origins[0], path = "history/edits/" + origin.key.sourceBindingID + "/" + origin.sourceHashes[0] + ".json"
        try FileManager.default.removeItem(at: p.fixture.paths.readState().file(path))
        XCTAssertThrowsError(try freeze(p, publisher: publisher, permit: good))
    }
    func testWrongMarkerAndOldWriterCannotPublishAndProviderRollbackRejects() throws {
        let p = try make(); defer { p.fixture.remove() }
        let owner = PublicationTestOwner(), permit = try permit(p, owner: owner), publisher = try publisher(p)
        try publisher.createBinding(permit: permit)
        XCTAssertThrowsError(try freeze(p, publisher: self.publisher(p, writerVersion: "1.1.0"), permit: permit))
        let frozen = try freeze(p, publisher: publisher, permit: permit)
        var marker = p.selection.document; marker["binding_id"] = UUID().uuidString.lowercased()
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(marker), to: publisher.remote.appendingPathComponent("family.json"))
        XCTAssertThrowsError(try publisher.publish(frozen, paths: p.fixture.paths, permit: permit))
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(p.selection.document), to: publisher.remote.appendingPathComponent("family.json"))
        _ = try publisher.publish(frozen, paths: p.fixture.paths, permit: permit)
        try FileManager.default.removeItem(at: publisher.remote.appendingPathComponent("current.json"))
        XCTAssertThrowsError(try publisher.publish(frozen, paths: p.fixture.paths, permit: permit))
    }
}
