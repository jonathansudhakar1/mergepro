import Foundation

/// Why an activity item appeared, from the event category written by the inventory diff or the notification feed.
public enum ActivityReason: String, CaseIterable, Hashable, Sendable {
  case reviewRequested, review, checks, mention, assignment, merge, other
  public init(category: String) {
    switch category {
    case "review requested", "review request signals": self = .reviewRequested
    case "review decision": self = .review
    case "checks", "CI activity signals": self = .checks
    case "mention signals": self = .mention
    case "assignment signals": self = .assignment
    case "merged", "ready to merge", "ready for merge queue": self = .merge
    default: self = .other
    }
  }
  public var title: String {
    switch self {
    case .reviewRequested: "Review requests"
    case .review: "Reviews"
    case .checks: "Checks"
    case .mention: "Mentions"
    case .assignment: "Assignments"
    case .merge: "Merges"
    case .other: "Other"
    }
  }
}

/// The activity items about one subject (a pull request, issue or other notification subject) of one account.
public struct ActivityGroup: Identifiable, Sendable {
  public let id: String
  /// Newest first.
  public let events: [InboxEvent]
  public var newest: InboxEvent { events[0] }
  public var latest: Date { newest.event.occurredAt }
  public var unread: Int { events.filter { !$0.acknowledged }.count }
  /// Distinct reasons in newest-first order.
  public var reasons: [ActivityReason] {
    var seen = Set<ActivityReason>()
    return events.map { ActivityReason(category: $0.event.category) }.filter { seen.insert($0).inserted }
  }
}

public enum ActivityInbox {
  /// Inventory events carry the PR key while notification threads carry a thread key; both locate the subject by
  /// type and number, so they group together. Accounts never share a group.
  static func subjectKey(_ event: ChangeEvent) -> String {
    let o = event.object
    if let locator = event.locator, let number = locator.subjectNumber {
      return [o.host, o.accountID, o.repositoryID, locator.subjectType, number].map { "\($0.utf8.count):\($0)" }.joined()
    }
    return [o.host, o.accountID, o.repositoryID, "object", o.objectID].map { "\($0.utf8.count):\($0)" }.joined()
  }
  /// Groups newest first. `reasons` nil means every reason.
  public static func groups(_ events: [InboxEvent], reasons: Set<ActivityReason>? = nil, unreadOnly: Bool = false) -> [ActivityGroup] {
    var buckets: [String: [InboxEvent]] = [:]
    for item in events {
      if unreadOnly && item.acknowledged { continue }
      if let reasons, !reasons.contains(ActivityReason(category: item.event.category)) { continue }
      buckets[subjectKey(item.event), default: []].append(item)
    }
    let newestFirst: (InboxEvent, InboxEvent) -> Bool = {
      $0.event.occurredAt == $1.event.occurredAt ? $0.id < $1.id : $0.event.occurredAt > $1.event.occurredAt
    }
    return buckets.map { ActivityGroup(id: $0.key, events: $0.value.sorted(by: newestFirst)) }
      .sorted { newestFirst($0.newest, $1.newest) }
  }
  /// Events per reason, for the filter controls.
  public static func counts(_ events: [InboxEvent]) -> [ActivityReason: Int] {
    events.reduce(into: [:]) { $0[ActivityReason(category: $1.event.category), default: 0] += 1 }
  }

  /// Finds the cached pull request an event is about, within the event's own account only.
  public struct PRLookup: Sendable {
    private let keys: Set<ProviderKey>
    private let byNumber: [String: ProviderKey]
    public init(rows: [PullRequest]) {
      keys = Set(rows.map(\.key))
      var numbers: [String: ProviderKey] = [:]
      for pr in rows {
        guard let number = pr.metadata?.number else { continue }
        numbers[Self.compose(pr.key.host, pr.key.accountID, pr.key.repositoryID, String(number))] = pr.key
      }
      byNumber = numbers
    }
    private static func compose(_ parts: String...) -> String { parts.map { "\($0.utf8.count):\($0)" }.joined() }
    public func key(for event: ChangeEvent) -> ProviderKey? {
      if keys.contains(event.object) { return event.object }
      guard let locator = event.locator, locator.subjectType == "PullRequest", let number = locator.subjectNumber else { return nil }
      return byNumber[Self.compose(event.object.host, event.object.accountID, event.object.repositoryID, number)]
    }
  }
}
