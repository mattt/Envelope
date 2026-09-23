import Foundation
import SQLite3
import XCTest
import Emlx
@testable import Mail

final class MailTests: XCTestCase {
    private var root: URL!
    private var writer: OpaquePointer?
    private var version: URL { root.appendingPathComponent("V10") }
    private var mailbox: URL { version.appendingPathComponent("account/Inbox.mbox") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: version.appendingPathComponent("MailData"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: mailbox, withIntermediateDirectories: true)
        XCTAssertEqual(sqlite3_open(version.appendingPathComponent("MailData/Envelope Index").path, &writer), SQLITE_OK)
        try execute(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, mailbox INTEGER, subject INTEGER, sender INTEGER, date_received INTEGER, read INTEGER, message_id TEXT);
            CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
            CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT);
            CREATE TABLE labels (message_id INTEGER, mailbox_id INTEGER);
            INSERT INTO subjects VALUES (1, 'Budget 100%'), (2, 'Other');
            INSERT INTO addresses VALUES (1, 'alice@example.com'), (2, 'bob@example.com');
            INSERT INTO mailboxes VALUES (1, '\(mailbox.absoluteString)'), (2, '\(version.appendingPathComponent("account/Other.mbox").absoluteString)');
            INSERT INTO messages VALUES (1,1,1,1,100,0,'one@example.com'), (2,2,1,1,200,1,'two@example.com'), (3,1,2,2,300,0,'three@example.com');
            INSERT INTO labels VALUES (2,1);
            """
        )
    }

    override func tearDownWithError() throws {
        sqlite3_close(writer)
        writer = nil
        try FileManager.default.removeItem(at: root)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK else {
            throw Mail.Error.queryFailed(String(cString: sqlite3_errmsg(writer)))
        }
    }

    private func emlx(_ mime: String) -> Data {
        let payload = Data(mime.utf8)
        return Data("\(payload.count)\n".utf8) + payload + Data("\n<plist>ignored trailer</plist>".utf8)
    }

    private func checkpoint() -> Int32 {
        sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    func testConfiguredConnectionLimitsAndAdmissionRelease() throws {
        let configuration = Mail.Database.Configuration(queryTimeLimit: .seconds(2), maximumConnections: 2)
        let first = try Mail.Database(root: root, configuration: configuration)
        let second = try Mail.Database(root: root, configuration: configuration)
        XCTAssertThrowsError(try Mail.Database(root: root, configuration: configuration)) { error in
            XCTAssertEqual(error as? Mail.Error, .databaseBusy)
        }
        XCTAssertThrowsError(try Mail.Database(root: root)) { error in
            XCTAssertEqual(error as? Mail.Error, .databaseBusy)
        }
        first.close()
        first.close()
        XCTAssertThrowsError(try Mail.Database(root: root))
        second.close()
        let exclusive = try Mail.Database(root: root)
        XCTAssertThrowsError(try Mail.Database(root: root, configuration: configuration))
        exclusive.close()
        let reopened = try Mail.Database(root: root, configuration: configuration)
        XCTAssertEqual(try reopened.fetch(.init()).count, 3)
    }

    func testWALWriterCanCommitDuringReadAndCheckpointAfterward() throws {
        let database = try Mail.Database(root: root)
        var wroteDuringRead = false
        let ids = try database.query("SELECT ROWID FROM messages ORDER BY ROWID") { row in
            if !wroteDuringRead {
                try execute("INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com')")
                wroteDuringRead = true
                // A reader still delays WAL reset, even with SQLITE_OPEN_READONLY.
                XCTAssertEqual(checkpoint(), SQLITE_BUSY)
            }
            return row.integer(0)
        }
        XCTAssertEqual(ids, [1, 2, 3])
        // Finalizing the statement releases its read lock, before connection close.
        XCTAssertEqual(checkpoint(), SQLITE_OK)
        XCTAssertEqual(try database.fetch(.init()).first?.id, 4)
    }

    func testSeparateWriterProcessCanCommitAndThenResetWAL() throws {
        func runWriter(_ sql: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = ["-batch", version.appendingPathComponent("MailData/Envelope Index").path, sql]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, text)
            return text
        }

        // Allow for process startup in this synthetic contention test.
        // The separate deadline test exercises the production 100 ms budget.
        let database = try Mail.Database(root: root, configuration: .init(queryTimeLimit: .seconds(2)))
        var wroteDuringRead = false
        try database.query("SELECT ROWID FROM messages ORDER BY ROWID") { _ in
            if !wroteDuringRead {
                let result = try runWriter(
                    """
                    INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com');
                    PRAGMA wal_checkpoint(TRUNCATE);
                    """
                )
                XCTAssertTrue(result.hasPrefix("1|"), result)
                wroteDuringRead = true
            }
        }
        XCTAssertTrue(wroteDuringRead)
        XCTAssertEqual(try runWriter("PRAGMA wal_checkpoint(TRUNCATE); SELECT count(*) FROM messages;"), "0|0|0\n4\n")
    }

    func testQueryDeadlineReleasesReadLock() throws {
        let database = try Mail.Database(root: root)
        let start = ContinuousClock.now
        XCTAssertThrowsError(
            try database.query(
                """
                WITH RECURSIVE counter(n) AS (
                    SELECT ROWID FROM messages
                    UNION ALL SELECT n + 1 FROM counter WHERE n < 1000000000
                ) SELECT sum(n) FROM counter
                """
            ) { $0.integer(0) }
        ) { error in
            XCTAssertEqual(error as? Mail.Error, .queryTimedOut)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(checkpoint(), SQLITE_OK)
        // An interrupted statement must not poison the next request.
        XCTAssertEqual(try database.fetch(.init()).count, 3)
    }

    func testThrownTransformReleasesReadLock() throws {
        let database = try Mail.Database(root: root)
        XCTAssertThrowsError(
            try database.query("SELECT ROWID FROM messages") { _ -> Int in
                throw Mail.Error.messageMismatch
            }
        ) { error in
            XCTAssertEqual(error as? Mail.Error, .messageMismatch)
        }
        XCTAssertEqual(checkpoint(), SQLITE_OK)
    }

    func testCancellationReleasesReadLockAndConnectionAdmission() async throws {
        let root = try XCTUnwrap(root)
        let task = Task {
            let database = try Mail.Database(root: root)
            return try database.query("SELECT ROWID FROM messages") { row in
                withUnsafeCurrentTask { $0?.cancel() }
                return row.integer(0)
            }
        }
        do {
            _ = try await task.value
            XCTFail("Expected task cancellation")
        } catch is CancellationError {
            // Expected; no partial results are returned.
        }
        XCTAssertEqual(checkpoint(), SQLITE_OK)
        XCTAssertEqual(try Mail.Database(root: root).fetch(.init()).count, 3)
    }

    func testRejectsOverlappingConnectionsAndAllowsReopen() throws {
        let database = try Mail.Database(root: root)
        XCTAssertThrowsError(try Mail.Database(root: root)) { error in
            XCTAssertEqual(error as? Mail.Error, .databaseBusy)
        }
        database.close()
        database.close()
        let reopened = try Mail.Database(root: root)
        XCTAssertEqual(try reopened.fetch(.init()).count, 3)
        XCTAssertThrowsError(try database.fetch(.init())) { error in
            XCTAssertEqual(error as? Mail.Error, .indexNotReadable)
        }
    }

    @MainActor
    func testWorkerRejectsOverlapAndReleasesAdmissionAfterCancellation() async throws {
        let worker = Mail.Worker()
        let entered = expectation(description: "Worker started")
        // Only the dispatch worker waits on this semaphore, never an async task.
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task {
            try await worker.run { _ in
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else {
                    throw Mail.Error.queryTimedOut
                }
                return 1
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        do {
            _ = try await worker.run { _ in 2 }
            XCTFail("Expected the overlapping operation to be rejected")
        } catch {
            XCTAssertEqual(error as? Mail.Error, .databaseBusy)
        }

        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation instead of the worker's result")
        } catch is CancellationError {
            // The worker must release admission before returning cancellation.
        }
        let result = try await worker.run { _ in 3 }
        XCTAssertEqual(result, 3)
    }

    func testWorkerCancellationInterruptsQueryAndReleasesReadLock() async throws {
        let root = try XCTUnwrap(root)
        let worker = Mail.Worker()
        let entered = expectation(description: "Query returned its first row")
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
                    if n == 1 { entered.fulfill() }
                    return n
                }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation of the query on the dispatch worker")
        } catch is CancellationError {
            // Cancellation must reach SQLite without the caller's task context.
        }
        XCTAssertEqual(checkpoint(), SQLITE_OK)
        let count = try await worker.run { cancellation in
            let database = try Mail.Database(root: root, cancellation: cancellation)
            defer { database.close() }
            return try database.fetch(.init()).count
        }
        XCTAssertEqual(count, 3)
    }

    func testWorkerDoesNotStartAlreadyCancelledOperation() async throws {
        let worker = Mail.Worker()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.run { _ in
                XCTFail("A canceled task must not start file or database work")
                return 1
            }
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let result = try await worker.run { _ in 2 }
        XCTAssertEqual(result, 2)
    }

    func testBusyIndexFailsWithoutWaitingAndAllowsReopen() throws {
        try execute("PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE; UPDATE messages SET read=1;")
        defer { try? execute("ROLLBACK; PRAGMA locking_mode=NORMAL;") }
        let start = ContinuousClock.now
        XCTAssertThrowsError(try Mail.Database(root: root)) { error in
            XCTAssertEqual(error as? Mail.Error, .databaseBusy)
        }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        try execute("ROLLBACK; PRAGMA locking_mode=NORMAL; SELECT * FROM messages;")
        XCTAssertEqual(try Mail.Database(root: root).fetch(.init()).count, 3)
    }

    func testRejectsRollbackJournalWithoutChangingIt() throws {
        try execute("PRAGMA journal_mode=DELETE;")
        XCTAssertThrowsError(try Mail.Database(root: root)) { error in
            XCTAssertEqual(error as? Mail.Error, .unsupportedJournalMode)
        }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(writer, "PRAGMA journal_mode", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "delete")
        try execute("INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com')")
    }

    func testSearchFiltersPaginationAndLiveWAL() throws {
        let database = try Mail.Database(root: root)
        XCTAssertEqual(try database.fetch(.init()).map(\.id), [3, 2, 1])
        var query = Mail.Message.FetchRequest()
        query.sender = "ALICE"
        query.subject = "%"
        query.mailbox = 1
        query.startDate = Date(timeIntervalSince1970: 100)
        query.endDate = Date(timeIntervalSince1970: 200)
        query.isRead = false
        XCTAssertEqual(try database.fetch(query).map(\.id), [1])
        query.endDate = Date(timeIntervalSince1970: 201)
        query.isRead = true
        XCTAssertEqual(try database.fetch(query).map(\.id), [2])
        query = .init()
        query.limit = 1
        query.offset = 1
        XCTAssertEqual(try database.fetch(query).map(\.id), [2])
        try execute("INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com')")
        XCTAssertEqual(try database.fetch(.init()).first?.id, 4)
        query.limit = 101
        XCTAssertThrowsError(try database.fetch(query))
        query.limit = 1
        query.offset = -1
        XCTAssertThrowsError(try database.fetch(query))
        query = .init()
        query.sender = "' OR 1=1 --"
        XCTAssertTrue(try database.fetch(query).isEmpty)
    }

    func testReadTransactionUsesOneSnapshotAndReleasesIt() throws {
        let database = try Mail.Database(root: root)
        let counts = try database.readTransaction {
            let before = try database.query("SELECT count(*) FROM messages") { $0.integer(0) }
            try execute("INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com')")
            let after = try database.query("SELECT count(*) FROM messages") { $0.integer(0) }
            return (before, after)
        }
        XCTAssertEqual(counts.0, [3])
        XCTAssertEqual(counts.1, [3])
        XCTAssertEqual(checkpoint(), SQLITE_OK)

        XCTAssertThrowsError(try database.readTransaction { try database.query("SELECT missing FROM messages") { _ in } })
        XCTAssertEqual(checkpoint(), SQLITE_OK)
        XCTAssertEqual(try database.search(.init()).indexedMessageCount, 4)
        XCTAssertEqual(checkpoint(), SQLITE_OK)
    }

    func testSubstringSearchIgnoresCaseBeyondASCII() throws {
        try execute(
            """
            INSERT INTO subjects VALUES (3, 'École d''été');
            INSERT INTO addresses VALUES (3, 'ÉLODIE@example.com');
            INSERT INTO messages VALUES (4,1,3,3,400,0,'four@example.com');
            """
        )
        let database = try Mail.Database(root: root)
        XCTAssertEqual(try database.fetch(.init(subject: "école")).map(\.id), [4])
        XCTAssertEqual(try database.fetch(.init(subject: "D'ÉTÉ")).map(\.id), [4])
        XCTAssertEqual(try database.fetch(.init(sender: "élodie")).map(\.id), [4])
        XCTAssertEqual(try database.fetch(.init(subject: "ecole")).map(\.id), [])
        XCTAssertEqual(try database.fetch(.init(sender: "ALICE")).map(\.id), [2, 1])
    }

    func testReceivedDateAndRangeUseUnixEpoch() throws {
        // Use literal timestamps and independently parsed calendar dates so the
        // fixture cannot hide an epoch change in both decoding and filtering.
        try execute(
            """
            INSERT INTO messages VALUES
                (4,1,1,1,1704067199,0,'before@example.com'),
                (5,1,1,1,1704067200,0,'start@example.com'),
                (6,1,1,1,1704153599,0,'last@example.com'),
                (7,1,1,1,1704153600,0,'end@example.com');
            """
        )
        let formatter = ISO8601DateFormatter()
        let start = try XCTUnwrap(formatter.date(from: "2024-01-01T00:00:00Z"))
        let end = try XCTUnwrap(formatter.date(from: "2024-01-02T00:00:00Z"))
        let database = try Mail.Database(root: root)
        let record = try XCTUnwrap(database.fetch(.init(id: 5)).first)
        XCTAssertEqual(record.date, start)
        XCTAssertEqual(record.date.formatted(.iso8601), "2024-01-01T00:00:00Z")

        var request = Mail.Message.FetchRequest()
        request.startDate = start
        request.endDate = end
        XCTAssertEqual(try database.fetch(request).map(\.id), [6, 5])
        request.endDate = nil
        XCTAssertEqual(try database.fetch(request).map(\.id), [7, 6, 5])
        request.startDate = nil
        request.endDate = end
        XCTAssertEqual(try database.fetch(request).map(\.id), [6, 5, 4, 3, 2, 1])
    }

    func testDefaultAndMaximumLimits() throws {
        try execute(
            """
            WITH RECURSIVE numbers(n) AS (SELECT 4 UNION ALL SELECT n+1 FROM numbers WHERE n<110)
            INSERT INTO messages SELECT n,1,1,1,400+n,0,'id@example.com' FROM numbers;
            """
        )
        let database = try Mail.Database(root: root)
        XCTAssertEqual(try database.fetch(.init()).count, 30)
        var request = Mail.Message.FetchRequest()
        request.limit = 100
        XCTAssertEqual(try database.fetch(request).count, 100)
        XCTAssertThrowsError(try database.query("DELETE FROM messages") { _ in })
        XCTAssertEqual(try database.mailboxes().count, 2)
    }

    func testListedMailboxIdentifierWorksAsSearchFilter() throws {
        let database = try Mail.Database(root: root)
        let listed = try XCTUnwrap(database.mailboxes().first { $0.id == 1 })
        let identifier = String(listed.id)
        let request = Mail.Message.FetchRequest(mailbox: try Mail.Mailbox.parseIdentifier(identifier))
        XCTAssertEqual(try database.fetch(request).map(\.id), [3, 2, 1])
        XCTAssertThrowsError(try Mail.Mailbox.parseIdentifier(listed.url)) { error in
            XCTAssertEqual(error as? Mail.ValidationError, .invalidMailboxIdentifier)
        }
        for invalid in ["", "0", "-1", "+1", " 1", "1.0", "INBOX", "9223372036854775808"] {
            XCTAssertThrowsError(try Mail.Mailbox.parseIdentifier(invalid), invalid)
        }
        XCTAssertThrowsError(try database.search(.init(mailbox: 999))) { error in
            XCTAssertTrue(error.localizedDescription.contains("does not exist"))
        }
    }

    func testSearchExplainsLocalIndexCoverage() throws {
        let database = try Mail.Database(root: root)
        // A label and home membership must count the message only once.
        try execute("INSERT INTO labels VALUES (1,1), (2,1)")
        var request = Mail.Message.FetchRequest(subject: "No match", mailbox: 1)
        var result = try database.search(request)
        XCTAssertEqual(result.records.count, 0)
        XCTAssertEqual(result.indexedMessageCount, 3)
        XCTAssertEqual(result.filters, request)

        request.subject = nil
        request.offset = 100
        result = try database.search(request)
        XCTAssertEqual(result.records.count, 0)
        XCTAssertEqual(result.indexedMessageCount, 3)

        try execute("INSERT INTO mailboxes VALUES (3, 'imap://account/Empty')")
        result = try database.search(.init(mailbox: 3))
        XCTAssertEqual(result.indexedMessageCount, 0)
        XCTAssertEqual(result.filters.mailbox, 3)

        try execute("DROP TABLE labels")
        result = try database.search(.init(mailbox: 1))
        XCTAssertEqual(result.indexedMessageCount, 2)
        result = try database.search(.init())
        XCTAssertEqual(result.indexedMessageCount, 3)
    }

    func testAccountLabelsAndMissingMetadata() throws {
        let first = "11111111-1111-4111-8111-111111111111"
        let second = "22222222-2222-4222-8222-222222222222"
        let third = "33333333-3333-4333-8333-333333333333"
        try execute(
            """
            UPDATE mailboxes SET url = 'imap://\(first)/INBOX' WHERE ROWID = 1;
            UPDATE mailboxes SET url = 'imap://\(second)/INBOX' WHERE ROWID = 2;
            INSERT INTO mailboxes VALUES (3, 'imap://\(third)/INBOX');
            INSERT INTO mailboxes VALUES (4, '\(version.appendingPathComponent(first + "/Archive.mbox").absoluteString)');
            """
        )
        let database = try Mail.Database(root: root)
        XCTAssertTrue(try database.mailboxes().allSatisfy { $0.account?.email == nil })
        let metadata = version.appendingPathComponent("MailData/Signatures/AccountsMap.plist")
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let entries: [String: Any] = [
            first: ["AccountURL": "imap://personal%2Bmail%40example.com@imap.example.com/"],
            second: ["AccountURL": "imap://work%40example.com@imap.example.com/"],
            third: ["AccountURL": "imap://username@imap.example.com/"],
            "invalid-entry": "not an account",
        ]
        try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0).write(to: metadata)
        let mailboxes = try database.mailboxes()
        let personal = try XCTUnwrap(mailboxes.first { $0.id == 1 })
        let work = try XCTUnwrap(mailboxes.first { $0.id == 2 })
        XCTAssertEqual(personal.name, work.name)
        XCTAssertEqual(personal.account?.email, "personal+mail@example.com")
        XCTAssertEqual(work.account?.email, "work@example.com")
        XCTAssertEqual(mailboxes.first { $0.id == 3 }?.account?.id, third)
        XCTAssertNil(mailboxes.first { $0.id == 3 }?.account?.email)
        XCTAssertEqual(mailboxes.first { $0.id == 4 }?.account?.email, "personal+mail@example.com")

        try Data("invalid plist".utf8).write(to: metadata)
        XCTAssertTrue(try database.mailboxes().allSatisfy { $0.account?.email == nil })
        try FileManager.default.removeItem(at: metadata)
        let outside = root.appendingPathComponent("Outside.plist")
        try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0).write(to: outside)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: outside)
        XCTAssertTrue(try database.mailboxes().allSatisfy { $0.account?.email == nil })
    }

    func testDiscoveryAndUnsupportedSchema() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("V99"),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(try Mail.Database(root: root).versionURL.lastPathComponent, "V10")
        try execute("DROP TABLE subjects")
        XCTAssertThrowsError(try Mail.Database(root: root)) { error in
            XCTAssertEqual(error as? Mail.Error, .unsupportedSchema)
        }
    }

    func testFileSeparationIdentityAndStaleCache() throws {
        let database = try Mail.Database(root: root)
        let record = try XCTUnwrap(database.fetch(.init()).last)
        let files = Mail.Files()
        XCTAssertThrowsError(try files.readContent(record, version: version))
        let url = mailbox.appendingPathComponent("1.emlx")
        try emlx("Message-ID: <one@example.com>\nSubject: One\n\nCorrect").write(to: url)
        XCTAssertEqual(try files.readContent(record, version: version).body, "Correct")
        try emlx("Message-ID: <wrong@example.com>\nSubject: Wrong\n\nWrong").write(to: url)
        XCTAssertThrowsError(try files.readContent(record, version: version))
        try FileManager.default.removeItem(at: url)
        let other = version.appendingPathComponent("account/Other.mbox")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try emlx("Message-ID: <one@example.com>\nSubject: One\n\nWrong mailbox").write(
            to: other.appendingPathComponent("1.emlx")
        )
        XCTAssertThrowsError(try files.readContent(record, version: version))
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other.appendingPathComponent("1.emlx"))
        XCTAssertThrowsError(try files.readContent(record, version: version))
        XCTAssertThrowsError(try files.mailboxDirectory("file:///tmp/Outside.mbox", version: version))
    }

    func testFileReadMapsAccountMailboxesAndRejectsAnotherStore() throws {
        let account = "11111111-1111-4111-8111-111111111111"
        try execute("UPDATE mailboxes SET url = 'imap://\(account)/Folder/INBOX' WHERE ROWID = 1")
        let database = try Mail.Database(root: root)
        let record = try XCTUnwrap(database.fetch(.init(id: 1)).first)
        database.close()
        for store in ["V10", "V11"] {
            let messages = root.appendingPathComponent("\(store)/\(account)/Folder.mbox/INBOX.mbox/Data/1/Messages")
            try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
            try emlx("Message-ID: <one@example.com>\nSubject: One\n\n\(store)").write(to: messages.appendingPathComponent("1.emlx"))
        }
        let files = Mail.Files()
        XCTAssertEqual(try files.readContent(record, version: version).body, "V10")
        XCTAssertThrowsError(try files.readContent(record, version: root.appendingPathComponent("V11"))) { error in
            XCTAssertEqual(error as? Mail.Error, .storeChanged)
        }
    }

    func testFileReadsAndMIMEParsingRespectCancellation() throws {
        let database = try Mail.Database(root: root)
        let record = try XCTUnwrap(database.fetch(.init()).last)
        database.close()
        let files = Mail.Files()
        let cancellation = Mail.Cancellation()
        cancellation.cancel()
        // A canceled cold lookup must stop before reporting a missing file.
        XCTAssertThrowsError(try files.readContent(record, version: version, cancellation: cancellation)) { error in
            XCTAssertTrue(error is CancellationError)
        }

        let data = emlx("Message-ID: <one@example.com>\nSubject: One\n\nCorrect")
        try data.write(to: mailbox.appendingPathComponent("1.emlx"))
        XCTAssertEqual(try files.readContent(record, version: version).body, "Correct")
        XCTAssertThrowsError(try files.readContent(record, version: version, cancellation: cancellation)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try Emlx.Content(emlx: data, checkCancellation: cancellation.check)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try files.readContent(record, version: version).body, "Correct")
    }

    func testIdentifierRoundTripAndLookup() throws {
        let database = try Mail.Database(root: root)
        let record = try XCTUnwrap(database.fetch(.init()).first)
        XCTAssertEqual(record.identifier.description, "V10:1:3")
        XCTAssertEqual(Mail.Message.Identifier("V10:1:3"), record.identifier)
        XCTAssertEqual(try database.record(for: record.identifier).id, 3)
        for invalid in ["", "V10:1", "V10:1:3:4", ":1:3", "V10:0:3", "V10:1:-3", "V10:x:3"] {
            XCTAssertNil(Mail.Message.Identifier(invalid), invalid)
        }
        XCTAssertThrowsError(try database.record(for: .init(store: "V9", mailbox: 1, message: 3))) { error in
            XCTAssertEqual(error as? Mail.Error, .storeChanged)
        }
        // A label gives mailbox membership in search, but the identifier names the home mailbox.
        XCTAssertThrowsError(try database.record(for: .init(store: "V10", mailbox: 1, message: 2))) { error in
            XCTAssertEqual(error as? Mail.Error, .messageNotFound)
        }
    }

}

private extension Mail.Files {
    func readContent(_ record: Mail.Message, version: URL, cancellation: Mail.Cancellation = .init()) throws -> Emlx.Content {
        try read(record, version: version, cancellation: cancellation) {
            try Emlx.Content(emlx: $0, expectedMessageID: record.messageID, checkCancellation: cancellation.check)
        }
    }
}
