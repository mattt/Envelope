import Foundation

/// A row of the `messages` table, joined with its mailbox, subject, and sender.
public struct Message: Sendable {
    /// The identifier used to look up a message again.
    /// It names the store and mailbox as well,
    /// so an identifier from an earlier store or a moved message is rejected instead of misread.
    public struct Identifier: Sendable, Hashable, LosslessStringConvertible {
        /// The version directory name, such as `V10`.
        public let store: String
        /// The home mailbox row identifier.
        public let mailbox: Int64
        /// The message row identifier.
        public let message: Int64

        /// Creates an identifier from index values.
        /// - Parameters:
        ///   - store: The version directory name.
        ///   - mailbox: The home mailbox row identifier.
        ///   - message: The message row identifier.
        public init(store: String, mailbox: Int64, message: Int64) {
            self.store = store
            self.mailbox = mailbox
            self.message = message
        }

        public init?(_ description: String) {
            let parts = description.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty,
                let mailbox = Int64(parts[1]), mailbox > 0,
                let message = Int64(parts[2]), message > 0
            else { return nil }
            self.init(store: String(parts[0]), mailbox: mailbox, message: message)
        }

        public var description: String {
            "\(store):\(mailbox):\(message)"
        }
    }

    /// The message row identifier.
    public let id: Int64
    /// The version directory name.
    public let store: String
    /// The home mailbox row identifier.
    public let mailbox: Int64
    /// The storage URL of the home mailbox.
    public let mailboxURL: String
    /// The indexed subject, or an empty string when absent.
    public let subject: String
    /// The indexed sender address, or an empty string when absent.
    public let sender: String
    /// The received date, decoded from Unix time.
    public let date: Date
    /// Whether the index marks the message as read.
    public let isRead: Bool
    /// Some schemas store an integer here instead of the RFC Message-ID.
    public let messageID: String

    /// An identifier that includes the store and home mailbox.
    public var identifier: Identifier {
        Identifier(store: store, mailbox: mailbox, message: id)
    }

    /// Reads the current row of a statement prepared from `FetchRequest.statement(matchesLabels:)`.
    init(_ row: Database.Row, store: String) throws {
        guard let id = row.integer(0), let mailbox = row.integer(1),
            let date = row.double(5), date.isFinite
        else {
            throw Error.unsupportedSchema
        }

        self.id = id
        self.store = store
        self.mailbox = mailbox
        mailboxURL = row.text(2) ?? ""
        subject = row.text(3) ?? ""
        sender = row.text(4) ?? ""
        self.date = Date(timeIntervalSince1970: date)
        isRead = row.integer(6) == 1
        messageID = row.text(7) ?? ""
    }
}
