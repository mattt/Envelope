import Foundation
import Testing

@testable import Envelope

/// Synthetic MIME messages with the structure of Mail's `.partial.emlx` files.
///
/// Mail keeps the headers and the text parts, and leaves the body of each part
/// that it stores separately empty, with the original length in X-Apple-Content-Length.
enum PartialFixtures {
    /// A message with an attachment that Mail stores separately.
    static let attachment = """
        Message-ID: <one@example.com>
        Subject: Report
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary="inner"

        --inner
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        The report is attached.
        --inner
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        <p>The report is attached.</p>
        --inner--

        --outer
        Content-Type: application/pdf; name=report.pdf
        Content-Disposition: attachment; filename=report.pdf
        Content-Transfer-Encoding: base64
        X-Apple-Content-Length: 59336

        --outer--

        """

    /// An HTML message with inline images that Mail stores separately, without filenames.
    static let inlineImages = """
        Message-ID: <one@example.com>
        Subject: Newsletter
        MIME-Version: 1.0
        Content-Type: multipart/related; boundary="related"

        --related
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: 7bit

        <p><img src="cid:logo"><img src="cid:banner"></p>
        --related
        Content-Type: image/png
        Content-Disposition: inline
        Content-Transfer-Encoding: base64
        Content-ID: <logo>
        X-Apple-Content-Length: 2978

        --related
        Content-Type: image/gif
        Content-Disposition: inline
        Content-Transfer-Encoding: base64
        Content-ID: <banner>
        X-Apple-Content-Length: 3862

        --related--

        """

    /// A message whose text parts Mail stores separately.
    static let separateBody = """
        Message-ID: <one@example.com>
        Subject: Missing body
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="alternative"

        --alternative
        Content-Type: text/plain; charset=utf-8
        X-Apple-Content-Length: 924

        --alternative
        Content-Type: text/html; charset=utf-8
        X-Apple-Content-Length: 43526

        --alternative--

        """
}

@Suite
struct PartialTests {
    private func emlx(_ mime: String) -> Data {
        let payload = Data(mime.utf8)
        return Data("\(payload.count)\n".utf8) + payload + Data("\n<plist>ignored trailer</plist>".utf8)
    }

    @Test("A partial file supplies the body and reports an attachment that Mail stores separately")
    func attachmentStoredSeparately() throws {
        let content = try Content(emlx: emlx(PartialFixtures.attachment), expectedMessageID: "one@example.com")
        #expect(content.body == "The report is attached.")
        #expect(content.mediaType == "text/plain")
        #expect(content.attachments == [.init(mediaType: "application/pdf", filename: "report.pdf", isStoredSeparately: true)])
        #expect(content.attachmentFilenames == ["report.pdf"])
    }

    @Test("Inline images that Mail stores separately are reported without filenames")
    func inlineImagesStoredSeparately() throws {
        let content = try Content(emlx: emlx(PartialFixtures.inlineImages))
        #expect(content.body == #"<p><img src="cid:logo"><img src="cid:banner"></p>"#)
        #expect(content.mediaType == "text/html")
        #expect(
            content.attachments == [
                .init(mediaType: "image/png", filename: nil, isStoredSeparately: true),
                .init(mediaType: "image/gif", filename: nil, isStoredSeparately: true),
            ]
        )
        #expect(content.attachmentFilenames.isEmpty)
    }

    @Test("Text parts that Mail stores separately do not supply an empty body")
    func separateBodyIsPartial() throws {
        #expect(throws: EmlxError.partialMessage) {
            try Content(emlx: emlx(PartialFixtures.separateBody))
        }
    }

    @Test("A part with content is not stored separately, even with an X-Apple-Content-Length header")
    func partWithContentIsIncluded() throws {
        let content = try Content(
            emlx: emlx(
                """
                Subject: Complete
                Content-Type: multipart/mixed; boundary=x

                --x
                X-Apple-Content-Length: 4

                Body
                --x
                Content-Type: application/pdf
                Content-Disposition: attachment; filename=report.pdf
                Content-Transfer-Encoding: base64
                X-Apple-Content-Length: 8

                cmVwb3J0
                --x--
                """
            )
        )
        #expect(content.body == "Body")
        #expect(content.attachments == [.init(mediaType: "application/pdf", filename: "report.pdf", isStoredSeparately: false)])
    }

    @Test("An attached message that Mail stores separately counts as one attachment")
    func attachedMessageStoredSeparately() throws {
        let content = try Content(
            emlx: emlx(
                """
                Subject: Forward
                Content-Type: multipart/mixed; boundary=x

                --x

                See the attached message.
                --x
                Content-Type: message/rfc822
                Content-Disposition: attachment; filename=original.eml
                X-Apple-Content-Length: 2048

                --x--
                """
            )
        )
        #expect(content.body == "See the attached message.")
        #expect(content.attachments == [.init(mediaType: "message/rfc822", filename: "original.eml", isStoredSeparately: true)])
    }
}
