# Envelope

Envelope reads Mail.app's local message store on macOS.
It provides two Swift modules:

- `Mail` reads metadata from the live `Envelope Index` SQLite database
  and locates `.emlx` message files.
- `Emlx` separates an `.emlx` file's MIME payload from its trailing bytes
  and parses readable content with an internal MIME reader.

## Requirements

Envelope requires macOS 13 or later and Swift 6.1 or later.
Development requires Xcode with a compatible macOS SDK.

The caller must have access to the Mail folder.
Envelope does not request permissions or manage security-scoped bookmarks.
Keep any security scope active until all database and file reads finish.

## Installation

During development, add Envelope as a local Swift package dependency:

```swift
.package(path: "../Envelope")
```

Add the products your target uses:

```swift
.product(name: "Mail", package: "Envelope"),
.product(name: "Emlx", package: "Envelope"),
```

The planned first release is `0.1.0`.
Once that tag is published, the remote dependency is:

```swift
.package(url: "https://github.com/mattt/Envelope", from: "0.1.0")
```

## Usage

Use `Mail.Database` for metadata reads.
Pass the Mail root folder, such as `~/Library/Mail`, with `~` expanded.
Envelope discovers the highest numbered `V<n>` directory with an index.

```swift
import Foundation
import Mail

let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Mail")
let worker = Mail.Worker()

let result = try await worker.run { cancellation in
    let database = try Mail.Database(root: root, cancellation: cancellation)
    defer { database.close() }

    let mailboxes = try database.mailboxes()
    let mailboxID = mailboxes.first?.id
    return try database.search(.init(subject: "Invoice", mailboxID: mailboxID))
}

for message in result.records {
    print(message.id, message.subject ?? "")
}
```

Filters combine with AND.
Sender and subject searches match substrings without regard to case.
A search term with non-ASCII characters uses a slower comparison.
Dates use the Unix epoch, with an inclusive start and exclusive end.
Results sort by received date and row identifier, newest first.
The default limit is 30; the maximum is 100.
Mailbox filters include label membership when the store has a labels table.

`SearchResult` contains the matching records, the request,
and `indexedMessageCount` for the selected mailbox scope before other filters
and pagination.
The records and the count come from one snapshot of the index.
This count does not describe server contents or account sync status.
A zero count can mean an empty mailbox or incomplete local indexing.

Close the database before reading message files.
The parsing closure lets `Mail` locate and cache files without depending on MIME.
Pass the indexed Message-ID to `Emlx.Content` to check file identity.

```swift
import Emlx

let reader = Mail.MessageFileReader()
if let identifier = result.records.first?.id {
    let content = try await worker.run { cancellation in
        let database = try Mail.Database(root: root, cancellation: cancellation)
        defer { database.close() }
        let record = try database.record(for: identifier)
        database.close()

        return try reader.read(record, version: database.versionURL,
                               cancellation: cancellation) { data in
            try Emlx.Content(emlx: data, expectedMessageID: record.messageID,
                             checkCancellation: cancellation.check)
        }
    }
    print(content.mediaType, content.body)
}
```

`Emlx.Content` returns decoded headers, a plain-text body when available,
an HTML body otherwise, attachment filenames, and the MIME Message-ID.
HTML remains data; Envelope does not load remote content.
A damaged part, such as an attachment with invalid parameters,
does not hide a readable body in another part.
When no part supplies a readable body,
encrypted, partial, malformed, and unsupported content produces an `EmlxError`.
`Emlx.Container` exposes the counted payload and unparsed trailing bytes.
It does not require a valid trailing property list.
The complete input to `Emlx.Content`, including trailing bytes, is limited to 32 MiB.
MIME parsing permits 64 nesting levels below the root, 1,024 entities,
256 KiB of headers per entity, 1 MiB of total headers,
and 64 MiB of decoded UTF-8 output.
Resource failures use `unsupportedMessage`.
See the [behavior specification](Documentation/MIME.md) for body selection,
strict decoding, recovery rules, and verification tooling.

### Limits and cancellation

The database opens read-only and requires WAL journal mode.
Envelope does not copy the database, change its journal mode, or run checkpoints.
SQLite lock conflicts fail immediately with `MailError.databaseBusy`, without a retry.
Each statement has a cooperative 100 ms deadline by default.
An active read can still delay a WAL checkpoint.
The deadline cannot interrupt blocked filesystem I/O.

`Database.Configuration` makes the statement budget and connection limit explicit.
The default is one open connection per process.
When callers choose different limits, the smallest limit of the open connections
and the requested connection applies to admission.
A connection over the limit fails with `MailError.connectionLimitReached`.
Use each database on one thread at a time.

`Mail.Worker` runs one blocking operation at a time on a dispatch queue.
Overlapping calls fail immediately with `MailError.operationInProgress`,
including during file reads.
Its cancellation signal reaches synchronous database and file operations.
Pass `cancellation.check` to `Emlx.Content` to extend that signal through parsing.
The MIME reader checks cancellation while scanning and decoding,
and before and after platform charset conversion.
Filesystem calls and platform conversion can delay cancellation.

File reads check that the store matches the message,
check folder containment, and accept regular files up to 32 MiB.
Cached locations are hints and are checked again on every read.
The parser closure is responsible for checking MIME identity;
the usage example checks it whenever the index contains an RFC Message-ID.

### Development

Run the fixture tests and formatter from the repository root:

```sh
swift test
swift format lint --strict --recursive .
```

If a separately installed Swift toolchain conflicts with the selected Xcode SDK,
use `xcrun --toolchain XcodeDefault swift` for these commands.
The tests use synthetic fixtures and do not need access to the Mail folder.

## FAQ

### Does Envelope download or change messages?

No.
It reads local metadata and message files.
It does not fetch missing messages, change read state, compose, or send mail.

### Can a metadata-only consumer avoid MIME binaries?

Yes.
The `Mail` target uses Foundation, the system SQLite3 module, and system locks.
It has no dependency on `Emlx` or `MIME`.
`Emlx` uses the internal `MIME` target, Foundation, and CoreFoundation.
Envelope has no external runtime dependencies.

### Is the Mail store format stable?

Mail's store is undocumented and can change between macOS releases.
Envelope checks the required schema and reports unsupported stores.
Message identifiers include the store and home mailbox to detect stale results.

## Acknowledgments

Envelope extracts the Mail store reader from [iMCP](https://github.com/mattt/iMCP).
Its package structure follows [Madrid](https://github.com/mattt/Madrid).
The MIME reader is independently implemented from the RFCs listed in
[its behavior specification](Documentation/MIME.md).
A separate development harness compares synthetic fixtures with MimeFoundation
and Python's standard-library email parser.

## Legal

Envelope is an independent project and is not affiliated with Apple Inc.
Mail and macOS are trademarks of Apple Inc.
Applications that use Envelope are responsible for obtaining access to mail data.

## License

Envelope is available under the MIT license.
See [LICENSE.md](LICENSE.md).
