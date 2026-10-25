import Foundation

/// All host business writers must enter this scheduler: processor, native edit,
/// and sync apply. Transport/prepare are separate paths and never enter it.
/// This is local fairness; the fixed workspace gate remains the write barrier.
public actor ReviewHostWriteScheduler {
    public enum WorkKind: Sendable { case processor, localEdit, readySync }
    public struct Status: Sendable {
        public let running: WorkKind?
        public let waitingBusiness: Int
        public let waitingSync: Int
        public let frozen: Bool
    }
    private struct Job: Sendable {
        let id: UUID; let kind: WorkKind
        let execute: @Sendable () async -> Void
        let cancelQueued: @Sendable () -> Void
    }
    private var business = [Job](), sync = [Job](), batch = [Job]()
    private var active: Job?
    private var activeTask: Task<Void, Never>?
    private var businessTurnAfterBatch = false
    private var frozen = false

    public init() {}
    /// Ready sync admission means dependency checks completed before this call.
    /// Missing-ancestor work stays in prepare/cache and cannot block ready jobs.
    public func run<T: Sendable>(kind: WorkKind, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let job = Job(id: id, kind: kind, execute: {
                    do { continuation.resume(returning: try await operation()) }
                    catch { continuation.resume(throwing: error) }
                }, cancelQueued: { continuation.resume(throwing: CancellationError()) })
                if kind == .readySync { sync.append(job) } else { business.append(job) }
                drain()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    /// Maintenance pauses are explicit user states. Never infer them
    /// from processor duration or use them to hide ordinary sync waiting.
    public func setFrozen(_ value: Bool) { frozen = value; if !value { drain() } }
    public func status() -> Status {
        Status(running: active?.kind, waitingBusiness: business.count, waitingSync: sync.count + batch.count, frozen: frozen)
    }
    private func cancel(_ id: UUID) {
        if active?.id == id {
            // This only requests cancellation. Commit-aware operations determine
            // whether it means abandon staging or stop waiting after commit.
            activeTask?.cancel(); return
        }
        for index in business.indices where business[index].id == id { business.remove(at: index).cancelQueued(); drain(); return }
        for index in sync.indices where sync[index].id == id { sync.remove(at: index).cancelQueued(); drain(); return }
        for index in batch.indices where batch[index].id == id { batch.remove(at: index).cancelQueued(); drain(); return }
    }
    private func drain() {
        guard active == nil, !frozen else { return }
        let next: Job
        if !batch.isEmpty {
            next = batch.removeFirst()
        } else if businessTurnAfterBatch && !business.isEmpty {
            // Arrivals during a finite sync batch enter the next batch. At most
            // one business writer runs between batches, so neither class starves.
            businessTurnAfterBatch = false; next = business.removeFirst()
        } else if !sync.isEmpty {
            batch = sync; sync.removeAll(keepingCapacity: true)
            businessTurnAfterBatch = true; next = batch.removeFirst()
        } else if !business.isEmpty {
            businessTurnAfterBatch = false; next = business.removeFirst()
        } else { return }
        active = next
        activeTask = Task {
            await next.execute()
            finished(next.id)
        }
    }
    private func finished(_ id: UUID) {
        guard active?.id == id else { return }
        let wasBusiness = active?.kind != .readySync
        active = nil; activeTask = nil
        // At the processor/edit release, all already-ready sync items get their
        // finite batch before another business writer is allowed to start.
        if wasBusiness { businessTurnAfterBatch = false }
        drain()
    }
}
