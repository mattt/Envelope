import Foundation

/// A failure while reading local mail.
public enum Error: LocalizedError, Equatable {
    case indexNotFound
    case indexNotReadable
    case unsupportedSchema
    case unsupportedJournalMode
    case databaseBusy
    case queryTimedOut
    case queryFailed(String)
    case notContained(String)
    case storeChanged
    case messageNotFound
    case messageFileNotFound
    case messageFileTooLarge
    case messageMismatch
    case unsupportedMailbox
    case partialMessage

    public var errorDescription: String? {
        switch self {
        case .indexNotFound:
            return
                "Mail access is unavailable: no local Envelope Index was found."
        case .indexNotReadable:
            return
                "Mail access is unavailable. The index and its live WAL files must be readable."
        case .unsupportedSchema:
            return "Unsupported Mail Envelope Index schema."
        case .unsupportedJournalMode:
            return
                "Mail reading is unavailable because the index is not in WAL mode. Envelope will not change Mail's database settings."
        case .databaseBusy:
            return
                "Mail reading is busy. Try again later; Envelope does not wait for database locks or queue concurrent reads."
        case .queryTimedOut:
            return
                "Mail reading stopped to limit interference with Mail. Use a narrower date range or more specific filters."
        case .queryFailed(let message):
            return "Could not read the live Mail index: \(message)"
        case .notContained(let item):
            return "\(item) is outside the selected Mail folder."
        case .storeChanged:
            return "The Mail store changed. Search again for a current identifier."
        case .messageNotFound:
            return "Message is no longer in the local Mail index."
        case .messageFileNotFound:
            return "Local message file is missing or ambiguous. Open the message in Mail to download it."
        case .messageFileTooLarge:
            return "Local message exceeds the 32 MiB read limit or is not a regular file."
        case .messageMismatch:
            return "Local message identity does not match the Mail index."
        case .unsupportedMailbox:
            return "Unsupported mailbox storage mapping."
        case .partialMessage:
            return "Partial message: Mail has not downloaded all content."
        }
    }
}
