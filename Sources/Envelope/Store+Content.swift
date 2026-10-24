extension Store {
    /// Reads the readable content of a message and checks that the file holds the message.
    ///
    /// The store looks up the current record, closes its connection,
    /// and then reads and parses the message file.
    /// When the mailbox has no complete `.emlx` file for the message,
    /// the store reads its `.partial.emlx` file,
    /// and ``Content/attachments`` reports the parts that Mail stores separately.
    /// When the index records an RFC 5322 Message-ID,
    /// the parser compares it with the Message-ID in the file.
    /// - Parameter identifier: The identifier of a message from an earlier search.
    /// - Returns: The decoded headers, body, and attachments of the message.
    /// - Throws: A ``MailError`` if the message or its file cannot be found or read,
    ///   an ``EmlxError`` if the file does not contain a readable body or holds another message,
    ///   or `CancellationError`.
    public func content(for identifier: Message.Identifier) throws -> Content {
        try readMessage(identifier) { file in
            try Content(emlx: file.data, expectedMessageID: file.message.messageID)
        }
    }
}
