import Foundation
import Testing

@testable import Envelope

@Suite
struct IdentifierTests {
    @Test("Mailbox identifiers round-trip through strings")
    func mailboxIdentifierStringForm() throws {
        let id = try #require(Mailbox.ID("V10:12"))
        #expect(id.store == "V10")
        #expect(id.rowID == 12)
        #expect(id.description == "V10:12")
        for invalid in ["", "V10", "12", ":12", "V10:0", "V10:-1", "V10:x", "V10:12:3"] {
            #expect(Mailbox.ID(invalid) == nil, "\(invalid)")
        }
    }

    @Test("Identifiers and cursors encode as their string forms")
    func identifiersEncodeAsStrings() throws {
        struct Payload: Codable, Equatable {
            let mailbox: Mailbox.ID
            let message: Message.Identifier
            let cursor: Message.FetchRequest.Cursor
        }
        let json = #"{"cursor":"V10:300.0:3","mailbox":"V10:12","message":"V10:12:345"}"#
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        #expect(payload.mailbox == Mailbox.ID("V10:12"))
        #expect(payload.message == Message.Identifier("V10:12:345"))
        #expect(payload.cursor == Message.FetchRequest.Cursor("V10:300.0:3"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(payload), as: UTF8.self) == json)
    }

    @Test("Decoding rejects strings that are not identifiers")
    func decodingRejectsInvalidStrings() {
        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) { try decoder.decode(Mailbox.ID.self, from: Data(#""V10""#.utf8)) }
        #expect(throws: DecodingError.self) { try decoder.decode(Message.Identifier.self, from: Data(#""V10:1""#.utf8)) }
        #expect(throws: DecodingError.self) { try decoder.decode(Message.FetchRequest.Cursor.self, from: Data("12".utf8)) }
    }
}
