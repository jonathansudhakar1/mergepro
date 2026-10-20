import Foundation

/// A transition key includes account, object kind and revision/attempt/status identity.
/// GitHub feed threads are signals; they do not assert PR/check state transitions.
public struct ChangeEvent: Hashable, Codable, Sendable {
    public let key: String
    public let object: ProviderKey
    public let category: String
    public let occurredAt: Date
    public let title: String?
    public let locator: EventLocator?
    public let teams: Set<String>
    public init(key: String, object: ProviderKey, category: String, occurredAt: Date,
                title: String? = nil, locator: EventLocator? = nil, teams: Set<String> = []) {
        self.key = key; self.object = object; self.category = category; self.occurredAt = occurredAt
        self.title = title; self.locator = locator; self.teams = teams
    }
}
/// Explicit subject location; a PR number is never confused with the provider's database ID.
public struct EventLocator: Hashable, Codable, Sendable {
    public let subjectType: String
    public let subjectNumber: String?
    public let webURL: URL?
    public init(subjectType: String, subjectNumber: String? = nil, webURL: URL? = nil) {
        self.subjectType = subjectType; self.subjectNumber = subjectNumber; self.webURL = webURL
    }
}
public struct InboxEvent: Identifiable, Equatable, Codable, Sendable {
    public var id: String { event.key }
    public let event: ChangeEvent
    public let acknowledged: Bool
    public let surfaced: Bool
}
public struct PollSummary: Equatable, Codable, Sendable {
    public let cycleID: UUID
    public let eventKeys: [String]
    public let title: String
    public let body: String
    /// One notification per subject when the cycle is small; empty when it collapses to `title`/`body`.
    public let items: [NotificationItem]
    public init(cycleID: UUID, eventKeys: [String], title: String, body: String, items: [NotificationItem] = []) {
        self.cycleID = cycleID; self.eventKeys = eventKeys; self.title = title; self.body = body; self.items = items
    }
    private enum CodingKeys: String, CodingKey { case cycleID, eventKeys, title, body, items }
    /// This summary without `account`'s subjects (titles, web URLs, repository names) and without those
    /// event keys plus `eventKeys`; nil when nothing would change. Title and body hold only counts.
    func removing(account: AccountScope, eventKeys removed: Set<String>) -> PollSummary? {
        let dropped = items.filter { $0.account == account }
        let keys = removed.union(dropped.flatMap(\.eventKeys))
        let kept = eventKeys.filter { !keys.contains($0) }
        guard !dropped.isEmpty || kept.count != eventKeys.count else { return nil }
        return PollSummary(cycleID:cycleID,eventKeys:kept,title:title,body:body,items:items.filter { $0.account != account })
    }
    /// Summaries stored before per-subject notifications have no items.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cycleID = try container.decode(UUID.self, forKey: .cycleID); eventKeys = try container.decode([String].self, forKey: .eventKeys)
        title = try container.decode(String.self, forKey: .title); body = try container.decode(String.self, forKey: .body)
        items = try container.decodeIfPresent([NotificationItem].self, forKey: .items) ?? []
    }
}
public protocol NotificationSink: Sendable {
    func post(_ summary: PollSummary) async throws
}
