import Emlx
import Foundation
import SQLite3

@testable import Mail

/// A synthetic Mail folder with one store, `V10`, and a writer connection to its index.
///
/// The index uses WAL journal mode and disables automatic checkpoints,
/// so that tests can observe readers that delay a checkpoint.
/// The store has two mailboxes, two subjects, two senders, three messages,
/// and one label that gives message 2 membership in mailbox 1.
/// Deinitialization closes the writer and removes the folder.
final class MailStore {
    let root: URL
    private(set) var writer: OpaquePointer?

    /// The store directory.
    var version: URL { root.appendingPathComponent("V10") }
    /// The `.mbox` folder of mailbox 1.
    var mailbox: URL { version.appendingPathComponent("account/Inbox.mbox") }
    /// The Envelope Index file.
    var index: URL { version.appendingPathComponent("MailData/Envelope Index") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: version.appendingPathComponent("MailData"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: mailbox, withIntermediateDirectories: true)
        guard sqlite3_open(index.path, &writer) == SQLITE_OK else {
            throw MailError.indexNotReadable
        }
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

    deinit {
        sqlite3_close(writer)
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs SQL on the writer connection.
    func execute(_ sql: String) throws {
        guard sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK else {
            throw MailError.queryFailed(String(cString: sqlite3_errmsg(writer)))
        }
    }

    /// Closes the writer connection before the test replaces the index.
    func closeWriter() {
        sqlite3_close(writer)
        writer = nil
    }

    /// Runs a truncating WAL checkpoint and returns its SQLite result code.
    ///
    /// The result is `SQLITE_BUSY` while a reader holds a snapshot.
    func checkpoint() -> Int32 {
        sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    /// Returns the contents of an `.emlx` file for a MIME message, with a trailing property list.
    func emlx(_ mime: String) -> Data {
        let payload = Data(mime.utf8)
        return Data("\(payload.count)\n".utf8) + payload + Data("\n<plist>ignored trailer</plist>".utf8)
    }
}

extension Mail.MessageFileReader {
    /// Reads and parses a message file the way the README describes.
    func readContent(_ record: Mail.Message, version: URL, cancellation: Mail.Cancellation = .init()) throws -> Emlx.Content {
        try read(record, version: version, cancellation: cancellation) {
            try Emlx.Content(emlx: $0, expectedMessageID: record.messageID, checkCancellation: cancellation.check)
        }
    }
}
