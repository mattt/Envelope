import Foundation
import SQLite3
import os

private let envelopeIndexPath = "MailData/Envelope Index"

/// The name of the SQL function that finds a substring without regard to case.
let containsFunction = "envelope_contains"

/// A read-only connection to the Envelope Index of the newest Mail store in a folder.
/// The index is read live, without a copy and with its write-ahead log.
public final class Database {
    /// Limits work on the live index.
    public struct Configuration: Sendable {
        /// The cooperative deadline for each SQL statement.
        public let queryTimeLimit: Duration
        /// The maximum number of open connections in this process.
        /// The smallest limit among open connections applies.
        public let maximumConnections: Int

        /// Creates limits for live reads.
        /// - Parameters:
        ///   - queryTimeLimit: A positive per-statement budget; defaults to 100 ms.
        ///   - maximumConnections: A positive connection limit; defaults to one.
        public init(queryTimeLimit: Duration = .milliseconds(100), maximumConnections: Int = 1) {
            precondition(queryTimeLimit > .zero)
            precondition(maximumConnections > 0)
            self.queryTimeLimit = queryTimeLimit
            self.maximumConnections = maximumConnections
        }
    }

    /// Messages and the local index scope used for a search.
    public struct SearchResult: Sendable {
        /// The matching messages, in descending date and row order.
        public let records: [Message]
        /// The indexed count before filters and pagination, within the selected mailbox.
        /// This count does not describe server contents or sync status.
        public let indexedMessageCount: Int64
        /// The request used to select the messages.
        public let filters: Message.FetchRequest
    }

    // Overlapping readers can prevent WAL checkpoints from completing.
    // Only hold this lock to reserve/release a connection, never during SQLite work.
    private static let admission = OSAllocatedUnfairLock(initialState: [UUID: Int]())

    /// The versioned store directory, such as `~/Library/Mail/V10`.
    public let versionURL: URL
    private var connection: OpaquePointer?
    private let admissionID = UUID()
    private var hasAdmission = false
    private let queryTimeLimit: Duration
    private let cancellation: Cancellation

    /// Finds the index without opening a SQLite connection.
    /// - Parameter root: The Mail folder containing versioned store directories.
    /// - Returns: The resolved version directory and index file URLs.
    /// - Throws: A location, access, or containment error.
    public static func location(in root: URL) throws -> (version: URL, index: URL) {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch {
            throw MailError.indexNotReadable
        }

        let versions: [(number: Int, url: URL)] = entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.first == "V", let number = Int(name.dropFirst()),
                FileManager.default.fileExists(atPath: url.appendingPathComponent(envelopeIndexPath).path)
            else { return nil }
            return (number, url)
        }
        guard let version = versions.max(by: { $0.number < $1.number })?.url else {
            throw MailError.indexNotFound
        }

        let versionURL = version.resolvingSymlinksInPath()
        guard versionURL.isContained(in: root) else {
            throw MailError.notContained(versionURL)
        }
        let databaseURL = version.appendingPathComponent(envelopeIndexPath).resolvingSymlinksInPath()
        guard databaseURL.isContained(in: versionURL) else {
            throw MailError.notContained(databaseURL)
        }
        return (versionURL, databaseURL)
    }

    /// Opens the newest store in a folder that the caller can access.
    /// Keep any security scope open until `close()` returns.
    /// Use the connection from one thread at a time.
    /// - Parameters:
    ///   - root: The Mail folder containing versioned store directories.
    ///   - configuration: Statement deadlines and process-wide connection limits.
    ///   - cancellation: A shared cancellation signal.
    /// - Throws: A store, schema, admission, or cancellation error.
    public init(
        root: URL,
        configuration: Configuration = Configuration(),
        cancellation: Cancellation = Cancellation()
    ) throws {
        try cancellation.check()
        let location = try Self.location(in: root)
        versionURL = location.version
        self.queryTimeLimit = configuration.queryTimeLimit
        self.cancellation = cancellation
        try cancellation.check()

        hasAdmission = Self.admission.withLock { [admissionID] occupied in
            let limit = min(configuration.maximumConnections, occupied.values.min() ?? configuration.maximumConnections)
            guard occupied.count < limit else { return false }
            occupied[admissionID] = configuration.maximumConnections
            return true
        }
        guard hasAdmission else { throw MailError.connectionLimitReached }

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE
        guard sqlite3_open_v2(location.index.path, &connection, flags, nil) == SQLITE_OK else {
            close()
            throw MailError.indexNotReadable
        }
        // Yield immediately to Mail rather than waiting or retrying.
        sqlite3_busy_timeout(connection, 0)
        sqlite3_create_function_v2(
            connection,
            containsFunction,
            2,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            nil,
            { context, _, arguments in
                guard let arguments else { return sqlite3_result_null(context) }
                sqlite3_result_int(context, containsIgnoringCase(arguments[0], arguments[1]))
            },
            nil,
            nil,
            nil
        )

        do {
            // Rollback-journal readers can block commits. Refuse that mode;
            // never change the owner's journal settings or bypass its locks.
            // The first statement reads the file, so its failure means the index is not readable.
            let journalMode: String?
            do {
                journalMode = try query("PRAGMA journal_mode", transform: { $0.text(0) }).first ?? nil
            } catch MailError.queryFailed {
                throw MailError.indexNotReadable
            }
            guard journalMode == "wal" else {
                throw MailError.unsupportedJournalMode
            }
            do {
                for (table, columns) in [
                    "messages": ["ROWID", "mailbox", "subject", "sender", "date_received", "read", "message_id"],
                    "mailboxes": ["ROWID", "url"],
                    "subjects": ["ROWID", "subject"],
                    "addresses": ["ROWID", "address"],
                ] {
                    try query("SELECT \(columns.joined(separator: ", ")) FROM \(table) LIMIT 0") { _ in }
                }
            } catch MailError.queryFailed {
                throw MailError.unsupportedSchema
            }
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    /// Closes the connection. Call it before the security scope of the Mail folder ends.
    public func close() {
        sqlite3_close(connection)
        connection = nil
        if hasAdmission {
            Self.admission.withLock { [admissionID] in _ = $0.removeValue(forKey: admissionID) }
            hasAdmission = false
        }
    }

    /// Returns local mailboxes with available account labels.
    /// - Returns: Mailboxes ordered by storage URL and row identifier.
    /// - Throws: A database or cancellation error.
    public func mailboxes() throws -> [Mailbox] {
        let accounts = Account.load(in: versionURL)
        return try query("SELECT ROWID, url FROM mailboxes ORDER BY url, ROWID") {
            try Mailbox($0, version: versionURL, accounts: accounts)
        }
    }

    /// Searches metadata and counts the local mailbox scope before filtering.
    /// - Parameter request: Filters and pagination to apply.
    /// - Returns: The matching records, scope count, and applied request.
    /// - Throws: A validation, database, or cancellation error.
    public func search(_ request: Message.FetchRequest) throws -> SearchResult {
        try readTransaction {
            let records = try fetch(request)
            // Count the selected local scope without the search filters or pagination.
            let scope = Message.FetchRequest(mailbox: request.mailbox)
            let (sql, bindings) = scope.statement(matchesLabels: try hasLabels, countOnly: true)
            let count = try query(sql, bindings) { $0.integer(0) ?? 0 }.first ?? 0
            return SearchResult(records: records, indexedMessageCount: count, filters: request)
        }
    }

    /// Returns messages that match a metadata request.
    /// - Parameter request: Filters and pagination to apply.
    /// - Returns: Matching messages in descending received date and row order.
    /// - Throws: A validation, database, or cancellation error.
    public func fetch(_ request: Message.FetchRequest) throws -> [Message] {
        try request.validate()
        if let mailbox = request.mailbox {
            let exists = try query("SELECT 1 FROM mailboxes WHERE ROWID = ?", [.integer(mailbox)]) { _ in true }
            guard !exists.isEmpty else {
                throw MailError.mailboxNotFound
            }
        }
        let (sql, bindings) = request.statement(matchesLabels: try hasLabels)
        return try query(sql, bindings) { try Message($0, store: versionURL.lastPathComponent) }
    }

    /// Returns the indexed message that an identifier from an earlier fetch refers to.
    /// - Parameter identifier: The store, home mailbox, and message identifiers.
    /// - Returns: The current indexed message.
    /// - Throws: `MailError.storeChanged`, `MailError.messageNotFound`,
    ///   or a database or cancellation error.
    public func record(for identifier: Message.Identifier) throws -> Message {
        guard identifier.store == versionURL.lastPathComponent else {
            throw MailError.storeChanged
        }
        guard let record = try fetch(.init(id: identifier.message)).first,
            record.mailbox == identifier.mailbox
        else {
            throw MailError.messageNotFound
        }
        return record
    }

    /// Whether the store has a usable `labels` table.
    /// Stores with that table record label membership of a message there.
    private var hasLabels: Bool {
        get throws {
            let tables = try query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'labels'") {
                $0.text(0)
            }
            guard !tables.isEmpty else { return false }
            try query("SELECT message_id, mailbox_id FROM labels LIMIT 0") { _ in }
            return true
        }
    }

    /// Runs statements in one read transaction, so that they read the same snapshot.
    ///
    /// The transaction ends even if the time limit has passed or the work is canceled,
    /// because an open read transaction delays WAL checkpoints.
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try query("BEGIN") { _ in }
        defer {
            if let connection, sqlite3_get_autocommit(connection) == 0 {
                sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
            }
        }
        return try body()
    }

    /// Runs a statement and transforms each row of its result.
    @discardableResult
    func query<T>(
        _ sql: String,
        _ bindings: [Binding] = [],
        transform: (Row) throws -> T
    ) throws -> [T] {
        guard let connection else { throw MailError.connectionClosed }
        let budget = QueryBudget(timeLimit: queryTimeLimit, cancellation: cancellation)
        try budget.check()
        sqlite3_progress_handler(
            connection,
            1000,
            { context in
                guard let context else { return 1 }
                let budget = Unmanaged<QueryBudget>.fromOpaque(context).takeUnretainedValue()
                return budget.shouldStop ? 1 : 0
            },
            Unmanaged.passUnretained(budget).toOpaque()
        )
        defer {
            sqlite3_progress_handler(connection, 0, nil, nil)
            withExtendedLifetime(budget) {}
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try checkResult(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), budget: budget)

        for (offset, binding) in bindings.enumerated() {
            try checkResult(binding.bind(to: statement, at: Int32(offset + 1)), budget: budget)
        }

        var results: [T] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            try budget.check()
            results.append(try transform(Row(statement: statement)))
            try budget.check()
            result = sqlite3_step(statement)
        }
        try checkResult(result, budget: budget)
        return results
    }

    private func checkResult(_ result: Int32, budget: QueryBudget) throws {
        try budget.check()
        switch result & 0xff {
        case SQLITE_OK, SQLITE_DONE:
            return
        case SQLITE_BUSY, SQLITE_LOCKED:
            throw MailError.databaseBusy
        default:
            throw MailError.queryFailed(String(cString: sqlite3_errmsg(connection)))
        }
    }

    /// A cooperative deadline, including cancellation of the calling task.
    /// SQLite cannot call the progress handler while blocked in filesystem I/O.
    private final class QueryBudget {
        let deadline: ContinuousClock.Instant
        let cancellation: Cancellation

        init(timeLimit: Duration, cancellation: Cancellation) {
            deadline = ContinuousClock.now.advanced(by: timeLimit)
            self.cancellation = cancellation
        }

        var shouldStop: Bool {
            cancellation.isCancelled || ContinuousClock.now >= deadline
        }

        func check() throws {
            try cancellation.check()
            guard ContinuousClock.now < deadline else { throw MailError.queryTimedOut }
        }
    }
}

extension Database {
    /// A value bound to a `?` placeholder in a prepared statement.
    enum Binding {
        case text(String)
        case double(Double)
        case integer(Int64)

        func bind(to statement: OpaquePointer?, at index: Int32) -> Int32 {
            switch self {
            case .text(let string):
                return sqlite3_bind_text(statement, index, string, -1, SQLITE_TRANSIENT)
            case .double(let double):
                return sqlite3_bind_double(statement, index, double)
            case .integer(let integer):
                return sqlite3_bind_int64(statement, index, integer)
            }
        }
    }

    /// The current row of a prepared statement. Accessors return nil for `NULL`.
    struct Row {
        let statement: OpaquePointer?

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func integer(_ column: Int32) -> Int64? {
            isNull(column) ? nil : sqlite3_column_int64(statement, column)
        }

        func double(_ column: Int32) -> Double? {
            isNull(column) ? nil : sqlite3_column_double(statement, column)
        }

        private func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, column) == SQLITE_NULL
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Returns 1 if a text value contains a term without regard to case, and 0 otherwise.
///
/// SQLite's `lower()` folds only ASCII letters.
/// The search uses this function only for a term that has non-ASCII characters.
private func containsIgnoringCase(_ text: OpaquePointer?, _ term: OpaquePointer?) -> Int32 {
    guard let textBytes = sqlite3_value_text(text), let termBytes = sqlite3_value_text(term) else { return 0 }
    let textCount = Int(sqlite3_value_bytes(text))
    let termCount = Int(sqlite3_value_bytes(term))
    // A term with non-ASCII letters cannot match text that has only ASCII bytes,
    // except through rare folds such as the Kelvin sign.
    // Most indexed subjects and addresses are ASCII, so this check avoids most conversions.
    guard UnsafeBufferPointer(start: textBytes, count: textCount).contains(where: { $0 >= 0x80 }) else { return 0 }
    guard
        let haystack = CFStringCreateWithBytesNoCopy(nil, textBytes, textCount, CFStringBuiltInEncodings.UTF8.rawValue, false, kCFAllocatorNull),
        let needle = CFStringCreateWithBytesNoCopy(nil, termBytes, termCount, CFStringBuiltInEncodings.UTF8.rawValue, false, kCFAllocatorNull)
    else { return 0 }
    return CFStringFind(haystack, needle, .compareCaseInsensitive).location == kCFNotFound ? 0 : 1
}
