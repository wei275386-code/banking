import XCTest
@testable import PaymentImageCore

@MainActor final class ReviewHostWriteSchedulerTests: XCTestCase {
    actor Barrier {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
        func isStarted() -> Bool { started }
    }
    actor Events {
        var values = [String]()
        func append(_ value: String) { values.append(value) }
        func all() -> [String] { values }
    }
    func spinUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<10_000 { if await condition() { return }; await Task.yield() }
        throw WorkspaceError.invalid("scheduler test did not become ready")
    }
    func testReadyFiniteBatchPrecedesNextProcessorAndNewSyncWaitsForNextBatch() async throws {
        let scheduler = ReviewHostWriteScheduler(), processorBarrier = Barrier(), syncBarrier = Barrier(), events = Events()
        let processor = Task { try await scheduler.run(kind: .processor) {
            await events.append("processor-start"); await processorBarrier.wait(); await events.append("processor-finish")
        } }
        try await spinUntil { await processorBarrier.isStarted() }
        let next = Task { try await scheduler.run(kind: .localEdit) { await events.append("edit") } }
        try await spinUntil { await scheduler.status().waitingBusiness == 1 }
        let one = Task { try await scheduler.run(kind: .readySync) { await events.append("sync-one"); await syncBarrier.wait() } }
        try await spinUntil { await scheduler.status().waitingSync == 1 }
        let two = Task { try await scheduler.run(kind: .readySync) { await events.append("sync-two") } }
        try await spinUntil { await scheduler.status().waitingSync == 2 }
        await processorBarrier.release()
        try await spinUntil { await syncBarrier.isStarted() }
        let late = Task { try await scheduler.run(kind: .readySync) { await events.append("sync-late") } }
        try await spinUntil { await scheduler.status().waitingSync == 2 }
        await syncBarrier.release()
        try await processor.value; try await one.value; try await two.value; try await next.value; try await late.value
        let actual = await events.all()
        XCTAssertEqual(actual, ["processor-start", "processor-finish", "sync-one", "sync-two", "edit", "sync-late"])
    }
    func testQueuedCancellationNeverStartsBusinessAction() async throws {
        let scheduler = ReviewHostWriteScheduler(), barrier = Barrier(), events = Events()
        let first = Task { try await scheduler.run(kind: .processor) { await barrier.wait() } }
        try await spinUntil { await barrier.isStarted() }
        let cancelled = Task { try await scheduler.run(kind: .localEdit) { await events.append("cancelled-action") } }
        try await spinUntil { await scheduler.status().waitingBusiness == 1 }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("cancelled job should throw") } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        await barrier.release(); try await first.value
        let recorded = await events.all()
        XCTAssertTrue(recorded.isEmpty)
    }
}
