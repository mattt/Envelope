import Foundation

/// The MIME payload and trailing property-list bytes of an `.emlx` file.
public struct Container: Sendable {
    /// The MIME bytes counted by the first line.
    public let payload: Data
    /// The remaining bytes, preserved without parsing the property list.
    public let trailer: Data

    /// Splits an `.emlx` file at its byte-count boundary.
    /// - Parameter data: The complete file, including its byte-count line.
    /// - Throws: `Error.malformedMessage` or `Error.partialMessage`.
    public init(data: Data) throws {
        // Mail pads the byte count with spaces. The MIME payload still starts after
        // the original newline, not after the trimmed count.
        guard let newline = data.prefix(24).firstIndex(of: UInt8(ascii: "\n")),
            let line = String(data: data[..<newline], encoding: .ascii)
        else {
            throw Error.malformedMessage("invalid .emlx byte-count prefix")
        }
        let prefix = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isASCII && $0.isNumber }),
            let length = Int(prefix), length > 0
        else {
            throw Error.malformedMessage("invalid .emlx byte-count prefix")
        }

        let start = newline + 1
        guard length <= data.endIndex - start else {
            throw Error.partialMessage
        }
        let payload = data.subdata(in: start ..< (start + length))
        guard payload.range(of: Data("\r\n\r\n".utf8)) != nil || payload.range(of: Data("\n\n".utf8)) != nil else {
            throw Error.malformedMessage("missing MIME header boundary")
        }
        self.payload = payload
        trailer = data.subdata(in: (start + length) ..< data.endIndex)
    }

}
