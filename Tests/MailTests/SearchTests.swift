import Foundation
import Testing

@testable import Mail

extension MailTests {
    @Suite
    struct SearchTests {
        let store: MailStore

        init() throws {
            store = try MailStore()
        }

        @Test("Search filters and pagination apply, and the live WAL is visible")
        func searchFiltersPaginationAndLiveWAL() throws {
            let database = try Mail.Database(root: store.root)
            #expect(try database.fetch(.init()).map(\.id.rowID) == [3, 2, 1])
            var query = Mail.Message.FetchRequest()
            query.sender = "ALICE"
            query.subject = "%"
            query.mailboxID = 1
            query.startDate = Date(timeIntervalSince1970: 100)
            query.endDate = Date(timeIntervalSince1970: 200)
            query.isRead = false
            #expect(try database.fetch(query).map(\.id.rowID) == [1])
            query.endDate = Date(timeIntervalSince1970: 201)
            query.isRead = true
            #expect(try database.fetch(query).map(\.id.rowID) == [2])
            query = .init()
            query.limit = 1
            query.offset = 1
            #expect(try database.fetch(query).map(\.id.rowID) == [2])
            try store.execute("INSERT INTO messages VALUES(4,1,1,1,400,0,'four@example.com')")
            #expect(try database.fetch(.init()).first?.id.rowID == 4)
            query.limit = 101
            #expect(throws: (any Error).self) { try database.fetch(query) }
            query.limit = 1
            query.offset = -1
            #expect(throws: (any Error).self) { try database.fetch(query) }
            query = .init()
            query.sender = "' OR 1=1 --"
            #expect(try database.fetch(query).isEmpty)
        }

        @Test(
            "Invalid requests fail validation",
            arguments: [
                (Mail.Message.FetchRequest(limit: 0), Mail.Message.FetchRequest.ValidationError.limitOutOfRange),
                (Mail.Message.FetchRequest(limit: Mail.Message.FetchRequest.maximumLimit + 1), .limitOutOfRange),
                (Mail.Message.FetchRequest(offset: -1), .negativeOffset),
                (Mail.Message.FetchRequest(startDate: Date(timeIntervalSince1970: 200), endDate: Date(timeIntervalSince1970: 200)), .invalidDateRange),
                (Mail.Message.FetchRequest(startDate: Date(timeIntervalSince1970: 300), endDate: Date(timeIntervalSince1970: 200)), .invalidDateRange),
            ]
        )
        func invalidRequestsFailValidation(request: Mail.Message.FetchRequest, expected: Mail.Message.FetchRequest.ValidationError) throws {
            let database = try Mail.Database(root: store.root)
            #expect(throws: expected) { try database.fetch(request) }
            #expect(throws: expected) { try database.search(request) }
        }

        @Test("A new request uses the default limit and no filters")
        func newRequestDefaults() {
            let request = Mail.Message.FetchRequest()
            #expect(request.limit == Mail.Message.FetchRequest.defaultLimit)
            #expect(request.limit == 30)
            #expect(Mail.Message.FetchRequest.maximumLimit == 100)
            #expect(request.offset == 0)
            #expect(request.sender == nil && request.subject == nil && request.mailboxID == nil)
            #expect(request.startDate == nil && request.endDate == nil && request.isRead == nil)
        }

        @Test("Substring search ignores case beyond ASCII")
        func substringSearchIgnoresCaseBeyondASCII() throws {
            try store.execute(
                """
                INSERT INTO subjects VALUES (3, 'École d''été');
                INSERT INTO addresses VALUES (3, 'ÉLODIE@example.com');
                INSERT INTO messages VALUES (4,1,3,3,400,0,'four@example.com');
                """
            )
            let database = try Mail.Database(root: store.root)
            #expect(try database.fetch(.init(subject: "école")).map(\.id.rowID) == [4])
            #expect(try database.fetch(.init(subject: "D'ÉTÉ")).map(\.id.rowID) == [4])
            #expect(try database.fetch(.init(sender: "élodie")).map(\.id.rowID) == [4])
            #expect(try database.fetch(.init(subject: "ecole")).map(\.id.rowID) == [])
            #expect(try database.fetch(.init(sender: "ALICE")).map(\.id.rowID) == [2, 1])
        }

        @Test("Received dates and date ranges use the Unix epoch")
        func receivedDateAndRangeUseUnixEpoch() throws {
            // Use literal timestamps and independently parsed calendar dates so the
            // fixture cannot hide an epoch change in both decoding and filtering.
            try store.execute(
                """
                INSERT INTO messages VALUES
                    (4,1,1,1,1704067199,0,'before@example.com'),
                    (5,1,1,1,1704067200,0,'start@example.com'),
                    (6,1,1,1,1704153599,0,'last@example.com'),
                    (7,1,1,1,1704153600,0,'end@example.com');
                """
            )
            let formatter = ISO8601DateFormatter()
            let start = try #require(formatter.date(from: "2024-01-01T00:00:00Z"))
            let end = try #require(formatter.date(from: "2024-01-02T00:00:00Z"))
            let database = try Mail.Database(root: store.root)
            let record = try #require(database.fetch(.init(rowID: 5)).first)
            #expect(record.date == start)
            #expect(record.date.formatted(.iso8601) == "2024-01-01T00:00:00Z")

            var request = Mail.Message.FetchRequest()
            request.startDate = start
            request.endDate = end
            #expect(try database.fetch(request).map(\.id.rowID) == [6, 5])
            request.endDate = nil
            #expect(try database.fetch(request).map(\.id.rowID) == [7, 6, 5])
            request.startDate = nil
            request.endDate = end
            #expect(try database.fetch(request).map(\.id.rowID) == [6, 5, 4, 3, 2, 1])
        }

        @Test("The default and maximum limits apply, and the connection is read-only")
        func defaultAndMaximumLimits() throws {
            try store.execute(
                """
                WITH RECURSIVE numbers(n) AS (SELECT 4 UNION ALL SELECT n+1 FROM numbers WHERE n<110)
                INSERT INTO messages SELECT n,1,1,1,400+n,0,'id@example.com' FROM numbers;
                """
            )
            let database = try Mail.Database(root: store.root)
            #expect(try database.fetch(.init()).count == 30)
            var request = Mail.Message.FetchRequest()
            request.limit = 100
            #expect(try database.fetch(request).count == 100)
            #expect(throws: (any Error).self) { try database.query("DELETE FROM messages") { _ in } }
            #expect(try database.mailboxes().count == 2)
        }

        @Test("A listed mailbox identifier works as a search filter")
        func listedMailboxIdentifierWorksAsSearchFilter() throws {
            let database = try Mail.Database(root: store.root)
            let listed = try #require(database.mailboxes().first { $0.id == 1 })
            let request = Mail.Message.FetchRequest(mailboxID: listed.id)
            #expect(try database.fetch(request).map(\.id.rowID) == [3, 2, 1])
            #expect(listed.name == "Inbox.mbox")
            #expect(throws: MailError.mailboxNotFound) { try database.search(.init(mailboxID: 999)) }
        }

        @Test("Search results report the local index coverage of their scope")
        func searchExplainsLocalIndexCoverage() throws {
            let database = try Mail.Database(root: store.root)
            // A label and home membership must count the message only once.
            try store.execute("INSERT INTO labels VALUES (1,1), (2,1)")
            var request = Mail.Message.FetchRequest(subject: "No match", mailboxID: 1)
            var result = try database.search(request)
            #expect(result.records.count == 0)
            #expect(result.indexedMessageCount == 3)
            #expect(result.request == request)

            request.subject = nil
            request.offset = 100
            result = try database.search(request)
            #expect(result.records.count == 0)
            #expect(result.indexedMessageCount == 3)

            try store.execute("INSERT INTO mailboxes VALUES (3, 'imap://account/Empty')")
            result = try database.search(.init(mailboxID: 3))
            #expect(result.indexedMessageCount == 0)
            #expect(result.request.mailboxID == 3)

            try store.execute("DROP TABLE labels")
            result = try database.search(.init(mailboxID: 1))
            #expect(result.indexedMessageCount == 2)
            result = try database.search(.init())
            #expect(result.indexedMessageCount == 3)
        }

        @Test("Mailboxes report accounts from the account map, and tolerate missing metadata")
        func accountLabelsAndMissingMetadata() throws {
            let first = "11111111-1111-4111-8111-111111111111"
            let second = "22222222-2222-4222-8222-222222222222"
            let third = "33333333-3333-4333-8333-333333333333"
            try store.execute(
                """
                UPDATE mailboxes SET url = 'imap://\(first)/INBOX' WHERE ROWID = 1;
                UPDATE mailboxes SET url = 'imap://\(second)/INBOX' WHERE ROWID = 2;
                INSERT INTO mailboxes VALUES (3, 'imap://\(third)/INBOX');
                INSERT INTO mailboxes VALUES (4, '\(store.version.appendingPathComponent(first + "/Archive.mbox").absoluteString)');
                """
            )
            let database = try Mail.Database(root: store.root)
            #expect(try database.mailboxes().allSatisfy { $0.account?.email == nil })
            let metadata = store.version.appendingPathComponent("MailData/Signatures/AccountsMap.plist")
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
            let personal = try #require(mailboxes.first { $0.id == 1 })
            let work = try #require(mailboxes.first { $0.id == 2 })
            #expect(personal.name == work.name)
            #expect(personal.account?.email == "personal+mail@example.com")
            #expect(work.account?.email == "work@example.com")
            #expect(mailboxes.first { $0.id == 3 }?.account?.id == third)
            #expect(mailboxes.first { $0.id == 3 }?.account?.email == nil)
            #expect(mailboxes.first { $0.id == 4 }?.account?.email == "personal+mail@example.com")

            try Data("invalid plist".utf8).write(to: metadata)
            #expect(try database.mailboxes().allSatisfy { $0.account?.email == nil })
            try FileManager.default.removeItem(at: metadata)
            let outside = store.root.appendingPathComponent("Outside.plist")
            try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0).write(to: outside)
            try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: outside)
            #expect(try database.mailboxes().allSatisfy { $0.account?.email == nil })
        }

        @Test("Identifiers round-trip through strings and find their message")
        func identifierRoundTripAndLookup() throws {
            let database = try Mail.Database(root: store.root)
            let record = try #require(database.fetch(.init()).first)
            #expect(record.id.description == "V10:1:3")
            #expect(Mail.Message.Identifier("V10:1:3") == record.id)
            #expect(try database.record(for: record.id).id.rowID == 3)
            for invalid in ["", "V10:1", "V10:1:3:4", ":1:3", "V10:0:3", "V10:1:-3", "V10:x:3"] {
                #expect(Mail.Message.Identifier(invalid) == nil, "\(invalid)")
            }
            #expect(throws: MailError.storeChanged) {
                try database.record(for: .init(store: "V9", mailboxID: 1, rowID: 3))
            }
            // A label gives mailbox membership in search, but the identifier names the home mailbox.
            #expect(throws: MailError.messageNotFound) {
                try database.record(for: .init(store: "V10", mailboxID: 1, rowID: 2))
            }
        }
    }
}
