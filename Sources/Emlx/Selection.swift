import MIME

extension Content {
    /// Selects the body text and its media type.
    static func select(_ part: Part) -> (String, String)? {
        guard !part.isAttachment, part.failure == nil else { return nil }
        if let text = part.text, ["text/plain", "text/html"].contains(part.mediaType) {
            return (text, part.mediaType)
        }
        if part.mediaType == "multipart/related" {
            let root: Part?
            if let start = part.parameters["start"] {
                root = part.children.first { $0.header("content-id") == start }
            } else {
                root = part.children.first
            }
            return root.flatMap(select)
        }
        if part.mediaType == "multipart/alternative" {
            let candidates = part.children.compactMap(select)
            return candidates.last { $0.1 == "text/plain" } ?? candidates.last { $0.1 == "text/html" }
        }
        if part.mediaType == "multipart/signed" {
            return part.children.first.flatMap(select)
        }
        for child in part.children {
            if let body = select(child) { return body }
        }
        return nil
    }

    /// Returns the filenames of a part and the parts that it contains.
    static func filenames(_ part: Part) -> [String] {
        var names = part.filename.map { [$0] } ?? []
        // An attached message is one attachment, not a container of exposed files.
        if !part.isAttachment { names += part.children.flatMap(filenames) }
        return names
    }

    /// Returns the failure that best explains a missing body.
    ///
    /// Encrypted and partial content take precedence over other failures.
    /// Failures inside attachments do not explain a missing body.
    static func failure(in part: Part) -> Failure? {
        var failures: [Failure] = []
        func collect(_ part: Part) {
            guard !part.isAttachment else { return }
            if let failure = part.failure { failures.append(failure) }
            part.children.forEach(collect)
        }
        collect(part)
        return failures.first { $0 == .encrypted } ?? failures.first { $0 == .partial } ?? failures.first
    }
}
