import Foundation

// Identifiers and cursors encode as their string forms,
// so that they appear in JSON as the same strings that `description` returns.

extension Mailbox.ID: Codable {
    /// Creates an identifier from its string form in a decoder.
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError.dataCorrupted` if the string is not an identifier.
    public init(from decoder: any Decoder) throws {
        self = try decodeString(from: decoder, as: Self.self, describedAs: "mailbox identifier")
    }

    /// Encodes the identifier as its string form.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension Message.Identifier: Codable {
    /// Creates an identifier from its string form in a decoder.
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError.dataCorrupted` if the string is not an identifier.
    public init(from decoder: any Decoder) throws {
        self = try decodeString(from: decoder, as: Self.self, describedAs: "message identifier")
    }

    /// Encodes the identifier as its string form.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension Message.FetchRequest.Cursor: Codable {
    /// Creates a cursor from its string form in a decoder.
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError.dataCorrupted` if the string is not a cursor.
    public init(from decoder: any Decoder) throws {
        self = try decodeString(from: decoder, as: Self.self, describedAs: "cursor")
    }

    /// Encodes the cursor as its string form.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Decodes a value from a single string.
private func decodeString<Value: LosslessStringConvertible>(
    from decoder: any Decoder,
    as type: Value.Type,
    describedAs name: String
) throws -> Value {
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    guard let value = Value(string) else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "\"\(string)\" is not a valid \(name).")
    }
    return value
}
