import CoreFoundation
import Foundation

extension Budget {
    func string(_ bytes: [UInt8], charset: String?) throws -> String {
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
        guard bytes.count <= limits.decoded - decoded else { throw Failure.limit }
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
        var size = 0
        CFStringGetBytes(
            converted,
            CFRange(location: 0, length: CFStringGetLength(converted)),
            CFStringBuiltInEncodings.UTF8.rawValue,
            0,
            false,
            nil,
            0,
            &size
        )
        try cancel()
        try output(size)
        return converted as String
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

    func words(_ value: String) throws -> String {
        let input = Array(value.utf8)
        var result = ""
        var previousWord = false
        var cursor = 0
        var literalStart = 0
        while cursor + 1 < input.count {
            try tick(cursor)
            guard input[cursor] == 61 && input[cursor + 1] == 63 else { cursor += 1; continue }
            let prefix = input[literalStart ..< cursor]
            var whitespace = true
            for (index, byte) in prefix.enumerated() {
                try tick(index)
                if byte != 32 && byte != 9 { whitespace = false }
            }
            if !previousWord || !whitespace {
                try output(prefix.count)
                result += String(decoding: prefix, as: UTF8.self)
            }
            var end = cursor + 2
            while end + 1 < input.count && !(input[end] == 63 && input[end + 1] == 61) {
                guard end - cursor < 73 else { throw Failure.malformed("encoded word exceeds 75 bytes") }
                end += 1
            }
            guard end + 1 < input.count, end + 2 - cursor <= 75 else { throw Failure.malformed("incomplete encoded word") }
            let wordSource = String(decoding: input[(cursor + 2) ..< end], as: UTF8.self)
            let fields = wordSource.split(separator: "?", omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw Failure.malformed("invalid encoded word") }
            let mode = fields[1].lowercased()
            guard mode == "b" || mode == "q" else { throw Failure.malformed("invalid encoded word encoding") }
            let source = mode == "q" ? fields[2].replacingOccurrences(of: "_", with: "=20") : String(fields[2])
            let bytes = try transfer(Array(source.utf8)[...], encoding: mode == "b" ? "base64" : "quoted-printable")
            result += try string(bytes, charset: String(fields[0]))
            cursor = end + 2
            literalStart = cursor
            previousWord = true
        }
        let rest = input[literalStart...]
        try output(rest.count)
        result += String(decoding: rest, as: UTF8.self)
        return result
    }
}

func hex(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48 ... 57: return byte - 48
    case 65 ... 70: return byte - 55
    case 97 ... 102: return byte - 87
    default: return nil
    }
}
