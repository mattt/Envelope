import Emlx
import Foundation
import Testing

@testable import Mail

extension MailTests {
    /// Runs the README usage examples against the synthetic store.
    ///
    /// Keep the body of each `worker.run` closure the same as the README.
    @Suite
    struct UsageTests {
        let store: MailStore

        init() throws {
            store = try MailStore()
            try store.execute(
                """
                INSERT INTO subjects VALUES (3, 'Invoice 42');
                INSERT INTO messages VALUES (4,1,3,1,400,0,'invoice@example.com');
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
            try store.emlx(mime).write(to: store.mailbox.appendingPathComponent("4.emlx"))
        }

        @Test("The README search and read examples work")
        func readmeExamples() async throws {
            let root = store.root
            let worker = Mail.Worker()

            let result = try await worker.run { cancellation in
                try Mail.Database.read(root: root, cancellation: cancellation) { database in
                    let mailboxID = try database.mailboxes().first?.id
                    return try database.search(.init(subject: "Invoice", mailboxID: mailboxID))
                }
            }
            #expect(result.records.map(\.id.description) == ["V10:1:4"])
            #expect(result.records.first?.subject == "Invoice 42")
            #expect(result.indexedMessageCount == 4)

            let reader = Mail.MessageFileReader()
            let identifier = try #require(result.records.first?.id)
            let content = try await worker.run { cancellation in
                let record = try Mail.Database.read(root: root, cancellation: cancellation) { database in
                    try database.record(for: identifier)
                }
                return try reader.read(record, root: root, cancellation: cancellation) { data in
                    try Emlx.Content(
                        emlx: data,
                        expectedMessageID: record.messageID,
                        checkCancellation: cancellation.check
                    )
                }
            }
            #expect(content.mediaType == "text/plain")
            #expect(content.body == "Amount due: 42 €")
            #expect(content.attachmentFilenames == ["invoice.pdf"])
            #expect(content.messageID == "invoice@example.com")
        }
    }
}
