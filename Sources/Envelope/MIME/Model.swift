import Foundation

/// Resource limits for one parse.
///
/// All nested entities share the limits.
struct Limits: Sendable {
    /// The maximum nesting depth below the root entity, which has depth zero.
    var depth = 64
    /// The maximum number of entities, including the root.
    var entities = 1_024
    /// The maximum number of header bytes in one entity, including the line that ends the header block.
    var entityHeaders = 256 * 1_024
    /// The maximum number of header bytes in all entities.
    var totalHeaders = 1_024 * 1_024
    /// The maximum UTF-8 size of decoded header values, parameter values, and text bodies.
    var decoded = 64 * 1_024 * 1_024

    /// Creates the default limits.
    init() {}
}

/// A reason that the parser cannot read an entity.
enum Failure: Error, Equatable {
    /// The entity does not follow the MIME syntax.
    case malformed(String)
    /// The entity uses a charset or transfer encoding that the parser does not support.
    case unsupported(String)
    /// The message exceeds a resource limit.
    case limit
    /// The entity is one fragment of a message.
    case partial
    /// The entity is encrypted.
    case encrypted
}

/// A header field with its decoded value.
struct Header: Sendable {
    /// The field name, as it appears in the message.
    let name: String
    /// The unfolded value, with RFC 2047 encoded words decoded.
    let value: String
}

/// A MIME entity and its nested entities.
struct Part: Sendable {
    /// The header fields, in source order.
    let headers: [Header]
    /// The lowercased media type, such as `text/plain`.
    let mediaType: String
    /// The Content-Type parameters, by lowercased name.
    let parameters: [String: String]
    /// A Boolean value that indicates whether the Content-Disposition is `attachment`.
    let isAttachment: Bool
    /// The filename from the Content-Disposition, or the name from the Content-Type.
    let filename: String?
    /// The byte offsets of the body in the parsed data.
    ///
    /// Offsets start at zero at the first byte of the data,
    /// even when the data is a slice with other indices.
    let bodyRange: Range<Int>
    /// The decoded text of a text entity that is not an attachment.
    let text: String?
    /// The body parts of a multipart entity, or the message of a `message/rfc822` entity.
    let children: [Part]
    /// The reason that the parser could not read this entity, if any.
    let failure: Failure?

    /// Returns the value of the first header field with a name.
    /// - Parameter name: A lowercased field name.
    func header(_ name: String) -> String? {
        headers.first { $0.name.lowercased() == name }?.value
    }
}

extension Part {
    /// Creates a placeholder for a nested entity that the parser could not read.
    init(failure: Failure, bodyRange: Range<Int>) {
        self.init(
            headers: [],
            mediaType: "application/octet-stream",
            parameters: [:],
            isAttachment: false,
            filename: nil,
            bodyRange: bodyRange,
            text: nil,
            children: [],
            failure: failure
        )
    }
}

/// Tracks the resources that one parse uses, and checks for cancellation.
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

    /// Charges decoded bytes to the budget.
    func output(_ count: Int) throws {
        guard count <= limits.decoded - decoded else { throw Failure.limit }
        decoded += count
    }

    /// Checks for cancellation at every 16 KiB of a scan.
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
