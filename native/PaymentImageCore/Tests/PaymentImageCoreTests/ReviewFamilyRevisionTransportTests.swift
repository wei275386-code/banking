import Foundation
import XCTest
@testable import PaymentImageCore

@MainActor final class ReviewFamilyRevisionTransportTests: XCTestCase {
    let binding = "22222222-2222-4222-8222-222222222222"
    let oldBinding = "44444444-4444-4444-8444-444444444444"
    let workspace = "11111111-1111-4111-8111-111111111111"
    let host = "33333333-3333-4333-8333-333333333333"
    let field = "settings/family-profile"
    func selection() throws -> ReviewFamilyBindingSelection { try .init(workspaceID: workspace, bindingID: binding, hostID: host, initialSequence: 7) }
    func settings() throws -> HouseholdSettings {
        let raw = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "household-settings-golden", withExtension: "json", subdirectory: "Fixtures")))
        return try .init(profileData: XCTUnwrap(ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: ["profile"])),
            policiesData: XCTUnwrap(ReleaseCanonicalJSON.canonicalFragment(raw: raw, atObjectKeys: ["policies"])), context: context())
    }
    func context() -> HouseholdSettingsContext { .init(registeredSourceIDs: ["source-a", "source-b"], currencyCodes: ["CNY", "USD"], referencedMemberIDs: [], referencedAccountIDs: []) }
    func revision(_ name: String = "Mock", clock: Int = 1, parents: [String] = [], ordinary: Bool = false,
                  source: String? = nil) throws -> ReviewNativeRevision {
        let profile = try ReleaseCanonicalJSON.replacingObjectMember(raw: settings().profileData, key: "household_name", valueRaw: JSONEncoder().encode(name))
        let raw = try JSONEncoder().encode(ReviewRevision(id: UUID().uuidString.lowercased(), device: "mock-phone", clock: clock,
            values: ordinary ? ["parameter/afterTaxSalary": "100"] : [field: String(decoding: profile, as: UTF8.self)], bases: [:], observed: [:], parents: parents))
        return try .init(sourceBindingID: source ?? binding, raw: raw)
    }
    func root() throws -> URL {
        let url = try TestPlatform.temporaryDirectory().appendingPathComponent("family-transport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func writeMarker(_ root: URL, family: Bool = true) throws {
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(selection().document), to: root.appendingPathComponent(family ? "family.json" : "binding-v3.json"))
    }
    func origin(_ revision: ReviewNativeRevision) throws -> ReviewRevisionOrigin {
        try .init(sourceBindingID: revision.origin.sourceBindingID, sources: [revision.raw])
    }
    func objects(_ origins: [ReviewRevisionOrigin]) -> [String: Data] { origins.reduce(into: [:]) { $0.merge($1.sources) { old, _ in old } } }
    func testFamilyTransportRawRoundTripRestartAndCausalAToBToA() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }; try writeMarker(root)
        let cache = root.appendingPathComponent("local-cache")
        let a = try revision("A"), b = try revision("B", clock: 2, parents: [a.revision.id]), back = try revision("A", clock: 3, parents: [b.revision.id])
        let transport = try ReviewFamilyRevisionTransport(remote: root, cache: cache, selection: selection())
        let sent = try await transport.poll(outgoing: [back, a, b])
        XCTAssertEqual(sent.uploadedRevisionIDs, [a.revision.id, b.revision.id, back.revision.id]); XCTAssertTrue(sent.invalidRevisionIDs.isEmpty)
        let restarted = try ReviewFamilyRevisionTransport(remote: root, cache: cache, selection: selection())
        let cached = try await restarted.cachedRevisions()
        XCTAssertEqual(Set(cached.map(\.raw)), [a.raw, b.raw, back.raw])
        guard case .ready(let prepared) = try ReviewSettingsCausalFields.prepare(seedValues: ReviewSettingsFieldDocuments.values(settings()), revisions: cached,
            bindingID: binding, context: context()) else { return XCTFail("round trip not ready") }
        XCTAssertEqual(prepared.causal.frontier, [back.revision.id]); XCTAssertEqual(prepared.causal.values[field], a.revision.values[field])
        let origins = try ReviewRevisionOrigin.inventory(prepared.causal.inventory, objects: Dictionary(uniqueKeysWithValues: cached.map { ($0.origin.payloadHash, $0.raw) }), sourceBindings: [binding])
        guard case .ready(let replayed) = try ReviewSettingsCausalFields.prepare(seedValues: prepared.causal.seedValues, revisions: origins.map { .init(verified: $0) }, bindingID: binding, context: context()) else { return XCTFail("rehydrated replay not ready") }
        XCTAssertEqual(try replayed.causal.fieldState(), try prepared.causal.fieldState())
        for item in [a, b, back] { XCTAssertEqual(try WorkspaceIO.read(root.appendingPathComponent("objects/" + item.origin.payloadHash)), item.raw) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("objects-v3").path))
    }
    func testMissingOrMismatchedMarkerNeverCreatesPayloadOrCache() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }; try writeMarker(root, family: false)
        let edit = try revision(), transport = try ReviewFamilyRevisionTransport(remote: root, cache: root.appendingPathComponent("cache"), selection: selection())
        do { _ = try await transport.poll(outgoing: [edit]); XCTFail("used v3 marker") } catch {}
        for (key, value) in [("workspace_id", oldBinding as Any), ("binding_id", oldBinding as Any), ("host_id", oldBinding as Any), ("initial_sequence", 8 as Any), ("initial_sequence", true as Any)] {
            var doc = try selection().document; doc[key] = value
            try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(doc), to: root.appendingPathComponent("family.json"))
            do { _ = try await transport.poll(outgoing: [edit]); XCTFail("accepted bad marker \(key)") } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("objects").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
    }
    func testMissingEarlyObjectDoesNotStarveLaterReadyRevision() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }; try writeMarker(root)
        let sender = try ReviewFamilyRevisionTransport(remote: root, cache: root.appendingPathComponent("sender"), selection: selection())
        let items = try [revision("A"), revision("B", clock: 2)].sorted { $0.revision.id < $1.revision.id }
        _ = try await sender.poll(outgoing: items)
        let object = root.appendingPathComponent("objects/" + items[0].origin.payloadHash)
        try FileManager.default.removeItem(at: object)
        let receiver = try ReviewFamilyRevisionTransport(remote: root, cache: root.appendingPathComponent("receiver"), selection: selection())
        var waiting = Set<String>(), received = Set<String>()
        for _ in 0..<2 { let p = try await receiver.poll(outgoing: [], limit: 1); waiting.formUnion(p.waitingObjectHashes); received.formUnion(p.revisions.map { $0.revision.id }) }
        XCTAssertEqual(waiting, [items[0].origin.payloadHash]); XCTAssertEqual(received, [items[1].revision.id])
        try WorkspaceIO.atomicWrite(items[0].raw, to: object)
        let completed = try await receiver.poll(outgoing: [])
        XCTAssertEqual(Set(completed.revisions.map { $0.revision.id }), Set(items.map { $0.revision.id }))
    }
    func testProviderAndCachedEnvelopePinsRejectEvenWithValidOrdinaryInnerRaw() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }; try writeMarker(root)
        let edit = try revision(ordinary: true), sender = try ReviewFamilyRevisionTransport(remote: root, cache: root.appendingPathComponent("sender"), selection: selection())
        _ = try await sender.poll(outgoing: [edit])
        let name = edit.revision.id + ".json", envelope = root.appendingPathComponent("revisions/" + name)
        let raw = try WorkspaceIO.read(envelope), doc = try WorkspaceIO.object(raw), cache = await sender.cache
        for (key, value) in [("workspace_id", oldBinding as Any), ("binding_id", oldBinding as Any), ("source_binding_id", oldBinding as Any), ("host_id", oldBinding as Any), ("initial_sequence", 8 as Any), ("revision_id", oldBinding as Any), ("payload_hash", String(repeating: "a", count: 64) as Any)] {
            var changed = doc; changed[key] = value; let invalid = try WorkspaceIO.canonical(changed)
            try WorkspaceIO.atomicWrite(invalid, to: envelope)
            let receiver = try ReviewFamilyRevisionTransport(remote: root, cache: root.appendingPathComponent("receiver-" + UUID().uuidString), selection: selection())
            let poll = try await receiver.poll(outgoing: [])
            XCTAssertTrue(poll.revisions.isEmpty); XCTAssertTrue(poll.invalidRevisionIDs.contains(name) || !poll.waitingObjectHashes.isEmpty)
            try WorkspaceIO.atomicWrite(invalid, to: cache.appendingPathComponent("envelopes/" + name))
            do { _ = try await sender.cachedRevisions(); XCTFail("cache accepted \(key)") } catch {}
        }
        try WorkspaceIO.atomicWrite(raw, to: envelope); try WorkspaceIO.atomicWrite(raw, to: cache.appendingPathComponent("envelopes/" + name))
        let recovered = try await sender.cachedRevisions(); XCTAssertEqual(recovered.map(\.raw), [edit.raw])
    }
    func testCorruptObjectCollisionAndSymlinksFailClosed() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }; try writeMarker(root)
        let edit = try revision(), transport = try ReviewFamilyRevisionTransport(remote: root, cache: root.appendingPathComponent("cache"), selection: selection())
        let object = root.appendingPathComponent("objects/" + edit.origin.payloadHash)
        try WorkspaceIO.atomicWrite(Data("{}".utf8), to: object)
        do { _ = try await transport.poll(outgoing: [edit]); XCTFail("overwrote corrupt collision") } catch {}
        XCTAssertEqual(try WorkspaceIO.read(object), Data("{}".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("revisions/" + edit.revision.id + ".json").path))
        let link = root.appendingPathComponent("linked-cache"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try ReviewFamilyRevisionTransport(remote: root, cache: link, selection: selection()))
        XCTAssertThrowsError(try ReviewFamilyRevisionTransport(remote: link, cache: root.appendingPathComponent("other-cache"), selection: selection()))
    }
}
