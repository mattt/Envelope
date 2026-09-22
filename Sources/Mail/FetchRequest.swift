import Foundation

private let defaultLimit = 30
private let maximumLimit = 100

extension Message {
    /// Filters and pagination for an indexed message search.
    public struct FetchRequest: Sendable, Equatable {
        /// Sender address to match (partial, case-insensitive).
        public var sender: String?
        /// Subject to match (partial, case-insensitive).
        public var subject: String?
        /// Row identifier of a mailbox that holds the message or labels it.
        public var mailbox: Int64?
        /// Start of the date range (inclusive).
        public var startDate: Date?
        /// End of the date range (exclusive).
        public var endDate: Date?
        /// The read state to match, or nil for both states.
        public var isRead: Bool?
        /// The result limit, from 1 through 100; defaults to 30.
        public var limit = defaultLimit
        /// The number of matching messages to skip.
        public var offset = 0
        /// Row identifier of a single message.
        public var id: Int64?

        /// Creates a metadata request. Filters combine with AND.
        /// - Parameters:
        ///   - sender: A case-insensitive sender substring.
        ///   - subject: A case-insensitive subject substring.
        ///   - mailbox: A home mailbox or label row identifier.
        ///   - startDate: The inclusive start date.
        ///   - endDate: The exclusive end date.
        ///   - isRead: A read-state filter, or nil for both states.
        ///   - limit: The result limit, from 1 through 100.
        ///   - offset: The number of matching messages to skip.
        ///   - id: A single message row identifier.
        public init(
            sender: String? = nil,
            subject: String? = nil,
            mailbox: Int64? = nil,
            startDate: Date? = nil,
            endDate: Date? = nil,
            isRead: Bool? = nil,
            limit: Int = 30,
            offset: Int = 0,
            id: Int64? = nil
        ) {
            self.sender = sender
            self.subject = subject
            self.mailbox = mailbox
            self.startDate = startDate
            self.endDate = endDate
            self.isRead = isRead
            self.limit = limit
            self.offset = offset
            self.id = id
        }

        func validate() throws {
            guard (1 ... maximumLimit).contains(limit) else {
                throw ValidationError.limitOutOfRange
            }
            guard offset >= 0 else {
                throw ValidationError.negativeOffset
            }
            if let startDate, let endDate, startDate >= endDate {
                throw ValidationError.invalidDateRange
            }
        }

        /// The SQL and its bound values, in placeholder order.
        func statement(matchesLabels: Bool, countOnly: Bool = false) -> (
            sql: String, bindings: [Database.Binding]
        ) {
            var conditions: [String] = []
            var bindings: [Database.Binding] = []

            // instr, unlike LIKE, has no wildcard characters to escape.
            if let sender {
                conditions.append("instr(lower(a.address), lower(?)) > 0")
                bindings.append(.text(sender))
            }
            if let subject {
                conditions.append("instr(lower(s.subject), lower(?)) > 0")
                bindings.append(.text(subject))
            }
            if let mailbox {
                if matchesLabels {
                    conditions.append(
                        """
                        (m.mailbox = ? OR EXISTS \
                        (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id = ?))
                        """
                    )
                    bindings += [.integer(mailbox), .integer(mailbox)]
                } else {
                    conditions.append("m.mailbox = ?")
                    bindings.append(.integer(mailbox))
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
            if let id {
                conditions.append("m.ROWID = ?")
                bindings.append(.integer(id))
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
