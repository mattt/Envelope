import Foundation

/// An invalid metadata request or mailbox identifier.
public enum ValidationError: LocalizedError, Equatable {
    /// The limit is outside the supported range of 1 through 100.
    case limitOutOfRange
    /// The offset is negative.
    case negativeOffset
    /// The start date is not before the end date.
    case invalidDateRange
    /// The mailbox identifier is not a positive decimal integer.
    case invalidMailboxIdentifier

    public var errorDescription: String? {
        switch self {
        case .limitOutOfRange:
            return "The limit must be 1 through 100."
        case .negativeOffset:
            return "The offset must not be negative."
        case .invalidDateRange:
            return "The start date must be before the end date."
        case .invalidMailboxIdentifier:
            return "The mailbox identifier must be a positive decimal integer."
        }
    }
}
