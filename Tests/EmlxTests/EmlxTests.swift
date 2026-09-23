import Foundation
import XCTest
@testable import Emlx

final class EmlxTests: XCTestCase {
    private func emlx(_ mime: String) -> Data {
        let payload = Data(mime.utf8)
        return Data("\(payload.count)\n".utf8) + payload + Data("\n<plist>ignored trailer</plist>".utf8)
    }

    func testContainerPreservesPayloadAndTrailingBytes() throws {
        let payload = Data("Subject: Container\r\n\r\ncafé".utf8)
        let trailer = Data("\n<plist>trailing bytes</plist>".utf8)
        let prefix = Data("\(payload.count)   \r\n".utf8)
        let container = try Emlx.Container(data: prefix + payload + trailer)
        XCTAssertEqual(container.payload, payload)
        XCTAssertEqual(container.trailer, trailer)
        XCTAssertTrue(try Emlx.Container(data: prefix + payload).trailer.isEmpty)
    }

    func testExpectedMessageIDAndCancellation() throws {
        let data = emlx("Message-ID: <one@example.com>\nSubject: One\n\nBody")
        XCTAssertEqual(try Emlx.Content(emlx: data, expectedMessageID: "one@example.com").body, "Body")
        XCTAssertEqual(try Emlx.Content(emlx: data, expectedMessageID: "123").body, "Body")
        XCTAssertThrowsError(try Emlx.Content(emlx: data, expectedMessageID: "other@example.com")) { error in
            XCTAssertEqual(error as? Emlx.Error, .messageMismatch)
        }
        XCTAssertThrowsError(try Emlx.Content(emlx: data, checkCancellation: { throw CancellationError() })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testFoldedMessageIDMatchesIndex() throws {
        let data = emlx("Message-ID:\r\n <one@example.com>\r\nSubject:\r\n\tFolded\r\n\r\nBody")
        let content = try Emlx.Content(emlx: data, expectedMessageID: "<one@example.com>")
        XCTAssertEqual(content.messageID, "one@example.com")
        XCTAssertEqual(content.headers.map(\.value), ["<one@example.com>", "Folded"])
    }

    func testPaddedByteCountPreservesMIMEBoundaries() throws {
        let payload = Data("Subject: Padding\r\nContent-Type: text/plain; charset=utf-8\r\n\r\ncafé".utf8)
        let count = String(payload.count)
        let padded = count.padding(toLength: 10, withPad: " ", startingAt: 0)
        for prefix in [count + "\n", padded + "\n", padded + "\r\n"] {
            let data = Data(prefix.utf8) + payload + Data("\n<plist>not message content</plist>".utf8)
            let content = try Emlx.Content(emlx: data)
            XCTAssertEqual(content.body, "café")
            XCTAssertEqual(content.headers.first?.value, "Padding")
        }
        XCTAssertThrowsError(try Emlx.Content(emlx: Data("999       \n".utf8) + payload)) { error in
            XCTAssertEqual(error as? Emlx.Error, .partialMessage)
        }
    }

    func testInvalidByteCountsRemainRejected() throws {
        for prefix in ["", "          ", "1 2", "12x", "+12", "-12", "0", "99999999999999999999999"] {
            XCTAssertThrowsError(try Emlx.Content(emlx: Data((prefix + "\nSubject: Test\n\nBody").utf8))) { error in
                XCTAssertTrue(error.localizedDescription.contains("byte-count prefix"))
            }
        }
    }

    func testByteCountAndEncodedHeaders() throws {
        let content = try Emlx.Content(
            emlx: emlx("Subject: =?utf-8?B?Y2Fmw6k=?=\r\nContent-Type: text/plain; charset=utf-8\r\n\r\ncafé")
        )
        XCTAssertEqual(content.body, "café")
        XCTAssertEqual(content.headers.first?.value, "café")
        XCTAssertFalse(content.body.contains("plist"))
        XCTAssertThrowsError(try Emlx.Content(emlx: Data("999\nSubject: x\n\nshort".utf8)))
        XCTAssertThrowsError(try Emlx.Content(emlx: Data("oops\nhi".utf8)))
        XCTAssertThrowsError(try Emlx.Content(emlx: emlx("no headers")))
        XCTAssertEqual(
            try Emlx.Content(
                emlx: emlx("Subject: Lenient\nContent-Type: text/plain\nContent-Transfer-Encoding: base64\n\n%%%")
            ).body,
            ""
        )
        XCTAssertThrowsError(
            try Emlx.Content(emlx: emlx("Subject: Broken\nContent-Type: text/plain; charset=unknown-charset\n\ntext"))
        )
        XCTAssertThrowsError(
            try Emlx.Content(
                emlx: emlx(
                    "Subject: Broken\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n/w=="
                )
            )
        )
    }

    func testDamagedPartsDoNotHideTheBody() throws {
        for damaged in [
            "--x\nContent-Type: text/plain\nContent-Type: text/html\n\nduplicate\n",
            "--x\nContent-Type: application/pkcs7-mime; name=a.p7m\nContent-Disposition: attachment; filename=a.p7m\n\nYQ==\n",
            "--x\nContent-Type: multipart/encrypted; boundary=y\n\n--y\n\nsecret\n--y--\n",
            "--x\nContent-Type: message/partial\n\npiece\n",
            "--x\nContent-Type: multipart/mixed; boundary=y\n\n--y\n\nnested\n",
            "--x\nContent-Type: text/plain; charset=unknown\n\nlater\n",
            "--x\n",
        ] {
            let mime = "Content-Type: multipart/mixed; boundary=x\n\n--x\n\nreadable\n" + damaged + "--x--"
            XCTAssertEqual(try Emlx.Content(emlx: emlx(mime)).body, "readable", damaged)
        }
    }

    func testHeaderDefectsOutsideTheStructureAreTolerated() throws {
        var payload = Data("Subject: caf".utf8)
        payload.append(0xE9)
        payload.append(Data("\nMIME-Version: 1.0\nMIME-Version: 1.0\n\nbody".utf8))
        let content = try Emlx.Content(emlx: Data("\(payload.count)\n".utf8) + payload)
        XCTAssertEqual(content.headers.first?.value, "caf\u{FFFD}")
        XCTAssertEqual(content.body, "body")
    }

    func testMultipartAndCharacterEncoding() throws {
        let mime = """
            Subject: MIME
            Content-Type: multipart/mixed; boundary=outer

            --outer
            Content-Type: multipart/alternative; boundary=inner

            --inner
            Content-Type: text/plain; charset=iso-8859-1
            Content-Transfer-Encoding: quoted-printable

            caf=E9
            --inner
            Content-Type: text/html

            <p>HTML</p>
            --inner--
            --outer
            Content-Type: application/octet-stream
            Content-Disposition: attachment; filename="report.pdf"
            Content-Transfer-Encoding: base64

            YQ==
            --outer--
            """
        let content = try Emlx.Content(emlx: emlx(mime))
        XCTAssertEqual(content.mediaType, "text/plain")
        XCTAssertTrue(content.body.contains("café"))
        XCTAssertEqual(content.attachments, ["report.pdf"])
        XCTAssertThrowsError(try Emlx.Content(emlx: emlx(mime.replacingOccurrences(of: "--outer--", with: ""))))
        let html = try Emlx.Content(
            emlx: emlx("Subject: HTML\nContent-Type: text/html\n\n<img src=\"https://example.com/x\">")
        )
        XCTAssertEqual(html.mediaType, "text/html")
        XCTAssertTrue(html.body.contains("https://example.com/x"))
        XCTAssertThrowsError(
            try Emlx.Content(emlx: emlx("Subject: Secret\nContent-Type: application/pkcs7-mime\n\nencrypted"))
        )
    }

}
