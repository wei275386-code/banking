import Foundation
import XCTest
@testable import PaymentImageCore

@MainActor final class ReviewFamilyRequestTests: XCTestCase {
    struct Fixture {
        struct Provider { let remote: URL }
        let paths: WorkspacePaths, selection: ReviewFamilyBindingSelection, store: Provider
        func remove() {
            try? FileManager.default.removeItem(at: paths.workspace)
            try? FileManager.default.removeItem(at: store.remote)
        }
    }
    func fixture() throws -> Fixture {
        let owner = ReviewFamilyHostTests(), base = try owner.fixture(), remote = owner.remote(base)
        let selection = try ReviewFamilyBindingSelection(workspaceID: base.paths.readPointer().workspaceID,
            bindingID: UUID().uuidString.lowercased(), hostID: UUID().uuidString.lowercased())
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(selection.document), to: remote.appendingPathComponent("family.json"))
        return Fixture(paths: base.paths, selection: selection, store: .init(remote: remote))
    }
    func review(_ dataset: String = "synthetic-integration-v1") throws -> Data {
        try WorkspaceIO.canonical(["dataset_id": dataset, "decisions": [:], "metadata": ["note": "retained metadata"]])
    }
    func transport(_ f: Fixture, name: String) throws -> ReviewFamilyRequestTransport {
        try ReviewFamilyRequestTransport(remote: f.store.remote, cache: f.paths.device.appendingPathComponent(name), selection: f.selection)
    }
    func testReviewStableImmutableOutboxUploadAndRestartDoNotClaimIncluded() async throws {
        let f = try fixture(); defer { f.remove() }
        let sender = try transport(f, name: "request-client"), receiver = try transport(f, name: "request-host")
        let id = UUID().uuidString.lowercased(), author = UUID().uuidString.lowercased()
        let first = try await sender.enqueueReview(payload: review(), authorDeviceID: author, requestID: id)
        let second = try await sender.enqueueReview(payload: review(), authorDeviceID: author, requestID: id)
        XCTAssertEqual(first.raw, second.raw)
        let token = try WorkspaceCoordinator(paths: f.paths).acquireWriteToken()
        let old = try f.paths.readPointer()
        let sent = try await sender.poll(limit: 2)
        XCTAssertEqual(sent.uploadedRequestIDs, [id])
        let polled = try await receiver.poll(limit: 2)
        XCTAssertEqual(polled.requests.map(\.id), [id])
        XCTAssertEqual(polled.requests.first?.payload, first.payload)
        XCTAssertEqual(try f.paths.readPointer(), old)
        try token.validate(for: f.paths)
        let restarted = try transport(f, name: "request-client")
        let statuses = try await restarted.localStatuses()
        XCTAssertEqual(statuses[id], "queued")
        do { _ = try await sender.enqueueReview(payload: review("different"), authorDeviceID: author, requestID: id); XCTFail("immutable ID collision") } catch {}
    }
    func testImportRetainsIndependentOriginalsAndCacheTamperIsRejected() async throws {
        let f = try fixture(); defer { f.remove() }
        let sender = try transport(f, name: "import-client"), receiver = try transport(f, name: "import-host")
        let original = f.paths.device.appendingPathComponent("manual-original.csv")
        try WorkspaceIO.atomicWrite(Data("raw,中文,9007199254740993\n".utf8), to: original)
        let request = try await sender.enqueueImport(files: [original], authorDeviceID: UUID().uuidString.lowercased())
        _ = try await sender.poll()
        let incoming = try await receiver.poll()
        XCTAssertEqual(incoming.requests.map(\.id), [request.id])
        let copied = incoming.requests[0].cache.appendingPathComponent("objects/" + request.files[0].sha256)
        XCTAssertEqual(try WorkspaceIO.read(copied), try WorkspaceIO.read(original))
        try WorkspaceIO.atomicWrite(Data("tampered".utf8), to: original)
        XCTAssertEqual(try WorkspaceIO.hash(copied), request.files[0].sha256)
        try WorkspaceIO.atomicWrite(Data("broken local object".utf8), to: copied)
        do { _ = try await receiver.cachedRequests(); XCTFail("cache corruption must fail") } catch {}
    }
    func testMissingFirstPayloadDoesNotStarveLaterReadyRequest() async throws {
        let f = try fixture(); defer { f.remove() }
        let sender = try transport(f, name: "ready-client"), receiver = try transport(f, name: "ready-host")
        let ready = try await sender.enqueueReview(payload: review(), authorDeviceID: UUID().uuidString.lowercased(), requestID: "ffffffff-ffff-4fff-8fff-ffffffffffff")
        _ = try await sender.poll()
        var missing = try WorkspaceIO.object(ready.raw)
        let missingID = "00000000-0000-4000-8000-000000000000"
        missing["request_id"] = missingID; missing["payload_hash"] = String(repeating: "0", count: 64)
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(missing), to: f.store.remote.appendingPathComponent("requests/" + missingID + ".json"))
        let first = try await receiver.poll(limit: 1)
        XCTAssertEqual(first.waitingObjectHashes, [String(repeating: "0", count: 64)])
        let second = try await receiver.poll(limit: 1)
        XCTAssertEqual(second.requests.map(\.id), [ready.id])
    }
    func testCancellationIsDurableAndDoesNotFabricateCheckpointInclusion() async throws {
        let f = try fixture(); defer { f.remove() }
        let sender = try transport(f, name: "cancel-client")
        let request = try await sender.enqueueReview(payload: review(), authorDeviceID: UUID().uuidString.lowercased())
        try await sender.cancel(requestID: request.id)
        let poll = try await sender.poll()
        XCTAssertTrue(poll.uploadedRequestIDs.isEmpty)
        let restarted = try transport(f, name: "cancel-client")
        let status = try await restarted.localStatuses()
        XCTAssertEqual(status[request.id], "cancelled")
        XCTAssertNotEqual(status[request.id], "included")
        try await restarted.retry(requestID: request.id)
        let retried = try await restarted.cachedRequests()
        XCTAssertEqual(retried.map(\.id), [request.id])
        XCTAssertEqual(retried.first?.raw, request.raw)
        XCTAssertEqual(retried.first?.payload, request.payload)
        let resent = try await restarted.poll()
        XCTAssertEqual(resent.uploadedRequestIDs, [request.id])
    }
    #if os(macOS)
    func testActualCurrentHostProcessesOfflineImportOnceAndSelectedClientAcknowledges() async throws {
        let python = try TestPlatform.python()
        var project = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { project.deleteLastPathComponent() }
        let parent = try TestPlatform.temporaryDirectory().appendingPathComponent("current-request-" + UUID().uuidString)
        let paths = try WorkspacePaths(workspace: parent.appendingPathComponent("host"))
        let client = try WorkspacePaths(workspace: parent.appendingPathComponent("client"))
        let remote = parent.appendingPathComponent("provider")
        defer { try? FileManager.default.removeItem(at: parent) }
        let runtime = try ProcessorRuntime(project: project, python: python)
        _ = try await WorkspaceMaintenanceExecutor(runtime: runtime).run(.init(command: .create, workspace: paths.workspace))
        let connection = try ReviewFamilyHost.create(paths: paths, remote: remote)
        let handle = try ReviewFamilyClientSessionTests().connect(client, remote: remote)
        let queue = try ReviewFamilyClientSession.requestTransport(paths: client, expected: handle)
        let original = parent.appendingPathComponent("wallet.csv")
        try WorkspaceIO.atomicWrite(Data(("\u{FEFF}交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注\n" +
            "2026-08-31 18:44:48,餐饮美食,测试商户,,咖啡,支出,21.98,招商银行信用卡(0786),交易成功,current-request-order,merchant-1,\n").utf8), to: original)
        let request = try await queue.enqueueImport(files: [original], authorDeviceID: ReviewFamilyClientSession.requestDeviceID(paths: client))
        let beforeStatus = try await queue.localStatuses()
        XCTAssertEqual(beforeStatus[request.id], "queued")
        try await ReviewFamilyClientSession.transfer(paths: client)
        let driver = try ReviewFamilySyncDriver(paths: paths, connection: connection)
        let pending = try await driver.hasPendingRequests(); XCTAssertTrue(pending)
        try await driver.processRequests(runtime: runtime)
        let committed = try paths.readPointer()
        _ = try await driver.synchronize()
        let refreshed = try XCTUnwrap(ReviewFamilyClientSession.refresh(paths: client))
        let afterQueue = try ReviewFamilyClientSession.requestTransport(paths: client, expected: refreshed)
        let status = try await afterQueue.localStatuses()
        XCTAssertEqual(status[request.id], "included")
        try await afterQueue.retry(requestID: request.id)
        try await afterQueue.cancel(requestID: request.id)
        let unchangedStatus = try await afterQueue.localStatuses()
        XCTAssertEqual(unchangedStatus[request.id], "included")
        try await driver.processRequests(runtime: runtime)
        XCTAssertEqual(try paths.readPointer(), committed)
        let ledger = try WorkspaceIO.object(WorkspaceIO.read(paths.readState().operationResults))
        XCTAssertEqual((ledger["results"] as? [[String: Any]])?.filter { $0["request_id"] as? String == request.id }.count, 1)
    }
    #endif

    func testUnverifiedIncludedReceiptIsDemotedAndResentOnRestart() async throws {
        let f = try fixture(); defer { f.remove() }
        let sender = try transport(f, name: "old-receipt-client")
        let request = try await sender.enqueueReview(payload: review(), authorDeviceID: UUID().uuidString.lowercased())
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["request_id": request.id, "status": "included",
            "generation": String(repeating: "a", count: 64), "result_digest": String(repeating: "b", count: 64)]), to: request.cache.appendingPathComponent("outbox-status/" + request.id + ".json"))
        let restarted = try transport(f, name: "old-receipt-client")
        let statuses = try await restarted.localStatuses()
        XCTAssertEqual(statuses[request.id], "queued")
        let poll = try await restarted.poll()
        XCTAssertEqual(poll.uploadedRequestIDs, [request.id])
    }
    func testClientUploadOnlyDoesNotDownloadOtherClientsOriginals() async throws {
        let f = try fixture(); defer { f.remove() }
        let sender = try transport(f, name: "other-original-owner"), client = try transport(f, name: "compact-client")
        let source = f.paths.device.appendingPathComponent("other-client.csv")
        try WorkspaceIO.atomicWrite(Data(repeating: 65, count: 128 * 1024), to: source)
        let request = try await sender.enqueueImport(files: [source], authorDeviceID: UUID().uuidString.lowercased())
        _ = try await sender.poll(uploadOnly: true)
        let poll = try await client.poll(uploadOnly: true)
        XCTAssertTrue(poll.requests.isEmpty)
        XCTAssertTrue(poll.waitingObjectHashes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.cache.deletingLastPathComponent().appendingPathComponent("compact-client/objects").path))
        let statuses = try await client.localStatuses()
        XCTAssertTrue(statuses.isEmpty)
    }
    func testSuccessfulResultIndexUsesExactUniqueRequestIDs() throws {
        let entries: [[String: Any]] = (0..<2048).map { ["request_id": "request-\($0)", "outcome": $0.isMultiple(of: 2) ? "success" : "failed", "ordinal": $0] }
        let indexed = try ReviewFamilyRequestTransport.successfulResults(entries)
        XCTAssertEqual(indexed.count, 1024)
        for value in stride(from: 0, to: 2048, by: 2) { XCTAssertEqual(indexed["request-\(value)"]?["ordinal"] as? Int, value) }
        XCTAssertThrowsError(try ReviewFamilyRequestTransport.successfulResults(entries + [entries[0]]))
    }
    func testMissingFirstOutgoingObjectDoesNotBlockLaterReadyUpload() async throws {
        let f = try fixture(); defer { f.remove() }
        let sender = try transport(f, name: "outgoing-missing")
        let missing = try await sender.enqueueReview(payload: review("missing-payload"), authorDeviceID: UUID().uuidString.lowercased(), requestID: "00000000-0000-4000-8000-000000000000")
        let ready = try await sender.enqueueReview(payload: review("ready-payload"), authorDeviceID: UUID().uuidString.lowercased(), requestID: "ffffffff-ffff-4fff-8fff-ffffffffffff")
        try FileManager.default.removeItem(at: missing.cache.appendingPathComponent("objects/" + missing.payloadHash))
        let polled = try await sender.poll(limit: 2)
        XCTAssertEqual(polled.uploadedRequestIDs, [ready.id])
        XCTAssertTrue(polled.invalidRequestIDs.contains(missing.id + ".json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.remote.appendingPathComponent("requests/" + missing.id + ".json").path))
    }
    func testUnchangedOriginalTransferUsesOnlyVerifiedStampHintAndChangedBytesFail() async throws {
        let f = try fixture(); defer { f.remove() }
        let sender = try transport(f, name: "stamp-sender"), receiver = try transport(f, name: "stamp-receiver")
        let original = f.paths.device.appendingPathComponent("stamp-original.csv")
        try WorkspaceIO.atomicWrite(Data(repeating: 65, count: 128 * 1024), to: original)
        let request = try await sender.enqueueImport(files: [original], authorDeviceID: UUID().uuidString.lowercased())
        _ = try await sender.poll(uploadOnly: true); _ = try await receiver.poll()
        let sent = await sender.transferVerificationPasses, received = await receiver.transferVerificationPasses
        XCTAssertGreaterThan(sent, 0); XCTAssertGreaterThan(received, 0)
        _ = try await sender.poll(uploadOnly: true); _ = try await receiver.poll()
        let unchangedSent = await sender.transferVerificationPasses, unchangedReceived = await receiver.transferVerificationPasses
        XCTAssertEqual(unchangedSent, sent); XCTAssertEqual(unchangedReceived, received)
        let object = request.cache.appendingPathComponent("objects/" + request.files[0].sha256)
        try WorkspaceIO.atomicWrite(Data(repeating: 66, count: 128 * 1024), to: object)
        let changed = try await sender.poll(uploadOnly: true)
        XCTAssertTrue(changed.invalidRequestIDs.contains(request.id + ".json"))
        do { _ = try await sender.cachedRequests(); XCTFail("transfer hints cannot authorize corrupt originals") } catch {}
    }
    func testPinnedPartialIntentCannotBeOverwrittenByStaleCancelOrRetry() async throws {
        let f = try fixture(); defer { f.remove() }
        let sender = try transport(f, name: "partial-intent")
        let request = try await sender.enqueueReview(payload: review(), authorDeviceID: UUID().uuidString.lowercased())
        let file = request.cache.appendingPathComponent("outbox-status/" + request.id + ".json")
        let pinned = try WorkspaceIO.canonical(["request_id": request.id, "status": "needsReview",
            "generation": String(repeating: "a", count: 64), "result_digest": String(repeating: "b", count: 64)])
        // This fixture tests the final mutation guard after reader reconciliation;
        // a pin alone is never accepted by the reader as business membership.
        try WorkspaceIO.atomicWrite(pinned, to: file)
        try ReviewFamilyRequestTransport.writeLocalIntent("cancelled", id: request.id, cache: request.cache)
        try ReviewFamilyRequestTransport.writeLocalIntent("queued", id: request.id, cache: request.cache)
        XCTAssertEqual(try WorkspaceIO.read(file), pinned)
        try WorkspaceIO.atomicWrite(WorkspaceIO.canonical(["request_id": request.id, "status": "needsReview",
            "generation": NSNull(), "result_digest": NSNull()]), to: file)
        try await sender.retry(requestID: request.id)
        let statuses = try await sender.localStatuses()
        XCTAssertEqual(statuses[request.id], "queued")
    }
    func testPartialResultMatchesExactRequestInputsWithoutBecomingSuccessfulInclusion() async throws {
        let f = try fixture(); defer { f.remove() }
        let sender = try transport(f, name: "partial-identity")
        let request = try await sender.enqueueReview(payload: review(), authorDeviceID: UUID().uuidString.lowercased())
        var result: [String: Any] = ["workspace_id": f.selection.workspaceID, "request_id": request.id,
            "operation_id": request.id, "phase": "committed", "outcome": "partial",
            "inputs": [["kind": "review", "sha256": request.payloadHash]]]
        XCTAssertTrue(request.matches(result: result))
        XCTAssertTrue(try ReviewFamilyRequestTransport.successfulResults([result]).isEmpty)
        result["inputs"] = [["kind": "csv", "sha256": request.payloadHash]]
        XCTAssertFalse(request.matches(result: result))
        result["inputs"] = [["kind": "review", "sha256": String(repeating: "0", count: 64)]]
        XCTAssertFalse(request.matches(result: result))
    }
    func testForeignBindingAndFilenameAliasesAreRejected() async throws {
        let f = try fixture(); defer { f.remove() }
        let sender = try transport(f, name: "negative-client")
        let request = try await sender.enqueueReview(payload: review(), authorDeviceID: UUID().uuidString.lowercased())
        var foreign = try WorkspaceIO.object(request.raw); foreign["binding_id"] = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try ReviewFamilyRequest(raw: WorkspaceIO.canonical(foreign), payload: request.payload, cache: request.cache, selection: f.selection))
        let a = f.paths.device.appendingPathComponent("a/file.csv"), b = f.paths.device.appendingPathComponent("b/FILE.csv")
        try WorkspaceIO.atomicWrite(Data("first".utf8), to: a); try WorkspaceIO.atomicWrite(Data("second".utf8), to: b)
        do { _ = try await sender.enqueueImport(files: [a, b], authorDeviceID: UUID().uuidString.lowercased()); XCTFail("case collision") } catch {}
        let alias = f.paths.device.appendingPathComponent("alias.csv")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
        do { _ = try await sender.enqueueImport(files: [alias], authorDeviceID: UUID().uuidString.lowercased()); XCTFail("symlink") } catch {}
    }
    func testOfflineClientBackupPreservesQueuedOriginalAndCancelledIntent() async throws {
        let owner = ReviewFamilyHostTests(), f = try owner.fixture(), remote = owner.remote(f)
        let client = try ReviewFamilyClientSessionTests().client(f.paths)
        let restored = try ReviewFamilyClientSessionTests().client(f.paths)
        let package = f.paths.workspace.deletingLastPathComponent().appendingPathComponent("request-backup-" + UUID().uuidString)
        defer { f.remove(); for file in [remote, client.workspace, restored.workspace, package] { try? FileManager.default.removeItem(at: file) } }
        _ = try ReviewFamilyHost.create(paths: f.paths, remote: remote)
        let handle = try ReviewFamilyClientSessionTests().connect(client, remote: remote)
        let transport = try ReviewFamilyClientSession.requestTransport(paths: client, expected: handle)
        let original = client.device.appendingPathComponent("pending.csv")
        try WorkspaceIO.atomicWrite(Data("retained,current,input\n".utf8), to: original)
        let request = try await transport.enqueueImport(files: [original], authorDeviceID: ReviewFamilyClientSession.requestDeviceID(paths: client))
        try await transport.cancel(requestID: request.id)
        try FileManager.default.removeItem(at: remote)
        try ReviewFamilyClientSession.exportSelectedBackup(paths: client, destination: package)
        let reopened = try ReviewFamilyClientSession.restoreSelectedBackup(package: package, destination: restored.workspace)
        let queue = try ReviewFamilyClientSession.requestTransport(paths: restored, expected: reopened)
        let statuses = try await queue.localStatuses()
        XCTAssertEqual(statuses[request.id], "cancelled")
        try await queue.retry(requestID: request.id)
        let pending = try await queue.cachedRequests()
        XCTAssertEqual(pending.map(\.id), [request.id])
        XCTAssertEqual(pending.first?.raw, request.raw)
        XCTAssertEqual(try WorkspaceIO.read(pending[0].cache.appendingPathComponent("objects/" + request.files[0].sha256)), Data("retained,current,input\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.device.appendingPathComponent("host-authorization.json").path))
    }

}
