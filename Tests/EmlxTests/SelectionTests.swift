import Foundation
import MIME
import XCTest
@testable import Emlx

final class SelectionTests: XCTestCase {
    private func body(_ source: String) throws -> String? {
        Content.select(try Parser.parse(Data(source.utf8)))?.body
    }
    private func multipart(_ subtype: String, _ parts: [String], parameters: String = "") -> String {
        "Content-Type: multipart/\(subtype); boundary=x\(parameters)\n\npreamble\n" + parts.map { "--x\n" + $0 + "\n" }.joined() + "--x--\nepilogue"
    }
    func testAlternativeUsesLastPlainThenLastHTML() throws {
        XCTAssertEqual(try body(multipart("alternative", ["\nfirst", "Content-Type: text/html\n\nhtml", "\nlast"])), "last")
        XCTAssertEqual(try body(multipart("alternative", ["Content-Type: text/html\n\nfirst", "Content-Type: text/html\n\nlast"])), "last")
    }
    func testRelatedStartAndDefaultRoot() throws {
        let parts = ["Content-Type: text/html\nContent-ID: <first>\n\nfirst", "Content-ID: <second>\n\nsecond"]
        XCTAssertEqual(try body(multipart("related", parts)), "first")
        XCTAssertEqual(try body(multipart("related", parts, parameters: "; start=\"<second>\"")), "second")
        XCTAssertNil(try body(multipart("related", parts, parameters: "; start=\"<absent>\"")))
    }
    func testMixedUnknownSignedAndAttachedMessages() throws {
        for subtype in ["mixed", "unknown", "signed"] {
            XCTAssertEqual(try body(multipart(subtype, ["\nfirst", "\nsecond"])), "first")
        }
        let inline = "Content-Type: message/rfc822\n\nSubject: inner\n\ninner body"
        let attached = "Content-Disposition: attachment; filename=mail.eml\n" + inline
        XCTAssertEqual(try body(inline), "inner body")
        XCTAssertNil(try body(attached))
        XCTAssertEqual(try body(multipart("mixed", [attached, "\nouter body"])), "outer body")
    }
    func testBoundaryOnlyMatchesCompleteLines() throws {
        let text = "before --x-- after\n--x-not-a-boundary\nafter"
        XCTAssertEqual(try body(multipart("mixed", ["\n" + text])), text)
    }
}

extension SelectionTests {
    func testCompleteInputLimitAndDataSlices() throws {
        let mime = Data("Subject: x\n\nbody".utf8)
        let base = Data("\(mime.count)\n".utf8) + mime
        let slice = (Data("prefix".utf8) + base).dropFirst(6)
        // Container and Content must use Data's actual collection indices.
        XCTAssertEqual(try Container(data: slice).payload, mime)
        XCTAssertEqual(try Content(emlx: slice).body, "body")
        for delta in -1 ... 1 {
            var input = base
            input.append(Data(repeating: 0, count: 32 * 1_024 * 1_024 + delta - base.count))
            if delta <= 0 {
                XCTAssertEqual(try Content(emlx: input).body, "body")
            } else {
                XCTAssertThrowsError(try Content(emlx: input)) {
                    guard case EmlxError.unsupportedMessage = $0 else { return XCTFail("Expected input limit error") }
                }
            }
        }
    }
    func testIntegrationErrorCategories() throws {
        for (source, expected) in [
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
        ] {
            let data = Data("\(source.utf8.count)\n\(source)".utf8)
            XCTAssertThrowsError(try Content(emlx: data)) { XCTAssertEqual($0 as? EmlxError, expected) }
        }
    }
}
