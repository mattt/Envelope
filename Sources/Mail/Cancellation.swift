import Foundation
import os

/// A signal that carries task cancellation into synchronous work.
///
/// A ``Worker`` creates one signal for each operation,
/// and cancels it when the calling task is canceled.
/// Pass the signal to ``Database``, ``MessageFileReader``,
/// and the parser, so that each of them can stop early.
public final class Cancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    /// Creates a signal that is not canceled.
    public init() {}

    /// A Boolean value that indicates whether the signal or the current task is canceled.
    public var isCancelled: Bool {
        Task.isCancelled || state.withLock { $0 }
    }

    /// Cancels the operations that check this signal.
    public func cancel() {
        state.withLock { $0 = true }
    }

    /// Throws an error if the signal or the current task is canceled.
    /// - Throws: `CancellationError` if ``isCancelled`` is `true`.
    public func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
