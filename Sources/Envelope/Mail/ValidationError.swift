import Foundation

extension Message.FetchRequest {
    /// An error that describes an invalid search request.
    public enum ValidationError: LocalizedError, Hashable {
        /// The limit is not in the range from 1 through ``Message/FetchRequest/maximumLimit``.
        case limitOutOfRange
        /// The start date is not earlier than the end date.
        case invalidDateRange

        /// English text that describes the error.
        ///
        /// Envelope does not localize this text.
        public var errorDescription: String? {
            switch self {
            case .limitOutOfRange:
                return "The limit must be from 1 through \(Message.FetchRequest.maximumLimit)."
            case .invalidDateRange:
                return "The start date must be earlier than the end date."
            }
        }
    }
}

extension Store.Configuration {
    /// An error that describes an invalid connection configuration.
    public enum ValidationError: LocalizedError, Hashable {
        /// The time limit for each SQL statement is not positive.
        case invalidQueryTimeLimit
        /// The maximum number of connections is not positive.
        case invalidMaximumConnections
        /// The time limit for a snapshot is not positive.
        case invalidSnapshotTimeLimit

        /// English text that describes the error.
        ///
        /// Envelope does not localize this text.
        public var errorDescription: String? {
            switch self {
            case .invalidQueryTimeLimit:
                return "The query time limit must be positive."
            case .invalidMaximumConnections:
                return "The maximum number of connections must be positive."
            case .invalidSnapshotTimeLimit:
                return "The snapshot time limit must be positive."
            }
        }
    }
}
