import Foundation

extension Budget {
    private func uncomment(_ value: String) throws -> [UInt8] {
        var result: [UInt8] = []
        var depth = 0
        var quoted = false
        var escaped = false
        for (index, byte) in value.utf8.enumerated() {
            try tick(index)
            if escaped {
                if depth == 0 { result.append(byte) }
                escaped = false
            } else if byte == 92 && (quoted || depth > 0) {
                if depth == 0 { result.append(byte) }
                escaped = true
            } else if depth > 0 {
                if byte == 40 { depth += 1 }
                if byte == 41 { depth -= 1 }
            } else if byte == 34 {
                quoted.toggle(); result.append(byte)
            } else if byte == 40 && !quoted {
                depth = 1; result.append(32)
            } else {
                result.append(byte)
            }
        }
        guard depth == 0, !escaped, !quoted else { throw Failure.malformed("incomplete MIME comment or quote") }
        return result
    }

    func parameters(_ value: String) throws -> (String, [String: String]) {
        let bytes = try uncomment(value)
        var i = 0
        func space() throws { while i < bytes.count && [9, 32].contains(bytes[i]) { try tick(i); i += 1 } }
        func token() throws -> String {
            let start = i
            while i < bytes.count && bytes[i] > 32 && bytes[i] < 127 && !Array("()<>@,;:\\\"/[]?=".utf8).contains(bytes[i]) { try tick(i); i += 1 }
            return String(decoding: bytes[start ..< i], as: UTF8.self)
        }
        try space()
        var kind = try token().lowercased()
        try space()
        if i < bytes.count && bytes[i] == 47 { i += 1; try space(); kind += "/" + (try token().lowercased()) }
        guard !kind.isEmpty else { throw Failure.malformed("missing MIME value") }
        var raw: [String: String] = [:]
        try space()
        while i < bytes.count {
            try cancel()
            guard bytes[i] == 59 else { throw Failure.malformed("invalid MIME parameter") }
            i += 1; try space()
            let name = try token().lowercased()
            try space()
            guard !name.isEmpty, i < bytes.count, bytes[i] == 61, raw[name] == nil else { throw Failure.malformed("invalid or duplicate MIME parameter") }
            i += 1; try space()
            var data: [UInt8] = []
            if i < bytes.count && bytes[i] == 34 {
                i += 1
                while i < bytes.count && bytes[i] != 34 {
                    try tick(i)
                    if bytes[i] == 92 { i += 1 }
                    guard i < bytes.count else { throw Failure.malformed("incomplete quoted parameter") }
                    data.append(bytes[i]); i += 1
                }
                guard i < bytes.count else { throw Failure.malformed("incomplete quoted parameter") }
                i += 1
            } else {
                data = Array(try token().utf8)
            }
            guard let text = String(bytes: data, encoding: .utf8) else { throw Failure.malformed("invalid parameter text") }
            raw[name] = text
            try space()
        }
        var result = raw.filter { !$0.key.contains("*") }
        var extended: [String: [String: String]] = [:]
        for (key, text) in raw {
            try cancel()
            if let star = key.firstIndex(of: "*") {
                extended[String(key[..<star]), default: [:]][key] = text
            }
        }
        for (name, fields) in extended {
            var segments: [Int: (String, Bool)] = [:]
            for (key, text) in fields where key != name + "*" {
                var suffix = String(key.dropFirst(name.count + 1))
                let encoded = suffix.hasSuffix("*")
                if encoded { suffix.removeLast() }
                guard let index = Int(suffix), index >= 0, String(index) == suffix, segments[index] == nil else {
                    throw Failure.malformed("invalid parameter continuation")
                }
                segments[index] = (text, encoded)
            }
            guard raw[name + "*"] == nil || segments.isEmpty else { throw Failure.malformed("ambiguous extended parameter") }
            if let single = raw[name + "*"] { segments[0] = (single, true) }
            var joined: [UInt8] = []
            var charset: String?
            for index in 0 ..< segments.count {
                guard var segment = segments[index] else { throw Failure.malformed("parameter continuation gap") }
                if index == 0 && segment.1 {
                    let pieces = segment.0.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    guard pieces.count == 3, !pieces[0].isEmpty else { throw Failure.malformed("invalid extended parameter") }
                    charset = String(pieces[0]); segment.0 = String(pieces[2])
                }
                if segment.1 {
                    guard charset != nil else { throw Failure.malformed("missing parameter charset") }
                    let source = Array(segment.0.utf8)
                    var j = 0
                    while j < source.count {
                        try tick(j)
                        if source[j] == 37 {
                            guard j + 2 < source.count, let a = hex(source[j + 1]), let b = hex(source[j + 2]) else {
                                throw Failure.malformed("invalid parameter escape")
                            }
                            joined.append(a * 16 + b); j += 3
                        } else {
                            joined.append(source[j]); j += 1
                        }
                    }
                } else {
                    joined.append(contentsOf: segment.0.utf8)
                }
            }
            result[name] = try string(joined, charset: charset)
        }
        return (kind, result)
    }
}
