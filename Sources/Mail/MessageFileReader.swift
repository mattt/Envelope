import Foundation
import os

/// The largest message file that the reader opens.
private let maximumFileSize = 32 * 1024 * 1024

/// Finds and reads the `.emlx` files of messages in the local Mail index.
///
/// The reader caches file locations as hints.
/// Every read checks that the file is inside the mailbox folder,
/// and the parse closure checks that the file holds the expected message.
public final class MessageFileReader: Sendable {
    private let cache = OSAllocatedUnfairLock(initialState: [Message.Identifier: URL]())

    /// Creates a reader with an empty location cache.
    public init() {}

    /// Reads the file of a message and parses its data.
    ///
    /// If the parse closure throws for a cached location,
    /// the reader finds the file again and calls the closure again.
    /// - Parameters:
    ///   - message: The message to read.
    ///   - version: The store directory from ``Database/versionURL``.
    ///   - cancellation: A signal that stops the read.
    ///   - parse: A closure that parses the file data and checks that it holds the message.
    /// - Returns: The value that `parse` returns.
    /// - Throws: ``MailError/storeChanged`` if `version` is not the message's store,
    ///   another ``MailError`` if the file cannot be found or read,
    ///   the error that `parse` throws, or `CancellationError`.
    public func read<T>(
        _ message: Message,
        version: URL,
        cancellation: Cancellation = Cancellation(),
        parse: (Data) throws -> T
    ) throws -> T {
        try cancellation.check()
        // A row identifier names a different message in another store.
        guard version.resolvingSymlinksInPath().lastPathComponent == message.id.store else {
            throw MailError.storeChanged
        }
        guard let mailboxURL = message.mailboxURL else {
            throw MailError.unsupportedMailbox
        }
        let mailbox = try Self.mailboxDirectory(for: mailboxURL, in: version)

        if let cached = cache.withLock({ $0[message.id] }) {
            do {
                return try load(cached, in: mailbox, version: version, cancellation: cancellation, parse: parse)
            } catch let error as CancellationError {
                throw error
            } catch {
                cache.withLock { _ = $0.removeValue(forKey: message.id) }
            }
        }

        let url = try locate(message, in: mailbox, cancellation: cancellation)
        let content = try load(url, in: mailbox, version: version, cancellation: cancellation, parse: parse)
        cache.withLock {
            if $0.count >= 1000 { $0.removeAll() }
            $0[message.id] = url
        }
        return content
    }

    /// Returns the `.mbox` folder in a store for the URL of a mailbox.
    /// - Parameters:
    ///   - mailboxURL: The URL string that Mail records for the mailbox.
    ///   - version: The store directory.
    /// - Throws: ``MailError/unsupportedMailbox`` or ``MailError/notContained(_:)``.
    static func mailboxDirectory(for mailboxURL: String, in version: URL) throws -> URL {
        guard let url = URL(string: mailboxURL) else {
            throw MailError.unsupportedMailbox
        }

        let directory: URL
        if url.isFileURL {
            directory = url
        } else if let host = url.host, UUID(uuidString: host) != nil {
            // Modern stores use the account UUID as the mailbox URL host.
            directory = try url.path.split(separator: "/").reduce(version.appendingPathComponent(host)) {
                guard $1 != ".", $1 != ".." else { throw MailError.unsupportedMailbox }
                return $0.appendingPathComponent("\($1).mbox")
            }
        } else {
            throw MailError.unsupportedMailbox
        }

        guard directory.pathExtension == "mbox" else {
            throw MailError.unsupportedMailbox
        }
        guard directory.isContained(in: version) else {
            throw MailError.notContained(directory)
        }
        return directory.resolvingSymlinksInPath()
    }

    /// Searches a mailbox for the one file that holds a message.
    private func locate(_ message: Message, in mailbox: URL, cancellation: Cancellation) throws -> URL {
        try cancellation.check()
        guard
            let entries = FileManager.default.enumerator(
                at: mailbox,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw MailError.messageFileNotFound
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
            case "\(message.id.rowID).emlx":
                candidates.append(url)
            case "\(message.id.rowID).partial.emlx":
                isPartial = true
            default:
                break
            }
        }

        try cancellation.check()
        guard candidates.count == 1, let url = candidates.first else {
            // A partial file explains a missing complete file, but not duplicate files.
            throw candidates.isEmpty && isPartial ? MailError.partialMessage : MailError.messageFileNotFound
        }
        return url
    }

    /// Checks a message file and parses its data.
    private func load<T>(
        _ url: URL,
        in mailbox: URL,
        version: URL,
        cancellation: Cancellation,
        parse: (Data) throws -> T
    ) throws -> T {
        try cancellation.check()
        guard url.isContained(in: mailbox), url.isContained(in: version) else {
            throw MailError.notContained(url)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw MailError.messageFileNotRegular
        }
        guard let size = values.fileSize, size <= maximumFileSize else {
            throw MailError.messageFileTooLarge
        }

        try cancellation.check()
        let result = try parse(Data(contentsOf: url))
        try cancellation.check()
        return result
    }
}
