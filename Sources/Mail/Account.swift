import Foundation

/// Optional account labels stored inside the granted Mail folder.
public struct Account: Sendable {
    /// The account identifier recorded by Mail.
    public let id: String
    /// An email label from the local account map, when available.
    public let email: String?

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
