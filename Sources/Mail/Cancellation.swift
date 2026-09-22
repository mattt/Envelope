import Foundation
import os

/// Carries task cancellation into synchronous work on a dispatch queue.
public struct Cancellation: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    /// Creates a cancellation signal.
    public init() {}

    /// Whether the task or this signal is canceled.
    public var isCancelled: Bool {
        Task.isCancelled || cancelled.withLock { $0 }
    }

    /// Cancels all operations that share this signal.
    public func cancel() {
        cancelled.withLock { $0 = true }
    }

    /// Throws `CancellationError` when cancellation is requested.
    public func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
