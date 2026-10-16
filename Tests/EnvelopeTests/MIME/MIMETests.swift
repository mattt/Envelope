@testable import Envelope
import Foundation
import Testing

@Suite
struct MIMETests {
    func parse(_ source: String, limits: Limits = Limits()) throws -> Part {
        try Parser.parse(Data(source.utf8), limits: limits)
    }

    @Test("Synthetic corpus messages produce their expected bodies")
    func corpus() throws {
        let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let expectations =
            try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("expectations.json"))) as! [String: [String: Any]]
        for (name, expected) in expectations {
            let data = try Data(contentsOf: directory.appendingPathComponent(name + ".mime"))
            let container = Data("\(data.count)\n".utf8) + data
            guard let body = expected["body"] as? String else {
                #expect(throws: (any Error).self, "\(name)") { try Content(emlx: container) }
                continue
            }
            let part = try Parser.parse(data)
            func texts(_ part: Part) -> [String] { (part.text.map { [$0] } ?? []) + part.children.flatMap(texts) }
            #expect(texts(part).contains(body), "\(name)")
            #expect(try Content(emlx: container).body == body, "\(name)")
        }
    }

    @Test("Headers keep their order, and parameters decode")
    func headersAndParameters() throws {
        let part = try parse(
            "Subject: =?utf-8?B?Y2Fmw6k=?=\n\t=?us-ascii?Q?_test?=\nX-Test: one\nX-Test: two\nContent-Type: text/plain; name=fallback\nContent-Disposition: inline; filename=plain; filename*0*=utf-8''caf%C3; filename*1*=%A9.txt\n\nBody"
        )
        #expect(part.headers.map(\.name) == ["Subject", "X-Test", "X-Test", "Content-Type", "Content-Disposition"])
        #expect(part.headers[0].value == "café test")
        #expect(part.filename == "café.txt")
        #expect(try parse("Content-Disposition: attachment; filename=\"a\\\"b.txt\"\n\nbinary").filename == "a\"b.txt")
    }

    @Test(
        "Malformed structure throws",
        arguments: [
            "Content-Type: text/plain\nContent-Type: text/html\n\nx",
            "Content-Type: multipart/mixed; boundary=x\n\n--x\n\nbody\ntext--x--",
            "Content-Type: multipart/mixed\n\n--x--",
            "Subject: x\nno colon\n\nx",
        ]
    )
    func malformedStructureThrows(source: String) {
        #expect(throws: (any Error).self) { try parse(source) }
    }

    @Test("Body failures are recorded on their parts")
    func bodyFailuresAreRecordedOnTheirParts() throws {
        #expect(try parse("Content-Type: text/plain; charset=unknown\n\nx").failure == .unsupported("unknown character encoding"))
        #expect(try parse("Content-Type: message/partial\n\nx").failure == .partial)
        #expect(try parse("Content-Type: application/pkcs7-mime\n\nx").failure == .encrypted)
        #expect(try parse("Content-Type: application/pkcs7-mime; smime-type=signed-data\n\nx").failure == nil)
        #expect(try parse("Content-Type: application/pkcs7-mime\nContent-Disposition: attachment\n\nx").failure == nil)
        let invalid = try Parser.parse(Data("Subject: x\n\n".utf8) + Data([255]))
        #expect(invalid.failure == .malformed("text does not match its character encoding"))
        let nested = try parse(
            "Content-Type: multipart/mixed; boundary=x\n\n--x\nContent-Type: multipart/mixed; boundary=y\n\n--y\n\nbody\n--x--"
        )
        #expect(nested.children.first?.failure == .malformed("missing closing multipart delimiter"))
    }

    @Test("Body ranges use the indices of a data slice")
    func rangesAndSlices() throws {
        let data = Data("paddingSubject: x\n\nBody".utf8).dropFirst(7)
        let part = try Parser.parse(data)
        #expect(part.text == "Body")
        #expect(Data(data)[part.bodyRange] == Data("Body".utf8))
    }

    @Test("Each limit fails one unit below its threshold", arguments: -1 ... 1)
    func limitThresholds(delta: Int) throws {
        let source = "X: y\n\nz"
        // Header bytes include the separator; decoded output includes header value and body.
        func check(_ source: String, _ limits: Limits) throws {
            if delta < 0 { #expect(throws: (any Error).self) { try parse(source, limits: limits) } } else { _ = try parse(source, limits: limits) }
        }
        var limits = Limits()
        limits.entityHeaders = 6 + delta
        try check(source, limits)
        limits = Limits(); limits.totalHeaders = 6 + delta
        try check(source, limits)
        limits = Limits(); limits.entities = 1 + delta
        try check(source, limits)
        limits = Limits(); limits.decoded = 2 + delta
        try check(source, limits)
        limits = Limits(); limits.depth = 1 + delta
        try check("Content-Type: message/rfc822\n\n" + source, limits)
    }

    @Test(
        "Cancellation stops long scans and decodes",
        arguments: LongInput.allCases
    )
    func cancellationDuringWork(input: LongInput) {
        var checks = 0
        #expect(throws: CancellationError.self) {
            try Parser.parse(
                Data(input.source.utf8),
                checkCancellation: {
                    checks += 1
                    if checks == 8 { throw CancellationError() }
                }
            )
        }
        #expect(checks == 8)
    }

    /// A message that takes many cancellation checks to parse.
    ///
    /// The test arguments are cases, not the messages,
    /// because the test log prints each argument value.
    enum LongInput: CaseIterable {
        /// A header with a long value.
        case header
        /// A long base64 body.
        case base64

        var source: String {
            switch self {
            case .header: "X: " + String(repeating: "a", count: 100_000) + "\n\nbody"
            case .base64: "Content-Transfer-Encoding: base64\n\n" + String(repeating: "YWFh", count: 100_000)
            }
        }
    }
}

extension MIMETests {
    @Test("Comments, white space, and spaces in encoded words are handled")
    func commentsWhitespaceAndWordSpaces() throws {
        #expect(try parse("Content-Type: (type) text / plain (note); charset = \"utf-8\"\n\nBody").text == "Body")
        #expect(try parse("Subject: =?us-ascii?Q?hello_?=\n\nBody").headers[0].value == "hello ")
        #expect(try parse("Content-Transfer-Encoding: quoted-printable\n\nline \t\r\nnext").text == "line\r\nnext")
    }
    @Test("Text that is not an encoded word stays literal")
    func textThatIsNotAnEncodedWordStaysLiteral() throws {
        // RFC 2047 section 6.1: other character sequences are ordinary text.
        #expect(try parse("Subject: Is a=?b true\n\nBody").headers[0].value == "Is a=?b true")
        #expect(try parse("Subject: =?utf-8?Q?a b?=\n\nBody").headers[0].value == "=?utf-8?Q?a b?=")
    }
    @Test("Incorrectly formed encoded words do not stop the message")
    func incorrectlyFormedEncodedWordsDoNotStopTheMessage() throws {
        // RFC 2047 section 6.3: a reader must not reject a message for an incorrectly formed word.
        for word in ["=?utf-8?B?%%?=", "=?utf-8?Q?bad=ZZ?=", "=?unknown?Q?x?=", "=?us-ascii?Q?=E9?="] {
            #expect(try parse("Subject: \(word) tail\n\nBody").headers[0].value == "\(word) tail", "\(word)")
        }
        #expect(try parse("Subject: =?utf-8?Q?a?= =?bad?Q?b?=\n\nBody").headers[0].value == "a =?bad?Q?b?=")
    }
    @Test("Long encoded words and language suffixes decode")
    func longEncodedWordsAndLanguageSuffixesDecode() throws {
        let long = String(repeating: "a", count: 80)
        #expect(try parse("Subject: =?utf-8?Q?\(long)?=\n\nBody").headers[0].value == long)
        #expect(try parse("Subject: =?utf-8*en?Q?hi?=\n\nBody").headers[0].value == "hi")
    }
    @Test("Parameters tolerate common defects")
    func parametersTolerateCommonDefects() throws {
        // Empty parameters, such as one after a final semicolon, are ignored.
        #expect(try parse("Content-Type: text/plain; charset=utf-8;\n\nBody").parameters == ["charset": "utf-8"])
        #expect(try parse("Content-Type: text/plain;;\n\nBody").mediaType == "text/plain")
        // An unquoted value continues to the next semicolon.
        #expect(try parse("Content-Disposition: attachment; filename=my file.pdf; size=3\n\nx").filename == "my file.pdf")
        // RFC 2045 section 3: Content-Disposition cannot contain comments.
        #expect(try parse("Content-Disposition: attachment; filename=report(1).pdf\n\nx").filename == "report(1).pdf")
        #expect(try parse("Content-Type: text/plain; charset=utf-8; charset=iso-8859-1\n\nBody").parameters["charset"] == "utf-8")
    }
    @Test(
        "Invalid extended parameters fall back to plain values",
        arguments: [
            "inline; filename=plain; filename*1*=utf-8''gap",
            "inline; filename=plain; filename*=utf-8''%ZZ",
            "inline; filename=plain; filename*=unknown''x",
            "inline; filename=plain; filename*=utf-8''x; filename*0=y",
        ]
    )
    func invalidExtendedParametersFallBackToPlainValues(disposition: String) throws {
        #expect(try parse("Content-Disposition: \(disposition)\n\nBody").filename == "plain")
    }
    @Test("An invalid extended parameter without a plain value has no filename")
    func invalidExtendedParameterWithoutPlainValue() throws {
        #expect(try parse("Content-Disposition: inline; filename*1*=utf-8''gap\n\nBody").filename == nil)
    }
    @Test("Attachments are not decoded")
    func attachmentsAreNotDecoded() throws {
        let part = try parse("Content-Disposition: attachment; filename=x.bin\nContent-Transfer-Encoding: base64\n\nYQ==")
        #expect(part.text == nil)
        #expect(try parse("Content-Disposition: attachment\nContent-Transfer-Encoding: x-uuencode\n\n%%%").text == nil)
    }
    @Test("Base64 skips bytes outside the alphabet")
    func base64SkipsBytesOutsideTheAlphabet() throws {
        // RFC 2045 section 6.8: bytes outside the alphabet are ignored.
        #expect(try parse("Content-Transfer-Encoding: base64\n\nY%W\nJj\n").text == "abc")
        #expect(try parse("Content-Transfer-Encoding: base64\n\nYWJjZA").text == "abcd")
        #expect(try parse("Content-Transfer-Encoding: base64\n\nYQ=").text == "a")
        #expect(try parse("Content-Transfer-Encoding: base64\n\nYR==").text == "a")
    }
    @Test("Quoted-printable keeps invalid escapes and raw bytes")
    func quotedPrintableKeepsInvalidEscapesAndRawBytes() throws {
        // RFC 2045 section 6.7, note 2: keep "=" when no valid escape follows.
        #expect(try parse("Content-Transfer-Encoding: quoted-printable\n\nx=GG").text == "x=GG")
        #expect(try parse("Content-Transfer-Encoding: quoted-printable\n\nsoft= \nbreak=").text == "softbreak")
        let raw = "Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\ncaf\u{E9}=C3=A9"
        #expect(try parse(raw).text == "caf\u{E9}\u{E9}")
    }
    @Test("Nested messages share one header budget", arguments: -1 ... 1)
    func sharedNestedBudget(delta: Int) throws {
        let source = "Content-Type: message/rfc822\n\nX: y\n\nz"
        let headers = "Content-Type: message/rfc822\n\n".utf8.count + 6
        var limits = Limits(); limits.totalHeaders = headers + delta
        if delta < 0 { #expect(throws: (any Error).self) { try parse(source, limits: limits) } } else { _ = try parse(source, limits: limits) }
    }
    @Test("The default depth and entity limits apply")
    func defaultDepthAndEntityLimits() throws {
        var nested = "X: y\n\nz"
        for depth in 1 ... 65 {
            nested = "Content-Type: message/rfc822\n\n" + nested
            if depth >= 63 {
                if depth <= 64 { _ = try parse(nested) } else { #expect(throws: (any Error).self) { try parse(nested) } }
            }
        }
        for entities in 1_023 ... 1_025 {
            let source = "Content-Type: multipart/mixed; boundary=x\n\n" + String(repeating: "--x\n\nz\n", count: entities - 1) + "--x--"
            if entities <= 1_024 { _ = try parse(source) } else { #expect(throws: (any Error).self) { try parse(source) } }
        }
    }
}

extension MIMETests {
    @Test("The default entity header limit applies", arguments: -1 ... 1)
    func defaultHeaderLimitThreshold(delta: Int) throws {
        let count = Limits().entityHeaders + delta
        let source = "X: " + String(repeating: "a", count: count - 5) + "\n\nbody"
        if delta <= 0 { _ = try parse(source) } else { #expect(throws: (any Error).self) { try parse(source) } }
    }
    @Test("UTF-16 follows its byte order mark or defaults to big-endian")
    func utf16FollowsByteOrderMarkOrDefaultsToBigEndian() throws {
        let budget = Budget(Limits(), {})
        #expect(try budget.string([0xFE, 0xFF, 0x00, 0x62, 0x00, 0x6F], charset: "utf-16") == "bo")
        #expect(try budget.string([0xFF, 0xFE, 0x62, 0x00, 0x6F, 0x00], charset: "utf-16") == "bo")
        // RFC 2781 section 4.3: text without a byte order mark is big-endian.
        #expect(try budget.string([0x00, 0x62, 0x00, 0x6F], charset: "utf-16") == "bo")
        #expect(try budget.string([0x62, 0x00, 0x6F, 0x00], charset: "utf-16le") == "bo")
        #expect(try budget.string([0x00, 0x62, 0x00, 0x6F], charset: "utf-16be") == "bo")
        #expect(try budget.string([0xEF, 0xBB, 0xBF, 0x62], charset: "utf-8") == "b")
    }
    @Test("The decoded budget counts UTF-8 bytes", arguments: -1 ... 1)
    func decodedBudgetUsesUTF8Size(delta: Int) throws {
        var limits = Limits(); limits.decoded = 2 + delta
        let budget = Budget(limits, {})
        if delta < 0 {
            #expect(throws: (any Error).self) { try budget.string([0xE9], charset: "iso-8859-1") }
        } else {
            #expect(try budget.string([0xE9], charset: "iso-8859-1") == "é")
        }
        let output = Budget(Limits(), {})
        if delta <= 0 {
            try output.output(Limits().decoded + delta)
        } else {
            #expect(throws: (any Error).self) { try output.output(Limits().decoded + delta) }
        }
    }
}

extension MIMETests {
    @Test("Transport padding can follow a delimiter")
    func transportPaddingAfterDelimiter() throws {
        // RFC 2046 section 5.1.1: linear white space can follow a boundary delimiter.
        let part = try parse("Content-Type: multipart/mixed; boundary=x\n\n--x \t\n\nbody\n--x-- \n")
        #expect(part.children.map(\.text) == ["body"])
    }
    @Test("Quoted-printable keeps white space inside a line")
    func quotedPrintableKeepsInnerWhiteSpace() throws {
        // RFC 2045 section 6.7, rule 3: only white space at the end of a line is removed.
        #expect(try parse("Content-Transfer-Encoding: quoted-printable\n\na \tb").text == "a \tb")
    }
    @Test("Continuations join encoded and plain segments")
    func continuationsJoinEncodedAndPlainSegments() throws {
        // RFC 2231 section 4.1: only segments with an asterisk are percent-decoded.
        let disposition = "attachment; filename*0*=utf-8''caf%C3%A9; filename*1=%41.txt"
        #expect(try parse("Content-Disposition: \(disposition)\n\nx").filename == "café%41.txt")
    }
    @Test("Content-Type comments and quoted strings keep escaped characters")
    func contentTypeEscapes() throws {
        // RFC 5322 section 3.2.2: a comment can contain an escaped parenthesis.
        let part = try parse("Content-Type: text/plain (a \\) b); charset=utf-8; name=\"a\\\"b.txt\"\n\nBody")
        #expect(part.mediaType == "text/plain")
        #expect(part.parameters["charset"] == "utf-8")
        #expect(part.filename == "a\"b.txt")
    }
}

extension MIMETests {
    @Test("The default total header limit applies", arguments: -1 ... 1)
    func defaultTotalHeaderThreshold(delta: Int) throws {
        let root = "Content-Type: multipart/mixed; boundary=x\n\n"
        var remaining = Limits().totalHeaders + delta - root.utf8.count
        var source = root
        while remaining > 0 {
            let count = min(remaining, Limits().entityHeaders)
            source += "--x\nX: " + String(repeating: "a", count: count - 5) + "\n\nz\n"
            remaining -= count
        }
        source += "--x--"
        if delta <= 0 { _ = try parse(source) } else { #expect(throws: (any Error).self) { try parse(source) } }
    }
}
