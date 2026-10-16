@_exported import Emlx
@_exported import Mail

extension Mail.Store {
    /// Reads the readable content of a message and checks that the file holds the message.
    ///
    /// The store looks up the current record, closes its connection,
    /// and then reads and parses the message file.
    /// When the index records an RFC 5322 Message-ID,
    /// the parser compares it with the Message-ID in the file.
    /// - Parameter identifier: The identifier of a message from an earlier search.
    /// - Returns: The decoded headers, body, and attachment filenames of the message.
    /// - Throws: A ``Mail/MailError`` if the message or its file cannot be found or read,
    ///   an ``Emlx/EmlxError`` if the file does not contain a readable body or holds another message,
    ///   or `CancellationError`.
    public func content(for identifier: Mail.Message.Identifier) throws -> Emlx.Content {
        try readMessage(identifier) { file in
            try Emlx.Content(emlx: file.data, expectedMessageID: file.message.messageID)
        }
    }
}
