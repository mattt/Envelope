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
                .connectionLimitReached, .connectionClosed, .operationInProgress, .queryTimedOut, .queryFailed("disk I/O error"),
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

        @Test("Every validation error has a description", arguments: [ValidationError.limitOutOfRange, .negativeOffset, .invalidDateRange])
        func validationErrorDescription(error: ValidationError) throws {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
            #expect(error.localizedDescription == description)
        }

        @Test("The limit error names the maximum limit")
        func limitErrorNamesMaximum() {
            #expect(ValidationError.limitOutOfRange.localizedDescription.contains("\(Mail.Message.FetchRequest.maximumLimit)"))
        }
    }
}
