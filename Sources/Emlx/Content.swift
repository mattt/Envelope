import Foundation
import MIME

/// The readable content of a local `.emlx` message file.
public struct Content: Sendable {
    /// A decoded MIME header field.
    public struct Header: Sendable {
        /// The header field name.
        public let name: String
        /// The decoded header value.
        public let value: String
    }

    /// The decoded MIME headers, in source order.
    public let headers: [Header]
    /// The decoded plain-text or HTML body.
    public let body: String
    /// `text/plain`, or `text/html` for a message without a plain-text body.
    public let mediaType: String
    /// The filenames of attachments that supply a name.
    public let attachments: [String]
    /// The MIME Message-ID, when present.
    public let messageID: String?

    /// Parses a complete local message without loading remote content.
    /// - Parameters:
    ///   - data: The complete `.emlx` file.
    ///   - expectedMessageID: An index Message-ID to check when it contains `@`.
    ///   - checkCancellation: A cooperative cancellation check.
    /// - Throws: A content error, an identity mismatch, or a cancellation error.
    public init(
        emlx data: Data,
        expectedMessageID: String? = nil,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        guard data.count <= 32 * 1_024 * 1_024 else {
            throw Error.unsupportedMessage("the complete .emlx input exceeds 32 MiB")
        }
        let payload = try Container(data: data).payload
        let message: Part
        do {
            message = try Parser.parse(payload, checkCancellation: checkCancellation)
        } catch let failure as MIME.Failure {
            switch failure {
            case .malformed(let reason): throw Error.malformedMessage(reason)
            case .unsupported(let reason): throw Error.unsupportedMessage(reason)
            case .limit: throw Error.unsupportedMessage("MIME resource limit exceeded")
            case .partial: throw Error.partialMessage
            case .encrypted: throw Error.encryptedMessage
            }
        }
        guard let selected = Self.select(message) else {
            throw Error.unsupportedMessage("the local body is missing or not text")
        }
        headers = message.headers.map { Header(name: $0.name, value: $0.value) }
        body = selected.0
        mediaType = selected.1
        attachments = Self.filenames(message)
        messageID = message.header("message-id")?.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        if let expectedMessageID, expectedMessageID.contains("@") {
            let brackets = CharacterSet(charactersIn: "<>")
            guard messageID?.trimmingCharacters(in: brackets) == expectedMessageID.trimmingCharacters(in: brackets) else {
                throw Error.messageMismatch
            }
        }
        try checkCancellation()
    }

}
