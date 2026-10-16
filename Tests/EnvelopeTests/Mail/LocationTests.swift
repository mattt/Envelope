import Foundation
import Testing

@testable import Envelope

extension MailTests {
    @Suite
    struct LocationTests {
        let store: MailStore

        init() throws {
            store = try MailStore()
        }

        /// Creates an empty file at the index path of a store directory.
        private func createIndex(in version: URL) throws {
            let data = version.appendingPathComponent("MailData")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: data.appendingPathComponent("Envelope Index").path, contents: nil)
        }

        @Test("Location returns the store and index URLs")
        func locationReturnsStoreAndIndex() throws {
            let location = try Database.location(in: store.root)
            #expect(location.versionURL == store.version.resolvingSymlinksInPath())
            #expect(location.indexURL == store.index.resolvingSymlinksInPath())
        }

        @Test("Location compares store numbers as integers")
        func locationComparesStoreNumbersAsIntegers() throws {
            try createIndex(in: store.root.appendingPathComponent("V9"))
            try FileManager.default.createDirectory(at: store.root.appendingPathComponent("V11"), withIntermediateDirectories: true)
            #expect(try Database.location(in: store.root).versionURL.lastPathComponent == "V10")
        }

        @Test("Location fails for a folder that cannot be read")
        func locationFailsForMissingFolder() throws {
            #expect(throws: MailError.indexNotReadable) {
                try Database.location(in: store.root.appendingPathComponent("Missing"))
            }
        }

        @Test("Location ignores directories that are not numbered stores")
        func locationIgnoresUnnumberedDirectories() throws {
            let root = store.root.appendingPathComponent("Unnumbered")
            for name in ["V", "Vx", "v11", "V-1", "V+12", "V1.5", "Backup"] {
                try createIndex(in: root.appendingPathComponent(name))
            }
            #expect(throws: MailError.indexNotFound) { try Database.location(in: root) }
            #expect(throws: MailError.indexNotFound) { try Database(root: root) }
        }

        @Test("Location rejects a store or an index outside the folder")
        func locationRejectsLinksOutsideTheFolder() throws {
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: outside) }
            try createIndex(in: outside)

            let linkedStore = store.root.appendingPathComponent("LinkedStore")
            try FileManager.default.createDirectory(at: linkedStore, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkedStore.appendingPathComponent("V11"), withDestinationURL: outside)
            let storeError = #expect(throws: MailError.self) { try Database.location(in: linkedStore) }
            #expect(storeError == .notContained(outside.resolvingSymlinksInPath()))

            let linkedIndex = store.root.appendingPathComponent("LinkedIndex")
            let data = linkedIndex.appendingPathComponent("V11/MailData")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let index = outside.appendingPathComponent("MailData/Envelope Index")
            try FileManager.default.createSymbolicLink(at: data.appendingPathComponent("Envelope Index"), withDestinationURL: index)
            let indexError = #expect(throws: MailError.self) { try Database.location(in: linkedIndex) }
            #expect(indexError == .notContained(index.resolvingSymlinksInPath()))
        }
    }
}
