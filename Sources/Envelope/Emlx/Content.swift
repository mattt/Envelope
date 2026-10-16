import Foundation

/// The largest `.emlx` file that ``Content`` parses.
let maximumInputSize = 32 * 1_024 * 1_024

/// The readable content of a local `.emlx` message file.
public struct Content: Sendable, Hashable {
    /// A header field of the message.
    public struct Header: Sendable, Hashable {
        /// The field name, as it appears in the message.
        public let name: String
        /// The unfolded value, with RFC 2047 encoded words decoded.
        public let value: String
    }

    /// The header fields of the message, in source order.
    public let headers: [Header]
    /// The decoded plain-text or HTML body.
    public let body: String
    /// The media type of the body.
    ///
    /// The value is `text/plain`, or `text/html` for a message without a plain-text body.
    public let mediaType: String
    /// The filenames that the message's parts supply, including inline parts such as images.
    ///
    /// An attached message counts as one part; the parts inside it are not included.
    public let attachmentFilenames: [String]
    /// The MIME Message-ID without angle brackets, if the message has one.
    public let messageID: String?

    /// Parses the readable content of an `.emlx` file without loading remote content.
    ///
    /// For alternative parts, the parser selects the last plain-text part,
    /// or the last HTML part if there is no plain-text part.
    /// A damaged part does not stop the parse when another part supplies the body.
    /// - Parameters:
    ///   - data: The complete `.emlx` file, which must not be larger than 32 MiB.
    ///   - expectedMessageID: The Message-ID from the index.
    ///     The parser compares it with the MIME Message-ID when it contains `@`.
    ///   - checkCancellation: A closure that throws to stop the parse.
    ///     The default checks the current task.
    /// - Throws: An ``EmlxError`` if the file does not contain a readable body
    ///   or does not match `expectedMessageID`, or the error from `checkCancellation`.
    public init(
        emlx data: Data,
        expectedMessageID: String? = nil,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        guard data.count <= maximumInputSize else {
            throw EmlxError.unsupportedMessage("the complete .emlx input exceeds 32 MiB")
        }
        let payload = try Container(data: data).payload
        let message: Part
        do {
            message = try Parser.parse(payload, checkCancellation: checkCancellation)
        } catch let failure as Failure {
            throw Self.error(for: failure)
        }
        guard let selected = Self.select(message) else {
            if let failure = Self.failure(in: message) {
                throw Self.error(for: failure)
            }
            throw EmlxError.unsupportedMessage("the local body is missing or not text")
        }
        headers = message.headers.map { Header(name: $0.name, value: $0.value) }
        body = selected.body
        mediaType = selected.mediaType
        attachmentFilenames = Self.filenames(message)
        messageID = message.header("message-id").map(Self.unbracketed)
        if let expectedMessageID, expectedMessageID.contains("@") {
            guard messageID == Self.unbracketed(expectedMessageID) else {
                throw EmlxError.messageMismatch
            }
        }
        try checkCancellation()
    }

    /// Removes white space and angle brackets from the ends of a Message-ID.
    private static func unbracketed(_ messageID: String) -> String {
        messageID.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    /// Returns the public error for a parser failure.
    private static func error(for failure: Failure) -> EmlxError {
        switch failure {
        case .malformed(let reason): return .malformedMessage(reason)
        case .unsupported(let reason): return .unsupportedMessage(reason)
        case .limit: return .unsupportedMessage("MIME resource limit exceeded")
        case .partial: return .partialMessage
        case .encrypted: return .encryptedMessage
        }
    }
}
