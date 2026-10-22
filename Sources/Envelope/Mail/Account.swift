import Foundation
import os

private let logger = Logger(subsystem: "Envelope", category: "Accounts")

/// A Mail account that owns mailboxes in the store.
public struct Account: Sendable, Hashable, Identifiable {
    /// The account identifier that Mail records, usually a UUID string.
    public let id: String
    /// The email address from the store's account map, if the map has one.
    ///
    /// The address is `nil` when the map is missing or cannot be read,
    /// when the map does not list the account,
    /// or when the account URL in the map does not contain an address,
    /// as for Exchange accounts.
    public let email: String?
}

extension Account {
    /// The accounts in a store's account map, `MailData/Signatures/AccountsMap.plist`.
    ///
    /// The map is a dictionary keyed by account UUID string.
    /// Each value is a dictionary whose `AccountURL` string can contain the account's address.
    /// Mail records the address in one of two places in that URL:
    ///
    /// - The whole authority, percent-encoded, such as `imap://user%40example.com/`.
    /// - The user, percent-encoded, before a server host,
    ///   such as `imap://user%40example.com@imap.example.com/`.
    ///
    /// Other URLs, such as Exchange's `ews://<opaque identifier>/`, do not contain an address.
    ///
    /// Reading the map never throws.
    /// A missing or unreadable map gives no addresses,
    /// and the reason goes to the log with the subsystem `Envelope` and the category `Accounts`.
    struct Map {
        /// The outcome of reading the map file.
        enum Status: Sendable, Hashable {
            /// The map was read, and it has no entries
            /// or at least one entry in the expected form.
            case loaded
            /// The store does not have the map file.
            case missing
            /// The map file cannot be read, or it resolves to a location outside the store.
            case notReadable
            /// The map file is not a property list dictionary with entries in the expected form.
            case unrecognized
        }

        /// The outcome of reading the map file.
        let status: Status
        /// The accounts that have an address, by uppercase UUID string.
        let accounts: [String: Account]
        /// The uppercase UUID strings of the entries in the expected form,
        /// including entries without an address.
        let listedIDs: Set<String>

        init(status: Status, accounts: [String: Account] = [:], listedIDs: Set<String> = []) {
            self.status = status
            self.accounts = accounts
            self.listedIDs = listedIDs
        }

        /// Reads the account map of a store, and logs each reason that an account has no address.
        /// - Parameter version: The store directory, such as `~/Library/Mail/V10`.
        init(in version: URL) {
            let url = version.appendingPathComponent("MailData/Signatures/AccountsMap.plist")
            guard url.isContained(in: version) else {
                logger.notice("The account map resolves to a location outside the store.")
                self.init(status: .notReadable)
                return
            }

            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                let error = error as NSError
                let missingCodes = [CocoaError.fileReadNoSuchFile.rawValue, CocoaError.fileNoSuchFile.rawValue]
                if error.domain == NSCocoaErrorDomain, missingCodes.contains(error.code) {
                    logger.info("The store does not have an account map.")
                    self.init(status: .missing)
                } else {
                    logger.notice(
                        "The account map cannot be read: \(error.domain, privacy: .public) error \(error.code, privacy: .public)."
                    )
                    self.init(status: .notReadable)
                }
                return
            }

            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
                logger.notice("The account map is not a property list.")
                self.init(status: .unrecognized)
                return
            }
            guard let entries = plist as? [String: Any] else {
                logger.notice("The account map is not a dictionary.")
                self.init(status: .unrecognized)
                return
            }

            var accounts: [String: Account] = [:]
            var listedIDs: Set<String> = []
            for (key, entry) in entries {
                guard let uuid = UUID(uuidString: key) else {
                    logger.debug("The account map has a key that is not a UUID: \(key, privacy: .private).")
                    continue
                }
                guard let entry = entry as? [String: Any], let value = entry["AccountURL"] as? String else {
                    logger.debug("The account map entry for \(key, privacy: .private) does not have an AccountURL string.")
                    continue
                }
                listedIDs.insert(uuid.uuidString)
                guard let email = Self.address(in: value) else {
                    let scheme = URLComponents(string: value)?.scheme ?? "unknown"
                    logger.debug(
                        "The account URL for \(key, privacy: .private) does not contain an address. Its scheme is \(scheme, privacy: .public)."
                    )
                    continue
                }
                accounts[uuid.uuidString] = Account(id: key, email: email)
            }

            if listedIDs.isEmpty, !entries.isEmpty {
                logger.notice("The account map has \(entries.count, privacy: .public) entries, but none is in the expected form.")
                self.init(status: .unrecognized)
            } else {
                logger.debug(
                    "The account map lists \(listedIDs.count, privacy: .public) accounts, and \(accounts.count, privacy: .public) have an address."
                )
                self.init(status: .loaded, accounts: accounts, listedIDs: listedIDs)
            }
        }

        /// Returns the account for an identifier from a mailbox URL.
        /// - Parameter id: The account identifier, usually a UUID string in either case.
        /// - Returns: The account from the map, or an account without an address.
        func account(for id: String) -> Account {
            accounts[Self.key(for: id)] ?? Account(id: id, email: nil)
        }

        /// Logs each account that mailboxes refer to but the map does not list.
        /// - Parameter mailboxes: The mailboxes that refer to accounts.
        func logUnlistedAccounts(of mailboxes: [Mailbox]) {
            guard status == .loaded else { return }
            let ids = Set(mailboxes.compactMap { $0.account?.id })
            for id in ids.sorted() where !listedIDs.contains(Self.key(for: id)) {
                logger.debug("Mailboxes refer to account \(id, privacy: .private), which the account map does not list.")
            }
        }

        /// Returns the address in an account URL, if the URL contains one.
        /// - Parameter accountURL: The `AccountURL` string from the map.
        /// - Returns: The percent-decoded address, or `nil`.
        static func address(in accountURL: String) -> String? {
            guard let components = URLComponents(string: accountURL) else { return nil }
            if let user = components.user {
                // The user comes before a server host, such as `imap://user%40example.com@imap.example.com/`.
                return user.contains("@") ? user : nil
            }
            // The address is the whole authority, such as `imap://user%40example.com/`.
            guard let host = components.percentEncodedHost?.removingPercentEncoding, host.contains("@") else {
                return nil
            }
            return host
        }

        /// Returns the dictionary key for an account identifier:
        /// the uppercase form of a UUID string, or the identifier itself.
        private static func key(for id: String) -> String {
            UUID(uuidString: id)?.uuidString ?? id
        }
    }
}
