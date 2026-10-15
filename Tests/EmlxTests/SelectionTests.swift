import Foundation
import MIME
import Testing

@testable import Emlx

@Suite
struct SelectionTests {
    private func body(_ source: String) throws -> String? {
        Content.select(try Parser.parse(Data(source.utf8)))?.body
    }
    private func multipart(_ subtype: String, _ parts: [String], parameters: String = "") -> String {
        "Content-Type: multipart/\(subtype); boundary=x\(parameters)\n\npreamble\n" + parts.map { "--x\n" + $0 + "\n" }.joined() + "--x--\nepilogue"
    }
    @Test("Alternative parts use the last plain-text part, then the last HTML part")
    func alternativeUsesLastPlainThenLastHTML() throws {
        #expect(try body(multipart("alternative", ["\nfirst", "Content-Type: text/html\n\nhtml", "\nlast"])) == "last")
        #expect(try body(multipart("alternative", ["Content-Type: text/html\n\nfirst", "Content-Type: text/html\n\nlast"])) == "last")
    }
    @Test("Related parts use the start part or the first part")
    func relatedStartAndDefaultRoot() throws {
        let parts = ["Content-Type: text/html\nContent-ID: <first>\n\nfirst", "Content-ID: <second>\n\nsecond"]
        #expect(try body(multipart("related", parts)) == "first")
        #expect(try body(multipart("related", parts, parameters: "; start=\"<second>\"")) == "second")
        #expect(try body(multipart("related", parts, parameters: "; start=\"<absent>\"")) == nil)
    }
    @Test("Mixed, unknown, signed, and attached messages select the first readable part")
    func mixedUnknownSignedAndAttachedMessages() throws {
        for subtype in ["mixed", "unknown", "signed"] {
            #expect(try body(multipart(subtype, ["\nfirst", "\nsecond"])) == "first")
        }
        let inline = "Content-Type: message/rfc822\n\nSubject: inner\n\ninner body"
        let attached = "Content-Disposition: attachment; filename=mail.eml\n" + inline
        #expect(try body(inline) == "inner body")
        #expect(try body(attached) == nil)
        #expect(try body(multipart("mixed", [attached, "\nouter body"])) == "outer body")
    }
    @Test("Boundaries match only complete lines")
    func boundaryOnlyMatchesCompleteLines() throws {
        let text = "before --x-- after\n--x-not-a-boundary\nafter"
        #expect(try body(multipart("mixed", ["\n" + text])) == text)
    }
}

extension SelectionTests {
    @Test("The complete input limit applies, and data slices parse")
    func completeInputLimitAndDataSlices() throws {
        let mime = Data("Subject: x\n\nbody".utf8)
        let base = Data("\(mime.count)\n".utf8) + mime
        let slice = (Data("prefix".utf8) + base).dropFirst(6)
        // Container and Content must use Data's actual collection indices.
        #expect(try Container(data: slice).payload == mime)
        #expect(try Content(emlx: slice).body == "body")
        for delta in -1 ... 1 {
            var input = base
            input.append(Data(repeating: 0, count: 32 * 1_024 * 1_024 + delta - base.count))
            if delta <= 0 {
                #expect(try Content(emlx: input).body == "body")
            } else {
                let error = #expect(throws: EmlxError.self) { try Content(emlx: input) }
                guard case .unsupportedMessage = error else {
                    Issue.record("Expected input limit error")
                    continue
                }
            }
        }
    }
    @Test(
        "Parser failures map to public error categories",
        arguments: [
            ("Content-Type: message/partial\n\nx", EmlxError.partialMessage),
            ("Content-Type: application/pkcs7-mime\n\nx", EmlxError.encryptedMessage),
            ("Content-Type: multipart/mixed; boundary=x\n\n--x\n\nbody", EmlxError.malformedMessage("missing closing multipart delimiter")),
            ("Content-Type: multipart/mixed; boundary=x\n\n--x--", EmlxError.malformedMessage("multipart has no body parts")),
            (
                "Content-Type: multipart/mixed; boundary=x\n\n--x\nContent-Type: multipart/encrypted; boundary=y\n\n--y\n\nx\n--y--\n--x--",
                EmlxError.encryptedMessage
            ),
            ("Content-Type: application/pkcs7-mime; smime-type=signed-data\n\nx", EmlxError.unsupportedMessage("the local body is missing or not text")),
            ("Content-Type: text/plain; charset=unknown\n\nx", EmlxError.unsupportedMessage("unknown character encoding")),
        ]
    )
    func integrationErrorCategories(source: String, expected: EmlxError) throws {
        let data = Data("\(source.utf8.count)\n\(source)".utf8)
        #expect(throws: expected) { try Content(emlx: data) }
    }
}
