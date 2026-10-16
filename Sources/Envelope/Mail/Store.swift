import Foundation

/// Read-only access to the newest Mail store in a Mail folder.
///
/// A store runs one operation at a time on a private dispatch queue,
/// outside Swift's cooperative thread pool.
/// Calls that arrive while an operation runs wait their turn, without a limit.
/// Swift does not guarantee that waiting calls run in the order that they arrive.
/// Each operation opens its own connection to the index and closes it before it returns,
/// so a store holds no connection between operations.
/// On macOS 14 and later, each operation runs at the priority of the calling task.
///
/// Operations run as part of the calling task.
/// Canceling the task stops SQL statements, file lookups,
/// and parsers that check `Task.isCancelled`, such as `Content`.
///
/// The caller must have access to the Mail folder.
/// Keep any security scope active until each call returns or throws;
/// by then, the store has finished all database and file work for that call.
public actor Store {
    /// Limits on the work that a store does in the live index.
    public struct Configuration: Sendable, Hashable {
        /// The time limit for each SQL statement.
        ///
        /// The limit is cooperative: SQLite checks it between steps,
        /// so it cannot stop a statement that is blocked in file I/O.
        public let queryTimeLimit: Duration
        /// The maximum number of connections that the process can open.
        ///
        /// A store opens at most one connection at a time.
        /// When open connections have different limits, the smallest limit applies.
        public let maximumConnections: Int
        /// The time limit for all the statements of one snapshot.
        ///
        /// A snapshot holds a read transaction, which can delay Mail's WAL checkpoints.
        /// When the limit passes, the next statement step throws ``MailError/queryTimedOut``.
        /// Searches and other single operations also read one snapshot, so the limit applies to them too.
        public let snapshotTimeLimit: Duration

        /// The default limits: 100 ms for each statement, one connection, and 1 second for each snapshot.
        public static let `default` = Configuration(
            validQueryTimeLimit: .milliseconds(100),
            maximumConnections: 1,
            snapshotTimeLimit: .seconds(1)
        )

        /// Creates limits for a store.
        ///
        /// Use ``default`` for the default limits.
        /// - Parameters:
        ///   - queryTimeLimit: The time limit for each SQL statement. The value must be positive.
        ///   - maximumConnections: The maximum number of open connections. The value must be positive.
        ///   - snapshotTimeLimit: The time limit for all the statements of one snapshot.
        ///     The value must be positive.
        /// - Throws: A ``ValidationError`` that describes the first value that is not positive.
        public init(
            queryTimeLimit: Duration = Configuration.default.queryTimeLimit,
            maximumConnections: Int = Configuration.default.maximumConnections,
            snapshotTimeLimit: Duration = Configuration.default.snapshotTimeLimit
        ) throws {
            guard queryTimeLimit > .zero else {
                throw ValidationError.invalidQueryTimeLimit
            }
            guard maximumConnections > 0 else {
                throw ValidationError.invalidMaximumConnections
            }
            guard snapshotTimeLimit > .zero else {
                throw ValidationError.invalidSnapshotTimeLimit
            }
            self.init(
                validQueryTimeLimit: queryTimeLimit,
                maximumConnections: maximumConnections,
                snapshotTimeLimit: snapshotTimeLimit
            )
        }

        /// Creates limits that are already known to be positive.
        private init(validQueryTimeLimit: Duration, maximumConnections: Int, snapshotTimeLimit: Duration) {
            queryTimeLimit = validQueryTimeLimit
            self.maximumConnections = maximumConnections
            self.snapshotTimeLimit = snapshotTimeLimit
        }
    }

    /// The locations of a store and its index.
    public struct Location: Sendable, Hashable {
        /// The store directory, such as `~/Library/Mail/V10`, with symbolic links resolved.
        public let versionURL: URL
        /// The Envelope Index file, with symbolic links resolved.
        public let indexURL: URL
    }

    /// The messages that match a search, and the number of messages in the searched scope.
    public struct SearchResult: Sendable, Hashable {
        /// The matching messages, newest first.
        public let records: [Message]
        /// The position after which the next page starts, or `nil` if no more messages match.
        ///
        /// Set ``Message/FetchRequest/cursor`` to this value to request the next page.
        public let nextCursor: Message.FetchRequest.Cursor?
        /// The number of indexed messages in the requested mailbox, or in the store,
        /// before the other filters and pagination apply.
        ///
        /// The count describes the local index only.
        /// A count of zero can mean an empty mailbox, or a mailbox that Mail has not indexed.
        public let indexedMessageCount: Int
        /// The request that selected the messages.
        public let request: Message.FetchRequest
    }

    /// The contents of a message file, and the index record that located it.
    public struct MessageFile: Sendable {
        /// The current index record of the message.
        ///
        /// Pass its ``Message/messageID`` to the parser to check file identity.
        public let message: Message
        /// The complete `.emlx` file, at most 32 MiB.
        public let data: Data
    }

    /// A read-only view of the index in which every query reads the same snapshot.
    ///
    /// A snapshot is valid only inside the closure that receives it.
    /// After the closure returns, its queries throw ``MailError/connectionClosed``.
    public struct Snapshot {
        let database: Database

        /// The store directory and index that the snapshot reads.
        public let location: Location

        /// Returns the mailboxes in the local index.
        ///
        /// The accounts include email addresses when the store's account map has them.
        /// - Returns: The mailboxes, ordered by URL and row identifier.
        /// - Throws: A ``MailError`` or `CancellationError`.
        public func mailboxes() throws -> [Mailbox] {
            try database.mailboxes()
        }

        /// Returns the messages that match a request,
        /// and the number of indexed messages in the requested scope.
        /// - Parameter request: The filters and pagination.
        /// - Returns: The messages, the count, and the request.
        /// - Throws: A ``Message/FetchRequest/ValidationError`` if the request is invalid,
        ///   a ``MailError`` if the index cannot be read, or `CancellationError`.
        public func search(_ request: Message.FetchRequest) throws -> SearchResult {
            try database.search(request)
        }

        /// Returns the messages that match a request, without a count.
        /// - Parameter request: The filters and pagination.
        /// - Returns: The matching messages, newest first.
        /// - Throws: A ``Message/FetchRequest/ValidationError`` if the request is invalid,
        ///   a ``MailError`` if the index cannot be read, or `CancellationError`.
        public func fetch(_ request: Message.FetchRequest) throws -> [Message] {
            try database.fetch(request)
        }

        /// Returns the current values of a message from an earlier search.
        /// - Parameter identifier: The identifier of the message.
        /// - Returns: The message.
        /// - Throws: ``MailError/storeChanged`` if the identifier is from another store,
        ///   ``MailError/messageNotFound`` if the message is no longer in its home mailbox,
        ///   another ``MailError`` if the index cannot be read, or `CancellationError`.
        public func record(for identifier: Message.Identifier) throws -> Message {
            try database.record(for: identifier)
        }
    }

    /// The Mail folder, such as `~/Library/Mail`.
    public nonisolated let root: URL
    /// The limits that apply to each operation.
    public nonisolated let configuration: Configuration

    private let files = MessageFileReader()
    private nonisolated let executor = QueueExecutor(label: "me.mattt.Envelope.mail")

    /// The executor that runs the store's operations on its private dispatch queue.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// Creates a store for a Mail folder, without reading it.
    ///
    /// Each operation finds the newest `V` directory with an index,
    /// so a store follows Mail when it upgrades its store.
    /// Call ``checkAccess()`` to check that the folder can be read.
    /// - Parameters:
    ///   - root: The Mail folder, such as `~/Library/Mail`, with `~` expanded.
    ///   - configuration: The time limits and the connection limit.
    public init(root: URL, configuration: Configuration = .default) {
        self.root = root
        self.configuration = configuration
    }

    /// Checks that the store can open the index and read its schema.
    ///
    /// The check opens a connection, checks the journal mode and the tables that Envelope reads,
    /// and closes the connection without reading any messages.
    /// Call it after the caller gets access to the Mail folder, such as after the user grants it.
    /// - Returns: The locations of the store and its index.
    /// - Throws: A ``MailError`` if the folder, the store, or the index cannot be read,
    ///   or if the index has an unsupported schema or journal mode; or `CancellationError`.
    @discardableResult
    public func checkAccess() throws -> Location {
        try withDatabase { Location(versionURL: $0.versionURL, indexURL: $0.indexURL) }
    }

    /// Finds the newest store and its index without opening a connection.
    ///
    /// This method reads only the folder's directory entries and symbolic links,
    /// so it runs on the caller's thread and does not wait for other operations of the store.
    /// It does not check that the index can be opened; ``checkAccess()`` does.
    /// - Returns: The locations of the store and its index.
    /// - Throws: ``MailError/indexNotReadable`` if the folder cannot be read,
    ///   ``MailError/indexNotFound`` if no store has an index,
    ///   ``MailError/notContained(_:)`` if a symbolic link leads outside the folder,
    ///   or `CancellationError`.
    public nonisolated func location() throws -> Location {
        try Task.checkCancellation()
        return try Database.location(in: root)
    }

    /// Returns the mailboxes in the local index.
    /// - Returns: The mailboxes, ordered by URL and row identifier.
    /// - Throws: A ``MailError`` or `CancellationError`.
    public func mailboxes() throws -> [Mailbox] {
        try withSnapshot { try $0.mailboxes() }
    }

    /// Returns the messages that match a request,
    /// and the number of indexed messages in the requested scope, from one snapshot.
    /// - Parameter request: The filters and pagination.
    /// - Returns: The messages, the count, and the request.
    /// - Throws: A ``Message/FetchRequest/ValidationError``, a ``MailError``, or `CancellationError`.
    public func search(_ request: Message.FetchRequest) throws -> SearchResult {
        try withSnapshot { try $0.search(request) }
    }

    /// Returns the messages that match a request, without a count.
    /// - Parameter request: The filters and pagination.
    /// - Returns: The matching messages, newest first.
    /// - Throws: A ``Message/FetchRequest/ValidationError``, a ``MailError``, or `CancellationError`.
    public func fetch(_ request: Message.FetchRequest) throws -> [Message] {
        try withSnapshot { try $0.fetch(request) }
    }

    /// Returns the current values of a message from an earlier search.
    /// - Parameter identifier: The identifier of the message.
    /// - Returns: The message.
    /// - Throws: ``MailError/storeChanged``, ``MailError/messageNotFound``,
    ///   another ``MailError``, or `CancellationError`.
    public func record(for identifier: Message.Identifier) throws -> Message {
        try withSnapshot { try $0.record(for: identifier) }
    }

    /// Runs several queries in one snapshot of the index.
    ///
    /// The snapshot holds a read transaction until the closure returns,
    /// which can delay Mail's WAL checkpoints.
    /// Its statements stop at ``Configuration/snapshotTimeLimit``.
    /// - Parameter body: A closure that queries the snapshot.
    ///   The snapshot is not valid after the closure returns.
    /// - Returns: The value that `body` returns.
    /// - Throws: A ``MailError``, the error that `body` throws, or `CancellationError`.
    public func withSnapshot<T: Sendable>(_ body: @Sendable (Snapshot) throws -> T) throws -> T {
        try withDatabase { database in
            try database.readTransaction {
                try body(Snapshot(database: database, location: Location(versionURL: database.versionURL, indexURL: database.indexURL)))
            }
        }
    }

    /// Reads the file of a message and parses its contents.
    ///
    /// The store looks up the current record, closes its connection,
    /// and then finds and reads the message file.
    /// File locations are cached as hints and checked again on every read.
    /// If `parse` throws for a cached location,
    /// the store finds the file again and calls `parse` again.
    /// - Parameters:
    ///   - identifier: The identifier of a message from an earlier search.
    ///   - parse: A closure that parses the file and checks that it holds the message.
    /// - Returns: The value that `parse` returns.
    /// - Throws: A ``MailError`` if the message or its file cannot be found or read,
    ///   the error that `parse` throws, or `CancellationError`.
    public func readMessage<T: Sendable>(
        _ identifier: Message.Identifier,
        parse: @Sendable (MessageFile) throws -> T
    ) throws -> T {
        let (record, version) = try withDatabase { database in
            (try database.record(for: identifier), database.versionURL)
        }
        // The connection is closed here, before file I/O and parsing.
        return try files.read(record, version: version) { data in
            try parse(MessageFile(message: record, data: data))
        }
    }

    /// Opens a connection for one operation and closes it before returning.
    ///
    /// The connection's statements stop at the snapshot time limit.
    func withDatabase<T>(_ body: (Database) throws -> T) throws -> T {
        try Task.checkCancellation()
        let database = try Database(root: root, configuration: configuration)
        database.snapshotDeadline = ContinuousClock.now.advanced(by: configuration.snapshotTimeLimit)
        defer { database.close() }
        return try body(database)
    }
}

@available(*, unavailable)
extension Store.Snapshot: Sendable {}

/// A serial executor that runs jobs on a private dispatch queue.
///
/// `DispatchSerialQueue` conforms to `SerialExecutor` only from macOS 14,
/// so this type adapts a queue for macOS 13.
/// Each job runs at the priority of its task on macOS 14 and later, and at `.utility` before that.
final class QueueExecutor: SerialExecutor {
    let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    func enqueue(_ job: UnownedJob) {
        queue.async(qos: DispatchQoS(qosClass: Self.qosClass(of: job), relativePriority: 0)) {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    /// Returns the quality of service that matches the priority of a job's task.
    ///
    /// Task priorities use the raw values of the quality-of-service classes.
    static func qosClass(of job: UnownedJob) -> DispatchQoS.QoSClass {
        guard #available(macOS 14, *) else { return .utility }
        let rawValue = qos_class_t(rawValue: UInt32(job.priority.rawValue))
        guard let qosClass = DispatchQoS.QoSClass(rawValue: rawValue), qosClass != .unspecified else {
            return .utility
        }
        return qosClass
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
