import Foundation

/// The parts of an `.emlx` file: a MIME message and the bytes that follow it.
///
/// An `.emlx` file starts with a line that holds the byte count of the message.
/// Mail stores a property list after the message.
public struct Container: Sendable, Hashable {
    /// The MIME message, which has the length from the first line.
    public let payload: Data
    /// The bytes after the message, without parsing.
    public let trailer: Data

    /// Separates an `.emlx` file into its message and the bytes that follow it.
    /// - Parameter data: The complete file, including its byte-count line.
    /// - Throws: ``EmlxError/malformedMessage(_:)`` if the byte count or message header is invalid,
    ///   or ``EmlxError/partialMessage`` if the file is shorter than its byte count.
    public init(data: Data) throws {
        // Mail pads the byte count with spaces. The MIME payload still starts after
        // the original newline, not after the trimmed count.
        guard let newline = data.prefix(24).firstIndex(of: UInt8(ascii: "\n")),
            let line = String(data: data[..<newline], encoding: .ascii)
        else {
            throw EmlxError.malformedMessage("invalid .emlx byte-count prefix")
        }
        let prefix = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isASCII && $0.isNumber }),
            let length = Int(prefix), length > 0
        else {
            throw EmlxError.malformedMessage("invalid .emlx byte-count prefix")
        }

        let start = newline + 1
        guard length <= data.endIndex - start else {
            throw EmlxError.partialMessage
        }
        let payload = data.subdata(in: start ..< (start + length))
        guard payload.range(of: Data("\r\n\r\n".utf8)) != nil || payload.range(of: Data("\n\n".utf8)) != nil else {
            throw EmlxError.malformedMessage("missing MIME header boundary")
        }
        self.payload = payload
        trailer = data.subdata(in: (start + length) ..< data.endIndex)
    }
}
