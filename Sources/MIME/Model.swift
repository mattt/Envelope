import Foundation

package struct Limits: Sendable {
    package var depth = 64
    package var entities = 1_024
    package var entityHeaders = 256 * 1_024
    package var totalHeaders = 1_024 * 1_024
    package var decoded = 64 * 1_024 * 1_024
    package init() {}
}

package enum Failure: Error {
    case malformed(String)
    case unsupported(String)
    case limit
    case partial
    case encrypted
}

package struct Header: Sendable {
    package let name: String
    package let value: String
}

package struct Part: Sendable {
    package let headers: [Header]
    package let mediaType: String
    package let parameters: [String: String]
    package let attachment: Bool
    package let filename: String?
    package let bodyRange: Range<Int>
    package let text: String?
    package let children: [Part]
    package func header(_ name: String) -> String? {
        headers.first { $0.name.lowercased() == name }?.value
    }
}

final class Budget {
    let limits: Limits
    let cancel: () throws -> Void
    var entities = 0
    var headers = 0
    var decoded = 0
    init(_ limits: Limits, _ cancel: @escaping () throws -> Void) {
        self.limits = limits
        self.cancel = cancel
    }
    func output(_ count: Int) throws {
        guard count <= limits.decoded - decoded else { throw Failure.limit }
        decoded += count
    }
    func tick(_ offset: Int) throws {
        if offset % 16_384 == 0 { try cancel() }
    }
}

/// ASCII bytes that the MIME grammar uses.
enum ASCII {
    static let tab = UInt8(ascii: "\t")
    static let lineFeed = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let quote = UInt8(ascii: "\"")
    static let openParenthesis = UInt8(ascii: "(")
    static let closeParenthesis = UInt8(ascii: ")")
    static let asterisk = UInt8(ascii: "*")
    static let hyphen = UInt8(ascii: "-")
    static let slash = UInt8(ascii: "/")
    static let semicolon = UInt8(ascii: ";")
    static let equals = UInt8(ascii: "=")
    static let question = UInt8(ascii: "?")
    static let backslash = UInt8(ascii: "\\")
    static let underscore = UInt8(ascii: "_")
    static let percent = UInt8(ascii: "%")

    /// Returns whether a byte is a space or a horizontal tab.
    static func isBlank(_ byte: UInt8) -> Bool {
        byte == space || byte == tab
    }

    /// Returns whether a byte is a printable ASCII character other than a space.
    static func isVisible(_ byte: UInt8) -> Bool {
        (33 ... 126).contains(byte)
    }

    /// Returns whether a byte can appear in an RFC 2045 token.
    static func isToken(_ byte: UInt8) -> Bool {
        isVisible(byte) && !#"()<>@,;:\"/[]?="#.utf8.contains(byte)
    }
}
