import Foundation

/// An error that occurs when Envelope reads the Mail store.
public enum MailError: LocalizedError, Hashable {
    /// The folder does not contain a store with an Envelope Index.
    case indexNotFound
    /// The folder, the index, or its write-ahead log files cannot be read.
    case indexNotReadable
    /// The index does not have the tables and columns that Envelope reads.
    case unsupportedSchema
    /// The index uses a rollback journal, and a reader could block Mail's writes.
    case unsupportedJournalMode
    /// Mail holds a lock on the index.
    case databaseBusy
    /// The process already has the maximum number of open connections to the index.
    case connectionLimitReached
    /// The connection to the index is closed.
    case connectionClosed
    /// The worker is already running an operation.
    case operationInProgress
    /// A statement did not finish within its time limit.
    case queryTimedOut
    /// SQLite reported an error, with its message.
    case queryFailed(String)
    /// A file or folder resolves to a location outside the Mail folder.
    case notContained(URL)
    /// An identifier or message refers to a different store than the one that is open.
    case storeChanged
    /// The index does not contain the mailbox.
    case mailboxNotFound
    /// The index does not contain the message in its home mailbox.
    case messageNotFound
    /// The mailbox has no message file for the message, or has more than one.
    case messageFileNotFound
    /// The message file is larger than the read limit.
    case messageFileTooLarge
    /// The message file is not a regular file.
    case messageFileNotRegular
    /// Envelope cannot map the mailbox URL to a folder in the store.
    case unsupportedMailbox
    /// Mail has downloaded only part of the message.
    case partialMessage

    /// English text that describes the error and, for some errors, what to do next.
    ///
    /// Envelope does not localize this text.
    public var errorDescription: String? {
        switch self {
        case .indexNotFound:
            return "The selected folder does not contain a Mail store."
        case .indexNotReadable:
            return "The Mail index cannot be read. The index and its write-ahead log files must be readable."
        case .unsupportedSchema:
            return "The Mail index uses an unsupported schema."
        case .unsupportedJournalMode:
            return "The Mail index does not use write-ahead logging, so reading it could block Mail."
        case .databaseBusy:
            return "Mail is using the index. Try again later."
        case .connectionLimitReached:
            return "Too many connections to the Mail index are open. Close a connection and try again."
        case .connectionClosed:
            return "The connection to the Mail index is closed."
        case .operationInProgress:
            return "Another Mail operation is in progress. Try again when it finishes."
        case .queryTimedOut:
            return "Reading the Mail index stopped at the time limit, to avoid delaying Mail. A search with more specific filters can finish sooner."
        case .queryFailed(let message):
            return "The Mail index cannot be read: \(message)"
        case .notContained(let url):
            return "The item at \(url.path) is outside the selected Mail folder."
        case .storeChanged:
            return "The Mail store changed. Search again to get a current identifier."
        case .mailboxNotFound:
            return "The mailbox is not in the local Mail index."
        case .messageNotFound:
            return "The message is no longer in the local Mail index."
        case .messageFileNotFound:
            return "The local message file is missing or ambiguous. Open the message in Mail to download it."
        case .messageFileTooLarge:
            return "The local message file is larger than the 32 MiB read limit."
        case .messageFileNotRegular:
            return "The local message file is not a regular file."
        case .unsupportedMailbox:
            return "The mailbox storage location is not supported."
        case .partialMessage:
            return "Mail has downloaded only part of the message. Open the message in Mail to download it."
        }
    }
}
