import Foundation
import SQLite3
import Testing

@testable import Mail

extension MailTests {
    @Suite
    struct DatabaseTests {
        let store: MailStore

        init() throws {
            store = try MailStore()
        }

        @Test("Configured connection limits apply, and closing releases admission")
        func configuredConnectionLimitsAndAdmissionRelease() throws {
            let root = store.root
            let configuration = Mail.Database.Configuration(queryTimeLimit: .seconds(2), maximumConnections: 2)
            let first = try Mail.Database(root: root, configuration: configuration)
            let second = try Mail.Database(root: root, configuration: configuration)
            #expect(throws: MailError.connectionLimitReached) {
                try Mail.Database(root: root, configuration: configuration)
            }
            #expect(throws: MailError.connectionLimitReached) {
                try Mail.Database(root: root)
            }
            first.close()
            first.close()
            #expect(throws: (any Error).self) { try Mail.Database(root: root) }
            second.close()
            let exclusive = try Mail.Database(root: root)
            #expect(throws: (any Error).self) { try Mail.Database(root: root, configuration: configuration) }
            exclusive.close()
            let reopened = try Mail.Database(root: root, configuration: configuration)
            #expect(try reopened.fetch(.init()).count == 3)
        }

        @Test(
            "Limits that are not positive fail before admission",
            arguments: [
                (Mail.Database.Configuration(queryTimeLimit: .zero), Mail.Database.Configuration.ValidationError.invalidQueryTimeLimit),
                (Mail.Database.Configuration(queryTimeLimit: .milliseconds(-1)), .invalidQueryTimeLimit),
                (Mail.Database.Configuration(maximumConnections: 0), .invalidMaximumConnections),
                (Mail.Database.Configuration(maximumConnections: -1), .invalidMaximumConnections),
            ]
        )
        func invalidConfigurationFailsBeforeAdmission(
            configuration: Mail.Database.Configuration,
            expected: Mail.Database.Configuration.ValidationError
        ) throws {
            #expect(throws: expected) { try Mail.Database(root: store.root, configuration: configuration) }
            // The missing folder is not checked, because validation comes first.
            #expect(throws: expected) {
                try Mail.Database(root: store.root.appendingPathComponent("Missing"), configuration: configuration)
            }
            #expect(try Mail.Database(root: store.root).fetch(.init()).count == 3)
        }

        @Test("A WAL writer can commit during a read and checkpoint afterward")
        func walWriterCanCommitDuringReadAndCheckpointAfterward() throws {
            let database = try Mail.Database(root: store.root)
            var wroteDuringRead = false
            let ids = try database.query("SELECT ROWID FROM messages ORDER BY ROWID") { row in
                if !wroteDuringRead {
                    try store.execute("INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com')")
                    wroteDuringRead = true
                    // A reader still delays WAL reset, even with SQLITE_OPEN_READONLY.
                    #expect(store.checkpoint() == SQLITE_BUSY)
                }
                return row.integer(0)
            }
            #expect(ids == [1, 2, 3])
            // Finalizing the statement releases its read lock, before connection close.
            #expect(store.checkpoint() == SQLITE_OK)
            #expect(try database.fetch(.init()).first?.id.rowID == 4)
        }

        @Test("A separate writer process can commit and then reset the WAL")
        func separateWriterProcessCanCommitAndThenResetWAL() throws {
            let index = store.index
            func runWriter(_ sql: String) throws -> String {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                process.arguments = ["-batch", index.path, sql]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                #expect(process.terminationStatus == 0, "\(text)")
                return text
            }

            // Allow for process startup in this synthetic contention test.
            // The separate deadline test exercises the production 100 ms budget.
            let database = try Mail.Database(root: store.root, configuration: .init(queryTimeLimit: .seconds(2)))
            var wroteDuringRead = false
            try database.query("SELECT ROWID FROM messages ORDER BY ROWID") { _ in
                if !wroteDuringRead {
                    let result = try runWriter(
                        """
                        INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com');
                        PRAGMA wal_checkpoint(TRUNCATE);
                        """
                    )
                    #expect(result.hasPrefix("1|"), "\(result)")
                    wroteDuringRead = true
                }
            }
            #expect(wroteDuringRead)
            #expect(try runWriter("PRAGMA wal_checkpoint(TRUNCATE); SELECT count(*) FROM messages;") == "0|0|0\n4\n")
        }

        @Test("The query deadline releases the read lock")
        func queryDeadlineReleasesReadLock() throws {
            let database = try Mail.Database(root: store.root)
            let start = ContinuousClock.now
            #expect(throws: MailError.queryTimedOut) {
                try database.query(
                    """
                    WITH RECURSIVE counter(n) AS (
                        SELECT ROWID FROM messages
                        UNION ALL SELECT n + 1 FROM counter WHERE n < 1000000000
                    ) SELECT sum(n) FROM counter
                    """
                ) { $0.integer(0) }
            }
            #expect(start.duration(to: .now) < .seconds(2))
            #expect(store.checkpoint() == SQLITE_OK)
            // An interrupted statement must not poison the next request.
            #expect(try database.fetch(.init()).count == 3)
        }

        @Test("A throwing transform releases the read lock")
        func thrownTransformReleasesReadLock() throws {
            let database = try Mail.Database(root: store.root)
            #expect(throws: CocoaError(.featureUnsupported)) {
                try database.query("SELECT ROWID FROM messages") { _ -> Int in
                    throw CocoaError(.featureUnsupported)
                }
            }
            #expect(store.checkpoint() == SQLITE_OK)
        }

        @Test("Cancellation releases the read lock and connection admission")
        func cancellationReleasesReadLockAndConnectionAdmission() async throws {
            let root = store.root
            let task = Task {
                let database = try Mail.Database(root: root)
                return try database.query("SELECT ROWID FROM messages") { row in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return row.integer(0)
                }
            }
            // No partial results are returned.
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(store.checkpoint() == SQLITE_OK)
            #expect(try Mail.Database(root: root).fetch(.init()).count == 3)
        }

        @Test("Overlapping connections are rejected, and a closed connection can reopen")
        func rejectsOverlappingConnectionsAndAllowsReopen() throws {
            let root = store.root
            let database = try Mail.Database(root: root)
            #expect(throws: MailError.connectionLimitReached) { try Mail.Database(root: root) }
            database.close()
            database.close()
            let reopened = try Mail.Database(root: root)
            #expect(try reopened.fetch(.init()).count == 3)
            #expect(throws: MailError.connectionClosed) { try database.fetch(.init()) }
        }

        @Test("A busy index fails without waiting and allows a reopen")
        func busyIndexFailsWithoutWaitingAndAllowsReopen() throws {
            try store.execute("PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE; UPDATE messages SET read=1;")
            defer { try? store.execute("ROLLBACK; PRAGMA locking_mode=NORMAL;") }
            let start = ContinuousClock.now
            #expect(throws: MailError.databaseBusy) { try Mail.Database(root: store.root) }
            #expect(start.duration(to: .now) < .milliseconds(500))
            try store.execute("ROLLBACK; PRAGMA locking_mode=NORMAL; SELECT * FROM messages;")
            #expect(try Mail.Database(root: store.root).fetch(.init()).count == 3)
        }

        @Test("An unreadable index is not reported as a schema error")
        func unreadableIndexIsNotReportedAsSchemaError() throws {
            store.closeWriter()
            let index = store.index
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: index.path + suffix)
            }
            try Data(repeating: 0x41, count: 8_192).write(to: index)
            #expect(throws: MailError.indexNotReadable) { try Mail.Database(root: store.root) }
            #expect(try Mail.Database.location(in: store.root).indexURL.lastPathComponent == "Envelope Index")
        }

        @Test("A rollback journal is rejected and left unchanged")
        func rejectsRollbackJournalWithoutChangingIt() throws {
            try store.execute("PRAGMA journal_mode=DELETE;")
            #expect(throws: MailError.unsupportedJournalMode) { try Mail.Database(root: store.root) }
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(store.writer, "PRAGMA journal_mode", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            #expect(sqlite3_step(statement) == SQLITE_ROW)
            #expect(String(cString: sqlite3_column_text(statement, 0)) == "delete")
            try store.execute("INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com')")
        }

        @Test("A read transaction uses one snapshot and releases it")
        func readTransactionUsesOneSnapshotAndReleasesIt() throws {
            let database = try Mail.Database(root: store.root)
            let counts = try database.readTransaction {
                let before = try database.query("SELECT count(*) FROM messages") { $0.integer(0) }
                try store.execute("INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com')")
                let after = try database.query("SELECT count(*) FROM messages") { $0.integer(0) }
                return (before, after)
            }
            #expect(counts.0 == [3])
            #expect(counts.1 == [3])
            #expect(store.checkpoint() == SQLITE_OK)

            #expect(throws: (any Error).self) {
                try database.readTransaction { try database.query("SELECT missing FROM messages") { _ in } }
            }
            #expect(store.checkpoint() == SQLITE_OK)
            #expect(try database.search(.init()).indexedMessageCount == 4)
            #expect(store.checkpoint() == SQLITE_OK)
        }

        @Test("Discovery picks the newest store with an index, and checks the schema")
        func discoveryAndUnsupportedSchema() throws {
            try FileManager.default.createDirectory(
                at: store.root.appendingPathComponent("V99"),
                withIntermediateDirectories: true
            )
            #expect(try Mail.Database(root: store.root).versionURL.lastPathComponent == "V10")
            try store.execute("DROP TABLE subjects")
            #expect(throws: MailError.unsupportedSchema) { try Mail.Database(root: store.root) }
        }
    }
}
