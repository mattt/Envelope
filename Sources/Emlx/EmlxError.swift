import Foundation

/// An error that occurs when Envelope reads an `.emlx` file.
public enum EmlxError: LocalizedError, Hashable {
    /// The file is shorter than its byte count, or the message is one fragment of a larger message.
    case partialMessage
    /// The readable body is encrypted.
    case encryptedMessage
    /// The file or its MIME structure is malformed, with a reason.
    case malformedMessage(String)
    /// The message has no body that Envelope can read, with a reason.
    case unsupportedMessage(String)
    /// The MIME Message-ID does not match the Message-ID in the index.
    case messageMismatch

    /// English text that describes the error.
    ///
    /// Envelope does not localize this text.
    public var errorDescription: String? {
        switch self {
        case .partialMessage:
            return "Only part of the message is available."
        case .encryptedMessage:
            return "The message is encrypted."
        case .malformedMessage(let reason):
            return "The message is malformed: \(reason)."
        case .unsupportedMessage(let reason):
            return "The message is not supported: \(reason)."
        case .messageMismatch:
            return "The message file does not match the message in the Mail index."
        }
    }
}
