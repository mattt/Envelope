import Foundation

/// A Mail account that owns mailboxes in the store.
public struct Account: Sendable, Hashable, Identifiable {
    /// The account identifier that Mail records, usually a UUID string.
    public let id: String
    /// The email address from the store's account map, if the map has one.
    public let email: String?

    /// Loads the email addresses of accounts from the store's account map.
    /// - Returns: The accounts by uppercase UUID string,
    ///   or an empty dictionary if the map is missing or cannot be read.
    static func load(in version: URL) -> [String: Account] {
        let url = version.appendingPathComponent("MailData/Signatures/AccountsMap.plist")
        guard url.isContained(in: version),
            let data = try? Data(contentsOf: url),
            let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }

        var accounts: [String: Account] = [:]
        for (id, entry) in entries {
            guard let uuid = UUID(uuidString: id),
                let entry = entry as? [String: Any],
                let value = entry["AccountURL"] as? String,
                let components = URLComponents(string: value),
                let user = components.user, user.contains("@")
            else { continue }
            accounts[uuid.uuidString] = Account(id: id, email: user)
        }
        return accounts
    }
}
