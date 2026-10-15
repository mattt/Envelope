import Foundation
import Testing

@testable import Emlx

@Suite
struct EmlxTests {
    private func emlx(_ mime: String) -> Data {
        let payload = Data(mime.utf8)
        return Data("\(payload.count)\n".utf8) + payload + Data("\n<plist>ignored trailer</plist>".utf8)
    }

    @Test("Container preserves the payload and the trailing bytes")
    func containerPreservesPayloadAndTrailingBytes() throws {
        let payload = Data("Subject: Container\r\n\r\ncafé".utf8)
        let trailer = Data("\n<plist>trailing bytes</plist>".utf8)
        let prefix = Data("\(payload.count)   \r\n".utf8)
        let container = try Emlx.Container(data: prefix + payload + trailer)
        #expect(container.payload == payload)
        #expect(container.trailer == trailer)
        #expect(try Emlx.Container(data: prefix + payload).trailer.isEmpty)
    }

    @Test("Content checks the expected Message-ID and cancellation")
    func expectedMessageIDAndCancellation() throws {
        let data = emlx("Message-ID: <one@example.com>\nSubject: One\n\nBody")
        #expect(try Emlx.Content(emlx: data, expectedMessageID: "one@example.com").body == "Body")
        #expect(try Emlx.Content(emlx: data, expectedMessageID: "123").body == "Body")
        #expect(throws: EmlxError.messageMismatch) {
            try Emlx.Content(emlx: data, expectedMessageID: "other@example.com")
        }
        #expect(throws: CancellationError.self) {
            try Emlx.Content(emlx: data, checkCancellation: { throw CancellationError() })
        }
    }

    @Test("A folded Message-ID matches the index")
    func foldedMessageIDMatchesIndex() throws {
        let data = emlx("Message-ID:\r\n <one@example.com>\r\nSubject:\r\n\tFolded\r\n\r\nBody")
        let content = try Emlx.Content(emlx: data, expectedMessageID: "<one@example.com>")
        #expect(content.messageID == "one@example.com")
        #expect(content.headers.map(\.value) == ["<one@example.com>", "Folded"])
    }

    @Test("A padded byte count preserves MIME boundaries")
    func paddedByteCountPreservesMIMEBoundaries() throws {
        let payload = Data("Subject: Padding\r\nContent-Type: text/plain; charset=utf-8\r\n\r\ncafé".utf8)
        let count = String(payload.count)
        let padded = count.padding(toLength: 10, withPad: " ", startingAt: 0)
        for prefix in [count + "\n", padded + "\n", padded + "\r\n"] {
            let data = Data(prefix.utf8) + payload + Data("\n<plist>not message content</plist>".utf8)
            let content = try Emlx.Content(emlx: data)
            #expect(content.body == "café")
            #expect(content.headers.first?.value == "Padding")
        }
        #expect(throws: EmlxError.partialMessage) {
            try Emlx.Content(emlx: Data("999       \n".utf8) + payload)
        }
    }

    @Test("Invalid byte counts are rejected", arguments: ["", "          ", "1 2", "12x", "+12", "-12", "0", "99999999999999999999999"])
    func invalidByteCountsRemainRejected(prefix: String) throws {
        let error = #expect(throws: EmlxError.self) {
            try Emlx.Content(emlx: Data((prefix + "\nSubject: Test\n\nBody").utf8))
        }
        #expect(error?.localizedDescription.contains("byte-count prefix") == true)
    }

    @Test("A byte-count line must end within the first 24 bytes")
    func byteCountLineMustEndEarly() throws {
        let error = #expect(throws: EmlxError.self) {
            try Emlx.Container(data: Data((String(repeating: "1", count: 24) + "\nSubject: x\n\nBody").utf8))
        }
        #expect(error == .malformedMessage("invalid .emlx byte-count prefix"))
        #expect(throws: EmlxError.malformedMessage("invalid .emlx byte-count prefix")) {
            try Emlx.Container(data: Data())
        }
    }

    @Test("An unknown transfer encoding is unsupported")
    func unknownTransferEncodingIsUnsupported() throws {
        #expect(throws: EmlxError.unsupportedMessage("unknown transfer encoding")) {
            try Emlx.Content(emlx: emlx("Content-Transfer-Encoding: x-uuencode\n\nbody"))
        }
    }

    @Test(
        "Every Emlx error has a description",
        arguments: [
            EmlxError.partialMessage, .encryptedMessage, .malformedMessage("bad header"), .unsupportedMessage("no text"), .messageMismatch,
        ]
    )
    func errorDescription(error: EmlxError) throws {
        let description = try #require(error.errorDescription)
        #expect(!description.isEmpty)
        #expect(error.localizedDescription == description)
        if case .malformedMessage(let reason) = error { #expect(description.contains(reason)) }
        if case .unsupportedMessage(let reason) = error { #expect(description.contains(reason)) }
    }

    @Test("The byte count and encoded headers decode")
    func byteCountAndEncodedHeaders() throws {
        let content = try Emlx.Content(
            emlx: emlx("Subject: =?utf-8?B?Y2Fmw6k=?=\r\nContent-Type: text/plain; charset=utf-8\r\n\r\ncafé")
        )
        #expect(content.body == "café")
        #expect(content.headers.first?.value == "café")
        #expect(!content.body.contains("plist"))
        #expect(throws: (any Error).self) { try Emlx.Content(emlx: Data("999\nSubject: x\n\nshort".utf8)) }
        #expect(throws: (any Error).self) { try Emlx.Content(emlx: Data("oops\nhi".utf8)) }
        #expect(throws: (any Error).self) { try Emlx.Content(emlx: emlx("no headers")) }
        #expect(
            try Emlx.Content(
                emlx: emlx("Subject: Lenient\nContent-Type: text/plain\nContent-Transfer-Encoding: base64\n\n%%%")
            ).body == ""
        )
        #expect(throws: (any Error).self) {
            try Emlx.Content(emlx: emlx("Subject: Broken\nContent-Type: text/plain; charset=unknown-charset\n\ntext"))
        }
        #expect(throws: (any Error).self) {
            try Emlx.Content(
                emlx: emlx(
                    "Subject: Broken\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n/w=="
                )
            )
        }
    }

    @Test(
        "Damaged parts do not hide the body",
        arguments: [
            "--x\nContent-Type: text/plain\nContent-Type: text/html\n\nduplicate\n",
            "--x\nContent-Type: application/pkcs7-mime; name=a.p7m\nContent-Disposition: attachment; filename=a.p7m\n\nYQ==\n",
            "--x\nContent-Type: multipart/encrypted; boundary=y\n\n--y\n\nsecret\n--y--\n",
            "--x\nContent-Type: message/partial\n\npiece\n",
            "--x\nContent-Type: multipart/mixed; boundary=y\n\n--y\n\nnested\n",
            "--x\nContent-Type: text/plain; charset=unknown\n\nlater\n",
            "--x\n",
        ]
    )
    func damagedPartsDoNotHideTheBody(damaged: String) throws {
        let mime = "Content-Type: multipart/mixed; boundary=x\n\n--x\n\nreadable\n" + damaged + "--x--"
        #expect(try Emlx.Content(emlx: emlx(mime)).body == "readable")
    }

    @Test("Header defects outside the structure are tolerated")
    func headerDefectsOutsideTheStructureAreTolerated() throws {
        var payload = Data("Subject: caf".utf8)
        payload.append(0xE9)
        payload.append(Data("\nMIME-Version: 1.0\nMIME-Version: 1.0\n\nbody".utf8))
        let content = try Emlx.Content(emlx: Data("\(payload.count)\n".utf8) + payload)
        #expect(content.headers.first?.value == "caf\u{FFFD}")
        #expect(content.body == "body")
    }

    @Test("Multipart messages and character encodings decode")
    func multipartAndCharacterEncoding() throws {
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
        #expect(content.mediaType == "text/plain")
        #expect(content.body.contains("café"))
        #expect(content.attachmentFilenames == ["report.pdf"])
        #expect(try Emlx.Content(emlx: emlx(mime)) == content)
        #expect(throws: (any Error).self) {
            try Emlx.Content(emlx: emlx(mime.replacingOccurrences(of: "--outer--", with: "")))
        }
        let html = try Emlx.Content(
            emlx: emlx("Subject: HTML\nContent-Type: text/html\n\n<img src=\"https://example.com/x\">")
        )
        #expect(html.mediaType == "text/html")
        #expect(html.body.contains("https://example.com/x"))
        #expect(throws: (any Error).self) {
            try Emlx.Content(emlx: emlx("Subject: Secret\nContent-Type: application/pkcs7-mime\n\nencrypted"))
        }
    }
}
