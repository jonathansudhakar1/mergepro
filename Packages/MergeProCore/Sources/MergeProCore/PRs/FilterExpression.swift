import Foundation

/// Deterministic field:operator/value tokens plus quoted free text. Unknown fields reject input.
public struct FilterExpression: Equatable, Codable, Sendable {
  public enum Field: String, CaseIterable, Codable, Sendable {
    case account, org, repo, pinned, author, authorType, reviewer, request, assignee, label, base,
      head, checks, requiredChecks, mergeable, review, draft, size, age, updated, created, risk,
      eligible, state, ready
  }
  public enum Operator: String, CaseIterable, Codable, Sendable {
    case equals, notEquals, contains, greater, less
  }
  public struct Token: Equatable, Codable, Sendable {
    public var field: Field
    public var operation: Operator
    public var value: String
    public init(field: Field, operation: Operator = .equals, value: String) {
      self.field = field
      self.operation = operation
      self.value = value
    }
  }
  public var tokens: [Token] = []
  public var text: [String] = []
  public init() {}
  public enum ParseError: Error {
    case unknownField, unclosedQuote, invalidValue, unsupportedOperator, invalidEscape
  }
  public var serialized: String {
    func quoted(_ value: String) -> String {
      "\""
        + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
          of: "\"", with: "\\\"") + "\""
    }
    let fields = tokens.map { token in
      let symbol: String =
        switch token.operation {
        case .equals: ""
        case .notEquals: "!"
        case .contains: "~"
        case .greater: ">"
        case .less: "<"
        }
      return token.field.rawValue + ":" + symbol + quoted(token.value)
    }
    return (fields + text.map(quoted)).joined(separator: " ")
  }
  public static func parse(_ input: String) throws -> FilterExpression {
    var parts: [(characters: [Character], separator: Int?, operation: Int?)] = []
    var characters: [Character] = []
    var separator: Int?
    var operation: Int?
    var quoted = false
    var escaped = false
    var active = false
    func finish() {
      if active { parts.append((characters, separator, operation)) }
      characters = []
      separator = nil
      operation = nil
      active = false
    }
    for character in input {
      if escaped {
        characters.append(character)
        escaped = false
        active = true
        continue
      }
      if character == "\\" {
        escaped = true
        active = true
        continue
      }
      if character == "\"" {
        quoted.toggle()
        active = true
        continue
      }
      if character.isWhitespace && !quoted {
        finish()
        continue
      }
      if !quoted {
        if character == ":", separator == nil {
          separator = characters.count
        } else if let colon = separator, characters.count == colon + 1,
          ["!", ">", "<", "~"].contains(character)
        {
          operation = characters.count
        }
      }
      characters.append(character)
      active = true
    }
    guard !escaped else { throw ParseError.invalidEscape }
    guard !quoted else { throw ParseError.unclosedQuote }
    finish()
    var result = FilterExpression()
    for part in parts {
      guard let colon = part.separator else {
        result.text.append(String(part.characters))
        continue
      }
      guard let field = Field(rawValue: String(part.characters[..<colon])) else {
        throw ParseError.unknownField
      }
      var start = colon + 1
      var op = Operator.equals
      if let index = part.operation {
        op =
          switch part.characters[index] {
          case "!": .notEquals
          case ">": .greater
          case "<": .less
          default: .contains
          }
        start += 1
      }
      let value = String(part.characters[start...])
      guard !value.isEmpty else { throw ParseError.invalidValue }
      guard field.supportedOperators.contains(op) else { throw ParseError.unsupportedOperator }
      if field == .age {
        let number = value.hasSuffix("d") ? String(value.dropLast()) : value
        guard let days = Double(number), days.isFinite, days >= 0 else {
          throw ParseError.invalidValue
        }
      }
      if field == .updated || field == .created, Self.dateBound(value) == nil {
        throw ParseError.invalidValue
      }
      result.tokens.append(Token(field: field, operation: op, value: value))
    }
    return result
  }
  public var includesClosed: Bool {
    tokens.contains { $0.field == .state && $0.value == "closed" && $0.operation != .notEquals }
  }
  public func matches(_ pr: PullRequest, now: Date, pinned: Set<RepositoryKey> = []) -> Bool {
    matcher(now: now, pinned: pinned).matches(pr)
  }
  /// Prepared once per projection: lowercased text and parsed thresholds are not rebuilt for every row.
  func matcher(now: Date, pinned: Set<RepositoryKey> = []) -> Matcher {
    Matcher(self, now: now, pinned: pinned)
  }
  /// `updated:`/`created:` thresholds: an ISO-8601 date-time, or a calendar date (`2024-01-01`) read in the
  /// user's time zone. A date-only value spans that whole day: `>` is after the day, `<` is before it, and
  /// `=`/`!` keep their since/not-since meaning from the day's start.
  struct DateBound: Equatable {
    let start: Date
    let end: Date?
  }
  static func dateBound(_ value: String, timeZone: TimeZone = .current) -> DateBound? {
    // Typed filters keep the default formatter's leniency, not `GitHubDate` (pinned in GitHubDateTests).
    if let date = ISO8601DateFormatter().date(from: value) { return DateBound(start: date, end: nil) }
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
      parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isWholeNumber } }),
      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
      calendar.component(.year, from: start) == year, calendar.component(.month, from: start) == month,
      calendar.component(.day, from: start) == day,
      let end = calendar.date(byAdding: .day, value: 1, to: start)
    else { return nil }
    return DateBound(start: start, end: end)
  }
  struct Matcher {
    let expression: FilterExpression
    let now: Date
    let pinned: Set<RepositoryKey>
    private let text: [String]
    private let dates: [DateBound?]
    private let ages: [Double]
    init(_ expression: FilterExpression, now: Date, pinned: Set<RepositoryKey>) {
      self.expression = expression
      self.now = now
      self.pinned = pinned
      text = expression.text.map { $0.lowercased() }
      dates = expression.tokens.map {
        $0.field == .updated || $0.field == .created ? FilterExpression.dateBound($0.value) : nil
      }
      ages = expression.tokens.map { Double($0.value.replacingOccurrences(of: "d", with: "")) ?? .infinity }
    }
    func matches(_ pr: PullRequest) -> Bool {
      let m = pr.metadata
      if !text.isEmpty {
        let searchable = [
          pr.title, m?.repositoryName ?? "", m?.authorLogin ?? "", m?.headBranch ?? "",
          String(m?.number ?? 0),
        ].joined(separator: " ").lowercased()
        guard text.allSatisfy({ searchable.contains($0) }) else { return false }
      }
      return expression.tokens.indices.allSatisfy { index in
        let token = expression.tokens[index]
        guard token.field.supportedOperators.contains(token.operation) else { return false }
        let values: [String]
        switch token.field {
        case .account: values = [pr.key.accountID, pr.key.host]
        case .org: values = [m?.repositoryName.split(separator: "/").first.map(String.init) ?? ""]
        case .repo: values = [m?.repositoryName ?? "", pr.key.repositoryID]
        case .pinned: values = [String(pinned.contains(pr.key.repository))]
        case .author:
          values =
            [m?.authorLogin ?? "", m?.authorID ?? ""] + (m?.viewerIsAuthor == true ? ["me"] : [])
        case .authorType:
          // Bot identity alone never implies agent authorship; AgentClassifier (with manual overrides) decides.
          values = [m?.authorClassification ?? "unknown", m?.actorType?.lowercased() ?? "unknown"]
        case .reviewer: values = m?.reviewers ?? []
        case .request:
          values =
            (pr.needsViewer ? ["me"] : [])
            + (m?.requests.filter(\.isForViewer).map { $0.kind.rawValue } ?? [])
        case .assignee: values = m?.assignees ?? []
        case .label: values = m?.labels ?? []
        case .base: values = [m?.baseBranch ?? ""]
        case .head: values = [m?.headBranch ?? ""]
        case .checks: values = [m?.checks?.lowercased() ?? "unknown"]
        case .requiredChecks:
          values = m?.failingRequiredCheck.map { [$0 ? "failure" : "success"] } ?? ["unknown"]
        case .mergeable: values = [m?.mergeable?.lowercased() ?? "unknown"]
        case .review: values = [m?.reviewDecision?.lowercased() ?? "unknown"]
        case .draft: values = [String(pr.isDraft)]
        case .size: values = [m?.sizeClass.lowercased() ?? "unknown"]
        case .age:
          guard let date = m?.activityDate else { return false }
          let days = now.timeIntervalSince(date) / 86400
          let amount = ages[index]
          let equal = floor(days) == floor(amount)
          return token.operation == .greater
            ? days > amount
            : token.operation == .less
              ? days < amount : token.operation == .notEquals ? !equal : equal
        case .updated, .created:
          guard let date = token.field == .updated ? m?.updatedAt : m?.createdAt,
            let bound = dates[index]
          else { return false }
          switch token.operation {
          case .equals: return date >= bound.start
          case .notEquals: return date < bound.start
          case .greater: return bound.end.map { date >= $0 } ?? (date > bound.start)
          case .less: return date < bound.start
          case .contains: return false
          }
        case .risk: values = m?.riskFlags ?? ["unknown"]
        // Fresh merge evidence only (it expires after `MergePolicy.maximumAge`); "Ready to merge" uses `ready`.
        case .eligible: values = m?.mergeEvidence.map { _ in [String(MergePolicy.evaluate(pr:pr,now:now).eligible)] } ?? ["unknown"]
        // Inventory readiness (`MergePolicy.inventoryReadiness`): true, false or unknown; it never expires by age.
        case .ready:
          switch MergePolicy.inventoryReadiness(pr) {
          case .ready: values = ["true"]
          case .notReady: values = ["false"]
          case .unknown: values = ["unknown"]
          }
        case .state: values = [pr.state.rawValue]
        }
        let match = values.contains { value in
          token.operation == .contains
            ? value.lowercased().contains(token.value.lowercased())
            : token.field == .head
              ? value.lowercased().hasPrefix(token.value.lowercased())
              : value.caseInsensitiveCompare(token.value) == .orderedSame
        }
        return token.operation == .notEquals ? !match : match
      }
    }
  }
}

extension FilterExpression.Field {
  public var supportedOperators: [FilterExpression.Operator] {
    switch self {
    case .age, .updated, .created: [.equals, .notEquals, .greater, .less]
    default: [.equals, .notEquals, .contains]
    }
  }
}
