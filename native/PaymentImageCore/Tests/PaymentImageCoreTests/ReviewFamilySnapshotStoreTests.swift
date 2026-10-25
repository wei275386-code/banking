import Foundation
import XCTest
@testable import PaymentImageCore

@MainActor final class ReviewFamilySnapshotStoreTests: XCTestCase {
    typealias Packet = ReviewFamilySnapshotPayloadTests.Packet
    func remote(_ p: Packet) -> URL { p.fixture.paths.workspace.appendingPathComponent("family-reader-provider") }
    func context(_ p: Packet) -> ReviewFamilySnapshotContext { .init(sourceBindings: p.bindings, settings: ReviewFamilySnapshotPayloadTests().context()) }
    func store(_ p: Packet) throws -> ReviewFamilySnapshotStore {
        try .init(remote: remote(p), local: p.fixture.paths.device.appendingPathComponent("reader-cache"), selection: p.selection)
    }
    @discardableResult func wire(_ p: Packet, current: Bool = true, omit: Set<String> = []) throws -> String {
        let raw = try p.raw(), hash = WorkspaceIO.digest(raw), root = remote(p)
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(p.selection.document), to: root.appendingPathComponent("family.json"))
        for (hash, file) in p.objects where !omit.contains(hash) {
            try ReviewContentObjectIO.copy(file, to: root.appendingPathComponent("objects/" + hash), hash: hash)
        }
        try WorkspaceIO.atomicWrite(raw, to: root.appendingPathComponent("snapshots/" + hash))
        if current { try point(p, generation: hash, sequence: p.manifest["sequence"] as! Int) }; return hash
    }
    func point(_ p: Packet, generation: String, sequence: Int) throws {
        var pointer = p.selection.document; pointer["generation"] = generation; pointer["sequence"] = sequence
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(pointer), to: remote(p).appendingPathComponent("current.json"))
    }
    func descendant(_ p: Packet, parent: String, sequence: Int = 8) -> Packet {
        var copy = p; copy.manifest["parent_generation"] = parent; copy.manifest["sequence"] = sequence; return copy
    }
    func cached(_ result: ReviewFamilySnapshotPreparation) throws -> ReviewCachedFamilySnapshot {
        switch result { case .ready(let value), .unchanged(let value): return value; default: throw WorkspaceError.invalid("cache not ready") }
    }
    func testRequiredClosureCachesAndReopensOfflineWithoutSelectingClientOrHost() throws {
        let p = try ReviewFamilySnapshotPayloadTests().make(heads: true); defer { p.fixture.remove() }
        let generation = try wire(p), store = try store(p), before = try p.fixture.paths.readPointer()
        let value = try cached(store.prepare { _, _ in self.context(p) })
        XCTAssertEqual(value.generation, generation); XCTAssertEqual(value.payload.coveredRevisions.count, 1)
        for origin in p.origins { for hash in origin.sourceHashes { XCTAssertEqual(try WorkspaceIO.read(store.local.appendingPathComponent("objects/" + hash)), origin.sources[hash]) } }
        for hash in value.payload.optionalOriginalObjects { XCTAssertFalse(FileManager.default.fileExists(atPath: store.local.appendingPathComponent("objects/" + hash).path)) }
        let offline = remote(p).deletingLastPathComponent().appendingPathComponent("provider-offline")
        try FileManager.default.moveItem(at: remote(p), to: offline)
        let reopened = try XCTUnwrap(store.readCached { _, _ in self.context(p) })
        XCTAssertEqual(reopened.generation, generation); XCTAssertEqual(try WorkspaceIO.read(reopened.file("family-profile.json")), try p.file("family-profile.json"))
        XCTAssertEqual(try p.fixture.paths.readPointer(), before)
        for name in ["client-active.json", "host-authorization.json", "family-connection.json"] { XCTAssertFalse(FileManager.default.fileExists(atPath: p.fixture.paths.device.appendingPathComponent(name).path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.local.appendingPathComponent("client-current.json").path))
    }
    func testLatestSnapshotReadsAndBacksUpWithoutAnyAncestor() throws {
        let p = try ReviewFamilySnapshotPayloadTests().make(); defer { p.fixture.remove() }
        let absentParent = WorkspaceIO.digest(Data("removed historical snapshot".utf8))
        let child = descendant(p, parent: absentParent), head = try wire(child), store = try store(p)
        var visited = [String]()
        let ready = try cached(store.prepare { generation, _ in visited.append(generation); return self.context(p) })
        XCTAssertEqual(visited, [head]); XCTAssertEqual(ready.generation, head)
        try FileManager.default.removeItem(at: remote(p))
        let offline = try XCTUnwrap(store.readCached { _, _ in self.context(p) })
        XCTAssertEqual(offline.generation, head)
    }
    func testRollbackAndEqualSequenceForkDoNotReplaceCacheHead() throws {
        let p = try ReviewFamilySnapshotPayloadTests().make(); defer { p.fixture.remove() }
        let root = try wire(p), store = try store(p); _ = try cached(store.prepare { _, _ in self.context(p) })
        let child = descendant(p, parent: root), head = try wire(child)
        _ = try cached(store.prepare { _, _ in self.context(p) })
        let pointer = store.local.appendingPathComponent("cached-snapshot.json"), before = try WorkspaceIO.read(pointer)
        try point(p, generation: root, sequence: 7)
        XCTAssertThrowsError(try store.prepare { _, _ in self.context(p) })
        var equal = child; equal.manifest["min_writer_version"] = "1.2.1"; _ = try wire(equal)
        XCTAssertThrowsError(try store.prepare { _, _ in self.context(p) })
        XCTAssertEqual(try WorkspaceIO.read(pointer), before); XCTAssertEqual(try store.readCached { _, _ in self.context(p) }?.generation, head)
    }
    func testLatestSnapshotDoesNotReadRetiredAncestors() throws {
        let p = try ReviewFamilySnapshotPayloadTests().make(); defer { p.fixture.remove() }
        var ancestor = p; ancestor.manifest["min_reader_version"] = "99.0.0"
        let root = try wire(ancestor, current: false), child = descendant(p, parent: root), store = try store(p)
        let head = try wire(child)
        var visited = [String]()
        let ready = try cached(store.prepare { hash, _ in visited.append(hash); return self.context(p) })
        XCTAssertEqual(visited, [head]); XCTAssertEqual(ready.generation, head)
    }
    func testMissingNewRequiredObjectKeepsPreviousHeadAndRetryCompletes() throws {
        let p = try ReviewFamilySnapshotPayloadTests().make(); defer { p.fixture.remove() }
        let root = try wire(p), store = try store(p); _ = try cached(store.prepare { _, _ in self.context(p) })
        var child = descendant(p, parent: root)
        let extra = Data("{\"mock\":true}".utf8), hash = WorkspaceIO.digest(extra)
        try child.set("extra-report.json", extra); let head = try wire(child, omit: [hash])
        guard case .waiting(let hashes, _) = try store.prepare(contextForGeneration: { _, _ in self.context(p) }) else { return XCTFail("incomplete payload accepted") }
        XCTAssertEqual(hashes, [hash]); XCTAssertEqual(try store.readCached { _, _ in self.context(p) }?.generation, root)
        _ = try wire(child)
        let complete = try cached(store.prepare { _, _ in self.context(p) }); XCTAssertEqual(complete.generation, head)
        XCTAssertEqual(try WorkspaceIO.read(complete.file("extra-report.json")), extra)
        guard case .unchanged(let unchanged) = try store.prepare(contextForGeneration: { _, _ in self.context(p) }) else { return XCTFail("stable head not revalidated") }
        XCTAssertEqual(unchanged.generation, head)
    }
    func testProviderPointerRaceAndCacheLockRejectBeforeHighWaterCommit() throws {
        let p = try ReviewFamilySnapshotPayloadTests().make(); defer { p.fixture.remove() }
        let root = try wire(p), child = descendant(p, parent: root), head = try wire(child, current: false), store = try store(p)
        XCTAssertThrowsError(try store.prepare { _, _ in
            try self.point(p, generation: head, sequence: 8); return self.context(p)
        })
        XCTAssertNil(try store.readCached { _, _ in self.context(p) })
        var lockTested = false
        let ready = try cached(store.prepare { _, _ in
            if !lockTested {
                lockTested = true
                XCTAssertThrowsError(try store.prepare { _, _ in self.context(p) }) { error in
                    guard case WorkspaceError.busy = error else { return XCTFail("wrong lock error \(error)") }
                }
            }
            return self.context(p)
        })
        XCTAssertEqual(ready.generation, head)
    }
    func testCachedCorruptionAndFutureCacheHeadRejectWithoutProviderRepair() throws {
        let p = try ReviewFamilySnapshotPayloadTests().make(heads: true); defer { p.fixture.remove() }
        _ = try wire(p); let store = try store(p); _ = try cached(store.prepare { _, _ in self.context(p) })
        let head = store.local.appendingPathComponent("cached-snapshot.json"), original = try WorkspaceIO.read(head)
        var doc = try WorkspaceIO.object(original); doc["purpose"] = "invalid"; try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(doc), to: head)
        XCTAssertThrowsError(try store.readCached { _, _ in self.context(p) })
        try WorkspaceIO.atomicWrite(original, to: head)
        let alias = p.origins[0].sourceHashes[0], object = store.local.appendingPathComponent("objects/" + alias), bytes = try WorkspaceIO.read(object)
        try WorkspaceIO.atomicWrite(Data("{}".utf8), to: object)
        XCTAssertThrowsError(try store.readCached { _, _ in self.context(p) })
        XCTAssertThrowsError(try store.prepare { _, _ in self.context(p) })
        try WorkspaceIO.atomicWrite(bytes, to: object)
        XCTAssertNotNil(try store.readCached { _, _ in self.context(p) })
    }
    func testStoreRejectsWrongMarkerAndSymlinkAndKeepsBindingsIsolated() throws {
        let p = try ReviewFamilySnapshotPayloadTests().make(); defer { p.fixture.remove() }
        _ = try wire(p); let store = try store(p)
        var marker = p.selection.document; marker["binding_id"] = UUID().uuidString.lowercased()
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(marker), to: remote(p).appendingPathComponent("family.json"))
        XCTAssertThrowsError(try store.prepare { _, _ in self.context(p) }); XCTAssertNil(try store.readCached { _, _ in self.context(p) })
        let link = p.fixture.paths.workspace.appendingPathComponent("linked-reader")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: p.fixture.paths.device)
        XCTAssertThrowsError(try ReviewFamilySnapshotStore(remote: remote(p), local: link, selection: p.selection))
        let shared = try ReviewFamilySnapshotStore(remote: remote(p), local: p.fixture.paths.device.appendingPathComponent("shared-cache"), selection: p.selection)
        XCTAssertTrue(shared.local.path.contains("" + p.selection.bindingID)); XCTAssertNil(try shared.readCached { _, _ in self.context(p) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.fixture.paths.device.appendingPathComponent("shared-cache").appendingPathComponent("cached-snapshot.json").path))
    }
}
