import Foundation
import os

/// Runs one blocking Mail operation at a time outside the cooperative executor.
/// Overlapping requests fail immediately, including while message files are read.
public final class Worker: Sendable {
    private let queue = DispatchQueue(label: "me.mattt.Envelope.mail", qos: .utility)
    private let occupied = OSAllocatedUnfairLock(initialState: false)

    /// Creates a worker with a private serial dispatch queue.
    public init() {}

    /// Runs blocking work with cooperative cancellation.
    /// - Parameter operation: Work that checks the supplied cancellation signal.
    /// - Returns: The operation's result.
    /// - Throws: `Error.databaseBusy` on overlap, or the operation's error.
    public func run<T: Sendable>(
        _ operation: @Sendable @escaping (Cancellation) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let admitted = occupied.withLock { occupied in
            guard !occupied else { return false }
            occupied = true
            return true
        }
        guard admitted else { throw Error.databaseBusy }

        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let result = Result {
                        try cancellation.check()
                        let value = try operation(cancellation)
                        try cancellation.check()
                        return value
                    }
                    // Release admission before resuming the caller, even on failure.
                    self.occupied.withLock { $0 = false }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
