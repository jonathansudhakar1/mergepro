import Foundation
import MergeProCore

/// The App's storage adapter over Core: `AppServices` (the store, the account session and provider services),
/// `NotificationPolicyAssembly` and the workspace's `WorkspaceRowCache`. Feature extensions (SetupStorage+*.swift)
/// reach the services through the accessors below. What differs in the fixture app comes from `dependencies`.
actor SetupStorage {
    nonisolated let dependencies: AppDependencies
    private let services: AppServices
    private var rows = WorkspaceRowCache()
    private var visibleActionRepositories:[UUID:RepositoryKey] = [:]
    /// Repositories on screen that only need the faster cadence (e.g. a repository PR tab); unlike
    /// `visibleActionRepositories` they never add untracked repositories to the collector.
    private var focusedRepositoryViews:[UUID:Set<RepositoryKey>] = [:]
    init(dependencies: AppDependencies = .forThisApp()) {
        self.dependencies = dependencies
        let directoryName = dependencies.storageDirectoryName, fixtures = dependencies.fixtures
        services = AppServices(.init(
            directory:{
                guard let directoryName else { throw CocoaError(.fileReadNoPermission) }
                return try AppServices.Configuration.applicationSupport(directoryName)()
            },
            credentials:dependencies.credentials, transport:dependencies.transport, pollFetchers:dependencies.pollFetchers,
            mergeAdapter:dependencies.mergeAdapter, prepareDatabase:{ try fixtures?.seed($0) }))
    }
    var rateBudget: RateBudget { services.budget }
    func stores() throws -> (DatabaseStore, CacheStore) { try services.stores() }
    func accountSession() throws -> GitHubAccountSession { try services.accountSession() }
    func actionsService() throws -> ActionsService { try services.actionsService() }
    func repositoryBrowserService() throws -> RepositoryBrowserService { try services.repositoryBrowserService() }
    func pollingStore() throws -> PollCycleStore { try services.pollingStore() }
    func notificationThreadCoordinator() throws -> NotificationThreadCoordinator { try services.notificationThreadCoordinator() }
    func detailService() throws -> PRDetailService { try services.detailService() }
    func writeCoordinator() throws -> PRWriteCoordinator { try services.writeCoordinator() }
    func mergeCoordinator() throws -> MergeCoordinator { try services.mergeCoordinator() }

    // MARK: Polling and notifications

    /// A tracked repository refreshed by the poller within 60 s, or an untracked one read within 2 min, returns
    /// its stored status without a request (`didFetch == false`).
    func refreshRepositoryPRs(_ key:RepositoryKey) async throws -> (status:PRInventoryStatus,didFetch:Bool) {
        let result = try await services.repositoryPRInventory().refreshIfStale(key)
        // Rows and status written outside a poll cycle are re-read by the next post-cycle patch.
        if result.didFetch { rows.repositoryRefreshed(key) }
        return result
    }
    /// Read when a poll cycle closes (PollCoordinator's policy provider), with the same authorization overlay as
    /// `load()`. PR rows are decoded only for tracked repositories and only when a saved view is a notification rule.
    private func notificationPolicy() async throws -> NotificationPolicy {
        let database = try stores().0, session = try accountSession()
        let scope = try await NotificationPolicyAssembly.scope(database:database) { try await session.authorizationState(for:$0) == .available }
        // Rule rows come from the row cache, decoding only rows this cycle changed (or that carry merge evidence).
        let ruleRows = scope.rules.isEmpty ? [] : try trackedRows(scope.allowedRepositories)
        // Only events a summary can still deliver (unacknowledged, unsurfaced) need matching.
        let events = try pollingStore().pendingInbox().map(\.event)
        return try NotificationPolicyAssembly.policy(scope:scope, ruleRows:ruleRows, pendingEvents:events, database:database, now:dependencies.clock())
    }
    func registerVisibleActions(_ id:UUID,repository:RepositoryKey?) { visibleActionRepositories[id] = repository }
    /// Marks repositories as on screen for polling cadence only (no untracked reads); an empty set unregisters.
    func registerFocusedRepositories(_ id:UUID,repositories:Set<RepositoryKey>) { focusedRepositoryViews[id] = repositories.isEmpty ? nil : repositories }
    /// Runs one poll cycle. `changes` is what it committed (nil when unknown), so callers refresh only changed state;
    /// `backlogged` is true when it left due work behind (initial sync of many repositories, a long history walk).
    func refreshActivity(sink: any NotificationSink, reason: PollRequest.Reason = .manual) async throws -> (id: UUID, changes: PollCycleChanges?, backlogged: Bool) {
        let database = try stores().0
        try await prepareFixtures()
        if reason == .manual { try dependencies.fixtures?.manualRefresh(database) }
        // Scopes come from targeted lookups (no PR decoding), with the session's authorization check as in `load()`.
        let session = try accountSession()
        let onScreen = Set(visibleActionRepositories.values).union(focusedRepositoryViews.values.joined())
        var visible:Set<RepositoryKey> = [],focused:Set<RepositoryKey> = [],scopes:[PollScope] = []
        for account in try database.accounts() {
            guard try await session.authorizationState(for:account.scope) == .available else { continue }
            let tracked = try database.trackedRepositories(account:account.scope)
            var browsing:Set<RepositoryKey> = []
            for key in Set(visibleActionRepositories.values) where key.account == account.scope {
                if try tracked.contains(key) || database.repository(key) != nil { browsing.insert(key) }
            }
            visible.formUnion(browsing.subtracting(tracked))
            let repositories = tracked.union(browsing)
            guard !repositories.isEmpty else { continue }
            focused.formUnion(repositories.intersection(onScreen))
            scopes.append(PollScope(account:account.scope,repositories:repositories))
        }
        // The notification policy is read by the coordinator when the cycle closes; the request's policy is unused.
        // Only on-screen repositories keep the fast Actions cadence; quiet background ones fall back to the idle one.
        let coordinator = try services.pollCoordinator(sink:sink) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.notificationPolicy()
        }
        let id = try await coordinator.refresh(PollRequest(scopes:scopes,reason:reason,visibleRepositories:visible,focusedRepositories:focused))
        return (id,dependencies.reportsCycleChanges ? await coordinator.changes(for:id) : nil,await coordinator.backlogged(id))
    }
    /// What the workspace must re-read after a cycle: nothing, these repositories' rows (statuses and account
    /// metadata are always re-read; an empty set reads no PR rows), or every tracked repository.
    typealias SnapshotRefresh = WorkspaceRowCache.Refresh
    func snapshotRefresh(after changes: PollCycleChanges?) -> SnapshotRefresh { rows.refresh(after:changes,now:dependencies.clock()) }
    func inbox(eventKeys: [String]? = nil) throws -> [InboxEvent] { try pollingStore().inbox(eventKeys:eventKeys) }
    func acknowledgeActivity(_ key: String) throws { try pollingStore().acknowledge([key]) }
    func notificationThreadOperations() throws -> [NotificationThreadOperation] { try stores().0.notificationThreadOperations() }
    func changeNotificationThread(_ event:ChangeEvent,intent:NotificationThreadIntent) async throws -> NotificationThreadOperation {
        try await notificationThreadCoordinator().perform(NotificationThreadCommand(event:event,intent:intent))
    }
    func releaseUnsentNotificationThread(_ id:UUID) throws { try stores().0.releaseUnsentNotificationThread(id) }
    func reconcileNotificationThread(_ id:UUID) async throws -> NotificationThreadOperation { try await notificationThreadCoordinator().reconcile(id) }
    func summary(_ id: UUID) throws -> PollSummary? { try pollingStore().summary(id) }
    /// Snoozes for the duration chosen in Settings (15 minutes when unset) and returns when notifications resume.
    @discardableResult func snoozeNotifications() throws -> Date {
        let database=try stores().0
        let until=NotificationSnooze(setting:try database.applicationSetting(.notificationSnoozeDuration)).until(dependencies.clock())
        try database.setApplicationSetting(String(until.timeIntervalSince1970),for:.notificationSnoozedUntil)
        return until
    }
    func notificationsEnabled() throws -> Bool { try stores().0.applicationSetting(.notificationsEnabled) == "true" }

    // MARK: Workspace snapshots

    /// Display status for tracked repositories (the only ones the workspace shows freshness for), without each
    /// status's resumable checkpoint. Only statuses a cycle or repository refresh changed (or not read yet) are
    /// re-read, plus a full pass every `WorkspaceRowCache.fullRefreshInterval`.
    func prInventoryStatuses() throws -> [RepositoryKey:PRInventoryStatus] {
        let database = try stores().0, poll = try pollingStore(), now = dependencies.clock()
        var tracked = Set<RepositoryKey>()
        for account in try database.accounts() { tracked.formUnion(try database.trackedRepositories(account:account.scope)) }
        let read = rows.statusRead(tracked:tracked,now:now)
        let fresh = read.repositories.isEmpty ? [:] : try poll.inventoryStatuses(repositories:read.repositories)
        return rows.store(statuses:fresh,read:read,tracked:tracked,now:now)
    }
    /// One repository's stored status (repository tabs and scoped detail routes), without an account-wide read.
    func prInventoryStatuses(repository key:RepositoryKey) async throws -> [RepositoryKey:PRInventoryStatus] {
        try await services.repositoryPRInventory().cachedStatus(key).map { [key:$0] } ?? [:]
    }
    private func prepareFixtures() async throws {
        guard let fixtures = dependencies.fixtures else { return }
        try await fixtures.prepare(database:stores().0,session:accountSession(),budget:rateBudget)
    }
    /// Every account's local state with the PR rows of its tracked repositories (the workspace shows no others),
    /// under the same authorization overlay as the session snapshot: a blocked account shows no rows. Accounts are
    /// read concurrently, and rows come from the row cache, decoding only rows whose stored bytes changed.
    func load() async throws -> ([LocalSnapshot], String?, AccountScope?, Bool) { try await load(refreshing:nil,firstPass:false) }
    /// A launch's first pass: open PRs and PRs updated within `WorkspaceRowCache.firstPassWindow`; a later `load()` fills in history.
    func loadFirstPass() async throws -> ([LocalSnapshot], String?, AccountScope?, Bool) { try await load(refreshing:nil,firstPass:true) }
    /// Re-reads PR rows of `refreshing` repositories only (plus any tracked repository without complete cached rows);
    /// the others are served from the row cache. Account metadata is always read.
    func load(refreshing: Set<RepositoryKey>) async throws -> ([LocalSnapshot], String?, AccountScope?, Bool) { try await load(refreshing:refreshing,firstPass:false) }
    /// True while some tracked repository only has its first-pass (open and recent) rows.
    var historyPending: Bool { rows.historyPending }
    private struct AccountRead: Sendable {
        let account: Account
        let state: AccountAuthorizationState
        let repositories: [Repository]
        let tracked: Set<RepositoryKey>
        let pins: Set<ProviderKey>
        let settings: [String:String]
        /// Repositories whose rows `rows` holds.
        let refreshed: Set<RepositoryKey>
        let rows: PullRequestRows?
    }
    private static func read(_ account: Account, session: GitHubAccountSession, database: DatabaseStore, store: PollCycleStore, refreshing: Set<RepositoryKey>?,
                             complete: Set<RepositoryKey>, known: [ProviderKey:Int], since: Date?) async throws -> AccountRead {
        let state = try await session.authorizationState(for:account.scope)
        let tracked = try database.trackedRepositories(account:account.scope), settings = try database.settings(account:account.scope)
        guard state == .available else {
            return AccountRead(account:account,state:state,repositories:[],tracked:tracked,pins:[],settings:settings,refreshed:[],rows:nil)
        }
        let read = tracked.filter { refreshing?.contains($0) ?? true || !complete.contains($0) }
        return AccountRead(account:account,state:state,repositories:try database.repositories(account:account.scope),tracked:tracked,
            pins:try database.pins(account:account.scope),settings:settings,refreshed:read,
            rows:read.isEmpty ? nil : try store.pullRequestRows(repositories:read,known:known,openOrUpdatedSince:since))
    }
    /// Current rows of these repositories through the row cache (the notification policy's rule rows).
    private func trackedRows(_ repositories: Set<RepositoryKey>) throws -> [PullRequest] {
        let previous = rows
        let read = try pollingStore().pullRequestRows(repositories:repositories,known:previous.knownFingerprints)
        return rows.merge(read,repositories:repositories,complete:true,previous:previous)
    }
    private func load(refreshing: Set<RepositoryKey>?, firstPass: Bool) async throws -> ([LocalSnapshot], String?, AccountScope?, Bool) {
        let (database,_) = try stores()
        try await prepareFixtures()
        let accounts = try database.accounts()
        let active = try database.activeActionAccount()
        let session = try accountSession(), store = try pollingStore(), started = dependencies.clock()
        let previous = rows, known = previous.knownFingerprints, complete = previous.completeRepositories
        // Only a launch (nothing cached yet) takes the first pass; a reopened window keeps its decoded history.
        let since = previous.firstPassSince(started,requested:firstPass)
        let reads = try await withThrowingTaskGroup(of:(Int,AccountRead).self) { group in
            for (index,account) in accounts.enumerated() {
                group.addTask { (index,try await Self.read(account,session:session,database:database,store:store,refreshing:refreshing,complete:complete,known:known,since:since)) }
            }
            var values: [(Int,AccountRead)] = []
            for try await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var snapshots: [LocalSnapshot] = []
        for read in reads {
            let pullRequests = rows.apply(account:read.account.scope,available:read.state == .available,tracked:read.tracked,read:read.rows,
                                          refreshed:read.refreshed,complete:since == nil,previous:previous)
            snapshots.append(read.state.applying(to:LocalSnapshot(account:read.account,repositories:read.repositories,trackedRepositories:read.tracked,
                pins:read.pins,settings:read.settings,pullRequests:pullRequests,drafts:[])))
        }
        // Rows of removed accounts are never served again.
        rows.retain(accounts:Set(accounts.map(\.scope)))
        if refreshing == nil, since == nil { rows.didReadAllRows(startedAt:started) }
        return (snapshots,try database.applicationSetting(.githubClientID),active,try database.applicationSetting(.notificationsEnabled) == "true")
    }
    /// What a repository-scoped workspace needs, without decoding every account's PR history: every account (so
    /// scoped routes and selections reconcile as with `load()`), and for the scoped account only this repository,
    /// its tracking, pins and rows. The same authorization overlay as `load()`: a blocked account shows no rows.
    func load(repository key:RepositoryKey) async throws -> (snapshots:[LocalSnapshot],activeAccount:AccountScope?) {
        let (database,_) = try stores()
        try await prepareFixtures()
        let accounts = try database.accounts()
        let active = try database.activeActionAccount()
        let session = try accountSession()
        var snapshots: [LocalSnapshot] = []
        for account in accounts {
            let state = try await session.authorizationState(for:account.scope)
            guard account.scope == key.account else {
                snapshots.append(state.applying(to:LocalSnapshot(account:account,repositories:[],trackedRepositories:[],pins:[],settings:[:],pullRequests:[],drafts:[])))
                continue
            }
            let available = state == .available
            snapshots.append(state.applying(to:LocalSnapshot(account:account,repositories:try database.repository(key).map { [$0] } ?? [],
                trackedRepositories:try database.trackedRepositories(account:key.account).intersection([key]),
                pins:try database.pins(account:key.account).filter { $0.repository == key },settings:try database.settings(account:key.account),
                pullRequests:available ? try database.pullRequests(repository:key) : [],drafts:[])))
        }
        return (snapshots,active)
    }

    // MARK: Accounts and settings

    func authorizationChanges() async throws -> AsyncStream<AccountAuthorizationChange> {
        try await accountSession().authorizationChanges()
    }
    /// Nil removes the setting.
    func setting(_ value: String?, for key: SettingsKey) throws {
        try stores().0.setApplicationSetting(value,for:key)
        if key == .githubClientID { services.clientIDChanged() }
    }
    func invalidateOperations(_ account: AccountScope) async throws { await (try accountSession()).invalidateOperations(for:account) }
    func save(_ result: AuthorizedGitHubAccount, replacing expected: AccountScope?) async throws {
        if let expected, expected != result.scope { throw SetupError.accountMismatch }
        try await accountSession().saveAuthorized(result)
    }
    func discover(_ account: AccountScope, clientID: String) async -> AccountDiscoveryOutcome {
        do { return await (try accountSession()).discover(account,clientID:clientID) }
        catch { AppLog.failed(AppLog.storage, "Discovery could not open the account session", error); return .retryable }
    }
    func tracked(_ repo: RepositoryKey, enabled: Bool) throws { try stores().0.setTracked(repo,tracked:enabled) }
    func pinned(_ repo: RepositoryKey, enabled: Bool) throws {
        let pin = ProviderKey(host:repo.account.host,accountID:repo.account.accountID,repositoryID:repo.repositoryID,objectID:"repository")
        try stores().0.setPinned(pin,pinned:enabled)
    }
    /// Removes the account, then its private local leftovers outside the cascade: in-memory PR detail and
    /// revision-bound reading progress (app-wide settings otherwise survive removal).
    func remove(_ account: AccountScope) async throws {
        defer { PRDetailMemoryCache.shared.purge(account:account) }
        try await accountSession().remove(account)
        try PRDetailStore(database:stores().0).purge(account:account)
    }
}
enum SetupError: Error { case accountMismatch }
