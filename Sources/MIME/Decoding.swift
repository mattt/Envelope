import CoreFoundation
import Foundation

extension Budget {
    /// Converts bytes from a declared charset, or from UTF-8 when no charset is declared.
    func convert(_ bytes: [UInt8], charset: String?) throws -> String {
        try cancel()
        let encoding: String.Encoding
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cf != kCFStringEncodingInvalidId else { throw Failure.unsupported("unknown character encoding") }
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            if encoding == .ascii && bytes.contains(where: { $0 > 127 }) { throw Failure.malformed("invalid ASCII text") }
        } else {
            encoding = .utf8
        }
        // An external representation uses a byte order mark when one is present,
        // and big-endian order otherwise, as RFC 2781 section 4.3 requires.
        let converted = bytes.withUnsafeBufferPointer {
            CFStringCreateWithBytes(
                kCFAllocatorDefault,
                $0.baseAddress,
                $0.count,
                CFStringConvertNSStringEncodingToEncoding(encoding.rawValue),
                true
            )
        }
        try cancel()
        guard let converted else { throw Failure.malformed("text does not match its character encoding") }
        return converted as String
    }

    /// Converts bytes and charges the UTF-8 size of the result to the decoded-output budget.
    func string(_ bytes: [UInt8], charset: String?) throws -> String {
        guard bytes.count <= limits.decoded - decoded else { throw Failure.limit }
        let text = try convert(bytes, charset: charset)
        try output(text.utf8.count)
        try cancel()
        return text
    }

    /// Decodes a body that uses a content transfer encoding.
    func transfer(_ bytes: ArraySlice<UInt8>, encoding: String) throws -> [UInt8] {
        switch encoding {
        case "7bit", "8bit", "binary":
            try cancel()
            guard bytes.count <= limits.decoded - decoded else { throw Failure.limit }
            return Array(bytes)
        case "base64":
            // Lenient decoding does not return nil.
            return try base64(bytes, strict: false) ?? []
        case "quoted-printable":
            return try quotedPrintable(bytes)
        default:
            throw Failure.unsupported("unknown transfer encoding")
        }
    }

    /// Decodes quoted-printable text.
    ///
    /// The decoder follows the guidance for robust implementations in RFC 2045 section 6.7.
    /// It keeps an "=" that does not start an escape,
    /// and it keeps bytes that the encoding does not permit.
    private func quotedPrintable(_ bytes: ArraySlice<UInt8>) throws -> [UInt8] {
        var output: [UInt8] = []
        func append(_ byte: UInt8) throws {
            guard output.count < limits.decoded - decoded else { throw Failure.limit }
            output.append(byte)
        }
        // Returns the offset after a line break, or nil if no line break starts at the offset.
        func lineBreak(at index: Int) -> Int? {
            if index < bytes.endIndex, bytes[index] == ASCII.lineFeed { return index + 1 }
            if index + 1 < bytes.endIndex, bytes[index] == ASCII.carriageReturn, bytes[index + 1] == ASCII.lineFeed {
                return index + 2
            }
            return nil
        }
        // Returns the offset after a run of spaces and tabs.
        func blankEnd(from index: Int) throws -> Int {
            var end = index
            while end < bytes.endIndex, ASCII.isBlank(bytes[end]) {
                try tick(end - bytes.startIndex)
                end += 1
            }
            return end
        }
        var index = bytes.startIndex
        while index < bytes.endIndex {
            try tick(index - bytes.startIndex)
            let byte = bytes[index]
            if ASCII.isBlank(byte) {
                // Rule 3 removes white space at the end of an encoded line.
                let end = try blankEnd(from: index)
                if end == bytes.endIndex || lineBreak(at: end) != nil {
                    index = end
                } else {
                    try bytes[index ..< end].forEach(append)
                    index = end
                }
            } else if byte == ASCII.equals {
                // Rule 5 makes "=" at the end of a line a soft line break.
                // Transport can add white space between the "=" and the line break.
                let end = try blankEnd(from: index + 1)
                if end == bytes.endIndex {
                    index = end
                } else if let next = lineBreak(at: end) {
                    index = next
                } else if index + 2 < bytes.endIndex, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    try append(high << 4 | low)
                    index += 3
                } else {
                    try append(byte)
                    index += 1
                }
            } else {
                try append(byte)
                index += 1
            }
        }
        return output
    }

    /// Decodes the RFC 2047 encoded words in a header value.
    ///
    /// Text that is not a well-formed encoded word stays literal,
    /// as RFC 2047 sections 6.1 and 6.3 require.
    func words(_ value: String) throws -> String {
        let input = Array(value.utf8)
        var result: [UInt8] = []
        var literalStart = 0
        var followsWord = false
        var cursor = 0
        while cursor + 1 < input.count {
            try tick(cursor)
            guard input[cursor] == ASCII.equals, input[cursor + 1] == ASCII.question,
                let word = try encodedWord(in: input, at: cursor)
            else {
                cursor += 1
                continue
            }
            let gap = input[literalStart ..< cursor]
            // White space between adjacent encoded words is not part of the text.
            if !followsWord || !gap.allSatisfy(ASCII.isBlank) {
                result += gap
            }
            result += word.text.utf8
            cursor = word.end
            literalStart = word.end
            followsWord = true
        }
        result += input[literalStart...]
        try output(result.count)
        return String(decoding: result, as: UTF8.self)
    }

    /// Decodes the encoded word that starts at an offset.
    /// - Returns: The text and the offset after the word,
    ///   or `nil` if the bytes do not form a word that can be decoded.
    private func encodedWord(in input: [UInt8], at start: Int) throws -> (text: String, end: Int)? {
        // The syntax is =?charset?encoding?encoded-text?=, without white space.
        var index = start + 2
        func field() -> ArraySlice<UInt8>? {
            let fieldStart = index
            while index < input.count, input[index] != ASCII.question {
                guard ASCII.isVisible(input[index]) else { return nil }
                index += 1
            }
            guard index < input.count else { return nil }
            defer { index += 1 }
            return input[fieldStart ..< index]
        }
        guard let charset = field(), !charset.isEmpty,
            let encoding = field(), encoding.count == 1,
            let text = field(), index < input.count, input[index] == ASCII.equals
        else { return nil }

        let bytes: [UInt8]?
        switch encoding[encoding.startIndex] | 0x20 {
        case UInt8(ascii: "b"): bytes = try base64(text, strict: true)
        case UInt8(ascii: "q"): bytes = qEncoding(text)
        default: return nil
        }
        guard let bytes else { return nil }
        // RFC 2231 section 5 permits a language suffix after the charset.
        let name = String(decoding: charset.prefix { $0 != ASCII.asterisk }, as: UTF8.self)
        do {
            return (try convert(bytes, charset: name), index + 1)
        } catch is Failure {
            // RFC 2047 section 6.2 permits showing a word in an unknown charset as it appears.
            return nil
        }
    }

    /// Decodes RFC 2047 "Q" text, or returns `nil` for an invalid escape.
    private func qEncoding(_ text: ArraySlice<UInt8>) -> [UInt8]? {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case ASCII.underscore:
                bytes.append(ASCII.space)
                index += 1
            case ASCII.equals:
                guard index + 2 < text.endIndex, let high = hex(text[index + 1]), let low = hex(text[index + 2]) else {
                    return nil
                }
                bytes.append(high << 4 | low)
                index += 3
            case let byte:
                bytes.append(byte)
                index += 1
            }
        }
        return bytes
    }

    /// Decodes base64 text.
    ///
    /// Lenient decoding skips bytes outside the alphabet, as RFC 2045 section 6.8 requires,
    /// and decodes a final group that has no padding.
    /// Strict decoding returns `nil` for those bytes and for a group of one character.
    func base64(_ text: ArraySlice<UInt8>, strict: Bool) throws -> [UInt8]? {
        var output: [UInt8] = []
        var group: UInt32 = 0
        var count = 0
        func append(_ byte: UInt32) throws {
            guard output.count < limits.decoded - decoded else { throw Failure.limit }
            output.append(UInt8(truncatingIfNeeded: byte))
        }
        // Padding or the end of the text completes a group of two or three characters.
        func finishGroup() throws -> Bool {
            switch count {
            case 2: try append(group >> 4)
            case 3:
                try append(group >> 10)
                try append(group >> 2)
            case 1: if strict { return false }
            default: break
            }
            group = 0
            count = 0
            return true
        }
        for (offset, byte) in text.enumerated() {
            try tick(offset)
            let value = base64Values[Int(byte)]
            if value < 64 {
                group = group << 6 | UInt32(value)
                count += 1
                if count == 4 {
                    try append(group >> 16)
                    try append(group >> 8)
                    try append(group)
                    group = 0
                    count = 0
                }
            } else if byte == ASCII.equals {
                guard try finishGroup() else { return nil }
            } else if strict {
                return nil
            }
        }
        guard try finishGroup() else { return nil }
        return output
    }
}

/// The value of each base64 alphabet byte, or 255 for other bytes.
private let base64Values: [UInt8] = {
    var values = [UInt8](repeating: 255, count: 256)
    for (value, byte) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
        values[Int(byte)] = UInt8(value)
    }
    return values
}()

func hex(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48 ... 57: return byte - 48
    case 65 ... 70: return byte - 55
    case 97 ... 102: return byte - 87
    default: return nil
    }
}
