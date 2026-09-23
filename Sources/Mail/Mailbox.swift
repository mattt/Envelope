import Foundation

/// A mailbox in the local Mail store.
public struct Mailbox: Sendable, Hashable, Identifiable {
    /// The row identifier of the mailbox.
    ///
    /// To search the mailbox, set ``Message/FetchRequest/mailboxID`` to this value.
    public let id: Int64
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
        guard let id = row.integer(0) else {
            throw MailError.unsupportedSchema
        }
        self.id = id
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
