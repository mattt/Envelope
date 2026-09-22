import Foundation

package struct Limits: Sendable {
    package var depth = 64
    package var entities = 1_024
    package var entityHeaders = 256 * 1_024
    package var totalHeaders = 1_024 * 1_024
    package var decoded = 64 * 1_024 * 1_024
    package init() {}
}

package enum Failure: Error {
    case malformed(String)
    case unsupported(String)
    case limit
    case partial
    case encrypted
}

package struct Header: Sendable {
    package let name: String
    package let value: String
}

package struct Part: Sendable {
    package let headers: [Header]
    package let mediaType: String
    package let parameters: [String: String]
    package let attachment: Bool
    package let filename: String?
    package let bodyRange: Range<Int>
    package let text: String?
    package let children: [Part]
    package func header(_ name: String) -> String? {
        headers.first { $0.name.lowercased() == name }?.value
    }
}

final class Budget {
    let limits: Limits
    let cancel: () throws -> Void
    var entities = 0
    var headers = 0
    var decoded = 0
    init(_ limits: Limits, _ cancel: @escaping () throws -> Void) {
        self.limits = limits
        self.cancel = cancel
    }
    func output(_ count: Int) throws {
        guard count <= limits.decoded - decoded else { throw Failure.limit }
        decoded += count
    }
    func tick(_ offset: Int) throws {
        if offset % 16_384 == 0 { try cancel() }
    }
}
