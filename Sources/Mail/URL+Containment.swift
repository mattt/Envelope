import Foundation

extension URL {
    /// Whether the file is inside a directory after both resolve their symbolic links.
    func isContained(in directory: URL) -> Bool {
        resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/")
    }
}
