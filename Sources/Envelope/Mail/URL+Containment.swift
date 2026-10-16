import Foundation

extension URL {
    /// Returns whether the location is inside a directory after both resolve their symbolic links.
    func isContained(in directory: URL) -> Bool {
        resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/")
    }
}
