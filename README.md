# Envelope

Envelope reads Mail.app's local message store on macOS.
It provides two Swift modules:

- `Mail` reads metadata from the live `Envelope Index` SQLite database
  and locates `.emlx` message files.
- `Emlx` separates an `.emlx` file's MIME payload from its trailing bytes
  and parses readable content with MimeFoundation.

## Requirements

Envelope requires macOS 13 or later and Swift 6.1 or later.
The pinned MimeFoundation revision requires Swift 6.1.
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
    let mailbox = mailboxes.first?.id
    return try database.search(.init(subject: "Invoice", mailbox: mailbox))
}

for message in result.records {
    print(message.identifier, message.subject)
}
```

Filters combine with AND.
Sender and subject searches use case-insensitive substrings.
Dates use the Unix epoch, with an inclusive start and exclusive end.
Results sort by received date and row identifier, newest first.
The default limit is 30; the maximum is 100.
Mailbox filters include label membership when the store has a labels table.

`SearchResult` contains records, the applied request in `filters`, and
`indexedMessageCount` for the selected mailbox scope before other filters
and pagination.
This count does not describe server contents or account sync status.
A zero count can mean an empty mailbox or incomplete local indexing.

Close the database before reading message files.
The parsing closure lets `Mail` locate and cache files without depending on MIME.
Pass the indexed Message-ID to `Emlx.Content` to check file identity.

```swift
import Emlx

let files = Mail.Files()
if let identifier = result.records.first?.identifier {
    let content = try await worker.run { cancellation in
        let database = try Mail.Database(root: root, cancellation: cancellation)
        defer { database.close() }
        let record = try database.record(for: identifier)
        database.close()

        return try files.read(record, version: database.versionURL,
                              cancellation: cancellation) { data in
            try Emlx.Content(emlx: data, expectedMessageID: record.messageID,
                             checkCancellation: cancellation.check)
        }
    }
    print(content.mediaType, content.body)
}
```

`Emlx.Content` returns decoded headers, a plain-text body when available,
an HTML body otherwise, attachment names, and the MIME Message-ID.
HTML remains data; Envelope does not load remote content.
Encrypted, partial, malformed, and unsupported content produces typed errors.
`Emlx.Container` exposes the counted payload and unparsed trailing bytes.
It does not require a valid trailing property list.

### Limits and cancellation

The database opens read-only and requires WAL journal mode.
Envelope does not copy the database, change its journal mode, or run checkpoints.
SQLite lock conflicts fail immediately without a retry.
Each statement has a cooperative 100 ms deadline by default.
An active read can still delay a WAL checkpoint.
The deadline cannot interrupt blocked filesystem I/O.

`Database.Configuration` makes the statement budget and connection limit explicit.
The default is one open connection per process.
When callers choose different limits, the smallest limit of the open connections
and the requested connection applies to admission.
Use each database on one thread at a time.

`Mail.Worker` runs one blocking operation at a time on a dispatch queue.
Overlapping calls fail immediately, including during file reads.
Its cancellation signal reaches synchronous database and file operations.
Pass `cancellation.check` to `Emlx.Content` to extend that signal through parsing.
MIME decoding and filesystem calls can delay a cancellation check.

File reads check folder containment and accept regular files up to 32 MiB.
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
Conductor Setup resolves package dependencies with Xcode's bundled compiler.
Conductor Run executes the fixture tests with that compiler.
Setup requires Xcode 16.3 or later, accepted Xcode license terms,
and network access for uncached dependencies.
No Mail folder grant or copied workspace files are needed for the tests.

## FAQ

### Does Envelope download or change messages?

No.
It reads local metadata and message files.
It does not fetch missing messages, change read state, compose, or send mail.

### Can a metadata-only consumer avoid MIME binaries?

Yes.
The `Mail` target uses Foundation, the system SQLite3 module, and system locks.
It has no dependency on `Emlx` or MimeFoundation.
SwiftPM still resolves package-level dependencies.
Consumers of `Emlx` link MimeFoundation and its crypto dependencies.

### Is the Mail store format stable?

Mail's store is undocumented and can change between macOS releases.
Envelope checks the required schema and reports unsupported stores.
Message identifiers include the store and home mailbox to detect stale results.

## Acknowledgments

Envelope extracts the Mail store reader from [iMCP](https://github.com/mattt/iMCP).
Its package structure follows [Madrid](https://github.com/mattt/Madrid).
[MimeFoundation](https://github.com/migueldeicaza/MimeFoundation)
provides MIME parsing and remains pinned to revision
`dcb6746729d20cf00c42ad6453b4637a075f7d0b`.

## Legal

Envelope is an independent project and is not affiliated with Apple Inc.
Mail and macOS are trademarks of Apple Inc.
Applications that use Envelope are responsible for obtaining access to mail data.

## License

Envelope is available under the MIT license.
See [LICENSE.md](LICENSE.md).
