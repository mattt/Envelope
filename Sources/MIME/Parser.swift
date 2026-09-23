import Foundation

package enum Parser {
    package static func parse(
        _ data: Data,
        limits: Limits = Limits(),
        checkCancellation: () throws -> Void = {}
    ) throws -> Part {
        try checkCancellation()
        return try withoutActuallyEscaping(checkCancellation) { cancel in
            let reader = Reader(bytes: Array(data), budget: Budget(limits, cancel))
            return try reader.entity(0 ..< data.count, depth: 0, defaultType: "text/plain")
        }
    }
}

private struct Reader {
    let bytes: [UInt8]
    let budget: Budget

    func line(_ start: Int, end: Int, maximum: Int = Int.max) throws -> (Range<Int>, Int) {
        var i = start
        while i < end && bytes[i] != 10 {
            guard i - start < maximum else { throw Failure.limit }
            try budget.tick(i - start); i += 1
        }
        let contentEnd = i > start && bytes[i - 1] == 13 ? i - 1 : i
        return (start ..< contentEnd, i < end ? i + 1 : i)
    }

    func entity(_ range: Range<Int>, depth: Int, defaultType: String) throws -> Part {
        try budget.cancel()
        guard depth <= budget.limits.depth, budget.entities < budget.limits.entities else { throw Failure.limit }
        budget.entities += 1
        var position = range.lowerBound
        var raw: [(String, String)] = []
        var separated = false
        while position < range.upperBound {
            let (lineRange, next) = try line(
                position,
                end: range.upperBound,
                maximum: min(budget.limits.entityHeaders - (position - range.lowerBound), budget.limits.totalHeaders - budget.headers)
            )
            let count = next - position
            guard next - range.lowerBound <= budget.limits.entityHeaders,
                count <= budget.limits.totalHeaders - budget.headers
            else { throw Failure.limit }
            budget.headers += count
            position = next
            if lineRange.isEmpty { separated = true; break }
            guard let text = String(bytes: bytes[lineRange], encoding: .utf8), !text.contains("\r"), !text.contains("\0") else {
                throw Failure.malformed("invalid header text")
            }
            if text.first == " " || text.first == "\t" {
                guard !raw.isEmpty else { throw Failure.malformed("orphan header continuation") }
                raw[raw.count - 1].1 += text
            } else {
                guard let colon = text.firstIndex(of: ":") else { throw Failure.malformed("missing header colon") }
                let name = String(text[..<colon])
                guard !name.isEmpty, name.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && $0 != 58 }) else { throw Failure.malformed("invalid header name") }
                raw.append((name, String(text[text.index(after: colon)...])))
            }
        }
        guard separated, depth != 0 || !raw.isEmpty else { throw Failure.malformed("missing MIME headers or separator") }
        let structural = Set(["content-type", "content-disposition", "content-transfer-encoding", "content-id", "mime-version"])
        var fields: [String: String] = [:]
        var headers: [Header] = []
        for (name, folded) in raw {
            // Trim after unfolding, so a value that starts on a continuation line has no leading space.
            let value = folded.trimmingCharacters(in: .whitespaces)
            let key = name.lowercased()
            if structural.contains(key) && fields[key] != nil { throw Failure.malformed("duplicate structural header") }
            fields[key] = value
            headers.append(Header(name: name, value: try budget.words(value)))
        }
        let (type, parameters) = try budget.parameters(fields["content-type"] ?? defaultType)
        guard type.split(separator: "/").count == 2 else { throw Failure.malformed("invalid media type") }
        let (disposition, dispositionParameters) = try budget.parameters(fields["content-disposition"] ?? "inline")
        let (encoding, encodingParameters) = try budget.parameters(fields["content-transfer-encoding"] ?? "7bit")
        guard encodingParameters.isEmpty else { throw Failure.malformed("transfer encoding has parameters") }
        if ["multipart/encrypted", "application/pkcs7-mime", "application/x-pkcs7-mime", "application/pgp-encrypted"].contains(type) {
            throw Failure.encrypted
        }
        if type == "message/partial" { throw Failure.partial }
        let bodyRange = position ..< range.upperBound
        var children: [Part] = []
        var text: String?
        if type.hasPrefix("multipart/") {
            guard ["7bit", "8bit", "binary"].contains(encoding) else { throw Failure.malformed("encoded multipart") }
            guard let boundary = parameters["boundary"], !boundary.isEmpty, boundary.utf8.count <= 70,
                boundary.last != " ",
                boundary.utf8.allSatisfy({
                    (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || Array("'()+_,-./:=? ".utf8).contains($0)
                })
            else { throw Failure.malformed("invalid multipart boundary") }
            let marker = Array(("--" + boundary).utf8)
            var childStart: Int?
            var closed = false
            while position < range.upperBound {
                let lineStart = position
                let (lineRange, next) = try line(position, end: range.upperBound)
                position = next
                var end = lineRange.upperBound
                while end > lineRange.lowerBound && [9, 32].contains(bytes[end - 1]) {
                    try budget.tick(lineRange.upperBound - end); end -= 1
                }
                let content = bytes[lineRange.lowerBound ..< end]
                let closing = content.count == marker.count + 2 && content.starts(with: marker) && content.suffix(2).elementsEqual([45, 45])
                let opening = content.elementsEqual(marker)
                if !closing && !opening { continue }
                if let start = childStart {
                    var childEnd = lineStart
                    if childEnd > start && bytes[childEnd - 1] == 10 { childEnd -= 1; if childEnd > start && bytes[childEnd - 1] == 13 { childEnd -= 1 } }
                    children.append(try entity(start ..< childEnd, depth: depth + 1, defaultType: type == "multipart/digest" ? "message/rfc822" : "text/plain"))
                }
                if closing { closed = true; break }
                childStart = next
            }
            guard closed, !children.isEmpty else { throw Failure.partial }
        } else if type == "message/rfc822" {
            guard ["7bit", "8bit", "binary"].contains(encoding) else { throw Failure.malformed("encoded encapsulated message") }
            children = [try entity(bodyRange, depth: depth + 1, defaultType: "text/plain")]
        } else if type.hasPrefix("text/") && disposition != "attachment" {
            let decoded = try budget.transfer(bytes[bodyRange], encoding: encoding)
            text = try budget.string(decoded, charset: parameters["charset"])
        } else {
            _ = try budget.transfer(bytes[bodyRange], encoding: encoding, validateOnly: true)
        }
        return Part(
            headers: headers,
            mediaType: type,
            parameters: parameters,
            attachment: disposition == "attachment",
            filename: dispositionParameters["filename"] ?? parameters["name"],
            bodyRange: bodyRange,
            text: text,
            children: children
        )
    }
}
