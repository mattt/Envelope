import Foundation

/// An error that describes an invalid search request.
public enum ValidationError: LocalizedError, Hashable {
    /// The limit is not in the range from 1 through ``Message/FetchRequest/maximumLimit``.
    case limitOutOfRange
    /// The offset is negative.
    case negativeOffset
    /// The start date is not earlier than the end date.
    case invalidDateRange

    public var errorDescription: String? {
        switch self {
        case .limitOutOfRange:
            return "The limit must be from 1 through \(Message.FetchRequest.maximumLimit)."
        case .negativeOffset:
            return "The offset must not be negative."
        case .invalidDateRange:
            return "The start date must be earlier than the end date."
        }
    }
}
