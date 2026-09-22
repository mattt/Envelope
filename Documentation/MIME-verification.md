# MIME replacement verification

Verification date: 2026-09-22.
The production reader is `Sources/MIME`.
`Emlx` selects content from its result without a fallback parser.
The public products, Swift 6.1 package floor, and macOS 13 floor are unchanged.

## Completed checks

| Check | Result |
|---|---|
| Envelope fixture and integration tests | 49 tests passed with Xcode's Swift 6.4 compiler. |
| Full Envelope test suite with AddressSanitizer | 49 tests passed. |
| Pre-removal mutation check | 1,000,000 seeded mutations passed under AddressSanitizer with the final reader, in release configuration. |
| CI mutation command after integration | 10,000 seeded mutations passed under AddressSanitizer. |
| Strict recursive Swift formatter lint | Passed. |
| Swift 6.2 production build | The MIME and Emlx targets built with the macOS 26.5 SDK. |
| iMCP dependency resolution and app build | Passed with the local Envelope package. |
| iMCP app tests | Both tests passed. |

The corpus contains 21 independently authored synthetic messages.
Additional tests cover selection, shared limits, invalid input, cancellation,
and nonzero-index Data slices.
The comparison decisions and RFC references are in [MIME.md](MIME.md).
The separate comparison package retains the old parser pin.
Envelope itself has no external package dependencies.
iMCP resolution removed MimeFoundation, swift-crypto, swift-certificates,
and swift-asn1 because no remaining package required them.
The existing uncommitted iMCP extraction changes were retained.

The mutation runner saves synthetic failures as regression fixtures and uses a
subprocess watchdog that terminates the process group on timeout.
No crash, hang, or unexpected error was found in the completed mutation runs.
The runner also retains the current synthetic input on failure.

## Manual app checks

The rebuilt development app was restarted with Mail enabled.
A temporary client called its MCP tools and retained only statuses and counts.

| Action | Observed result |
|---|---|
| List mailboxes | Returned 71 mailboxes. |
| Search a populated mailbox | Returned one message with limit 1. |
| Read that message | Returned text/html, 23 headers, and zero attachment names. |
| Open an empty compose window | The app reported success. No send action was called. |

No private message content was added to fixtures or diagnostic logs.
The development app and empty compose window were left open.

## Remaining verification

The Swift 6.1 and Swift 6.2 CI matrix is retained and includes the sanitizer
mutation command, but those remote jobs have not run for these changes.
Swift 6.1 is not installed on this machine.
The local Swift 6.2 compiler builds the production targets with the macOS 26.5
SDK, but cannot compile the newer XCTest frameworks bundled with Xcode here.
A matching Xcode runner is still required to complete both matrix test jobs.

No commit, push, tag, repository publication, or pull request was made.
