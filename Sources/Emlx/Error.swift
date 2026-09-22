import Foundation

/// A failure while reading local mail.
public enum Error: LocalizedError, Equatable {
    case partialMessage
    case encryptedMessage
    case malformedMessage(String)
    case unsupportedMessage(String)
    case messageMismatch

    public var errorDescription: String? {
        switch self {
        case .partialMessage:
            return "Partial message: Mail has not downloaded all content."
        case .encryptedMessage:
            return "Encrypted message content is unavailable."
        case .malformedMessage(let reason):
            return "Malformed message: \(reason)."
        case .unsupportedMessage(let reason):
            return "Unsupported message: \(reason)."
        case .messageMismatch:
            return "Local message identity does not match the Mail index."
        }
    }
}
