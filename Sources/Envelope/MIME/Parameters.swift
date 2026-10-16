import Foundation

extension Budget {
    /// Parses a structured field value into a lowercased value and its parameters.
    ///
    /// Parameter names are lowercased.
    /// The parser ignores empty parameters, text that does not form a parameter,
    /// and parameters that repeat an earlier name.
    /// An unquoted value continues to the next semicolon.
    /// - Parameters:
    ///   - value: The unfolded field value.
    ///   - allowsComments: Whether the field can contain RFC 822 comments.
    ///     RFC 2045 section 3 excludes Content-Disposition.
    /// - Returns: The value, such as `text/plain`, and the parameters by name.
    /// - Throws: `Failure.malformed` if the value is missing.
    func parameters(_ value: String, allowsComments: Bool = true) throws -> (String, [String: String]) {
        let bytes = allowsComments ? try uncomment(value) : Array(value.utf8)
        var index = 0
        func skipBlanks() throws {
            while index < bytes.count, ASCII.isBlank(bytes[index]) {
                try tick(index)
                index += 1
            }
        }
        func skipToSemicolon() throws {
            while index < bytes.count, bytes[index] != ASCII.semicolon {
                try tick(index)
                index += 1
            }
        }
        func token() throws -> String {
            let start = index
            while index < bytes.count, ASCII.isToken(bytes[index]) {
                try tick(index)
                index += 1
            }
            return String(decoding: bytes[start ..< index], as: UTF8.self).lowercased()
        }
        func quotedString() throws -> String {
            index += 1
            var text: [UInt8] = []
            while index < bytes.count, bytes[index] != ASCII.quote {
                try tick(index)
                if bytes[index] == ASCII.backslash, index + 1 < bytes.count { index += 1 }
                text.append(bytes[index])
                index += 1
            }
            // An unterminated quoted string continues to the end of the value.
            index = min(index + 1, bytes.count)
            return String(decoding: text, as: UTF8.self)
        }

        try skipBlanks()
        var kind = try token()
        try skipBlanks()
        if index < bytes.count, bytes[index] == ASCII.slash {
            index += 1
            try skipBlanks()
            kind += "/" + (try token())
        }
        guard !kind.isEmpty else { throw Failure.malformed("missing MIME value") }

        var raw: [String: String] = [:]
        while index < bytes.count {
            try cancel()
            try skipToSemicolon()
            guard index < bytes.count else { break }
            index += 1
            try skipBlanks()
            let name = try token()
            try skipBlanks()
            guard !name.isEmpty, index < bytes.count, bytes[index] == ASCII.equals else { continue }
            index += 1
            try skipBlanks()
            let text: String
            if index < bytes.count, bytes[index] == ASCII.quote {
                text = try quotedString()
            } else {
                let start = index
                try skipToSemicolon()
                var end = index
                while end > start, ASCII.isBlank(bytes[end - 1]) { end -= 1 }
                text = String(decoding: bytes[start ..< end], as: UTF8.self)
            }
            if raw[name] == nil { raw[name] = text }
        }

        var result = raw.filter { !$0.key.contains("*") }
        var extended: [String: [String: String]] = [:]
        for (key, text) in raw {
            if let star = key.firstIndex(of: "*") {
                extended[String(key[..<star]), default: [:]][key] = text
            }
        }
        for (name, fields) in extended {
            try cancel()
            // An invalid extended value leaves the plain value, if any, in place.
            if let text = try extendedValue(name, fields: fields) {
                result[name] = text
            }
        }
        return (kind, result)
    }

    /// Joins and decodes the RFC 2231 extended fields of one parameter.
    /// - Returns: The decoded value, or `nil` if the fields are incomplete, ambiguous, or invalid.
    private func extendedValue(_ name: String, fields: [String: String]) throws -> String? {
        var segments: [Int: (text: String, isEncoded: Bool)] = [:]
        for (key, text) in fields where key != name + "*" {
            var suffix = String(key.dropFirst(name.count + 1))
            let isEncoded = suffix.hasSuffix("*")
            if isEncoded { suffix.removeLast() }
            guard let index = Int(suffix), index >= 0, String(index) == suffix, segments[index] == nil else {
                return nil
            }
            segments[index] = (text, isEncoded)
        }
        if let single = fields[name + "*"] {
            guard segments.isEmpty else { return nil }
            segments[0] = (single, true)
        }

        var joined: [UInt8] = []
        var charset: String?
        for index in 0 ..< segments.count {
            // RFC 2231 section 3 requires consecutive segments that start at zero.
            guard var segment = segments[index] else { return nil }
            if index == 0 && segment.isEncoded {
                let pieces = segment.text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                guard pieces.count == 3, !pieces[0].isEmpty else { return nil }
                charset = String(pieces[0])
                segment.text = String(pieces[2])
            }
            guard segment.isEncoded else {
                joined.append(contentsOf: segment.text.utf8)
                continue
            }
            guard charset != nil else { return nil }
            let source = Array(segment.text.utf8)
            var offset = 0
            while offset < source.count {
                try tick(offset)
                if source[offset] == ASCII.percent {
                    guard offset + 2 < source.count, let high = hex(source[offset + 1]), let low = hex(source[offset + 2]) else {
                        return nil
                    }
                    joined.append(high << 4 | low)
                    offset += 3
                } else {
                    joined.append(source[offset])
                    offset += 1
                }
            }
        }
        do {
            return try string(joined, charset: charset)
        } catch Failure.malformed, Failure.unsupported {
            return nil
        }
    }

    /// Replaces RFC 822 comments outside quoted strings with a space.
    ///
    /// An unterminated comment removes the rest of the value.
    private func uncomment(_ value: String) throws -> [UInt8] {
        var result: [UInt8] = []
        var depth = 0
        var isQuoted = false
        var isEscaped = false
        for (index, byte) in value.utf8.enumerated() {
            try tick(index)
            if isEscaped {
                if depth == 0 { result.append(byte) }
                isEscaped = false
            } else if byte == ASCII.backslash && (isQuoted || depth > 0) {
                // Quoted strings keep the escape for the parameter parser.
                if depth == 0 { result.append(byte) }
                isEscaped = true
            } else if depth > 0 {
                if byte == ASCII.openParenthesis { depth += 1 }
                if byte == ASCII.closeParenthesis { depth -= 1 }
            } else if byte == ASCII.quote {
                isQuoted.toggle()
                result.append(byte)
            } else if byte == ASCII.openParenthesis && !isQuoted {
                depth = 1
                result.append(ASCII.space)
            } else {
                result.append(byte)
            }
        }
        return result
    }
}
