import Foundation
import os

private let maximumMessageSize = 32 * 1024 * 1024

/// Finds and reads the `.emlx` files of indexed messages.
/// Cache entries are hints only.
/// Every read checks containment and calls the supplied parser to check identity.
public final class Files: Sendable {
    private let cache = OSAllocatedUnfairLock(initialState: [Message.Identifier: URL]())

    /// Creates a file locator with an empty path cache.
    public init() {}

    /// Reads a message file and validates it through a caller-supplied parser.
    /// Cached paths are retried through a fresh lookup if parsing fails.
    /// - Parameters:
    ///   - record: The indexed message to read.
    ///   - version: The version directory returned by the database.
    ///   - cancellation: A shared cancellation signal.
    ///   - transform: A parser that checks the file's Message-ID against the record.
    /// - Returns: The parser's result.
    /// - Throws: A file, parser, or cancellation error.
    public func read<T>(
        _ record: Message,
        version: URL,
        cancellation: Cancellation = Cancellation(),
        transform: (Data) throws -> T
    ) throws -> T {
        try cancellation.check()
        // A row identifier names a different message in another store.
        guard version.resolvingSymlinksInPath().lastPathComponent == record.store else {
            throw Error.storeChanged
        }
        let mailbox = try mailboxDirectory(record.mailboxURL, version: version)

        if let cached = cache.withLock({ $0[record.identifier] }) {
            do {
                return try load(cached, for: record, in: mailbox, version: version, cancellation: cancellation, transform: transform)
            } catch let error as CancellationError {
                throw error
            } catch {
                cache.withLock { _ = $0.removeValue(forKey: record.identifier) }
            }
        }

        let url = try locate(record, in: mailbox, cancellation: cancellation)
        let content = try load(url, for: record, in: mailbox, version: version, cancellation: cancellation, transform: transform)
        cache.withLock {
            if $0.count >= 1000 { $0.removeAll() }
            $0[record.identifier] = url
        }
        return content
    }

    /// Maps the URL of a `mailboxes` row to its `.mbox` directory in the store.
    /// - Parameters:
    ///   - value: The storage URL recorded by Mail.
    ///   - version: The version directory returned by the database.
    /// - Returns: The resolved mailbox directory.
    /// - Throws: `Error.unsupportedMailbox` or `Error.notContained`.
    public func mailboxDirectory(_ value: String, version: URL) throws -> URL {
        guard let url = URL(string: value) else {
            throw Error.unsupportedMailbox
        }

        let directory: URL
        if url.isFileURL {
            directory = url
        } else if let host = url.host, UUID(uuidString: host) != nil {
            // Modern stores use the account UUID as the mailbox URL host.
            directory = try url.path.split(separator: "/").reduce(version.appendingPathComponent(host)) {
                guard $1 != ".", $1 != ".." else { throw Error.unsupportedMailbox }
                return $0.appendingPathComponent("\($1).mbox")
            }
        } else {
            throw Error.unsupportedMailbox
        }

        guard directory.pathExtension == "mbox" else {
            throw Error.unsupportedMailbox
        }
        guard directory.isContained(in: version) else {
            throw Error.notContained("The mailbox")
        }
        return directory.resolvingSymlinksInPath()
    }

    /// Searches a mailbox for the one file that holds a message.
    private func locate(_ record: Message, in mailbox: URL, cancellation: Cancellation) throws -> URL {
        try cancellation.check()
        guard
            let entries = FileManager.default.enumerator(
                at: mailbox,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw Error.messageFileNotFound
        }

        var candidates: [URL] = []
        var isPartial = false
        for case let url as URL in entries {
            try cancellation.check()
            let isSymbolicLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            // Nested mailboxes have separate membership.
            if isSymbolicLink || url.pathExtension == "mbox" {
                entries.skipDescendants()
                continue
            }

            switch url.lastPathComponent {
            case "\(record.id).emlx":
                candidates.append(url)
            case "\(record.id).partial.emlx":
                isPartial = true
            default:
                break
            }
        }

        try cancellation.check()
        guard candidates.count == 1, let url = candidates.first else {
            throw isPartial ? Error.partialMessage : Error.messageFileNotFound
        }
        return url
    }

    private func load<T>(
        _ url: URL,
        for record: Message,
        in mailbox: URL,
        version: URL,
        cancellation: Cancellation,
        transform: (Data) throws -> T
    ) throws -> T {
        try cancellation.check()
        guard url.isContained(in: mailbox), url.isContained(in: version) else {
            throw Error.notContained("The message file")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumMessageSize else {
            throw Error.messageFileTooLarge
        }

        try cancellation.check()
        let result = try transform(Data(contentsOf: url))
        try cancellation.check()
        return result
    }
}
