import Foundation

/// A message in the local Mail index.
public struct Message: Sendable, Hashable, Identifiable {
    /// An identifier that finds a message again in the same store.
    ///
    /// The identifier includes the store and the home mailbox,
    /// so a lookup rejects an identifier from an earlier store or for a message that moved.
    /// Its string form is `store:mailboxID:rowID`, such as `V10:12:345`.
    public struct Identifier: Sendable, Hashable, LosslessStringConvertible {
        /// The name of the store directory, such as `V10`.
        public let store: String
        /// The row identifier of the home mailbox.
        public let mailboxID: Int64
        /// The row identifier of the message.
        public let rowID: Int64

        /// Creates an identifier from the values in an index row.
        init(store: String, mailboxID: Int64, rowID: Int64) {
            self.store = store
            self.mailboxID = mailboxID
            self.rowID = rowID
        }

        /// Creates an identifier from its string form, such as `V10:12:345`.
        ///
        /// The string must have three fields that colons separate:
        /// a store name that is not empty, a positive mailbox row identifier,
        /// and a positive message row identifier.
        /// The initializer returns `nil` if the string does not have this form.
        /// - Parameter description: The string form of an identifier.
        public init?(_ description: String) {
            let parts = description.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty,
                let mailboxID = Int64(parts[1]), mailboxID > 0,
                let rowID = Int64(parts[2]), rowID > 0
            else { return nil }
            self.init(store: String(parts[0]), mailboxID: mailboxID, rowID: rowID)
        }

        /// The string form of the identifier, `store:mailboxID:rowID`.
        ///
        /// Pass this string to ``init(_:)`` to create the identifier again.
        public var description: String {
            "\(store):\(mailboxID):\(rowID)"
        }
    }

    /// The identifier of the message, which includes its store and home mailbox.
    public let id: Identifier
    /// The URL string of the home mailbox, if Mail records one.
    public let mailboxURL: String?
    /// The subject in the index, if any.
    public let subject: String?
    /// The sender address in the index, if any.
    public let sender: String?
    /// The date that Mail received the message.
    public let date: Date
    /// A Boolean value that indicates whether the index marks the message as read.
    public let isRead: Bool
    /// The value of the index's `message_id` column, if any.
    ///
    /// Some schemas store the RFC 5322 Message-ID in this column.
    /// Other schemas store an integer, which does not identify the message file.
    public let messageID: String?
    /// The value of the index's `date_received` column, in seconds since 1970.
    ///
    /// Cursors keep this value, so that they compare with the column exactly.
    let receivedTimestamp: Double

    /// Reads the current row of a statement from ``FetchRequest/statement(matchesLabels:countOnly:)``.
    init(_ row: Database.Row, store: String) throws {
        guard let rowID = row.integer(0), let mailboxID = row.integer(1),
            let date = row.double(5), date.isFinite
        else {
            throw MailError.unsupportedSchema
        }

        id = Identifier(store: store, mailboxID: mailboxID, rowID: rowID)
        mailboxURL = row.text(2)
        subject = row.text(3)
        sender = row.text(4)
        self.date = Date(timeIntervalSince1970: date)
        receivedTimestamp = date
        isRead = row.integer(6) == 1
        messageID = row.text(7)
    }
}
