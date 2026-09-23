import Foundation

extension Message {
    /// A metadata search of the local Mail index.
    ///
    /// Filters combine with AND.
    /// Results are ordered by received date and row identifier, newest first.
    public struct FetchRequest: Sendable, Hashable {
        /// The number of results that a request returns when it does not set a limit.
        public static let defaultLimit = 30
        /// The largest limit that a request can set.
        public static let maximumLimit = 100

        /// A substring of the sender address to match without regard to case.
        public var sender: String?
        /// A substring of the subject to match without regard to case.
        public var subject: String?
        /// The row identifier of a mailbox that holds the message or applies it as a label.
        public var mailboxID: Int64?
        /// The earliest received date to include.
        public var startDate: Date?
        /// The received date at which the range ends.
        ///
        /// The range excludes messages that Mail received at this date.
        public var endDate: Date?
        /// The read state to match, or `nil` to match both states.
        public var isRead: Bool?
        /// The maximum number of results, from 1 through ``maximumLimit``.
        public var limit: Int
        /// The number of matching messages to skip.
        public var offset: Int
        /// The row identifier of one message to match.
        var rowID: Int64?

        /// Creates a search request.
        /// - Parameters:
        ///   - sender: A substring of the sender address to match without regard to case.
        ///   - subject: A substring of the subject to match without regard to case.
        ///   - mailboxID: The row identifier of a mailbox that holds the message or applies it as a label.
        ///   - startDate: The earliest received date to include.
        ///   - endDate: The received date at which the range ends.
        ///   - isRead: The read state to match, or `nil` to match both states.
        ///   - limit: The maximum number of results, from 1 through ``maximumLimit``.
        ///   - offset: The number of matching messages to skip.
        public init(
            sender: String? = nil,
            subject: String? = nil,
            mailboxID: Int64? = nil,
            startDate: Date? = nil,
            endDate: Date? = nil,
            isRead: Bool? = nil,
            limit: Int = FetchRequest.defaultLimit,
            offset: Int = 0
        ) {
            self.sender = sender
            self.subject = subject
            self.mailboxID = mailboxID
            self.startDate = startDate
            self.endDate = endDate
            self.isRead = isRead
            self.limit = limit
            self.offset = offset
        }

        /// Creates a request for the message with a row identifier.
        init(rowID: Int64) {
            self.init()
            self.rowID = rowID
        }

        /// Checks the limit, the offset, and the date range.
        /// - Throws: A ``ValidationError`` that describes the first invalid value.
        func validate() throws {
            guard (1 ... Self.maximumLimit).contains(limit) else {
                throw ValidationError.limitOutOfRange
            }
            guard offset >= 0 else {
                throw ValidationError.negativeOffset
            }
            if let startDate, let endDate, startDate >= endDate {
                throw ValidationError.invalidDateRange
            }
        }

        /// Returns a condition that finds a term in a column without regard to case.
        ///
        /// An ASCII term uses SQLite's `lower()`, which is faster than the registered function.
        /// `instr`, unlike `LIKE`, has no wildcard characters to escape.
        static func contains(_ column: String, _ term: String) -> String {
            if term.allSatisfy(\.isASCII) {
                return "instr(lower(\(column)), lower(?)) > 0"
            }
            return "\(containsFunction)(\(column), ?)"
        }

        /// Returns the SQL for the request and its bound values, in placeholder order.
        /// - Parameters:
        ///   - matchesLabels: Whether the mailbox filter also matches label membership.
        ///   - countOnly: Whether the statement counts the matches without pagination.
        func statement(matchesLabels: Bool, countOnly: Bool = false) -> (
            sql: String, bindings: [Database.Binding]
        ) {
            var conditions: [String] = []
            var bindings: [Database.Binding] = []

            if let sender {
                conditions.append(Self.contains("a.address", sender))
                bindings.append(.text(sender))
            }
            if let subject {
                conditions.append(Self.contains("s.subject", subject))
                bindings.append(.text(subject))
            }
            if let mailboxID {
                if matchesLabels {
                    conditions.append(
                        """
                        (m.mailbox = ? OR EXISTS \
                        (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id = ?))
                        """
                    )
                    bindings += [.integer(mailboxID), .integer(mailboxID)]
                } else {
                    conditions.append("m.mailbox = ?")
                    bindings.append(.integer(mailboxID))
                }
            }
            if let startDate {
                conditions.append("m.date_received >= ?")
                bindings.append(.double(startDate.timeIntervalSince1970))
            }
            if let endDate {
                conditions.append("m.date_received < ?")
                bindings.append(.double(endDate.timeIntervalSince1970))
            }
            if let isRead {
                conditions.append("m.read = ?")
                bindings.append(.integer(isRead ? 1 : 0))
            }
            if let rowID {
                conditions.append("m.ROWID = ?")
                bindings.append(.integer(rowID))
            }
            if !countOnly {
                bindings += [.integer(Int64(limit)), .integer(Int64(offset))]
            }

            let whereClause =
                conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            let columns =
                countOnly
                ? "COUNT(*)" : "m.ROWID, m.mailbox, b.url, s.subject, a.address, m.date_received, m.read, m.message_id"
            let pagination = countOnly ? "" : "ORDER BY m.date_received DESC, m.ROWID DESC LIMIT ? OFFSET ?"
            let sql = """
                SELECT \(columns)
                FROM messages m
                JOIN mailboxes b ON b.ROWID = m.mailbox
                LEFT JOIN subjects s ON s.ROWID = m.subject
                LEFT JOIN addresses a ON a.ROWID = m.sender
                \(whereClause)
                \(pagination)
                """
            return (sql, bindings)
        }
    }
}
