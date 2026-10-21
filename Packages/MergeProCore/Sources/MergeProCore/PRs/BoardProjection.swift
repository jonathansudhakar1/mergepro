import Foundation

public struct BoardProjection: Sendable {
  public let rows: [PullRequest]
  public let columns: [PRColumn: [PullRequest]]
  /// Rows hidden by the time scope or merged window, counted in the column they would appear in.
  public let olderHidden: [PRColumn: Int]
  /// Closed, unmerged rows hidden by the time scope. They never appear in a column, so they are not
  /// counted in `olderHidden`.
  public let closedHidden: Int
  public let lanes: [String: [PullRequest]]
  public var hiddenCount: Int { olderHidden.values.reduce(0, +) + closedHidden }
  public static func column(for pr: PullRequest, showDrafts: Bool) -> PRColumn {
    if pr.state == .merged { return .merged }
    if pr.isDraft { return showDrafts ? .draft : .open }
    if pr.metadata?.reviewDecision == "APPROVED" { return .approved }
    // No-required-review fallback only with complete authoritative requirements/reviews.
    if let m = pr.metadata, m.reviewEvidenceComplete, m.requiredReviewCount == 0,
      (m.approvalCount ?? 0) > 0, m.outstandingChanges == false
    {
      return .approved
    }
    return .open
  }
  public static func count(
    rows: [PullRequest], view: PRViewConfiguration, now: Date = Date(),
    pinned: Set<RepositoryKey> = []
  ) -> Int {
    filtered(rows: rows, view: view, now: now, pinned: pinned).visible.count
  }
  private static func filtered(
    rows source: [PullRequest], view: PRViewConfiguration, now: Date, pinned: Set<RepositoryKey>
  ) -> (visible: [PullRequest], hidden: [PRColumn: Int], closedHidden: Int) {
    var visible: [PullRequest] = []
    var hidden: [PRColumn: Int] = [:]
    var closedHidden = 0
    let lower = view.timeScope == .custom ? view.customStart : view.timeScope.lowerBound(now: now)
    let matcher = view.filter.matcher(now: now, pinned: pinned)
    let includesClosed = view.filter.includesClosed
    for pr in source {
      guard pr.state != .closed || includesClosed, matcher.matches(pr) else { continue }
      let column = Self.column(for: pr, showDrafts: view.showDrafts)
      if column == .merged && view.hideMerged { continue }
      let m = pr.metadata
      let measured: Date? =
        switch view.measuredField {
        case .activity: m?.activityDate
        case .created: m?.createdAt
        case .updated: m?.updatedAt
        }
      let outsideScope = lower.map { cutoff in measured.map { $0 < cutoff } ?? true } ?? false
      let outsideEnd =
        view.timeScope == .custom
        && (view.customEnd.map { end in measured.map { $0 > end } ?? true } ?? false)
      let outsideMerged =
        column == .merged
        && (m?.mergedAt.map {
          $0 < now.addingTimeInterval(-Double(max(1, view.mergedDays)) * 86400)
        } ?? true)
      if (outsideScope || outsideEnd || outsideMerged) && !(view.keepWaitingOnMe && pr.needsViewer)
      {
        if pr.state == .closed { closedHidden += 1 } else { hidden[column, default: 0] += 1 }
        continue
      }
      visible.append(pr)
    }
    return (visible, hidden, closedHidden)
  }
  public init(
    rows source: [PullRequest], view: PRViewConfiguration, now: Date = Date(),
    pinned: Set<RepositoryKey> = []
  ) {
    let result = Self.filtered(rows: source, view: view, now: now, pinned: pinned)
    self.init(
      arranged: result.visible, view: view, hidden: result.hidden, closedHidden: result.closedHidden)
  }
  /// Sorts and groups rows that already passed this view's filter and time scope (collapsed stack cards),
  /// without evaluating the filter again.
  public init(arranging rows: [PullRequest], view: PRViewConfiguration) {
    self.init(arranged: rows, view: view, hidden: [:], closedHidden: 0)
  }
  private init(
    arranged visible: [PullRequest], view: PRViewConfiguration, hidden: [PRColumn: Int],
    closedHidden: Int
  ) {
    rows = Self.sorted(visible, view: view)
    olderHidden = hidden
    self.closedHidden = closedHidden
    columns = Dictionary(
      grouping: rows.filter { $0.state != .closed },
      by: { Self.column(for: $0, showDrafts: view.showDrafts) })
    lanes = Dictionary(
      grouping: rows,
      by: { row in
        switch view.grouping {
        case .none: "All"
        case .org:
          row.metadata?.repositoryName.split(separator: "/").first.map(String.init) ?? "Unknown"
        case .repository: row.metadata?.repositoryName ?? "Unknown"
        case .author: row.metadata?.authorLogin ?? "Unknown"
        case .authorType: row.metadata?.authorClassification ?? row.metadata?.actorType ?? "Unknown"
        }
      })
  }
  /// Sort keys are computed once per row rather than once per comparison.
  private static func sorted(_ rows: [PullRequest], view: PRViewConfiguration) -> [PullRequest] {
    func value(_ row: PullRequest) -> String {
      let m = row.metadata
      switch view.sort {
      case .repository: return m?.repositoryName.lowercased() ?? ""
      case .title: return row.title.lowercased()
      case .author: return m?.authorLogin ?? ""
      case .checks: return m?.checks ?? ""
      case .review: return m?.reviewDecision ?? ""
      case .labels: return m?.labels.joined(separator: ",") ?? ""
      case .mergeability: return m?.mergeable ?? ""
      default: return ""
      }
    }
    func number(_ row: PullRequest) -> Double {
      let m = row.metadata
      switch view.sort {
      case .updated: return m?.updatedAt?.timeIntervalSince1970 ?? 0
      case .created, .age: return m?.createdAt?.timeIntervalSince1970 ?? 0
      case .timeInColumn: return m?.columnChangedAt?.timeIntervalSince1970 ?? 0
      case .size: return Double(m?.size ?? -1)
      case .number: return Double(m?.number ?? 0)
      default: return 0
      }
    }
    let numeric = [PRViewConfiguration.Sort.updated, .created, .age, .timeInColumn, .size, .number]
      .contains(view.sort)
    let keyed = rows.map { row in
      (row: row, number: numeric ? number(row) : 0, text: numeric ? "" : value(row))
    }
    return keyed.sorted { a, b in
      if numeric, a.number != b.number {
        return view.ascending ? a.number < b.number : a.number > b.number
      }
      if !numeric, a.text != b.text {
        return view.ascending ? a.text < b.text : a.text > b.text
      }
      // Ties fall back to the newest pull request number rather than the key's string order (#1, #10, #100).
      if let m = a.row.metadata?.number, let n = b.row.metadata?.number, m != n { return m > n }
      let x = a.row.key
      let y = b.row.key
      return (x.host, x.accountID, x.repositoryID, x.objectID)
        < (y.host, y.accountID, y.repositoryID, y.objectID)
    }.map(\.row)
  }
}

/// Board cards arranged once per projection — lanes → columns → closed — with the keyboard order, so views
/// and keyboard commands read precomputed values instead of regrouping rows on every update.
public struct PRBoardLayout: Sendable {
  public struct Lane: Sendable, Identifiable {
    public let id: String
    public let columns: [PRColumn: [PullRequest]]
    public let closed: [PullRequest]
    public func cards(_ column: PRColumn) -> [PullRequest] { columns[column] ?? [] }
  }
  /// Filtered rows before stack collapse: hidden counts, list rows and batch selection.
  public let projection: BoardProjection
  /// Collapsed cards; each stack's visible representative owns its lane.
  public let cards: BoardProjection
  public let lanes: [Lane]
  /// Lanes → columns → closed cards, omitting collapsed lanes. Keyboard focus never lands on a hidden card.
  public let navigationKeys: [ProviderKey]
  public init(
    projection: BoardProjection = BoardProjection(rows: [], view: PRViewConfiguration()),
    stacks: PRStackProjection = PRStackProjection(), view: PRViewConfiguration = PRViewConfiguration(),
    expanded: Set<String> = []
  ) {
    self.projection = projection
    let cards = BoardProjection(
      arranging: StackGraph.visibleCards(
        projection.rows, projection: stacks, expanded: expanded,
        separate: view.separateStackLayers == true), view: view)
    self.cards = cards
    let lanes = cards.lanes.keys.sorted().map { lane in
      let rows = cards.lanes[lane] ?? []
      return Lane(
        id: lane,
        columns: Dictionary(
          grouping: rows.filter { $0.state != .closed },
          by: { BoardProjection.column(for: $0, showDrafts: view.showDrafts) }),
        closed: rows.filter { $0.state == .closed })
    }
    self.lanes = lanes
    navigationKeys = lanes.filter { view.grouping == .none || !view.collapsedLanes.contains($0.id) }
      .flatMap { lane in PRColumn.allCases.flatMap { lane.cards($0) } + lane.closed }.map(\.key)
  }
}

/// Row-derived workspace state. Stacks are rebuilt only when rows change; `layout` is pure and `Sendable`,
/// so filter edits can be projected off the main actor and never rebuild stacks.
public struct PRBoardPipeline: Sendable {
  public private(set) var rows: [PullRequest] = []
  public private(set) var stacks = PRStackProjection()
  /// Increments once per stack rebuild.
  public private(set) var stackRevision = 0
  public init(rows: [PullRequest] = []) { update(rows: rows) }
  /// Returns whether rows changed (and stacks were rebuilt).
  @discardableResult public mutating func update(rows next: [PullRequest]) -> Bool {
    guard next != rows else { return false }
    rows = next
    stacks = PRStackProjection(rows: next)
    stackRevision += 1
    return true
  }
  public func scoped(_ accountFilter: AccountScope?) -> [PullRequest] {
    accountFilter.map { scope in rows.filter { $0.key.account == scope } } ?? rows
  }
  public func layout(
    view: PRViewConfiguration, accountFilter: AccountScope? = nil, pinned: Set<RepositoryKey> = [],
    expanded: Set<String> = [], now: Date = Date()
  ) -> PRBoardLayout {
    layout(
      projection: BoardProjection(rows: scoped(accountFilter), view: view, now: now, pinned: pinned),
      view: view, expanded: expanded)
  }
  /// Collapses an existing projection again (e.g. after expanding a stack) without refiltering rows.
  public func layout(projection: BoardProjection, view: PRViewConfiguration, expanded: Set<String>)
    -> PRBoardLayout
  {
    PRBoardLayout(projection: projection, stacks: stacks, view: view, expanded: expanded)
  }
  /// Saved-view badge counts over the same account scope.
  public func counts(
    views: [PRSavedView], accountFilter: AccountScope? = nil, pinned: Set<RepositoryKey> = [],
    now: Date = Date()
  ) -> [UUID: Int] {
    let scoped = scoped(accountFilter)
    return Dictionary(
      views.map {
        ($0.id, BoardProjection.count(rows: scoped, view: $0.configuration, now: now, pinned: pinned))
      }, uniquingKeysWith: { first, _ in first })
  }
}
