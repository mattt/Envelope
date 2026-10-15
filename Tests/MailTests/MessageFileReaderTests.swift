import Emlx
import Foundation
import Testing

@testable import Mail

extension MailTests {
    @Suite
    struct MessageFileReaderTests {
        let store: MailStore

        init() throws {
            store = try MailStore()
        }

        @Test("A message file must be a regular file")
        func messageFileMustBeRegularFile() throws {
            let database = try Mail.Database(root: store.root)
            let record = try #require(database.fetch(.init()).last)
            try FileManager.default.createDirectory(at: store.mailbox.appendingPathComponent("1.emlx"), withIntermediateDirectories: true)
            #expect(throws: MailError.messageFileNotRegular) {
                try Mail.MessageFileReader().readContent(record, version: store.version)
            }
        }

        @Test("Reads check file identity and location, and recover from a stale cache")
        func fileSeparationIdentityAndStaleCache() throws {
            let version = store.version
            let database = try Mail.Database(root: store.root)
            let record = try #require(database.fetch(.init()).last)
            let files = Mail.MessageFileReader()
            #expect(throws: (any Error).self) { try files.readContent(record, version: version) }
            let url = store.mailbox.appendingPathComponent("1.emlx")
            try store.emlx("Message-ID: <one@example.com>\nSubject: One\n\nCorrect").write(to: url)
            #expect(try files.readContent(record, version: version).body == "Correct")
            try store.emlx("Message-ID: <wrong@example.com>\nSubject: Wrong\n\nWrong").write(to: url)
            #expect(throws: (any Error).self) { try files.readContent(record, version: version) }
            try FileManager.default.removeItem(at: url)
            let other = version.appendingPathComponent("account/Other.mbox")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try store.emlx("Message-ID: <one@example.com>\nSubject: One\n\nWrong mailbox").write(
                to: other.appendingPathComponent("1.emlx")
            )
            #expect(throws: (any Error).self) { try files.readContent(record, version: version) }
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other.appendingPathComponent("1.emlx"))
            #expect(throws: (any Error).self) { try files.readContent(record, version: version) }
            #expect(throws: MailError.notContained(URL(string: "file:///tmp/Outside.mbox")!)) {
                try Mail.MessageFileReader.mailboxDirectory(for: "file:///tmp/Outside.mbox", in: version)
            }
        }

        @Test("Reads map account mailboxes to folders, and reject another store")
        func fileReadMapsAccountMailboxesAndRejectsAnotherStore() throws {
            let account = "11111111-1111-4111-8111-111111111111"
            try store.execute("UPDATE mailboxes SET url = 'imap://\(account)/Folder/INBOX' WHERE ROWID = 1")
            let database = try Mail.Database(root: store.root)
            let record = try #require(database.fetch(.init(rowID: 1)).first)
            database.close()
            for name in ["V10", "V11"] {
                let messages = store.root.appendingPathComponent("\(name)/\(account)/Folder.mbox/INBOX.mbox/Data/1/Messages")
                try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
                try store.emlx("Message-ID: <one@example.com>\nSubject: One\n\n\(name)").write(to: messages.appendingPathComponent("1.emlx"))
            }
            let files = Mail.MessageFileReader()
            #expect(try files.readContent(record, version: store.version).body == "V10")
            #expect(throws: MailError.storeChanged) {
                try files.readContent(record, version: store.root.appendingPathComponent("V11"))
            }
        }

        @Test("Lookup reports partial, duplicate, and oversized files")
        func fileLookupReportsPartialDuplicateAndOversizedFiles() throws {
            let version = store.version
            let database = try Mail.Database(root: store.root)
            let record = try #require(database.fetch(.init(rowID: 1)).first)
            database.close()
            let messages = store.mailbox.appendingPathComponent("Data/1/Messages")
            try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)

            try store.emlx("Subject: Partial\n\nPart").write(to: messages.appendingPathComponent("1.partial.emlx"))
            #expect(throws: MailError.partialMessage) {
                try Mail.MessageFileReader().readContent(record, version: version)
            }
            // A complete file takes precedence over a partial one.
            let file = messages.appendingPathComponent("1.emlx")
            try store.emlx("Message-ID: <one@example.com>\n\nComplete").write(to: file)
            #expect(try Mail.MessageFileReader().readContent(record, version: version).body == "Complete")

            let copies = store.mailbox.appendingPathComponent("Data/2/Messages")
            try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
            try store.emlx("Message-ID: <one@example.com>\n\nCopy").write(to: copies.appendingPathComponent("1.emlx"))
            #expect(throws: MailError.messageFileNotFound) {
                try Mail.MessageFileReader().readContent(record, version: version)
            }
            try FileManager.default.removeItem(at: copies)

            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 32 * 1_024 * 1_024 + 1)
            try handle.close()
            #expect(throws: MailError.messageFileTooLarge) {
                try Mail.MessageFileReader().readContent(record, version: version)
            }
        }

        @Test("File reads and MIME parsing respect cancellation")
        func fileReadsAndMIMEParsingRespectCancellation() throws {
            let version = store.version
            let database = try Mail.Database(root: store.root)
            let record = try #require(database.fetch(.init()).last)
            database.close()
            let files = Mail.MessageFileReader()
            let cancellation = Mail.Cancellation()
            cancellation.cancel()
            // A canceled cold lookup must stop before reporting a missing file.
            #expect(throws: CancellationError.self) {
                try files.readContent(record, version: version, cancellation: cancellation)
            }

            let data = store.emlx("Message-ID: <one@example.com>\nSubject: One\n\nCorrect")
            try data.write(to: store.mailbox.appendingPathComponent("1.emlx"))
            #expect(try files.readContent(record, version: version).body == "Correct")
            #expect(throws: CancellationError.self) {
                try files.readContent(record, version: version, cancellation: cancellation)
            }
            #expect(throws: CancellationError.self) {
                try Emlx.Content(emlx: data, checkCancellation: cancellation.check)
            }
            #expect(try files.readContent(record, version: version).body == "Correct")
        }
    }
}
