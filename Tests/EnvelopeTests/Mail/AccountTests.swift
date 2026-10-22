import Foundation
import Testing

@testable import Envelope

extension MailTests {
    @Suite
    struct AccountTests {
        let store: MailStore

        init() throws {
            store = try MailStore()
        }

        @Test(
            "Account URLs give the address in the authority or the user",
            arguments: [
                ("imap://user%40example.com/", "user@example.com"),
                ("imap://user%40example.com", "user@example.com"),
                ("imap://first.last%2Btag%40example.co.uk/", "first.last+tag@example.co.uk"),
                ("imap://user%40example.com@imap.example.com/", "user@example.com"),
            ]
        )
        func accountURLAddress(accountURL: String, address: String) {
            #expect(Account.Map.address(in: accountURL) == address)
        }

        @Test(
            "Account URLs without an address give no address",
            arguments: [
                "ews://AAMkAGE5MTZiZmU5LTAwOTM==/",
                "imap://username@imap.example.com/",
                "imap://imap.example.com/",
                "imap://",
                "",
                "not a URL",
            ]
        )
        func accountURLWithoutAddress(accountURL: String) {
            #expect(Account.Map.address(in: accountURL) == nil)
        }

        @Test("A map reads addresses from both forms, and lists accounts without an address")
        func mapReadsBothForms() throws {
            let modern = "11111111-1111-4111-8111-111111111111"
            let legacy = "22222222-2222-4222-8222-222222222222"
            let exchange = "33333333-3333-4333-8333-333333333333"
            let unsigned = "44444444-4444-4444-8444-444444444444"
            try store.writeAccountsMap(
                [
                    modern.lowercased(): ["AccountURL": "imap://user%40example.com/", "Signatures": ["SIGNATURE-ID"]],
                    legacy: ["AccountURL": "imap://user%40example.org@imap.example.org/"],
                    exchange: ["AccountURL": "ews://AAMkAGE5MTZiZmU5LTAwOTM==/"],
                    unsigned: ["Signatures": [String]()],
                    "not-a-uuid": ["AccountURL": "imap://other%40example.com/"],
                ],
                format: .xml
            )
            let map = Account.Map(in: store.version)
            #expect(map.status == .loaded)
            #expect(map.listedIDs == [modern, legacy, exchange])
            #expect(map.account(for: modern) == Account(id: modern.lowercased(), email: "user@example.com"))
            #expect(map.account(for: modern.lowercased()).email == "user@example.com")
            #expect(map.account(for: legacy).email == "user@example.org")
            #expect(map.account(for: exchange) == Account(id: exchange, email: nil))
            #expect(map.account(for: unsigned) == Account(id: unsigned, email: nil))
            #expect(map.account(for: "not-a-uuid") == Account(id: "not-a-uuid", email: nil))
        }

        @Test("A missing map gives no addresses")
        func missingMap() {
            let map = Account.Map(in: store.version)
            #expect(map.status == .missing)
            #expect(map.accounts.isEmpty)
            #expect(map.account(for: "11111111-1111-4111-8111-111111111111").email == nil)
        }

        @Test("A map that cannot be read gives no addresses")
        func unreadableMap() throws {
            try store.writeAccountsMap(["11111111-1111-4111-8111-111111111111": ["AccountURL": "imap://user%40example.com/"]])
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.accountsMap.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.accountsMap.path) }
            let map = Account.Map(in: store.version)
            #expect(map.status == .notReadable)
            #expect(map.accounts.isEmpty)
        }

        @Test("A map outside the store gives no addresses")
        func mapOutsideStore() throws {
            let outside = store.root.appendingPathComponent("Outside.plist")
            let entries = ["11111111-1111-4111-8111-111111111111": ["AccountURL": "imap://user%40example.com/"]]
            try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0).write(to: outside)
            try FileManager.default.createDirectory(
                at: store.accountsMap.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: store.accountsMap, withDestinationURL: outside)
            let map = Account.Map(in: store.version)
            #expect(map.status == .notReadable)
            #expect(map.accounts.isEmpty)
        }

        @Test("A map in an unrecognized format gives no addresses")
        func unrecognizedMap() throws {
            try store.writeAccountsMap(["imap://user%40example.com/"])
            #expect(Account.Map(in: store.version).status == .unrecognized)

            try Data("invalid plist".utf8).write(to: store.accountsMap)
            #expect(Account.Map(in: store.version).status == .unrecognized)

            try store.writeAccountsMap(["Accounts": ["11111111-1111-4111-8111-111111111111": "imap://user%40example.com/"]])
            let map = Account.Map(in: store.version)
            #expect(map.status == .unrecognized)
            #expect(map.accounts.isEmpty)
        }

        @Test("An empty map is loaded and gives no addresses")
        func emptyMap() throws {
            try store.writeAccountsMap([String: Any]())
            let map = Account.Map(in: store.version)
            #expect(map.status == .loaded)
            #expect(map.accounts.isEmpty)
        }

        @Test("Mailboxes find accounts in the map regardless of UUID case")
        func mailboxesMatchUUIDCase() throws {
            let account = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
            try store.execute("UPDATE mailboxes SET url = 'imap://\(account.lowercased())/INBOX' WHERE ROWID = 1")
            try store.writeAccountsMap([account: ["AccountURL": "imap://user%40example.com/"]])
            let database = try Database(root: store.root)
            let inbox = try #require(database.mailboxes().first { $0.id.rowID == 1 })
            #expect(inbox.account == Account(id: account, email: "user@example.com"))
        }
    }
}
