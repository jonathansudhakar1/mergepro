import Foundation

public struct QuietHours: Sendable {
    public let startMinute: Int
    public let endMinute: Int
    public let timeZone: TimeZone
    public init(startMinute: Int, endMinute: Int, timeZone: TimeZone = .current) {
        self.startMinute = min(1439,max(0,startMinute)); self.endMinute = min(1439,max(0,endMinute)); self.timeZone = timeZone
    }
    public func contains(_ date: Date) -> Bool {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = timeZone
        let minute = calendar.component(.hour,from:date)*60 + calendar.component(.minute,from:date)
        if startMinute == endMinute { return false }
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }
}
public struct NotificationPolicy: Sendable {
    public var enabled: Bool
    public var mutedAccounts: Set<AccountScope>
    public var mutedRepositories: Set<RepositoryKey>
    public var mutedTeams: Set<String>
    public var categories: Set<String>?
    public var snoozedUntil: Date?
    public var quietHours: QuietHours?
    public var matchingEventKeys: [Set<String>]
    /// Current tracked/liveness scope revalidates deferred events before delivery.
    public var allowedRepositories: Set<RepositoryKey>?
    public init(enabled: Bool = false, mutedAccounts: Set<AccountScope> = [], mutedRepositories: Set<RepositoryKey> = [],
                mutedTeams: Set<String> = [], categories: Set<String>? = nil, snoozedUntil: Date? = nil,
                quietHours: QuietHours? = nil, matchingEventKeys: [Set<String>] = [], allowedRepositories: Set<RepositoryKey>? = nil) {
        self.enabled = enabled; self.mutedAccounts = mutedAccounts; self.mutedRepositories = mutedRepositories
        self.mutedTeams = mutedTeams; self.categories = categories; self.snoozedUntil = snoozedUntil
        self.quietHours = quietHours; self.matchingEventKeys = matchingEventKeys; self.allowedRepositories = allowedRepositories
    }
    public func permits(_ event: ChangeEvent, at date: Date) -> Bool {
        enabled && !(snoozedUntil.map { $0 > date } ?? false) && !(quietHours?.contains(date) ?? false) &&
        !mutedAccounts.contains(event.object.account) && !mutedRepositories.contains(event.object.repository) &&
        event.teams.isDisjoint(with:mutedTeams) && (categories?.contains(event.category) ?? true) &&
        (allowedRepositories?.contains(event.object.repository) ?? true) &&
        (matchingEventKeys.isEmpty || matchingEventKeys.contains { $0.contains(event.key) })
    }
}
public enum NotificationAggregator {
    /// Up to this many subjects (pull requests, runs, threads) notify individually; a larger cycle collapses to one summary.
    public static let individualLimit = 5
    public static func summary(cycleID: UUID, events: [ChangeEvent]) -> PollSummary {
        let unique = Array(Dictionary(events.map { ($0.key,$0) },uniquingKeysWith: { first,_ in first }).values).sorted { $0.key < $1.key }
        let keys = unique.map(\.key)
        let repos = Set(unique.map { $0.object.repository }).count
        let accounts = Set(unique.map { $0.object.account }).count
        let counts = Dictionary(grouping:unique,by:{ NotificationReason.of($0.category).noun }).mapValues(\.count)
        let categories = counts.keys.sorted().map { NotificationReason.count(counts[$0]!,noun:$0) }.joined(separator:", ")
        let body = keys.isEmpty ? "" : "\(keys.count) \(keys.count == 1 ? "update" : "updates") across \(repos) \(repos == 1 ? "repo" : "repos"), \(accounts) \(accounts == 1 ? "account" : "accounts"): \(categories)."
        let items = Dictionary(grouping:unique,by:NotificationItem.subjectID).map { NotificationItem(id:$0.key,events:$0.value) }.sorted { $0.id < $1.id }
        return PollSummary(cycleID:cycleID,eventKeys:keys,title:"MergePro updates",body:body,items:items.count <= individualLimit ? items : [])
    }
}

/// Lock-screen-safe text for one notification. `subtitle` is empty unless provider titles are allowed.
public struct NotificationContent: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let body: String
    public init(title: String, subtitle: String, body: String) { self.title = title; self.subtitle = subtitle; self.body = body }
}

/// Every event of one cycle about one subject in one account: a pull request (by number, so inventory transitions and
/// GitHub notification threads about it merge), or otherwise the event's object (a workflow run, a thread).
public struct NotificationItem: Equatable, Codable, Sendable {
    public let id: String
    public let eventKeys: [String]
    public let account: AccountScope
    public let repositoryName: String?
    public let subjectType: String?
    public let number: String?
    /// The pull request's own key, when an inventory transition carries it; notification threads only identify the thread.
    public let pullRequest: ProviderKey?
    public let webURL: URL?
    public let reasons: [String]
    /// Provider text (pull request title, workflow name). Shown only when the user opts in: it can appear on the lock screen.
    public let subjectTitle: String?
    /// Review applies to a pull request that is still open as far as this cycle knows.
    public let offersReview: Bool

    static func subjectID(_ event: ChangeEvent) -> String {
        let subject: String
        if let type = event.locator?.subjectType, ["PullRequest","Issue"].contains(type), let number = event.locator?.subjectNumber { subject = type + ":" + number }
        else { subject = event.object.objectID }
        // Length-prefixed, so provider strings cannot collide at separators.
        return [event.object.host,event.object.accountID,event.object.repositoryID,subject].map { "\($0.utf8.count):\($0)" }.joined()
    }
    init(id: String, events: [ChangeEvent]) {
        let events = events.sorted { $0.key < $1.key }, first = events[0]
        self.id = id
        eventKeys = events.map(\.key)
        account = first.object.account
        subjectType = first.locator?.subjectType
        number = ["PullRequest","Issue"].contains(subjectType ?? "") ? first.locator?.subjectNumber : nil
        webURL = events.lazy.compactMap { $0.locator?.webURL }.first
        repositoryName = webURL.flatMap(Self.repositoryName)
        let own = events.first { $0.locator?.subjectType == "PullRequest" && !$0.object.objectID.hasPrefix("notification-thread:") }
        pullRequest = own?.object
        subjectTitle = (own.map { [$0] + events } ?? events).lazy.compactMap(\.title).first { !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        let reasons = events.map { NotificationReason.of($0.category) }
        var seen = Set<String>()
        self.reasons = reasons.sorted { ($0.rank,$0.text) < ($1.rank,$1.text) }.map(\.text).filter { seen.insert($0).inserted }
        offersReview = subjectType == "PullRequest" && !events.contains { $0.category == "merged" }
    }
    /// Whether this notification offers "Approve…" (its category with Open, Approve… and Snooze). Like the menu bar,
    /// only for an open pull request whose cached `row` is this item's own pull request and passes
    /// `NotificationApproval.offers`; otherwise the category offers Open and Snooze only.
    public func offersApproval(row: PullRequest?, actionPR: PullRequest?) -> Bool {
        guard offersReview, let row, let pullRequest, row.key == pullRequest else { return false }
        return NotificationApproval.offers(row:row,actionPR:actionPR)
    }
    /// `owner/name` from a GitHub (or GitHub Enterprise) web URL.
    static func repositoryName(_ url: URL) -> String? {
        let parts = url.path.split(separator:"/").map(String.init)
        return parts.count >= 2 ? parts[0] + "/" + parts[1] : nil
    }
    public func content(showingTitles: Bool) -> NotificationContent {
        let kind = subjectType == "Issue" ? "Issue" : "Pull request"
        let title: String
        switch (repositoryName,number) {
        case (let repository?,let number?): title = repository + "#" + number
        case (let repository?,nil): title = repository
        case (nil,let number?): title = kind + " #" + number
        case (nil,nil): title = "MergePro"
        }
        let body = reasons.joined(separator:", ")
        return NotificationContent(title:title,subtitle:showingTitles ? (subjectTitle ?? "") : "",body:body.prefix(1).uppercased() + body.dropFirst())
    }
}

/// "Approve…" from a pull request notification follows the menu bar's rule (`PRMenuBarRules.offersApproval`): the
/// review composer acts as the action account, so it applies only to an open pull request whose own account is the
/// action account and which that account did not author. Otherwise the notification opens the pull request.
public enum NotificationApproval {
    public enum Route: Equatable, Sendable {
        /// The pull request is not cached (only a GitHub notification thread identified it): show its activity.
        case activity
        case openPullRequest
        /// Present the review composer with Approve preselected; nothing is sent until the user submits there.
        case approve
    }
    public static func offers(row: PullRequest, actionPR: PullRequest?) -> Bool {
        row.state == .open && PRMenuBarRules.offersApproval(row:row,actionPR:actionPR)
    }
    /// Where a notification response goes. `approve` is the "Approve…" action; the rule is checked again here, since
    /// the action account (or the pull request) may have changed since the notification was posted.
    public static func route(approve: Bool, row: PullRequest?, actionPR: PullRequest?) -> Route {
        guard let row else { return .activity }
        return approve && offers(row:row,actionPR:actionPR) ? .approve : .openPullRequest
    }
}

/// Readable wording for the categories fetchers emit. Unknown categories pass through unchanged.
struct NotificationReason {
    let text: String
    let noun: String
    let plural: String?
    let rank: Int
    private static let known: [String:(text:String,noun:String,plural:String)] = [
        "review requested":("review requested","review request","review requests"),
        "review request signals":("review requested","review request","review requests"),
        "review decision":("review decision changed","review decision","review decisions"),
        "checks":("checks changed","check update","check updates"),
        "CI activity signals":("CI activity","CI update","CI updates"),
        "ready to merge":("ready to merge","ready to merge","ready to merge"),
        "ready for merge queue":("ready for the merge queue","ready for the merge queue","ready for the merge queue"),
        "merged":("merged","merged pull request","merged pull requests"),
        "mention signals":("you were mentioned","mention","mentions"),
        "assignment signals":("you were assigned","assignment","assignments"),
        "workflow failures":("workflow failed","workflow failure","workflow failures"),
        "workflow status":("workflow status changed","workflow update","workflow updates"),
        "repository activity signals":("new activity","activity update","activity updates"),
    ]
    private static let order = ["review requested","review request signals","mention signals","assignment signals","review decision","checks","CI activity signals",
                                "workflow failures","workflow status","ready to merge","ready for merge queue","merged","repository activity signals"]
    static func of(_ category: String) -> NotificationReason {
        guard let entry = known[category] else { return NotificationReason(text:category,noun:category,plural:nil,rank:order.count) }
        return NotificationReason(text:entry.text,noun:entry.noun,plural:entry.plural,rank:order.firstIndex(of:category) ?? order.count)
    }
    static func count(_ count: Int, noun: String) -> String {
        guard let entry = known.values.first(where:{ $0.noun == noun }) else { return "\(count) \(noun)" }
        return "\(count) \(count == 1 ? entry.noun : entry.plural)"
    }
}
