import Foundation

/// GitHub REST and GraphQL timestamps: `2026-10-01T10:00:00Z`, with a `±hh:mm` offset, and with
/// fractional seconds (Actions step times such as `…T10:00:40.000-07:00`). One shared Sendable parser
/// replaces per-call `ISO8601DateFormatter`s. User-typed filter dates keep their own parsing
/// (`FilterExpression.dateBound`).
public enum GitHubDate {
    private static let whole = Date.ISO8601FormatStyle()
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    public static func parse(_ text: String) -> Date? {
        (try? whole.parse(text)) ?? (try? fractional.parse(text))
    }
}
