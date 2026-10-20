import Foundation

/// Builds the notification policy a poll cycle closes with: app-wide settings (enabled, snooze, quiet hours), account
/// and repository mutes, the authorization overlay, PR notification-rule views (projected with `BoardProjection`) and
/// Actions notification rules. Two steps, so the caller can supply rule rows from its own row cache in between:
/// `scope(database:isAvailable:)` reads no PR rows; `policy(scope:ruleRows:pendingEvents:database:now:)` matches events.
public enum NotificationPolicyAssembly {
    public struct Scope: Sendable, Equatable {
        public var mutedAccounts: Set<AccountScope> = []
        /// Muted tracked repositories, whatever their account's authorization.
        public var mutedRepositories: Set<RepositoryKey> = []
        /// Tracked repositories of accounts whose access is available: the only ones a summary may mention.
        public var allowedRepositories: Set<RepositoryKey> = []
        public var liveRepositories: [Repository] = []
        public var livePins: Set<RepositoryKey> = []
        /// Saved PR views that are notification rules.
        public var rules: [PRSavedView] = []
        public init() {}
    }

    /// Targeted lookups under the same authorization overlay as the workspace: an account that is not available
    /// contributes its mutes only.
    public static func scope(database: DatabaseStore, isAvailable: @Sendable (AccountScope) async throws -> Bool) async throws -> Scope {
        var scope = Scope()
        for account in try database.accounts() {
            let settings = try database.settings(account:account.scope), tracked = try database.trackedRepositories(account:account.scope)
            if settings[.notificationsMuted] == "true" { scope.mutedAccounts.insert(account.scope) }
            scope.mutedRepositories.formUnion(tracked.filter { settings[.notificationsMuted(repositoryID:$0.repositoryID)] == "true" })
            guard try await isAvailable(account.scope) else { continue }
            scope.allowedRepositories.formUnion(tracked)
            scope.liveRepositories += try database.repositories(account:account.scope)
            scope.livePins.formUnion(try database.pins(account:account.scope).map(\.repository))
        }
        scope.rules = try PullRequestStore(database:database).load().views.filter(\.notificationRule)
        return scope
    }

    /// `ruleRows` are the current rows of `scope.allowedRepositories` (unused, and may be empty, without rules);
    /// `pendingEvents` are the events a summary can still deliver (unacknowledged, unsurfaced).
    public static func policy(scope: Scope, ruleRows: [PullRequest], pendingEvents: [ChangeEvent], database: DatabaseStore,
                              now: Date = Date()) throws -> NotificationPolicy {
        let snooze = try database.applicationSetting(.notificationSnoozedUntil).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        var quiet: QuietHours?
        if let start = try database.applicationSetting(.quietHoursStartMinute).flatMap(Int.init),
           let end = try database.applicationSetting(.quietHoursEndMinute).flatMap(Int.init) { quiet = QuietHours(startMinute:start, endMinute:end) }
        let matching = scope.rules.map { rule in
            matchingKeys(BoardProjection(rows:ruleRows, view:rule.configuration, now:now, pinned:scope.livePins).rows, events:pendingEvents)
        }
        let workflowKeys = try ActionsStore(database:database).matchingEventKeys(events:pendingEvents, repositories:scope.liveRepositories)
        let selected = FeatureNotificationRules.matchingKeys(events:pendingEvents, prRules:matching, workflowKeys:workflowKeys)
        return NotificationPolicy(enabled:try database.applicationSetting(.notificationsEnabled) == "true", mutedAccounts:scope.mutedAccounts,
            mutedRepositories:scope.mutedRepositories, snoozedUntil:snooze, quietHours:quiet, matchingEventKeys:[selected],
            allowedRepositories:scope.allowedRepositories)
    }

    /// Keys of events about one of `rows`: by provider key, or by repository and PR number for notification threads.
    /// Indexed so each event is one lookup, not a scan of the rule's rows.
    static func matchingKeys(_ rows: [PullRequest], events: [ChangeEvent]) -> Set<String> {
        let keys = Set(rows.map(\.key))
        let numbers = Set(rows.compactMap { pr in pr.metadata.map { NumberedPR(repository:pr.key.repository, number:String($0.number)) } })
        return Set(events.filter { event in
            keys.contains(event.object) || (event.locator?.subjectType == "PullRequest" && event.locator?.subjectNumber.map {
                numbers.contains(NumberedPR(repository:event.object.repository, number:$0))
            } == true)
        }.map(\.key))
    }
    private struct NumberedPR: Hashable { let repository: RepositoryKey; let number: String }
}
