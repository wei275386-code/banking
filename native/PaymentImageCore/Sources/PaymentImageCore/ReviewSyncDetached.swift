import Foundation

/// Offloads blocking filesystem work while forwarding cancellation to the child
/// task. Merely awaiting Task.detached.value would let a cancelled writer commit.
public enum ReviewSyncDetached {
    public static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached { try Task.checkCancellation(); return try operation() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
