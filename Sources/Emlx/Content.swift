import Foundation
import MimeFoundation

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
        let payload = try Container(data: data).payload
        try checkCancellation()

        let message: MimeMessage
        do {
            message = try MimeMessage.load(MemoryStream(Array(payload), writable: false))
        } catch {
            throw Error.malformedMessage(error.localizedDescription)
        }
        try checkCancellation()
        guard !message.headers.isEmpty else {
            throw Error.malformedMessage("no MIME headers")
        }
        if let body = message.body {
            try Self.validate(body, in: payload, checkCancellation: checkCancellation)
        }

        let plain = message.textBody
        guard let body = plain ?? message.htmlBody else {
            throw Error.unsupportedMessage("the local body is missing or not text")
        }

        headers = message.headers.map { Header(name: $0.field, value: $0.value) }
        self.body = body
        mediaType = plain != nil ? "text/plain" : "text/html"
        attachments = message.attachments.compactMap { ($0 as? MimePart)?.fileName }
        messageID = message.messageId
        if let expectedMessageID, expectedMessageID.contains("@") {
            let brackets = CharacterSet(charactersIn: "<>")
            guard messageID?.trimmingCharacters(in: brackets) == expectedMessageID.trimmingCharacters(in: brackets) else {
                throw Error.messageMismatch
            }
        }
        try checkCancellation()
    }

    /// Rejects content that the parser accepts but cannot return as complete text.
    private static func validate(
        _ entity: MimeEntity,
        in payload: Data,
        depth: Int = 0,
        checkCancellation: () throws -> Void
    ) throws {
        try checkCancellation()
        guard depth < 64 else {
            throw Error.unsupportedMessage("MIME nesting is too deep")
        }

        switch entity.contentType.mimeType.lowercased() {
        case "multipart/encrypted", "application/pkcs7-mime", "application/x-pkcs7-mime",
            "application/pgp-encrypted":
            throw Error.encryptedMessage
        case "message/partial":
            throw Error.partialMessage
        default:
            break
        }

        if let text = entity as? TextPart, !text.isAttachment, let content = text.content {
            // The parser tolerates damaged transfer encodings. Do not report those as complete text.
            if text.contentTransferEncoding == .base64 {
                let encoded = MemoryStream()
                try content.writeTo(encoded)
                let whitespace = Set(" \t\r\n".utf8)
                let bytes = encoded.toByteArray().filter { !whitespace.contains($0) }
                guard Data(base64Encoded: Data(bytes)) != nil else {
                    throw Error.malformedMessage("invalid base64 body")
                }
            }
            if text.contentType.charset != nil {
                guard let encoding = text.contentType.charsetEncoding else {
                    throw Error.unsupportedMessage("unknown character encoding")
                }
                let decoded = MemoryStream()
                try content.decodeTo(decoded)
                guard String(data: Data(decoded.toByteArray()), encoding: encoding) != nil else {
                    throw Error.malformedMessage("text does not match its character encoding")
                }
            }
        }

        if let multipart = entity as? Multipart {
            let ending = Data(("--" + multipart.boundary + "--").utf8)
            guard !multipart.isEmpty, payload.range(of: ending) != nil else {
                throw Error.partialMessage
            }
            for child in multipart {
                try validate(child, in: payload, depth: depth + 1, checkCancellation: checkCancellation)
            }
        }
    }

}
