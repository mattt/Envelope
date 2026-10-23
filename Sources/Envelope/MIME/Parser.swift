import Foundation

/// Parses MIME messages.
enum Parser {
    /// Parses a message and its nested entities.
    ///
    /// A failure in the body of an entity, such as an unknown charset,
    /// is recorded in the entity's `failure`.
    /// A nested entity that the parser cannot read becomes a placeholder part,
    /// so the rest of the message stays readable.
    /// - Parameters:
    ///   - data: The message bytes.
    ///   - limits: The resource limits for the parse.
    ///   - checkCancellation: A closure that throws to stop the parse.
    /// - Returns: The root entity.
    /// - Throws: `Failure.limit` if the message exceeds a limit,
    ///   another `Failure` if the root header block or multipart structure is malformed,
    ///   or the error from `checkCancellation`.
    static func parse(
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

/// Reads the entities in the bytes of one message.
private struct Reader {
    /// The transfer encodings that a multipart or message entity can use.
    static let identityEncodings: Set = ["7bit", "8bit", "binary"]
    /// The header fields that cannot repeat, because a repeat makes the structure ambiguous.
    static let structuralFields: Set = ["content-type", "content-disposition", "content-transfer-encoding"]

    let bytes: [UInt8]
    let budget: Budget

    /// Finds the line that starts at an offset.
    /// - Returns: The range of the line without its line break, and the offset of the next line.
    func line(_ start: Int, end: Int, maximum: Int = .max) throws -> (content: Range<Int>, next: Int) {
        var index = start
        while index < end && bytes[index] != ASCII.lineFeed {
            guard index - start < maximum else { throw Failure.limit }
            try budget.tick(index - start)
            index += 1
        }
        let contentEnd = index > start && bytes[index - 1] == ASCII.carriageReturn ? index - 1 : index
        return (start ..< contentEnd, index < end ? index + 1 : index)
    }

    /// Parses a nested entity, or returns a placeholder if the entity cannot be read.
    func child(_ range: Range<Int>, depth: Int, defaultType: String) throws -> Part {
        do {
            return try entity(range, depth: depth, defaultType: defaultType)
        } catch let failure as Failure where failure != .limit {
            return Part(failure: failure, bodyRange: range)
        }
    }

    /// Parses the entity in a byte range.
    func entity(_ range: Range<Int>, depth: Int, defaultType: String) throws -> Part {
        try budget.cancel()
        guard depth <= budget.limits.depth, budget.entities < budget.limits.entities else { throw Failure.limit }
        budget.entities += 1
        let (headers, fields, bodyStart) = try headerBlock(range, depth: depth)

        let (type, parameters) = try budget.parameters(fields["content-type"] ?? defaultType)
        guard type.split(separator: "/").count == 2 else { throw Failure.malformed("invalid media type") }
        let (disposition, dispositionParameters) = try budget.parameters(
            fields["content-disposition"] ?? "inline",
            allowsComments: false
        )
        let (encoding, encodingParameters) = try budget.parameters(fields["content-transfer-encoding"] ?? "7bit")
        guard encodingParameters.isEmpty else { throw Failure.malformed("transfer encoding has parameters") }

        let isAttachment = disposition == "attachment"
        let bodyRange = bodyStart ..< range.upperBound
        // Mail leaves a part's body empty when it stores the content in a separate file,
        // and records the original length in X-Apple-Content-Length.
        let isStoredSeparately =
            headers.contains { $0.name.lowercased() == "x-apple-content-length" }
            && bytes[bodyRange].allSatisfy { ASCII.isBlank($0) || $0 == ASCII.carriageReturn || $0 == ASCII.lineFeed }
        var children: [Part] = []
        var text: String?
        var failure: Failure?
        if !isAttachment && Self.isEncrypted(type, parameters: parameters) {
            failure = .encrypted
        } else if !isAttachment && type == "message/partial" {
            failure = .partial
        } else if isStoredSeparately {
            failure = .partial
        } else if type.hasPrefix("multipart/") {
            children = try multipart(bodyRange, type: type, parameters: parameters, encoding: encoding, depth: depth)
        } else if type == "message/rfc822" {
            guard Self.identityEncodings.contains(encoding) else { throw Failure.malformed("encoded encapsulated message") }
            children = [try child(bodyRange, depth: depth + 1, defaultType: "text/plain")]
        } else if type.hasPrefix("text/") && !isAttachment {
            do {
                let decoded = try budget.transfer(bytes[bodyRange], encoding: encoding)
                text = try budget.string(decoded, charset: parameters["charset"])
            } catch let error as Failure where error != .limit {
                failure = error
            }
        }
        return Part(
            headers: headers,
            mediaType: type,
            parameters: parameters,
            isAttachment: isAttachment,
            filename: dispositionParameters["filename"] ?? parameters["name"],
            bodyRange: bodyRange,
            text: text,
            children: children,
            isStoredSeparately: isStoredSeparately,
            failure: failure
        )
    }

    /// Parses the header block at the start of an entity.
    /// - Returns: The decoded headers, the unfolded structural fields by lowercased name,
    ///   and the offset of the body.
    private func headerBlock(
        _ range: Range<Int>,
        depth: Int
    ) throws -> (headers: [Header], fields: [String: String], bodyStart: Int) {
        var position = range.lowerBound
        var raw: [(name: String, value: String)] = []
        var isSeparated = false
        while position < range.upperBound {
            let (content, next) = try line(
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
            if content.isEmpty {
                isSeparated = true
                break
            }
            // Invalid UTF-8 becomes replacement characters, because no legacy charset is guessed.
            let text = String(decoding: bytes[content], as: UTF8.self)
            guard !text.contains("\r"), !text.contains("\0") else { throw Failure.malformed("invalid header text") }
            if text.first == " " || text.first == "\t" {
                guard !raw.isEmpty else { throw Failure.malformed("orphan header continuation") }
                raw[raw.count - 1].value += text
            } else {
                guard let colon = text.firstIndex(of: ":") else { throw Failure.malformed("missing header colon") }
                let name = String(text[..<colon])
                guard !name.isEmpty, name.utf8.allSatisfy(ASCII.isVisible) else { throw Failure.malformed("invalid header name") }
                raw.append((name, String(text[text.index(after: colon)...])))
            }
        }
        // A nested entity can omit its header block, but the root message needs one.
        guard depth > 0 || (isSeparated && !raw.isEmpty) else { throw Failure.malformed("missing MIME headers or separator") }

        var fields: [String: String] = [:]
        var headers: [Header] = []
        for (name, folded) in raw {
            // Trim after unfolding, so a value that starts on a continuation line has no leading space.
            let value = folded.trimmingCharacters(in: .whitespaces)
            let key = name.lowercased()
            if Self.structuralFields.contains(key) {
                guard fields[key] == nil else { throw Failure.malformed("duplicate structural header") }
                fields[key] = value
            }
            headers.append(Header(name: name, value: try budget.words(value)))
        }
        return (headers, fields, position)
    }

    /// Parses the body parts of a multipart entity.
    private func multipart(
        _ range: Range<Int>,
        type: String,
        parameters: [String: String],
        encoding: String,
        depth: Int
    ) throws -> [Part] {
        guard Self.identityEncodings.contains(encoding) else { throw Failure.malformed("encoded multipart") }
        guard let boundary = parameters["boundary"], !boundary.isEmpty else {
            throw Failure.malformed("missing multipart boundary")
        }
        let delimiter = Array(("--" + boundary).utf8)
        let defaultType = type == "multipart/digest" ? "message/rfc822" : "text/plain"
        var children: [Part] = []
        var childStart: Int?
        var position = range.lowerBound
        while position < range.upperBound {
            let lineStart = position
            let (content, next) = try line(position, end: range.upperBound)
            position = next
            // Transport padding can follow a delimiter.
            var end = content.upperBound
            while end > content.lowerBound && ASCII.isBlank(bytes[end - 1]) {
                try budget.tick(content.upperBound - end)
                end -= 1
            }
            let candidate = bytes[content.lowerBound ..< end]
            let isClosing =
                candidate.count == delimiter.count + 2 && candidate.starts(with: delimiter)
                && candidate.suffix(2).allSatisfy { $0 == ASCII.hyphen }
            guard isClosing || candidate.elementsEqual(delimiter) else { continue }
            if let start = childStart {
                // The line break before a delimiter belongs to the delimiter.
                var childEnd = lineStart
                if childEnd > start && bytes[childEnd - 1] == ASCII.lineFeed {
                    childEnd -= 1
                    if childEnd > start && bytes[childEnd - 1] == ASCII.carriageReturn { childEnd -= 1 }
                }
                children.append(try child(start ..< childEnd, depth: depth + 1, defaultType: defaultType))
            }
            if isClosing {
                guard !children.isEmpty else { throw Failure.malformed("multipart has no body parts") }
                return children
            }
            childStart = next
        }
        throw Failure.malformed("missing closing multipart delimiter")
    }

    /// Returns whether an entity holds encrypted content.
    ///
    /// S/MIME signed data, certificates, and compressed data are not encrypted.
    static func isEncrypted(_ type: String, parameters: [String: String]) -> Bool {
        switch type {
        case "multipart/encrypted", "application/pgp-encrypted":
            return true
        case "application/pkcs7-mime", "application/x-pkcs7-mime":
            // RFC 8551 section 3.2.2 defines smime-type.
            // Senders that omit it usually send enveloped (encrypted) data.
            let smimeType = parameters["smime-type"]?.lowercased()
            return smimeType == nil || smimeType == "enveloped-data" || smimeType == "authenveloped-data"
        default:
            return false
        }
    }
}
