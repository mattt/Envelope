import Foundation

/// A mailbox in the local Mail store.
public struct Mailbox: Sendable, Hashable, Identifiable {
    /// An identifier that finds a mailbox again in the same store.
    ///
    /// The identifier includes the store, so a search rejects an identifier from an earlier store.
    /// Its string form is `store:rowID`, such as `V10:12`.
    public struct ID: Sendable, Hashable, LosslessStringConvertible {
        /// The name of the store directory, such as `V10`.
        public let store: String
        /// The row identifier of the mailbox.
        public let rowID: Int64

        /// Creates an identifier from the values in an index row.
        init(store: String, rowID: Int64) {
            self.store = store
            self.rowID = rowID
        }

        /// Creates an identifier from its string form, such as `V10:12`.
        ///
        /// The string must have two fields that a colon separates:
        /// a store name that is not empty and a positive row identifier.
        /// The initializer returns `nil` if the string does not have this form.
        /// - Parameter description: The string form of an identifier.
        public init?(_ description: String) {
            let parts = description.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty,
                let rowID = Int64(parts[1]), rowID > 0
            else { return nil }
            self.init(store: String(parts[0]), rowID: rowID)
        }

        /// The string form of the identifier, `store:rowID`.
        ///
        /// Pass this string to ``init(_:)`` to create the identifier again.
        public var description: String {
            "\(store):\(rowID)"
        }
    }

    /// The identifier of the mailbox, which includes its store.
    ///
    /// To search the mailbox, set ``Message/FetchRequest/mailboxID`` to this value.
    public let id: ID
    /// The URL string that Mail records for the mailbox, if any.
    ///
    /// Mail records a `file` URL, or an account URL such as `imap://<account UUID>/INBOX`.
    public let url: String?
    /// The account that owns the mailbox, if Mail records one.
    public let account: Account?

    /// The last path component of the mailbox URL, such as `INBOX`.
    public var name: String? {
        url.map { URL(string: $0)?.lastPathComponent ?? $0 }
    }

    /// Reads the current row of a `mailboxes` query.
    init(_ row: Database.Row, version: URL, accounts: [String: Account]) throws {
        guard let rowID = row.integer(0) else {
            throw MailError.unsupportedSchema
        }
        id = ID(store: version.lastPathComponent, rowID: rowID)
        url = row.text(1)
        let mailboxURL = url.flatMap(URL.init(string:))
        let accountID: String?
        if let mailboxURL, mailboxURL.isFileURL, mailboxURL.isContained(in: version) {
            // A file URL names the account directory after the store directory.
            accountID =
                mailboxURL.standardizedFileURL.pathComponents.dropFirst(
                    version.standardizedFileURL.pathComponents.count
                ).first
        } else {
            accountID = mailboxURL?.host
        }
        account = accountID.map {
            accounts[UUID(uuidString: $0)?.uuidString ?? $0] ?? Account(id: $0, email: nil)
        }
    }
}
