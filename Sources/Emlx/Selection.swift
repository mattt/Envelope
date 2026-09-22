import MIME

extension Content {
    static func select(_ part: Part) -> (String, String)? {
        guard !part.attachment else { return nil }
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

    static func filenames(_ part: Part) -> [String] {
        var names = part.filename.map { [$0] } ?? []
        // An attached message is one attachment, not a container of exposed files.
        if !part.attachment { names += part.children.flatMap(filenames) }
        return names
    }
}
