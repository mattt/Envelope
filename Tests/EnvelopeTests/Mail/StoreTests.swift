@testable import Envelope
import Foundation
import SQLite3
import Testing

extension Store {
    /// Counts without end, and calls `started` when the first row arrives.
    func countWithoutEnd(started: @Sendable () -> Void) throws -> [Int64?] {
        try withDatabase { database in
            try database.query(
                """
                WITH RECURSIVE counter(n) AS (
                    SELECT ROWID FROM messages WHERE ROWID = 1
                    UNION ALL SELECT n + 1 FROM counter WHERE n < 1000000000
                ) SELECT n FROM counter
                """
            ) { row in
                let n = row.integer(0)
                if n == 1 { started() }
                return n
            }
        }
    }
}

/// A box that lets a test move a value out of a `@Sendable` closure on purpose.
final class Leak<Value>: @unchecked Sendable {
    var value: Value?
}

/// Records the order in which operations finish.
final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func append(_ name: String) {
        lock.withLock { names.append(name) }
    }

    var values: [String] {
        lock.withLock { names }
    }
}

extension MailTests {
    @Suite(.timeLimit(.minutes(1)))
    struct StoreTests {
        let store: MailStore

        init() throws {
            store = try MailStore()
            try store.emlx("Message-ID: <one@example.com>\nSubject: One\n\nBody").write(
                to: store.mailbox.appendingPathComponent("1.emlx")
            )
        }

        @Test("Operations run on the store's queue as part of the calling task, after the connection closes")
        func operationsRunOnQueueInTaskAfterClose() async throws {
            let root = store.root
            let mailStore = Store(root: root)
            let oneID = try #require(Message.Identifier("V10:1:1"))
            let body = try await mailStore.readMessage(oneID) { file in
                #expect(!Thread.isMainThread)
                #expect(String(cString: __dispatch_queue_get_label(nil)) == "me.mattt.Envelope.mail")
                #expect(withUnsafeCurrentTask { $0 != nil })
                // The store released admission before the parser runs.
                let other = try Database(root: root)
                other.close()
                return try Content(emlx: file.data, expectedMessageID: file.message.messageID).body
            }
            #expect(body == "Body")
        }

        @Test("Task cancellation stops a running statement and releases the read lock")
        func taskCancellationStopsStatement() async throws {
            let mailStore = try Store(root: store.root, configuration: .init(queryTimeLimit: .seconds(5)))
            let (entered, started) = AsyncStream<Void>.makeStream()
            let task = Task { try await mailStore.countWithoutEnd { started.yield() } }
            for await _ in entered { break }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(store.checkpoint() == SQLITE_OK)
            #expect(try await mailStore.fetch(.init()).count == 3)
        }

        @Test("The parser's default cancellation check sees the calling task")
        func parserDefaultCheckSeesTask() async throws {
            let mailStore = Store(root: store.root)
            let oneID = try #require(Message.Identifier("V10:1:1"))
            let task = Task {
                try await mailStore.readMessage(oneID) { file in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try Content(emlx: file.data).body
                }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }

        @Test("Overlapping calls wait in order, and a canceled waiting call does not run")
        func overlappingCallsWait() async throws {
            let mailStore = Store(root: store.root)
            let oneID = try #require(Message.Identifier("V10:1:1"))
            let order = Order()
            let (entered, started) = AsyncStream<Void>.makeStream()
            // Only the store's dispatch queue waits on this semaphore, never an async task.
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }

            let first = Task {
                try await mailStore.readMessage(oneID) { _ in
                    started.yield()
                    _ = release.wait(timeout: .now() + 5)
                    order.append("first")
                }
            }
            for await _ in entered { break }

            let second = Task {
                let records = try await mailStore.fetch(.init())
                order.append("second")
                return records.count
            }
            let canceled = Task {
                try await mailStore.withSnapshot { _ in order.append("canceled") }
            }
            canceled.cancel()
            try await Task.sleep(for: .milliseconds(50))
            #expect(order.values.isEmpty)

            release.signal()
            try await first.value
            #expect(try await second.value == 3)
            await #expect(throws: CancellationError.self) { try await canceled.value }
            #expect(order.values == ["first", "second"])
        }

        @Test("Location does not wait for a running operation")
        func locationDoesNotWait() async throws {
            let mailStore = Store(root: store.root)
            let oneID = try #require(Message.Identifier("V10:1:1"))
            let (entered, started) = AsyncStream<Void>.makeStream()
            // Only the store's dispatch queue waits on this semaphore, never an async task.
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let running = Task {
                try await mailStore.readMessage(oneID) { _ in
                    started.yield()
                    _ = release.wait(timeout: .now() + 5)
                }
            }
            for await _ in entered { break }
            let start = ContinuousClock.now
            #expect(try mailStore.location().versionURL.lastPathComponent == "V10")
            #expect(start.duration(to: .now) < .seconds(1))
            release.signal()
            try await running.value
        }

        @Test("A snapshot reads one transaction and is not valid after its closure returns")
        func snapshotScope() async throws {
            nonisolated(unsafe) let writer = store
            let mailStore = Store(root: store.root)
            let leak = Leak<Store.Snapshot>()
            let counts = try await mailStore.withSnapshot { snapshot in
                leak.value = snapshot
                let before = try snapshot.fetch(.init()).count
                try writer.execute("INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com')")
                let after = try snapshot.search(.init())
                return (before, after.records.count, after.indexedMessageCount)
            }
            #expect(counts == (3, 3, 3))
            #expect(store.checkpoint() == SQLITE_OK)
            #expect(throws: MailError.connectionClosed) { try leak.value?.mailboxes() }
            #expect(try await mailStore.search(.init()).indexedMessageCount == 4)
        }

        @Test("A configuration rejects limits that are not positive")
        func configurationRejectsInvalidLimits() throws {
            #expect(throws: Store.Configuration.ValidationError.invalidQueryTimeLimit) {
                try Store.Configuration(queryTimeLimit: .zero)
            }
            #expect(throws: Store.Configuration.ValidationError.invalidMaximumConnections) {
                try Store.Configuration(maximumConnections: 0)
            }
            #expect(throws: Store.Configuration.ValidationError.invalidSnapshotTimeLimit) {
                try Store.Configuration(snapshotTimeLimit: .milliseconds(-1))
            }
            #expect(try Store.Configuration() == .default)
            #expect(Store(root: store.root).configuration == .default)
        }

        @Test("An access check opens the index and reports why it cannot")
        func accessCheck() async throws {
            let mailStore = Store(root: store.root)
            let location = try await mailStore.checkAccess()
            #expect(location.versionURL == store.version.resolvingSymlinksInPath())
            #expect(location.indexURL == store.index.resolvingSymlinksInPath())
            // The check closes its connection.
            try Database(root: store.root).close()

            let missing = Store(root: store.root.appendingPathComponent("Missing"))
            await #expect(throws: MailError.indexNotReadable) { try await missing.checkAccess() }
            try store.execute("PRAGMA journal_mode=DELETE;")
            await #expect(throws: MailError.unsupportedJournalMode) { try await mailStore.checkAccess() }
        }

        @Test("A snapshot stops at its time limit even when each statement is within its own")
        func snapshotTimeLimit() async throws {
            let mailStore = try Store(
                root: store.root,
                configuration: .init(queryTimeLimit: .seconds(5), snapshotTimeLimit: .milliseconds(50))
            )
            let start = ContinuousClock.now
            await #expect(throws: MailError.queryTimedOut) {
                try await mailStore.countWithoutEnd {}
            }
            #expect(start.duration(to: .now) < .seconds(2))
            #expect(store.checkpoint() == SQLITE_OK)
            #expect(try await mailStore.fetch(.init()).count == 3)
        }

        @Test("Failed operations close their connection")
        func failedOperationsClose() async throws {
            let mailStore = Store(root: store.root)
            await #expect(throws: MailError.mailboxNotFound) { try await mailStore.search(.init(mailboxID: 999)) }
            await #expect(throws: CocoaError(.featureUnsupported)) {
                try await mailStore.withSnapshot { _ -> Int in throw CocoaError(.featureUnsupported) }
            }
            #expect(store.checkpoint() == SQLITE_OK)
            try Database(root: store.root).close()

            // Another connection in the process takes the only admission.
            let other = try Database(root: store.root)
            await #expect(throws: MailError.connectionLimitReached) { try await mailStore.mailboxes() }
            other.close()
            #expect(try await mailStore.mailboxes().count == 2)
        }

        @Test("An identifier from an older store is stale")
        func identifierFromOlderStore() async throws {
            let mailStore = Store(root: store.root)
            let identifier = try #require(Message.Identifier("V10:1:1"))
            #expect(try await mailStore.record(for: identifier).id == identifier)
            let newer = store.root.appendingPathComponent("V11/MailData")
            try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: store.index, to: newer.appendingPathComponent("Envelope Index"))
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: store.index.path + "-wal"), to: newer.appendingPathComponent("Envelope Index-wal"))
            await #expect(throws: MailError.storeChanged) { try await mailStore.readMessage(identifier) { $0.data } }
        }

        @Test(
            "Operations run at the priority of the calling task",
            arguments: [(TaskPriority.high, QOS_CLASS_USER_INITIATED), (.medium, QOS_CLASS_DEFAULT), (.low, QOS_CLASS_UTILITY)]
        )
        func operationsFollowTaskPriority(priority: TaskPriority, expected: qos_class_t) async throws {
            let mailStore = Store(root: store.root)
            // Awaiting the task's value would raise its priority to the test's,
            // so the result comes back through a continuation.
            let qos = await withCheckedContinuation { continuation in
                Task(priority: priority) {
                    let qos = try? await mailStore.withSnapshot { _ in qos_class_self() }
                    continuation.resume(returning: qos)
                }
            }
            #expect(qos == expected)
        }

        @Test("Content checks that the file holds the indexed message")
        func contentChecksIdentity() async throws {
            let mailStore = Store(root: store.root)
            let identifier = try #require(Message.Identifier("V10:1:1"))
            #expect(try await mailStore.content(for: identifier).body == "Body")
            try store.emlx("Message-ID: <other@example.com>\nSubject: Other\n\nOther").write(
                to: store.mailbox.appendingPathComponent("1.emlx")
            )
            await #expect(throws: EmlxError.messageMismatch) { try await mailStore.content(for: identifier) }
        }
    }
}
