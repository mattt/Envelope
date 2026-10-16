import Testing

/// The parent suite of the Mail tests.
///
/// Connection admission is shared by the whole process,
/// so the nested suites run one test at a time.
@Suite(.serialized)
struct MailTests {}
