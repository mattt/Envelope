import Foundation
import SQLite3
import Testing

@testable import Mail

extension MailTests {
    @Suite(.timeLimit(.minutes(1)))
    struct WorkerTests {
        let store: MailStore

        init() throws {
            store = try MailStore()
        }

        @Test("The worker rejects overlapping operations, and releases admission after cancellation")
        @MainActor
        func workerRejectsOverlapAndReleasesAdmissionAfterCancellation() async throws {
            let worker = Mail.Worker()
            let (entered, started) = AsyncStream<Void>.makeStream()
            // Only the dispatch worker waits on this semaphore, never an async task.
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let task = Task {
                try await worker.run { _ in
                    #expect(!Thread.isMainThread)
                    started.yield()
                    guard release.wait(timeout: .now() + 5) == .success else {
                        throw MailError.queryTimedOut
                    }
                    return 1
                }
            }
            for await _ in entered { break }
            await #expect(throws: MailError.operationInProgress) {
                try await worker.run { _ in 2 }
            }

            task.cancel()
            release.signal()
            // The worker must release admission before returning cancellation.
            await #expect(throws: CancellationError.self) { try await task.value }
            let result = try await worker.run { _ in 3 }
            #expect(result == 3)
        }

        @Test("Worker cancellation interrupts a query and releases the read lock")
        func workerCancellationInterruptsQueryAndReleasesReadLock() async throws {
            let root = store.root
            let worker = Mail.Worker()
            let (entered, started) = AsyncStream<Void>.makeStream()
            let task = Task {
                try await worker.run { cancellation in
                    let database = try Mail.Database(root: root, configuration: .init(queryTimeLimit: .seconds(5)), cancellation: cancellation)
                    defer { database.close() }
                    return try database.query(
                        """
                        WITH RECURSIVE counter(n) AS (
                            SELECT ROWID FROM messages WHERE ROWID = 1
                            UNION ALL SELECT n + 1 FROM counter WHERE n < 1000000000
                        ) SELECT n FROM counter
                        """
                    ) { row in
                        let n = row.integer(0)
                        if n == 1 { started.yield() }
                        return n
                    }
                }
            }
            for await _ in entered { break }
            task.cancel()
            // Cancellation must reach SQLite without the caller's task context.
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(store.checkpoint() == SQLITE_OK)
            let count = try await worker.run { cancellation in
                let database = try Mail.Database(root: root, cancellation: cancellation)
                defer { database.close() }
                return try database.fetch(.init()).count
            }
            #expect(count == 3)
        }

        @Test("The worker does not start an operation for a canceled task")
        func workerDoesNotStartAlreadyCancelledOperation() async throws {
            let worker = Mail.Worker()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await worker.run { _ in
                    Issue.record("A canceled task must not start file or database work")
                    return 1
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            let result = try await worker.run { _ in 2 }
            #expect(result == 2)
        }
    }
}
