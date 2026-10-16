import Foundation
import os

/// A signal that carries task cancellation into synchronous work.
///
/// ``Store`` runs synchronous work as part of the calling task,
/// so `Task.isCancelled` already reflects the caller.
/// Tests use the explicit flag to cancel work without a task.
final class Cancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    /// Creates a signal that is not canceled.
    init() {}

    /// A Boolean value that indicates whether the signal or the current task is canceled.
    var isCancelled: Bool {
        Task.isCancelled || state.withLock { $0 }
    }

    /// Cancels the operations that check this signal.
    func cancel() {
        state.withLock { $0 = true }
    }

    /// Throws an error if the signal or the current task is canceled.
    /// - Throws: `CancellationError` if ``isCancelled`` is `true`.
    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
