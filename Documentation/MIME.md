# MIME reader behavior

The reader accepts bytes and returns ordered headers and an entity tree.
Body selection belongs to Emlx.
No parser source or fixtures from another implementation are used.
The fixtures are synthetic messages authored for this project.

## Standards

- [RFC 5322 sections 2 and 3](https://www.rfc-editor.org/rfc/rfc5322.html):
  preserve field order and spelling; unfold continuation lines.
- [RFC 2045 sections 5 and 6](https://www.rfc-editor.org/rfc/rfc2045.html):
  default to text/plain and identity encoding; decode base64 and quoted-printable.
- [RFC 2046 section 5](https://www.rfc-editor.org/rfc/rfc2046.html):
  delimiters must occupy a line; require closing delimiters.
  Exclude preambles and epilogues.
  The default child type of multipart/digest is message/rfc822.
- [RFC 2047](https://www.rfc-editor.org/rfc/rfc2047.html):
  decode B and Q words and ignore whitespace between adjacent encoded words.
- [RFC 2231](https://www.rfc-editor.org/rfc/rfc2231.html):
  join consecutive numbered parameters before charset conversion.
  A valid extended value takes precedence over a plain value.
- [RFC 2183](https://www.rfc-editor.org/rfc/rfc2183.html):
  exclude explicit attachments from body selection.
  Prefer disposition filename over Content-Type name.
- [RFC 2387](https://www.rfc-editor.org/rfc/rfc2387.html):
  select the start Content-ID, or the first child when start is absent.
- [RFC 6532](https://www.rfc-editor.org/rfc/rfc6532.html):
  accept valid UTF-8 header text.

## Selection and rejection

Alternative selects the last plain-text candidate, then the last HTML candidate.
Mixed and unknown multipart types select the first eligible subtree.
Signed content is readable without signature verification.
Inline encapsulated messages can supply a body; attached messages cannot.
Encrypted and partial entities fail, including nested entities.
Unknown charsets, invalid text, duplicate structural fields, malformed transfer
encoding, parameter gaps, and incomplete multipart structure fail.
Binary attachments are not returned or decoded.
Address interpretation, rendering, cryptography, composition, and flowed-text
reformatting are outside the reader's scope.

## Deliberate compatibility rules

LF line endings, a missing final newline, MIME linear whitespace, and valid
UTF-8 bodies without a charset are accepted.
The corpus cases lf, utf8, words, and multipart cover these rules.
No legacy charset is guessed.
An empty entity header block is valid; a root message must have a header.
Resource failures do not produce partial results.

## Budgets

The complete Emlx input is limited to 32 MiB.
The root is at depth zero; maximum depth is 64.
One parse permits 1,024 entities, 256 KiB of headers per entity,
1 MiB of total headers, and 64 MiB of decoded UTF-8 output.
Budgets are shared by all nested messages.
Cancellation is checked during byte scanning and decoding, and around charset
conversion.

## Comparison decisions

The development harness pins MimeFoundation at
`dcb6746729d20cf00c42ad6453b4637a075f7d0b`.
`Tools/MIMEComparison/compare.py` uses Python's standard-library email parser.
Run both against `Tests/MIMETests/Fixtures/*.mime`.
The expectation manifest records the source and expected body for each fixture.
A null body requires rejection, rather than an empty successful result.

The initial comparison produced these differences:

| Fixture | Observed comparison | Decision |
|---|---|---|
| inline-message | Both comparison body selectors return no body. | Select inline message content, as specified for this reader; RFC 2046 section 5.2.1 defines its encapsulated structure. |
| last-alternative | Python selects the first plain alternative. | Select the last supported plain alternative under RFC 2046 section 5.1.4 and the local plain-text preference. |
| utf8 | Python replaces undeclared non-ASCII body bytes. | Accept valid UTF-8 under the documented recovery rule. |
| bad-base64, bad-qp | Comparison parsers tolerate malformed transfer data. | Reject under the strict RFC 2045 decoding policy. |
| duplicate | Both return a body despite duplicate Content-Type. | Reject ambiguous structural fields. |
| continuation-gap | Both accept a filename continuation without segment zero. | Reject under RFC 2231 section 3. |
| truncated | Both return truncated text. | Require the RFC 2046 closing delimiter. |
| unknown-charset | MimeFoundation returns text; Python fails conversion. | Reject unknown declared charsets. |
| encrypted, partial | Comparison selectors return no body. | Preserve explicit encrypted and partial error categories. |

Python normalizes parameter quoting in displayed headers.
Envelope retains unfolded source parameter spelling in header values.
Other successful corpus body expectations agree with MimeFoundation and Python.
These observations support the tests; parser agreement is not the authority.
