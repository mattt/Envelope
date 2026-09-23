import Emlx
import Foundation
import XCTest
@testable import MIME

final class MIMETests: XCTestCase {
    func parse(_ source: String, limits: Limits = Limits()) throws -> Part {
        try Parser.parse(Data(source.utf8), limits: limits)
    }

    func testCorpus() throws {
        let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let expectations =
            try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("expectations.json"))) as! [String: [String: Any]]
        for (name, expected) in expectations {
            let data = try Data(contentsOf: directory.appendingPathComponent(name + ".mime"))
            guard let body = expected["body"] as? String else {
                XCTAssertThrowsError(try Parser.parse(data), name)
                continue
            }
            let part = try Parser.parse(data)
            func texts(_ part: Part) -> [String] { (part.text.map { [$0] } ?? []) + part.children.flatMap(texts) }
            XCTAssertTrue(texts(part).contains(body), name)
            let container = Data("\(data.count)\n".utf8) + data
            XCTAssertEqual(try Content(emlx: container).body, body, name)
        }
    }

    func testHeadersAndParameters() throws {
        let part = try parse(
            "Subject: =?utf-8?B?Y2Fmw6k=?=\n\t=?us-ascii?Q?_test?=\nX-Test: one\nX-Test: two\nContent-Type: text/plain; name=fallback\nContent-Disposition: inline; filename=plain; filename*0*=utf-8''caf%C3; filename*1*=%A9.txt\n\nBody"
        )
        XCTAssertEqual(part.headers.map(\.name), ["Subject", "X-Test", "X-Test", "Content-Type", "Content-Disposition"])
        XCTAssertEqual(part.headers[0].value, "café test")
        XCTAssertEqual(part.filename, "café.txt")
        XCTAssertEqual(try parse("Content-Disposition: attachment; filename=\"a\\\"b.txt\"\n\nbinary").filename, "a\"b.txt")
    }

    func testMalformedInputs() {
        for source in [
            "Content-Type: text/plain\nContent-Type: text/html\n\nx",
            "Content-Disposition: attachment; filename*1*=utf-8''x\n\nx",
            "Content-Disposition: attachment; filename*=utf-8''%ZZ\n\nx",
            "Content-Transfer-Encoding: base64\n\nYR==",
            "Content-Transfer-Encoding: base64\n\nYQ=",
            "Content-Transfer-Encoding: quoted-printable\n\nx=GG",
            "Content-Transfer-Encoding: quoted-printable\n\nx=",
            "Content-Type: text/plain; charset=unknown\n\nx",
            "Content-Type: multipart/mixed; boundary=x\n\n--x\n\nbody\ntext--x--",
            "Content-Type: multipart/mixed; boundary=x\n\n--x\nContent-Type: multipart/mixed; boundary=y\n\n--y\n\nbody\n--x--",
            "Content-Type: message/partial\n\nx",
            "Content-Type: application/pkcs7-mime\n\nx",
        ] { XCTAssertThrowsError(try parse(source), source) }
        XCTAssertThrowsError(try Parser.parse(Data("Subject: x\n\n".utf8) + Data([255])))
    }

    func testRangesAndSlices() throws {
        let data = Data("paddingSubject: x\n\nBody".utf8).dropFirst(7)
        let part = try Parser.parse(data)
        XCTAssertEqual(part.text, "Body")
        XCTAssertEqual(Data(data)[part.bodyRange], Data("Body".utf8))
    }

    func testLimitThresholds() throws {
        let source = "X: y\n\nz"
        // Header bytes include the separator; decoded output includes header value and body.
        for delta in -1 ... 1 {
            var limits = Limits()
            limits.entityHeaders = 6 + delta
            if delta < 0 { XCTAssertThrowsError(try parse(source, limits: limits)) } else { XCTAssertNoThrow(try parse(source, limits: limits)) }
            limits = Limits(); limits.totalHeaders = 6 + delta
            if delta < 0 { XCTAssertThrowsError(try parse(source, limits: limits)) } else { XCTAssertNoThrow(try parse(source, limits: limits)) }
            limits = Limits(); limits.entities = 1 + delta
            if delta < 0 { XCTAssertThrowsError(try parse(source, limits: limits)) } else { XCTAssertNoThrow(try parse(source, limits: limits)) }
            limits = Limits(); limits.decoded = 2 + delta
            if delta < 0 { XCTAssertThrowsError(try parse(source, limits: limits)) } else { XCTAssertNoThrow(try parse(source, limits: limits)) }
            limits = Limits(); limits.depth = 1 + delta
            let nested = "Content-Type: message/rfc822\n\n" + source
            if delta < 0 { XCTAssertThrowsError(try parse(nested, limits: limits)) } else { XCTAssertNoThrow(try parse(nested, limits: limits)) }
        }
    }

    func testCancellationDuringWork() {
        for source in [
            "X: " + String(repeating: "a", count: 100_000) + "\n\nbody", "Content-Transfer-Encoding: base64\n\n" + String(repeating: "YWFh", count: 100_000),
        ] {
            var checks = 0
            XCTAssertThrowsError(
                try Parser.parse(
                    Data(source.utf8),
                    checkCancellation: {
                        checks += 1
                        if checks == 8 { throw CancellationError() }
                    }
                )
            ) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(checks, 8)
        }
    }
}

extension MIMETests {
    func testCommentsWhitespaceAndWordSpaces() throws {
        XCTAssertEqual(try parse("Content-Type: (type) text / plain (note); charset = \"utf-8\"\n\nBody").text, "Body")
        XCTAssertEqual(try parse("Subject: =?us-ascii?Q?hello_?=\n\nBody").headers[0].value, "hello ")
        XCTAssertEqual(try parse("Content-Transfer-Encoding: quoted-printable\n\nline \t\r\nnext").text, "line\r\nnext")
    }
    func testTextThatIsNotAnEncodedWordStaysLiteral() throws {
        // RFC 2047 section 6.1: other character sequences are ordinary text.
        XCTAssertEqual(try parse("Subject: Is a=?b true\n\nBody").headers[0].value, "Is a=?b true")
        XCTAssertEqual(try parse("Subject: =?utf-8?Q?a b?=\n\nBody").headers[0].value, "=?utf-8?Q?a b?=")
    }
    func testIncorrectlyFormedEncodedWordsDoNotStopTheMessage() throws {
        // RFC 2047 section 6.3: a reader must not reject a message for an incorrectly formed word.
        for word in ["=?utf-8?B?%%?=", "=?utf-8?Q?bad=ZZ?=", "=?unknown?Q?x?=", "=?us-ascii?Q?=E9?="] {
            XCTAssertEqual(try parse("Subject: \(word) tail\n\nBody").headers[0].value, "\(word) tail", word)
        }
        XCTAssertEqual(try parse("Subject: =?utf-8?Q?a?= =?bad?Q?b?=\n\nBody").headers[0].value, "a =?bad?Q?b?=")
    }
    func testLongEncodedWordsAndLanguageSuffixesDecode() throws {
        let long = String(repeating: "a", count: 80)
        XCTAssertEqual(try parse("Subject: =?utf-8?Q?\(long)?=\n\nBody").headers[0].value, long)
        XCTAssertEqual(try parse("Subject: =?utf-8*en?Q?hi?=\n\nBody").headers[0].value, "hi")
    }
    func testBinarySyntaxWithoutDecodedAllocation() throws {
        let part = try parse("Content-Disposition: attachment; filename=x.bin\nContent-Transfer-Encoding: base64\n\nYQ==")
        XCTAssertNil(part.text)
        XCTAssertThrowsError(try parse("Content-Disposition: attachment\nContent-Transfer-Encoding: base64\n\n%%%"))
    }
    func testSharedNestedBudget() throws {
        let source = "Content-Type: message/rfc822\n\nX: y\n\nz"
        let headers = "Content-Type: message/rfc822\n\n".utf8.count + 6
        for delta in -1 ... 1 {
            var limits = Limits(); limits.totalHeaders = headers + delta
            if delta < 0 { XCTAssertThrowsError(try parse(source, limits: limits)) } else { XCTAssertNoThrow(try parse(source, limits: limits)) }
        }
    }
    func testDefaultDepthAndEntityLimits() throws {
        var nested = "X: y\n\nz"
        for depth in 1 ... 65 {
            nested = "Content-Type: message/rfc822\n\n" + nested
            if depth >= 63 {
                if depth <= 64 { XCTAssertNoThrow(try parse(nested)) } else { XCTAssertThrowsError(try parse(nested)) }
            }
        }
        for entities in 1_023 ... 1_025 {
            let source = "Content-Type: multipart/mixed; boundary=x\n\n" + String(repeating: "--x\n\nz\n", count: entities - 1) + "--x--"
            if entities <= 1_024 { XCTAssertNoThrow(try parse(source)) } else { XCTAssertThrowsError(try parse(source)) }
        }
    }
}

extension MIMETests {
    func testDefaultHeaderLimitThreshold() throws {
        for delta in -1 ... 1 {
            let count = Limits().entityHeaders + delta
            let source = "X: " + String(repeating: "a", count: count - 5) + "\n\nbody"
            if delta <= 0 { XCTAssertNoThrow(try parse(source)) } else { XCTAssertThrowsError(try parse(source)) }
        }
    }
    func testUTF16FollowsByteOrderMarkOrDefaultsToBigEndian() throws {
        let budget = Budget(Limits(), {})
        XCTAssertEqual(try budget.string([0xFE, 0xFF, 0x00, 0x62, 0x00, 0x6F], charset: "utf-16"), "bo")
        XCTAssertEqual(try budget.string([0xFF, 0xFE, 0x62, 0x00, 0x6F, 0x00], charset: "utf-16"), "bo")
        // RFC 2781 section 4.3: text without a byte order mark is big-endian.
        XCTAssertEqual(try budget.string([0x00, 0x62, 0x00, 0x6F], charset: "utf-16"), "bo")
        XCTAssertEqual(try budget.string([0x62, 0x00, 0x6F, 0x00], charset: "utf-16le"), "bo")
        XCTAssertEqual(try budget.string([0x00, 0x62, 0x00, 0x6F], charset: "utf-16be"), "bo")
        XCTAssertEqual(try budget.string([0xEF, 0xBB, 0xBF, 0x62], charset: "utf-8"), "b")
    }
    func testDecodedBudgetUsesUTF8Size() throws {
        for delta in -1 ... 1 {
            var limits = Limits(); limits.decoded = 2 + delta
            let budget = Budget(limits, {})
            if delta < 0 {
                XCTAssertThrowsError(try budget.string([0xE9], charset: "iso-8859-1"))
            } else {
                XCTAssertEqual(try budget.string([0xE9], charset: "iso-8859-1"), "é")
            }
        }
        for delta in -1 ... 1 {
            let budget = Budget(Limits(), {})
            if delta <= 0 {
                XCTAssertNoThrow(try budget.output(Limits().decoded + delta))
            } else {
                XCTAssertThrowsError(try budget.output(Limits().decoded + delta))
            }
        }
    }
}

extension MIMETests {
    func testDefaultTotalHeaderThreshold() throws {
        let root = "Content-Type: multipart/mixed; boundary=x\n\n"
        for delta in -1 ... 1 {
            var remaining = Limits().totalHeaders + delta - root.utf8.count
            var source = root
            while remaining > 0 {
                let count = min(remaining, Limits().entityHeaders)
                source += "--x\nX: " + String(repeating: "a", count: count - 5) + "\n\nz\n"
                remaining -= count
            }
            source += "--x--"
            if delta <= 0 { XCTAssertNoThrow(try parse(source)) } else { XCTAssertThrowsError(try parse(source)) }
        }
    }
}
