import Foundation

/// A row of the `mailboxes` table.
public struct Mailbox: Sendable {
    /// The mailbox row identifier.
    public let id: Int64
    /// The storage URL recorded by Mail.
    public let url: String
    /// The account identifier and any available email label.
    public let account: Account?

    /// The last path component of the storage URL.
    public var name: String {
        URL(string: url)?.lastPathComponent ?? url
    }

    /// Parses a positive decimal mailbox row identifier.
    /// - Parameter value: The decimal form of a mailbox `id`.
    /// - Returns: The row identifier.
    /// - Throws: `ValidationError` if the string is not a positive integer.
    public static func parseIdentifier(_ value: String) throws -> Int64 {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
            let id = Int64(value), id > 0
        else {
            throw ValidationError.invalidMailboxIdentifier
        }
        return id
    }

    init(_ row: Database.Row, version: URL, accounts: [String: Account]) throws {
        guard let id = row.integer(0) else {
            throw Error.unsupportedSchema
        }
        self.id = id
        self.url = row.text(1) ?? ""
        let mailboxURL = URL(string: url)
        let accountID: String?
        if let mailboxURL, mailboxURL.isFileURL, mailboxURL.isContained(in: version) {
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
