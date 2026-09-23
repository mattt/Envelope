import Foundation
import os

/// Runs blocking Mail operations one at a time, outside Swift's cooperative thread pool.
///
/// The worker does not queue calls.
/// A call that starts while another operation runs fails immediately,
/// including while the other operation reads message files.
public final class Worker: Sendable {
    private let queue = DispatchQueue(label: "me.mattt.Envelope.mail", qos: .utility)
    private let occupied = OSAllocatedUnfairLock(initialState: false)

    /// Creates a worker with a private serial dispatch queue.
    public init() {}

    /// Runs a blocking operation on the worker's queue.
    ///
    /// If the calling task is canceled, the worker cancels the signal that it passes to the operation.
    /// - Parameter operation: The work to run.
    ///   Pass its signal to ``Database``, ``MessageFileReader``, and the parser.
    /// - Returns: The value that `operation` returns.
    /// - Throws: ``MailError/operationInProgress`` if another operation is running,
    ///   `CancellationError` if the task is canceled, or the error that `operation` throws.
    public func run<T: Sendable>(
        _ operation: @Sendable @escaping (Cancellation) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let admitted = occupied.withLock { occupied in
            guard !occupied else { return false }
            occupied = true
            return true
        }
        guard admitted else { throw MailError.operationInProgress }

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
