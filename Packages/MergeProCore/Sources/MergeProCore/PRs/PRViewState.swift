import Foundation

public enum PRColumn: String, Codable, Sendable, CaseIterable { case draft, open, approved, merged }
public struct PRSelection: Equatable, Codable, Sendable {
  public var focused: ProviderKey?
  public var selected: Set<ProviderKey>
  public init(focused: ProviderKey? = nil, selected: Set<ProviderKey> = []) {
    self.focused = focused
    self.selected = selected
  }
  public mutating func preserve(in rows: [PullRequest]) {
    let keys = Set(rows.map(\.key))
    selected.formIntersection(keys)
    if let focused, !keys.contains(focused) { self.focused = rows.first?.key }
  }
}
public enum PRTimeScope: String, CaseIterable, Codable, Sendable {
  case lastHour, today, last24Hours, last3Days, last7Days, last30Days, allTime, custom
  public var title: String {
    switch self {
    case .lastHour: "Last hour"
    case .today: "Today"
    case .last24Hours: "Last 24 hours"
    case .last3Days: "Last 3 days"
    case .last7Days: "Last 7 days"
    case .last30Days: "Last 30 days"
    case .allTime: "All time"
    case .custom: "Custom range"
    }
  }
  public func lowerBound(now: Date, calendar: Calendar = .current) -> Date? {
    switch self {
    case .lastHour: now.addingTimeInterval(-3600)
    case .today: calendar.startOfDay(for: now)
    case .last24Hours: now.addingTimeInterval(-86400)
    case .last3Days: now.addingTimeInterval(-3 * 86400)
    case .last7Days: now.addingTimeInterval(-7 * 86400)
    case .last30Days: now.addingTimeInterval(-30 * 86400)
    case .allTime, .custom: nil
    }
  }
}
public struct PRViewConfiguration: Equatable, Codable, Sendable {
  public enum Mode: String, CaseIterable, Codable, Sendable { case board, list }
  public enum Grouping: String, CaseIterable, Codable, Sendable {
    case none, org, repository, author, authorType
  }
  public enum Sort: String, CaseIterable, Codable, Sendable {
    case updated, created, timeInColumn, size, checks, repository, number, title, author, review,
      age, labels, mergeability
  }
  public enum MeasuredField: String, CaseIterable, Codable, Sendable {
    case activity, created, updated
  }
  public enum TableColumn: String, CaseIterable, Codable, Sendable {
    case repository, number, title, author, checks, review, size, age, updated, labels, mergeability
  }
  public var mode: Mode = .board
  public var filter = FilterExpression()
  public var grouping: Grouping = .none
  public var sort: Sort = .updated
  public var ascending = false
  public var separateStackLayers:Bool?
  public var compact = false
  public var showDrafts = false
  public var hideMerged = false
  public var mergedDays = 7
  public var timeScope: PRTimeScope = .last30Days
  public var measuredField: MeasuredField = .activity
  public var customStart: Date?
  public var customEnd: Date?
  public var keepWaitingOnMe = false
  public var columns: [TableColumn] = [
    .repository, .number, .title, .author, .checks, .review, .updated,
  ]
  public var collapsedLanes: Set<String> = []
  public init() {}
}
public struct PRSavedView: Equatable, Codable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var icon: String
  public var configuration: PRViewConfiguration
  public var hidden = false
  public var isDefault = false
  public var notificationRule = false
  public init(
    id: UUID = UUID(), name: String, icon: String = "line.3.horizontal.decrease.circle",
    configuration: PRViewConfiguration = PRViewConfiguration()
  ) {
    self.id = id
    self.name = name
    self.icon = icon
    self.configuration = configuration
  }
}
public struct PRViewState: Equatable, Codable, Sendable {
  public var views: [PRSavedView]
  public var currentViewID: UUID?
  public var current = PRViewConfiguration()
  public var selection = PRSelection()
  public var scrollAnchor: ProviderKey?
  public var lastSeenAt: Date?
  public var lastLookAt: Date?
  public mutating func beginLook(at date:Date) -> Date {
    let cutoff=max(lastSeenAt ?? .distantPast,lastLookAt ?? .distantPast)
    lastLookAt=date
    return cutoff == .distantPast ? date : cutoff
  }
  public var recentRoutes: [ProviderKey] = []
  public var accountFilter: AccountScope?
  public var navigationHistory: [PRNavigationVisit]? { didSet { indexNavigation() } }
  /// Position of each key in `navigationHistory`, so ranking a row is a lookup rather than a scan of up to
  /// 1,000 visits. Derived: never encoded, rebuilt whenever the history changes or is decoded.
  private var navigationIndex: [ProviderKey: Int] = [:]
  public var globalShortcuts: PRGlobalShortcuts?
  private enum CodingKeys: String, CodingKey {
    case views, currentViewID, current, selection, scrollAnchor, lastSeenAt, lastLookAt, recentRoutes,
      accountFilter, navigationHistory, globalShortcuts
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    views = try c.decode([PRSavedView].self, forKey: .views)
    currentViewID = try c.decodeIfPresent(UUID.self, forKey: .currentViewID)
    current = try c.decode(PRViewConfiguration.self, forKey: .current)
    selection = try c.decode(PRSelection.self, forKey: .selection)
    scrollAnchor = try c.decodeIfPresent(ProviderKey.self, forKey: .scrollAnchor)
    lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
    lastLookAt = try c.decodeIfPresent(Date.self, forKey: .lastLookAt)
    recentRoutes = try c.decode([ProviderKey].self, forKey: .recentRoutes)
    accountFilter = try c.decodeIfPresent(AccountScope.self, forKey: .accountFilter)
    navigationHistory = try c.decodeIfPresent([PRNavigationVisit].self, forKey: .navigationHistory)
    globalShortcuts = try c.decodeIfPresent(PRGlobalShortcuts.self, forKey: .globalShortcuts)
    indexNavigation()
  }
  private mutating func indexNavigation() {
    var index: [ProviderKey: Int] = [:]
    for (position, visit) in (navigationHistory ?? []).enumerated() where index[visit.key] == nil {
      index[visit.key] = position
    }
    navigationIndex = index
  }
  public mutating func invalidate(_ account: AccountScope) {
    selection.selected = selection.selected.filter { $0.account != account }
    if selection.focused?.account == account { selection.focused = nil }
    if scrollAnchor?.account == account { scrollAnchor = nil }
    if accountFilter == account { accountFilter = nil }
    recentRoutes.removeAll { $0.account == account }
    navigationHistory?.removeAll { $0.key.account == account }
  }
  public mutating func recordVisit(_ key: ProviderKey, at date: Date = Date()) {
    var history = navigationHistory ?? []
    if let index = navigationIndex[key] {
      history[index].opens += 1
      history[index].lastOpenedAt = date
    } else {
      history.append(PRNavigationVisit(key: key, opens: 1, lastOpenedAt: date))
    }
    navigationHistory = Array(history.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.prefix(1000))
  }
  public func navigationScore(_ key: ProviderKey, at date: Date = Date()) -> Double {
    guard let index = navigationIndex[key], let visit = navigationHistory?[index] else { return 0 }
    let ageDays = max(0, date.timeIntervalSince(visit.lastOpenedAt) / 86400)
    return log2(Double(visit.opens) + 1) / (1 + ageDays)
  }
  public init() {
    let builtins: [(String, String)] = [
      ("All PRs", ""), ("Needs my review", "request:me"), ("My PRs", "author:me"),
      ("AI-authored", "authorType:agent"), ("Ready to merge", Self.readyToMergeQuery),
      ("Failing checks", "requiredChecks:failure"), ("Stale", "age:>7d"),
    ]
    views = builtins.map { name, query in
      var config = PRViewConfiguration()
      config.filter = (try? FilterExpression.parse(query)) ?? FilterExpression()
      return PRSavedView(name: name, configuration: config)
    }
    views[0].isDefault = true
    currentViewID = views[0].id
  }
  /// The built-in "Ready to merge" view filters on inventory readiness (`MergePolicy.inventoryReadiness`),
  /// which doesn't expire every minute like merge evidence did under its former `eligible:true` query.
  public static let readyToMergeQuery = "ready:true"
  /// Moves a stored built-in "Ready to merge" view (and the current configuration showing it) from the legacy
  /// `eligible:true` query to `readyToMergeQuery`. Views a user created or edited are left alone.
  /// Returns whether anything changed.
  public mutating func migrateLegacyBuiltins() -> Bool {
    guard let legacy = try? FilterExpression.parse("eligible:true"),
      let ready = try? FilterExpression.parse(Self.readyToMergeQuery)
    else { return false }
    var changed = false
    for index in views.indices
    where views[index].name == "Ready to merge" && views[index].configuration.filter == legacy {
      views[index].configuration.filter = ready
      if views[index].id == currentViewID, current.filter == legacy { current.filter = ready }
      changed = true
    }
    return changed
  }
}
