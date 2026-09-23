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
        let converted = bytes.withUnsafeBufferPointer {
            CFStringCreateWithBytes(
                kCFAllocatorDefault,
                $0.baseAddress,
                $0.count,
                CFStringConvertNSStringEncodingToEncoding(encoding.rawValue),
                false
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

    func transfer(_ bytes: ArraySlice<UInt8>, encoding: String, validateOnly: Bool = false) throws -> [UInt8] {
        var output: [UInt8] = []
        func append(_ byte: UInt8) throws {
            if validateOnly { return }
            guard output.count < limits.decoded - decoded else { throw Failure.limit }
            output.append(byte)
        }
        switch encoding {
        case "7bit", "8bit", "binary":
            for (i, byte) in bytes.enumerated() { try tick(i); try append(byte) }
        case "base64":
            var quartet: [UInt8] = []
            var ended = false
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
            for (i, byte) in bytes.enumerated() {
                try tick(i)
                if [9, 10, 13, 32].contains(byte) { continue }
                guard !ended, byte == 61 || alphabet.contains(byte) else { throw Failure.malformed("invalid base64") }
                quartet.append(byte)
                if quartet.count == 4 {
                    guard let a = alphabet.firstIndex(of: quartet[0]), let b = alphabet.firstIndex(of: quartet[1]) else {
                        throw Failure.malformed("invalid base64 padding")
                    }
                    let c = alphabet.firstIndex(of: quartet[2])
                    let d = alphabet.firstIndex(of: quartet[3])
                    if quartet[2] == 61 {
                        guard quartet[3] == 61, b & 15 == 0 else { throw Failure.malformed("invalid base64 padding") }
                    } else if quartet[3] == 61 {
                        guard let c, c & 3 == 0 else { throw Failure.malformed("invalid base64 padding") }
                    }
                    try append(UInt8((a << 2) | (b >> 4)))
                    if let c { try append(UInt8(((b & 15) << 4) | (c >> 2))) }
                    if let c, let d { try append(UInt8(((c & 3) << 6) | d)) }
                    ended = quartet[3] == 61
                    quartet.removeAll(keepingCapacity: true)
                }
            }
            guard quartet.isEmpty else { throw Failure.malformed("incomplete base64") }
        case "quoted-printable":
            var i = bytes.startIndex
            while i < bytes.endIndex {
                try tick(i - bytes.startIndex)
                let b = bytes[i]
                if b == 61 {
                    guard i + 1 < bytes.endIndex else { throw Failure.malformed("incomplete quoted-printable") }
                    if bytes[i + 1] == 10 { i += 2; continue }
                    if i + 2 < bytes.endIndex, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                    guard i + 2 < bytes.endIndex, let a = hex(bytes[i + 1]), let b = hex(bytes[i + 2]) else {
                        throw Failure.malformed("invalid quoted-printable")
                    }
                    try append(a * 16 + b)
                    i += 3
                } else {
                    guard b == 9 || b == 10 || b == 13 || (32 ... 126).contains(b) else { throw Failure.malformed("invalid quoted-printable byte") }
                    if b == 13 { guard i + 1 < bytes.endIndex, bytes[i + 1] == 10 else { throw Failure.malformed("bare carriage return") } }
                    // RFC 2045 requires removal of unencoded trailing whitespace.
                    if b == 9 || b == 32 {
                        var end = i
                        while end < bytes.endIndex && [9, 32].contains(bytes[end]) { try tick(end - bytes.startIndex); end += 1 }
                        if end == bytes.endIndex || [10, 13].contains(bytes[end]) { i = end; continue }
                        while i < end { try tick(i - bytes.startIndex); try append(bytes[i]); i += 1 }
                    } else {
                        try append(b); i += 1
                    }
                }
            }
        default: throw Failure.unsupported("unknown transfer encoding")
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
