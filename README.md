# Envelope

Envelope reads Mail.app's local message store on macOS.
Its one module, `Envelope`, has three parts:

- A `Store` reads metadata from the live `Envelope Index` SQLite database
  and locates `.emlx` message files.
- `Content` and `Container` read `.emlx` message files
  and parse readable content with an internal MIME reader.
- `Store.content(for:)` connects the two:
  it reads a message's content and checks that the file holds the message.

## Requirements

- Xcode 16.3+
- Swift 6.1+
- macOS 13.0+

The caller must have access to the Mail folder.
Envelope does not request permissions or manage security-scoped bookmarks.
Keep any security scope active until all database and file reads finish.
Each `Store` call finishes its database and file work before it returns or throws.

## Installation

### Swift Package Manager

Add Envelope as a dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mattt/Envelope.git", from: "0.2.0")
]
```

Then add the product to your target's dependencies:

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "Envelope", package: "Envelope")
        ]
    )
]
```

## Usage

Create a `Store` for the Mail folder, such as `~/Library/Mail`, with `~` expanded.
Each call finds the highest numbered `V<n>` directory with an index,
opens a read-only connection, and closes it before it returns.
Call `checkAccess()` after the user grants access to the folder.
`location()` finds the store without waiting for other calls,
so it suits a quick status check.

```swift
import Envelope
import Foundation

let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Mail")
let store = Store(root: root)
try await store.checkAccess()

for mailbox in try await store.mailboxes() {
    print(mailbox.id, mailbox.name ?? "", mailbox.account?.email ?? "")
}
```

Search with a `Message.FetchRequest`.
Each page of results includes a cursor for the next page.

```swift
var request = Message.FetchRequest(subject: "Invoice", limit: 50)
repeat {
    let page = try await store.search(request)
    for message in page.records {
        print(message.id, message.date, message.subject ?? "")
    }
    request.cursor = page.nextCursor
} while request.cursor != nil
```

Filters combine with AND.
Sender and subject searches match substrings without regard to case.
A search term with non-ASCII characters uses a slower comparison.
Dates use the Unix epoch, with an inclusive start and exclusive end.
Results sort by received date and row identifier, newest first.
The default limit is 30; the maximum is 100.
Mailbox filters include label membership when the store has a labels table.

A cursor names the last message of a page,
so mail that arrives between requests does not shift later pages.
Mailbox identifiers, message identifiers, and cursors include the store.
They round-trip through their string forms, such as `V10:12` for a mailbox,
and they encode as those strings in JSON.
After Mail moves to a new store, they fail with `MailError.storeChanged`.

`SearchResult` contains the matching records, the next cursor, the request,
and `indexedMessageCount` for the selected mailbox scope before other filters
and pagination.
The records and the count come from one snapshot of the index.
This count does not describe server contents or account sync status.
A zero count can mean an empty mailbox or incomplete local indexing.

Read a message's content with its identifier:

```swift
// An identifier round-trips through its string form, such as "V10:12:345".
if let identifier = Message.Identifier("V10:12:345") {
    let content = try await store.content(for: identifier)
    print(content.mediaType, content.body)
}
```

The store looks up the message, closes its connection,
and then reads and parses the message file.
`content(for:)` checks that the file's Message-ID matches the index
whenever the index records an RFC Message-ID.
To read the file with another parser, use `readMessage(_:parse:)`.
The parser receives the file's bytes and the current index record:

```swift
if let identifier = Message.Identifier("V10:12:345") {
    let size = try await store.readMessage(identifier) { file in
        file.data.count
    }
    print(size)
}
```

`Content` returns decoded headers, a plain-text body when available,
an HTML body otherwise, attachment filenames, and the MIME Message-ID.
HTML remains data; Envelope does not load remote content.
A damaged part, such as an attachment with invalid parameters,
does not hide a readable body in another part.
When no part supplies a readable body,
encrypted, partial, malformed, and unsupported content produces an `EmlxError`.
`Container` exposes the counted payload and unparsed trailing bytes.
It does not require a valid trailing property list.
The complete input to `Content`, including trailing bytes, is limited to 32 MiB.
MIME parsing permits 64 nesting levels below the root, 1,024 entities,
256 KiB of headers per entity, 1 MiB of total headers,
and 64 MiB of decoded UTF-8 output.
Resource failures use `unsupportedMessage`.
See the [behavior specification](Documentation/MIME.md) for body selection,
strict decoding, recovery rules, and verification tooling.

Run several queries in one snapshot of the index with `withSnapshot`.
The snapshot is valid only inside its closure.

```swift
let (mailboxes, unread) = try await store.withSnapshot { snapshot in
    let mailboxes = try snapshot.mailboxes()
    let inbox = mailboxes.first { $0.name == "INBOX" }
    return (mailboxes, try snapshot.search(.init(mailboxID: inbox?.id, isRead: false)))
}
print(mailboxes.count, unread.indexedMessageCount, unread.records.count)
```

### Limits and cancellation

The database opens read-only and requires WAL journal mode.
Envelope does not copy the database, change its journal mode, or run checkpoints.
SQLite lock conflicts fail immediately with `MailError.databaseBusy`, without a retry.
Each statement has a cooperative 100 ms deadline by default,
and the statements of one snapshot share a 1 second deadline by default.
An active read can still delay a WAL checkpoint.
The deadlines cannot interrupt blocked filesystem I/O.

`Store.Configuration` sets the statement and snapshot deadlines and the connection limit.
The default is one open connection per process,
and a store opens at most one connection at a time.
When callers choose different limits, the smallest limit of the open connections
and the requested connection applies to admission.
A connection over the limit fails with `MailError.connectionLimitReached`.
`Store.Configuration.init` throws `Store.Configuration.ValidationError` for a limit that is not positive,
and `Store.Configuration.default` holds the default limits.

A store runs one operation at a time on a private dispatch queue,
outside Swift's cooperative thread pool.
Overlapping calls wait their turn; Swift does not guarantee their order.
On macOS 14 and later, each operation runs at the priority of the calling task.
Operations run as part of the calling task, so canceling the task
stops SQL statements, file lookups, and MIME parsing:

```swift
let search = Task {
    try await store.search(.init(sender: "example.com"))
}
search.cancel()
do {
    print(try await search.value.records.count)
} catch is CancellationError {
    print("The search stopped and closed its connection.")
}
```

The MIME reader checks cancellation while scanning and decoding,
and before and after platform charset conversion.
Filesystem calls and platform conversion can delay cancellation.

File reads check that the store matches the message,
check folder containment, and accept regular files up to 32 MiB.
Cached locations are hints and are checked again on every read.

### Development

Run the fixture tests and formatter from the repository root:

```sh
swift test
swift format lint --strict --recursive .
```

If a separately installed Swift toolchain conflicts with the selected Xcode SDK,
use `xcrun --toolchain XcodeDefault swift` for these commands.
The tests use synthetic fixtures and do not need access to the Mail folder.
`UsageTests` runs the usage examples above against a synthetic store;
keep the two in sync.

## FAQ

### Does Envelope download or change messages?

No.
It reads local metadata and message files.
It does not fetch missing messages, change read state, compose, or send mail.

### What does Envelope depend on?

Envelope uses Foundation, CoreFoundation, the system SQLite3 module, and system locks.
It has no external runtime dependencies.

### What if my code declares a type with the same name as one in Envelope?

Your type takes precedence in your module.
Qualify Envelope's type with the module name, such as `Envelope.Message` or `Envelope.MailError`.

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
