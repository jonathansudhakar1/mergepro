import XCTest
@testable import MergeProCore

/// One Sendable GitHub timestamp parser replaces per-call ISO8601DateFormatters.
final class GitHubDateTests: XCTestCase {
    /// The shapes GitHub's REST and GraphQL APIs emit parse exactly as the default formatter did.
    func testMatchesTheFormerFormatterForGitHubTimestamps() {
        let former = ISO8601DateFormatter()
        for text in ["2026-10-01T10:00:00Z", "2026-01-01T00:00:00Z", "2026-10-01T10:00:00-07:00", "2026-10-01T10:00:00+05:30", "2026-10-01T10:00:00+0530", "1999-12-31T23:59:59Z"] {
            XCTAssertNotNil(GitHubDate.parse(text), text)
            XCTAssertEqual(GitHubDate.parse(text), former.date(from: text), text)
        }
        XCTAssertEqual(GitHubDate.parse("2026-10-01T10:00:00Z"), Date(timeIntervalSince1970: 1_790_848_800))
        XCTAssertEqual(GitHubDate.parse("2026-10-01T10:00:00-07:00"), Date(timeIntervalSince1970: 1_790_848_800 + 7 * 3600))
    }
    /// Actions step times carry fractional seconds, with Z or an offset (formerly a second formatter).
    func testAcceptsFractionalSeconds() throws {
        let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds); return f }()
        for text in ["2026-10-01T10:00:40.000-07:00", "2026-10-01T10:00:00.123Z", "2026-10-01T10:00:00.5+05:30"] {
            let parsed = try XCTUnwrap(GitHubDate.parse(text), text)
            let expected = try XCTUnwrap(fractional.date(from: text), text)
            XCTAssertEqual(parsed.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001, text)
        }
    }
    func testRejectsNonTimestamps() {
        for text in ["", "garbage", "2026-10-01", "2026-10-01T10:00:00", "2026-13-01T10:00:00Z", "2026-10-01 10:00:00Z", "20261001T100000Z"] {
            XCTAssertNil(GitHubDate.parse(text), text)
        }
    }
    /// Pins the user-typed `updated:`/`created:` parsing, which deliberately keeps the default formatter's
    /// leniency: no fractional seconds, a leading space tolerated, date-only values span the local day.
    func testFilterDateBoundKeepsItsOwnLeniency() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(FilterExpression.dateBound("2026-10-01T10:00:00Z", timeZone: utc), .init(start: Date(timeIntervalSince1970: 1_790_848_800), end: nil))
        XCTAssertEqual(FilterExpression.dateBound("2026-10-01T10:00:00-07:00", timeZone: utc), .init(start: Date(timeIntervalSince1970: 1_790_848_800 + 7 * 3600), end: nil))
        XCTAssertEqual(FilterExpression.dateBound(" 2026-10-01T10:00:00Z", timeZone: utc), .init(start: Date(timeIntervalSince1970: 1_790_848_800), end: nil))
        XCTAssertNil(FilterExpression.dateBound("2026-10-01T10:00:00.5Z", timeZone: utc), "fractional seconds stay rejected for typed filters")
        XCTAssertNil(FilterExpression.dateBound("2026-10-01T10:00:60Z", timeZone: utc))
        XCTAssertNil(FilterExpression.dateBound("2026-02-30", timeZone: utc))
        let day = try XCTUnwrap(FilterExpression.dateBound("2026-10-01", timeZone: utc))
        XCTAssertEqual(day.start, Date(timeIntervalSince1970: 1_790_812_800))
        XCTAssertEqual(day.end, Date(timeIntervalSince1970: 1_790_812_800 + 86_400))
    }
}
