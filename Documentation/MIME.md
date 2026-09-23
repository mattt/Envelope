# MIME reader behavior

The reader accepts bytes and returns ordered headers and an entity tree.
Body selection belongs to Emlx.
No parser source or fixtures from another implementation are used.
The fixtures are synthetic messages authored for this project.

## Standards

- [RFC 5322 sections 2 and 3](https://www.rfc-editor.org/rfc/rfc5322.html):
  preserve field order and spelling; unfold continuation lines,
  then trim white space from the ends of each value.
- [RFC 2045 sections 5 and 6](https://www.rfc-editor.org/rfc/rfc2045.html):
  default to text/plain and identity encoding;
  decode base64 and quoted-printable with the guidance for robust decoders
  in sections 6.7 and 6.8.
  Section 3 excludes comments from Content-Disposition.
- [RFC 2046 section 5](https://www.rfc-editor.org/rfc/rfc2046.html):
  delimiters must occupy a line; require closing delimiters.
  Exclude preambles and epilogues.
  The default child type of multipart/digest is message/rfc822.
- [RFC 2047](https://www.rfc-editor.org/rfc/rfc2047.html):
  decode B and Q words and ignore whitespace between adjacent encoded words.
  Text that is not a well-formed encoded word stays literal,
  as sections 6.1 and 6.3 require.
- [RFC 2231](https://www.rfc-editor.org/rfc/rfc2231.html):
  join consecutive numbered parameters before charset conversion.
  A valid extended value takes precedence over a plain value.
  An invalid extended value is ignored, and the plain value, if any, remains.
- [RFC 2183](https://www.rfc-editor.org/rfc/rfc2183.html):
  exclude explicit attachments from body selection.
  Prefer disposition filename over Content-Type name.
- [RFC 2387](https://www.rfc-editor.org/rfc/rfc2387.html):
  select the start Content-ID, or the first child when start is absent.
- [RFC 2781 section 4.3](https://www.rfc-editor.org/rfc/rfc2781.html):
  read UTF-16 in the order of its byte order mark, or big-endian without one.
- [RFC 6532](https://www.rfc-editor.org/rfc/rfc6532.html):
  accept valid UTF-8 header text.
- [RFC 8551 section 3.2.2](https://www.rfc-editor.org/rfc/rfc8551.html):
  treat S/MIME enveloped data, and pkcs7-mime without an smime-type, as encrypted.
  Signed data is not encrypted.

## Selection and rejection

Alternative selects the last plain-text candidate, then the last HTML candidate.
Mixed and unknown multipart types select the first eligible subtree.
Signed content is readable without signature verification.
Inline encapsulated messages can supply a body; attached messages cannot.

A nested entity that the reader cannot parse becomes a placeholder,
and body selection skips it.
Encrypted and partial entities, and text with an unknown charset or invalid bytes,
also cannot supply a body.
These failures do not affect a body in another part.
When no part supplies a body, the message fails with the encrypted error,
then the partial error, then the first other failure.

The root entity fails the message when its header block is invalid,
when it repeats Content-Type, Content-Disposition, or Content-Transfer-Encoding,
or when its multipart body has no closing delimiter or no body parts.
Attachments and other non-text bodies are not decoded or validated.
Address interpretation, rendering, cryptography, composition, and flowed-text
reformatting are outside the reader's scope.

## Deliberate compatibility rules

LF line endings, a missing final newline, MIME linear whitespace, and valid
UTF-8 bodies without a charset are accepted.
The corpus cases lf, utf8, words, and multipart cover these rules.
No legacy charset is guessed.
Invalid UTF-8 in a header line becomes the Unicode replacement character.
An empty entity header block is valid; a root message must have a header.
A nested entity can be empty.
A repeated MIME-Version field is accepted.

Parameter parsing ignores empty parameters, such as one after a final semicolon,
and later parameters with an earlier name.
An unquoted value continues to the next semicolon.
Encoded words longer than 75 characters decode,
and a language suffix after the charset is ignored.

The base64 decoder skips bytes outside the alphabet
and decodes a final group without padding.
The quoted-printable decoder keeps an "=" that does not start an escape,
keeps bytes that the encoding does not permit,
and accepts white space between a soft line break and the line end.
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

The comparison produced these differences:

| Fixture | Observed comparison | Decision |
|---|---|---|
| inline-message | Both comparison body selectors return no body. | Select inline message content, as specified for this reader; RFC 2046 section 5.2.1 defines its encapsulated structure. |
| last-alternative | Python selects the first plain alternative. | Select the last supported plain alternative under RFC 2046 section 5.1.4 and the local plain-text preference. |
| utf8 | Python replaces undeclared non-ASCII body bytes. | Accept valid UTF-8 under the documented recovery rule. |
| bad-base64 | Python returns "a"; MimeFoundation returns an empty body. | Decode the complete bytes, as RFC 2045 section 6.8 permits. |
| duplicate | Both return a body despite duplicate Content-Type. | Reject ambiguous structural fields. |
| truncated | Both return truncated text. | Require the RFC 2046 closing delimiter, and report a malformed message. |
| unknown-charset | MimeFoundation returns text; Python fails conversion. | Reject unknown declared charsets. |
| encrypted, partial | Comparison selectors return no body. | Preserve explicit encrypted and partial error categories. |

For bad-qp and continuation-gap, all three readers return the body.
The continuation-gap fixture has no segment zero,
so this reader ignores its filename under RFC 2231 section 3.
Python normalizes parameter quoting in displayed headers.
Envelope retains unfolded source parameter spelling in header values.
Other successful corpus body expectations agree with MimeFoundation and Python.
These observations support the tests; parser agreement is not the authority.
