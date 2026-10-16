import Envelope
import Foundation
import Testing

@testable import Mail

extension MailTests {
    /// Runs the README usage examples against the synthetic store.
    ///
    /// Keep each block the same as the README,
    /// except for the root folder, the identifier string, and the page size.
    @Suite
    struct UsageTests {
        let store: MailStore
        let account = "11111111-1111-4111-8111-111111111111"

        init() throws {
            store = try MailStore()
            try store.execute(
                """
                UPDATE mailboxes SET url = 'imap://\(account)/INBOX' WHERE ROWID = 1;
                INSERT INTO subjects VALUES (3, 'Invoice 42'), (4, 'Invoice 43');
                INSERT INTO messages VALUES (4,1,3,1,400,0,'invoice@example.com'), (5,1,4,1,500,1,'invoice43@example.com');
                """
            )
            let mime = """
                Message-ID: <invoice@example.com>
                Subject: Invoice 42
                Content-Type: multipart/mixed; boundary=x

                --x
                Content-Type: text/plain; charset=utf-8

                Amount due: 42 €
                --x
                Content-Type: application/pdf
                Content-Disposition: attachment; filename=invoice.pdf

                %PDF
                --x--
                """
            let inbox = store.version.appendingPathComponent("\(account)/INBOX.mbox/Messages")
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try store.emlx(mime).write(to: inbox.appendingPathComponent("4.emlx"))
        }

        @Test("The README examples work")
        func readmeExamples() async throws {
            let root = store.root
            let store = try Mail.Store(root: root)
            try await store.checkAccess()

            for mailbox in try await store.mailboxes() {
                print(mailbox.id, mailbox.name ?? "", mailbox.account?.email ?? "")
            }

            var pages: [[String]] = []
            var request = Mail.Message.FetchRequest(subject: "Invoice", limit: 1)
            repeat {
                let page = try await store.search(request)
                pages.append(page.records.map(\.id.description))
                request.cursor = page.nextCursor
            } while request.cursor != nil
            #expect(pages == [["V10:1:5"], ["V10:1:4"]])

            if let identifier = Mail.Message.Identifier("V10:1:4") {
                let content = try await store.content(for: identifier)
                #expect(content.mediaType == "text/plain")
                #expect(content.body == "Amount due: 42 €")
                #expect(content.attachmentFilenames == ["invoice.pdf"])
            }

            if let identifier = Mail.Message.Identifier("V10:1:4") {
                let size = try await store.readMessage(identifier) { file in
                    file.data.count
                }
                #expect(size > 0)
            }

            let (mailboxes, unread) = try await store.withSnapshot { snapshot in
                let mailboxes = try snapshot.mailboxes()
                let inbox = mailboxes.first { $0.name == "INBOX" }
                return (mailboxes, try snapshot.search(.init(mailboxID: inbox?.id, isRead: false)))
            }
            #expect(mailboxes.map(\.id) == [2, 1])
            #expect(unread.records.map(\.id.rowID) == [4, 3, 1])
            #expect(unread.indexedMessageCount == 5)

            let search = Task {
                try await store.search(.init(sender: "example.com"))
            }
            search.cancel()
            // The search can finish before the cancellation arrives.
            do {
                #expect(try await search.value.records.count == 5)
            } catch is CancellationError {}
            #expect(try await store.mailboxes().count == 2)
        }
    }
}
