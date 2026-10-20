import XCTest

@testable import MergeProCore

final class PRFilterRoundTripTests: XCTestCase {
  func testQuotedColonFreeTextAndEscapedLabelRoundTrip() throws {
    let input = #""fix: retry" label:"needs review: \"careful\" \\ path" head:~"feature branch""#
    let expression = try FilterExpression.parse(input)
    XCTAssertEqual(expression.text, ["fix: retry"])
    XCTAssertEqual(expression.tokens[0].value, #"needs review: "careful" \ path"#)
    XCTAssertEqual(try FilterExpression.parse(expression.serialized), expression)
    var literal = FilterExpression()
    literal.text = ["colon: value", #"say "hello" \path"#]
    literal.tokens = [.init(field: .label, value: "!literal label")]
    XCTAssertEqual(try FilterExpression.parse(literal.serialized), literal)
  }
  func testUpdatedNegationComplementsSinceAndRejectsUnsupportedOperators() throws {
    let threshold = "2026-10-01T10:00:00Z"
    var metadata = PRMetadata(
      number: 1, webURL: URL(string: "https://github.com/o/r/pull/1")!, repositoryName: "o/r")
    metadata.updatedAt = ISO8601DateFormatter().date(from: "2026-10-01T11:00:00Z")
    let pr = PullRequest(
      key: ProviderKey(host: "github.com", accountID: "a", repositoryID: "r", objectID: "pr"),
      headRevision: RevisionID("sha"), title: "fix: retry", state: .open, isDraft: false,
      metadata: metadata)
    XCTAssertTrue(try FilterExpression.parse("updated:\(threshold)").matches(pr, now: Date()))
    XCTAssertFalse(try FilterExpression.parse("updated:!\(threshold)").matches(pr, now: Date()))
    XCTAssertThrowsError(try FilterExpression.parse("updated:~\(threshold)"))
    XCTAssertThrowsError(try FilterExpression.parse("label:>bug"))
    XCTAssertThrowsError(try FilterExpression.parse("age:>banana"))
  }
  func testDateOnlyUpdatedAndCreatedComparisonsUseLocalDaysAndRoundTrip() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    var metadata = PRMetadata(
      number: 1, webURL: URL(string: "https://github.com/o/r/pull/1")!, repositoryName: "o/r")
    metadata.updatedAt = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 23, minute: 30))
    metadata.createdAt = calendar.date(from: DateComponents(year: 2023, month: 12, day: 31, hour: 0, minute: 15))
    let pr = PullRequest(
      key: ProviderKey(host: "github.com", accountID: "a", repositoryID: "r", objectID: "pr"),
      headRevision: RevisionID("sha"), title: "t", state: .open, isDraft: false, metadata: metadata)
    let expectations: [(String, Bool)] = [
      ("updated:>2024-01-01", false), ("updated:>2023-12-31", true), ("updated:2024-01-01", true),
      ("updated:!2024-01-01", false), ("updated:<2024-01-02", true), ("updated:<2024-01-01", false),
      ("created:<2024-01-01", true), ("created:2023-12-31", true), ("created:>2023-12-31", false),
      ("created:!2024-01-01", true),
    ]
    for (query, expected) in expectations {
      let expression = try FilterExpression.parse(query)
      XCTAssertEqual(try FilterExpression.parse(expression.serialized), expression, query)
      XCTAssertEqual(expression.tokens.first?.value, String(query.split(separator: ":")[1].drop { "<>!".contains($0) }))
      XCTAssertEqual(expression.matches(pr, now: Date()), expected, query)
    }
    XCTAssertThrowsError(try FilterExpression.parse("updated:>2024-02-30"))
    XCTAssertThrowsError(try FilterExpression.parse("updated:>2024-1-1"))
    XCTAssertThrowsError(try FilterExpression.parse("created:~2024-01-01"))
    let pacific = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    XCTAssertEqual(
      FilterExpression.dateBound("2024-01-01", timeZone: pacific)?.start,
      ISO8601DateFormatter().date(from: "2024-01-01T08:00:00Z"), "date-only values start at local midnight")
    XCTAssertEqual(
      FilterExpression.dateBound("2024-01-01", timeZone: pacific)?.end,
      ISO8601DateFormatter().date(from: "2024-01-02T08:00:00Z"))
    XCTAssertNil(FilterExpression.dateBound("2026-10-01T10:00:00Z")?.end, "date-times keep exact comparisons")
  }
}
