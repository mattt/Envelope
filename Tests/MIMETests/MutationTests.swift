import Foundation
import Testing

@testable import MIME

@Suite
struct MutationTests {
    /// The number of mutations to run, from `MIME_MUTATIONS`; `Tools/fuzz.py` sets it.
    static let count = ProcessInfo.processInfo.environment["MIME_MUTATIONS"].flatMap { Int($0) }

    @Test("Seeded mutations fail only with parser failures", .enabled(if: count != nil, "Set MIME_MUTATIONS or run Tools/fuzz.py"))
    func seededMutations() throws {
        let count = try #require(Self.count)
        let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        var corpus = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mime" }.sorted {
            $0.path < $1.path
        }.map { Array(try Data(contentsOf: $0)) }
        // Generated trees supplement the hand-authored corpus.
        for depth in 1 ... 8 {
            var message = "Subject: tree\n\nleaf"
            for level in 0 ..< depth { message = "Content-Type: multipart/mixed; boundary=b\(level)\n\n--b\(level)\n" + message + "\n--b\(level)--" }
            corpus.append(Array(message.utf8))
        }
        var state: UInt64 = 0x454e56454c4f5045
        func random(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(max(1, bound)))
        }
        let current: FileHandle?
        if let path = ProcessInfo.processInfo.environment["MIME_FUZZ_CURRENT"] {
            FileManager.default.createFile(atPath: path, contents: nil)
            current = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        } else {
            current = nil
        }
        defer { try? current?.close() }
        for iteration in 0 ..< count {
            var bytes = corpus[random(corpus.count)]
            for _ in 0 ... random(4) {
                let index = random(bytes.count)
                switch random(5) {
                case 0: bytes = Array(bytes.prefix(index))
                case 1: bytes.insert(UInt8(random(256)), at: index)
                case 2: if !bytes.isEmpty { bytes.remove(at: index) }
                case 3: if !bytes.isEmpty { bytes[index] = UInt8(random(256)) }
                default: bytes.insert(contentsOf: Array("=?utf-8?B?%%?=".utf8), at: index)
                }
            }
            if let current {
                try current.seek(toOffset: 0)
                try current.write(contentsOf: Data(bytes))
                try current.truncate(atOffset: UInt64(bytes.count))
            }
            if iteration % 10_000 == 0 {
                FileHandle.standardError.write(Data("Mutation \(iteration)/\(count)\n".utf8))
            }
            do { _ = try Parser.parse(Data(bytes)) } catch is Failure {} catch {
                Issue.record("Unexpected error at mutation \(iteration): \(error)")
                throw error
            }
        }
    }
}

extension MutationTests {
    @Test("Saved regressions fail only with parser failures")
    func savedRegressions() throws {
        let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Regressions")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for path in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where path.pathExtension == "mime" {
            do { _ = try Parser.parse(Data(contentsOf: path)) } catch is Failure {}
        }
    }
}
