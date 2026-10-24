import Foundation
import Testing

@testable import Envelope

extension MailTests {
    @Suite
    struct ErrorTests {
        @Test(
            "Every Mail error has a description",
            arguments: [
                MailError.indexNotFound, .indexNotReadable, .unsupportedSchema, .unsupportedJournalMode, .databaseBusy,
                .connectionLimitReached, .connectionClosed, .queryTimedOut, .queryFailed("disk I/O error"),
                .notContained(URL(fileURLWithPath: "/tmp/Outside.mbox")), .storeChanged, .mailboxNotFound, .messageNotFound,
                .messageFileNotFound, .messageFileTooLarge, .messageFileNotRegular, .unsupportedMailbox,
            ]
        )
        func mailErrorDescription(error: MailError) throws {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
            #expect(error.localizedDescription == description)
        }

        @available(*, deprecated)
        @Test("The deprecated partial-message error does not tell users to open Mail")
        func partialMessageDescription() {
            let description = MailError.partialMessage.localizedDescription
            #expect(description == "The local message file holds only part of the message.")
        }

        @Test("Mail error descriptions include their associated values")
        func mailErrorDescriptionsIncludeAssociatedValues() {
            #expect(MailError.queryFailed("disk I/O error").localizedDescription.contains("disk I/O error"))
            #expect(MailError.notContained(URL(fileURLWithPath: "/tmp/Outside.mbox")).localizedDescription.contains("/tmp/Outside.mbox"))
        }

        @Test(
            "Every request validation error has a description",
            arguments: [Message.FetchRequest.ValidationError.limitOutOfRange, .invalidDateRange]
        )
        func validationErrorDescription(error: Message.FetchRequest.ValidationError) throws {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
            #expect(error.localizedDescription == description)
        }

        @Test(
            "Every configuration validation error has a description",
            arguments: [Store.Configuration.ValidationError.invalidQueryTimeLimit, .invalidMaximumConnections, .invalidSnapshotTimeLimit]
        )
        func configurationErrorDescription(error: Store.Configuration.ValidationError) throws {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
            #expect(error.localizedDescription == description)
        }

        @Test("The limit error names the maximum limit")
        func limitErrorNamesMaximum() {
            #expect(Message.FetchRequest.ValidationError.limitOutOfRange.localizedDescription.contains("\(Message.FetchRequest.maximumLimit)"))
        }
    }
}
