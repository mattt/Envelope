import Foundation
import Testing

@testable import Mail

extension MailTests {
    @Suite
    struct ErrorTests {
        @Test(
            "Every Mail error has a description",
            arguments: [
                MailError.indexNotFound, .indexNotReadable, .unsupportedSchema, .unsupportedJournalMode, .databaseBusy,
                .connectionLimitReached, .connectionClosed, .queryTimedOut, .queryFailed("disk I/O error"),
                .notContained(URL(fileURLWithPath: "/tmp/Outside.mbox")), .storeChanged, .mailboxNotFound, .messageNotFound,
                .messageFileNotFound, .messageFileTooLarge, .messageFileNotRegular, .unsupportedMailbox, .partialMessage,
            ]
        )
        func mailErrorDescription(error: MailError) throws {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
            #expect(error.localizedDescription == description)
        }

        @Test("Mail error descriptions include their associated values")
        func mailErrorDescriptionsIncludeAssociatedValues() {
            #expect(MailError.queryFailed("disk I/O error").localizedDescription.contains("disk I/O error"))
            #expect(MailError.notContained(URL(fileURLWithPath: "/tmp/Outside.mbox")).localizedDescription.contains("/tmp/Outside.mbox"))
        }

        @Test(
            "Every request validation error has a description",
            arguments: [Mail.Message.FetchRequest.ValidationError.limitOutOfRange, .invalidDateRange]
        )
        func validationErrorDescription(error: Mail.Message.FetchRequest.ValidationError) throws {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
            #expect(error.localizedDescription == description)
        }

        @Test(
            "Every configuration validation error has a description",
            arguments: [Mail.Store.Configuration.ValidationError.invalidQueryTimeLimit, .invalidMaximumConnections, .invalidSnapshotTimeLimit]
        )
        func configurationErrorDescription(error: Mail.Store.Configuration.ValidationError) throws {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
            #expect(error.localizedDescription == description)
        }

        @Test("The limit error names the maximum limit")
        func limitErrorNamesMaximum() {
            #expect(Mail.Message.FetchRequest.ValidationError.limitOutOfRange.localizedDescription.contains("\(Mail.Message.FetchRequest.maximumLimit)"))
        }
    }
}
