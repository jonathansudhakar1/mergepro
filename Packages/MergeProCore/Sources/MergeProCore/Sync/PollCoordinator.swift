import Foundation
import Synchronization

public struct PollScope: Sendable {
    public let account: AccountScope
    public let repositories: Set<RepositoryKey>
    public init(account: AccountScope, repositories: Set<RepositoryKey>) { self.account = account; self.repositories = Set(repositories.filter { $0.account == account }) }
}
public struct PollRequest: Sendable {
    public enum Reason: Sendable { case scheduled, manual, activeRun, actionReconciliation }
    public let scopes: [PollScope]
    public let baseline: Bool
    public let reason: Reason
    public let policy: NotificationPolicy
    public let visibleRepositories: Set<RepositoryKey>
    /// Repositories currently on screen, tracked or not. Repository-scoped fetchers may poll these on a
    /// faster cadence (see `PollFeatureFetcher.pollInterval(for:repository:focused:)`). Untracked visible
    /// repositories (`visibleRepositories`) are always focused.
    public let focusedRepositories: Set<RepositoryKey>
    public init(scopes: [PollScope], baseline: Bool = false, reason: Reason = .manual, policy: NotificationPolicy = NotificationPolicy(), visibleRepositories: Set<RepositoryKey> = [], focusedRepositories: Set<RepositoryKey> = []) {
        self.scopes = scopes; self.baseline = baseline; self.reason = reason; self.policy = policy; self.visibleRepositories = visibleRepositories
        self.focusedRepositories = focusedRepositories
    }
}
public struct PollFetchContext: Sendable {
    public let cycleID: UUID
    public let account: AccountScope
    public let repositories: Set<RepositoryKey>
    public let featureID: String
    public let cachedPullRequests: [PullRequest]
    public let cachedSnapshots: [PollFeatureSnapshot]
    public let repositoryMetadata: [RepositoryKey:Repository]
    public let deadline: ContinuousClock.Instant
    public let operation: AccountOperation?
    public let client: GitHubHTTPClient?
    public let budget: RateBudget
    public let baselinedRepositories: Set<RepositoryKey>
    public let suppressNotifications: Bool
    public let reason: PollRequest.Reason
    public let cachedResponses: [String:PollResponseCache]
    public var observationFences: [ProviderKey:Int] = [:]
    /// Every repository of this account the cycle polls, for fetchers that batch reads across repositories.
    public var peerRepositories: Set<RepositoryKey> = []
    public init(cycleID:UUID,account:AccountScope,repositories:Set<RepositoryKey>,featureID:String,cachedPullRequests:[PullRequest],cachedSnapshots:[PollFeatureSnapshot],repositoryMetadata:[RepositoryKey:Repository],deadline:ContinuousClock.Instant,operation:AccountOperation?,client:GitHubHTTPClient?,budget:RateBudget,baselinedRepositories:Set<RepositoryKey>,suppressNotifications:Bool,cachedResponses:[String:PollResponseCache],observationFences:[ProviderKey:Int]=[:],reason:PollRequest.Reason = .manual,peerRepositories:Set<RepositoryKey> = []) {
        self.cycleID=cycleID;self.account=account;self.repositories=repositories;self.featureID=featureID
        self.cachedPullRequests=cachedPullRequests;self.cachedSnapshots=cachedSnapshots;self.repositoryMetadata=repositoryMetadata
        self.deadline=deadline;self.operation=operation;self.client=client;self.budget=budget
        self.baselinedRepositories=baselinedRepositories;self.suppressNotifications=suppressNotifications
        self.cachedResponses=cachedResponses;self.observationFences=observationFences;self.reason=reason;self.peerRepositories=peerRepositories
    }
    public func checkDeadline() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw CancellationError() }
    }
}
public struct PollFetchResult: Sendable {
    public let events: [ChangeEvent]
    public let pullRequests: [PullRequest]
    public let snapshots: [PollFeatureSnapshot]
    public let responses: [PollResponseCache]
    public let baselinedRepositories: Set<RepositoryKey>
    public let baselineEventKeys: Set<String>
    /// The fetch stopped at its request chunk with more to read (e.g. a history walk): the scope stays due, so
    /// the next cycle continues it instead of waiting out the poll interval.
    public let hasMoreWork: Bool
    public init(events: [ChangeEvent] = [], pullRequests: [PullRequest] = [], snapshots: [PollFeatureSnapshot] = [],
                responses: [PollResponseCache] = [], baselinedRepositories: Set<RepositoryKey> = [], baselineEventKeys: Set<String> = [],
                hasMoreWork: Bool = false) {
        self.events = events; self.pullRequests = pullRequests; self.snapshots = snapshots
        self.responses = responses; self.baselinedRepositories = baselinedRepositories; self.baselineEventKeys = baselineEventKeys
        self.hasMoreWork = hasMoreWork
    }
}
/// Fetchers perform reads only. Inventory and notification-feed signals are independent features.
/// Every page/retry uses context.client (which accounts for actual HTTP requests) and deadline.
public enum PollFetchScope: Sendable { case account, repository }
public protocol PollFeatureFetcher: Sendable {
    var featureID: String { get }
    var fetchScope: PollFetchScope { get }
    var allowsVisibleUntrackedReads: Bool { get }
    var pollInterval: TimeInterval? { get }
    func pollInterval(for reason: PollRequest.Reason) -> TimeInterval?
    /// Background seconds per tracked repository (see `PollCadence`): what one more repository costs this feature.
    var secondsPerRepository: TimeInterval { get }
    /// When this feature last completed a read of the scope, from its stored snapshots: after a relaunch the
    /// scope waits out the rest of its interval instead of being read again at once.
    func lastCompleted(_ snapshots: [PollFeatureSnapshot]) -> Date?
    /// Per-repository cadence for repository-scoped work. `focused` is true for on-screen repositories.
    func pollInterval(for reason: PollRequest.Reason, repository: RepositoryKey?, focused: Bool) -> TimeInterval?
    /// Higher priorities run first among work the account runner has not yet ordered.
    var schedulingPriority: Int { get }
    /// Fetchers that do not diff provider rows against cached PRs skip the account snapshot load.
    var usesCachedPullRequests: Bool { get }
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult
}
public extension PollFeatureFetcher {
    var featureID: String { String(reflecting:Self.self) }
    var fetchScope: PollFetchScope { .account }
    var allowsVisibleUntrackedReads: Bool { false }
    var pollInterval: TimeInterval? { nil }
    func pollInterval(for reason: PollRequest.Reason) -> TimeInterval? { pollInterval }
    func pollInterval(for reason: PollRequest.Reason, repository: RepositoryKey?, focused: Bool) -> TimeInterval? { pollInterval(for:reason) }
    var schedulingPriority: Int { 0 }
    var usesCachedPullRequests: Bool { true }
    var secondsPerRepository: TimeInterval { PollCadence.secondsPerRepository }
    func lastCompleted(_ snapshots: [PollFeatureSnapshot]) -> Date? { nil }
}

/// How often background repositories are read as an account tracks more of them. Requests for one account go
/// out one at a time (GitHub's guidance), and every tracked repository costs reads, so a fixed cadence that
/// suits ten repositories exceeds both the serial throughput and the hourly API budget at a few hundred.
public enum PollCadence {
    /// Background spacing per tracked repository for a feature that reads each repository on its own: about
    /// 2,000 reads an hour.
    public static let secondsPerRepository: TimeInterval = 1.8
    /// Spacing for PR inventory, whose `InventoryProbe` checks 25 repositories per 3-point read: 168 repositories
    /// are checked every 84 s for about 900 GraphQL points an hour, plus full reads of those that changed.
    public static let probedSecondsPerRepository: TimeInterval = 0.5
    /// On-screen repositories and fast cadences (active runs) keep their interval; slower background cadences
    /// stretch to `perRepository` for every repository the account tracks.
    public static func interval(_ base: TimeInterval, repositories: Int, focused: Bool, perRepository: TimeInterval = secondsPerRepository) -> TimeInterval {
        guard !focused, base >= 60 else { return base }
        return max(base, Double(repositories) * perRepository)
    }
    /// A repository's PRs count as behind only after missing about three background reads.
    public static func staleAfter(repositories: Int) -> TimeInterval {
        max(300, 3 * interval(60, repositories: repositories, focused: false, perRepository: probedSecondsPerRepository))
    }
}

/// One instance for the entire app. Unstructured fetch tasks report values through a generation
/// gate, so an uncooperative task cannot hold cycle closure hostage after the monotonic deadline.
public actor PollCoordinator {
    private let store: PollCycleStore
    private let publisher: PollNotificationPublisher
    private let fetchers: [any PollFeatureFetcher]
    private let duration: Duration
    private let session: GitHubAccountSession?
    private let clientID: @Sendable () async throws -> String
    private let policyProvider: (@Sendable () async throws -> NotificationPolicy)?
    public let budget: RateBudget
    public private(set) var coalescedRequestCount = 0
    private struct Work {
        let id: String
        let scope: PollScope
        let fetcher: any PollFeatureFetcher
        let requireTracked: Bool
        let focused: Bool
        /// Repositories the account polls this cycle: their count sets `PollCadence`, and repository-scoped
        /// fetchers may batch reads across them.
        let peers: Set<RepositoryKey>
    }
    private var workOrder: [AccountScope:[String]] = [:]
    private var unfinishedRetries: [AccountScope:Set<String>] = [:]
    private var interruptionPending: UUID?
    private struct Active {
        let id: UUID
        let request: PollRequest
        let deadline: ContinuousClock.Instant
        var remaining: Set<String>
        var started: Set<String> = []
        var accounts: [String:AccountScope]
        var tasks: [Task<Void,Never>]
        var timer: Task<Void,Never>?
        let waiter: CheckedContinuation<UUID,Error>
        var accepting = true
        var changes = PollCycleChanges()
        var backlogged = false
        /// Each account's ordered work not yet taken by one of its lanes.
        var queues: [AccountScope:[Work]] = [:]
        /// Diagnostics: work that read the provider, by feature, and work skipped as not yet due.
        var fetched: [String:Int] = [:]
        var notDue = 0
    }
    private struct Pending { var request: PollRequest; var waiters: [CheckedContinuation<UUID,Error>] }
    private var active: Active?
    private var pending: Pending?
    private var recovered = false
    private var followUpWaiters: [UUID:[CheckedContinuation<UUID,Error>]] = [:]
    /// What recently closed cycles committed, so callers refresh only changed state (bounded, newest kept).
    private var closedChanges: [(id: UUID, changes: PollCycleChanges)] = []
    /// Recently closed cycles that left due work behind (their deadline cut work off, or a fetch had more to read).
    private var backloggedCycles: [UUID] = []
    /// Whether the closed cycle `id` left due work behind, so the caller can start the next cycle right away.
    public func backlogged(_ id: UUID) -> Bool { backloggedCycles.contains(id) }
    /// Consecutive `hasMoreWork` results per poll key; past `continuationLimit` the scope waits out its interval.
    private var continuations: [String:Int] = [:]
    static let continuationLimit = 30
    /// What the closed cycle `id` committed; nil once it is no longer among the recent cycles.
    public func changes(for id: UUID) -> PollCycleChanges? { closedChanges.last { $0.id == id }?.changes }
    /// Cycle-scoped reads of account-wide rows that only this cycle's work rewrites: repository metadata
    /// and per-feature conditional validators. Feature snapshots (checkpoints an interactive repository
    /// refresh also commits), cached PR rows and observation fences are read per work item with targeted
    /// lookups, so a later work item never resumes from, and overwrites, a checkpoint newer than the cycle.
    private struct CycleReads {
        var metadata: [AccountScope:[RepositoryKey:Repository]] = [:]
        var responses: [String:[String:PollResponseCache]] = [:]
    }
    private var cycleReads = CycleReads()
    public init(store: PollCycleStore, publisher: PollNotificationPublisher, fetchers: [any PollFeatureFetcher],
                deadline: Duration = .seconds(30), budget: RateBudget = RateBudget(), session: GitHubAccountSession? = nil,
                clientID: @escaping @Sendable () async throws -> String = { "" },
                policyProvider: (@Sendable () async throws -> NotificationPolicy)? = nil) {
        self.store = store; self.publisher = publisher; self.fetchers = fetchers
        duration = min(.seconds(30),max(.zero,deadline)); self.budget = budget; self.session = session
        self.clientID = clientID; self.policyProvider = policyProvider
    }
    public func refresh(_ request: PollRequest) async throws -> UUID {
        try await withCheckedThrowingContinuation { continuation in
            if active != nil {
                coalescedRequestCount += 1
                if var pending {
                    pending.request = Self.merge(pending.request,request); pending.waiters.append(continuation); self.pending = pending
                } else { pending = Pending(request:request,waiters:[continuation]) }
            } else { start(request,waiter:continuation) }
        }
    }
    private static func merge(_ first: PollRequest, _ latest: PollRequest) -> PollRequest {
        var repos: [AccountScope:Set<RepositoryKey>] = [:]
        for scope in first.scopes + latest.scopes { repos[scope.account,default:[]].formUnion(scope.repositories) }
        return PollRequest(scopes:repos.map { PollScope(account:$0.key,repositories:$0.value) },baseline:first.baseline && latest.baseline,
                           reason:merge(first.reason,latest.reason),
                           policy:latest.policy,visibleRepositories:first.visibleRepositories.union(latest.visibleRepositories),
                           focusedRepositories:first.focusedRepositories.union(latest.focusedRepositories))
    }
    /// Coalescing never drops a waiter's forced manual read or faster active-run cadence, and
    /// suppresses notifications only when every coalesced request is an action reconciliation.
    private static func merge(_ first: PollRequest.Reason, _ latest: PollRequest.Reason) -> PollRequest.Reason {
        if first == .actionReconciliation { return latest }; if latest == .actionReconciliation { return first }
        if first == .manual || latest == .manual { return .manual }
        return first == .activeRun || latest == .activeRun ? .activeRun : .scheduled
    }
    private func start(_ request: PollRequest, waiter: CheckedContinuation<UUID,Error>) {
        let id = UUID(); let deadline = ContinuousClock.now.advanced(by:duration)
        do {
            if !recovered { try store.recoverInterruptedCycles(); recovered = true }
            if let ownedID = interruptionPending {
                try store.interrupt(ownedID); interruptionPending = nil
            }
            try store.begin(id,at:Date(),baseline:request.baseline)
            // Normalize duplicate account scopes so one feature/account has only one worker.
            let normalized = Self.merge(PollRequest(scopes:[]),request)
            cycleReads = CycleReads()
            // Until the App reports focus, an active-run request keeps every repository on the fast cadence.
            let focus = normalized.focusedRepositories.union(normalized.visibleRepositories)
            let legacyFocus = normalized.focusedRepositories.isEmpty && request.reason == .activeRun
            let work = normalized.scopes.filter { !$0.repositories.isEmpty }.flatMap { scope in
                fetchers.enumerated().flatMap { index, fetcher -> [Work] in
                    let prefix = "\(scope.account.host):\(scope.account.accountID):\(index)"
                    let eligible = fetcher.allowsVisibleUntrackedReads ? scope.repositories : scope.repositories.subtracting(normalized.visibleRepositories)
                    guard !eligible.isEmpty else { return [] }
                    if fetcher.fetchScope == .account { return [Work(id:prefix,scope:PollScope(account:scope.account,repositories:eligible),fetcher:fetcher,requireTracked:true,focused:legacyFocus || !focus.isDisjoint(with:eligible),peers:scope.repositories)] }
                    return eligible.map {
                        Work(id:prefix + ":" + $0.repositoryID,scope:PollScope(account:scope.account,repositories:[$0]),fetcher:fetcher,requireTracked:!normalized.visibleRepositories.contains($0),focused:legacyFocus || focus.contains($0),peers:scope.repositories)
                    }
                }
            }
            active = Active(id:id,request:request,deadline:deadline,remaining:Set(work.map(\.id)),accounts:Dictionary(uniqueKeysWithValues:work.map { ($0.id,$0.scope.account) }),tasks:[],waiter:waiter)
            let groups = Dictionary(grouping:work,by:{ $0.scope.account })
            // Each account works through one ordered queue (with `budget.concurrency` lanes). Settled work rotates to the tail.
            // Unfinished work gets one immediate retry, then rotates behind other scopes
            // if it expires again, so cutoff work and healthy followers both make progress.
            unfinishedRetries = unfinishedRetries.filter { groups[$0.key] != nil }
            for (account,items) in groups {
                let byID = Dictionary(uniqueKeysWithValues:items.map { ($0.id,$0) })
                if let retries = unfinishedRetries[account] { unfinishedRetries[account] = retries.intersection(Set(byID.keys)) }
                let retained = (workOrder[account] ?? []).filter { byID[$0] != nil }
                let known = Set(retained)
                // New work (e.g. after launch) is interleaved by repository, higher-priority features first within
                // each (PR inventory feeds the board): every feature advances instead of one waiting out a whole
                // pass of another across hundreds of repositories. Account-scoped work leads.
                let order = retained + byID.keys.filter { !known.contains($0) }.sorted { a, b in
                    let wa = byID[a]!, wb = byID[b]!
                    let ra = wa.fetcher.fetchScope == .account ? "" : wa.scope.repositories.first?.repositoryID ?? ""
                    let rb = wb.fetcher.fetchScope == .account ? "" : wb.scope.repositories.first?.repositoryID ?? ""
                    if ra != rb { return ra < rb }
                    let pa = wa.fetcher.schedulingPriority, pb = wb.fetcher.schedulingPriority
                    return pa == pb ? a < b : pa > pb
                }
                workOrder[account] = order
                active?.queues[account] = order.compactMap { byID[$0] }
                // As many lanes as the budget lets the account have requests in flight; each takes the next item,
                // so one slow repository holds up only its own lane.
                for _ in 0..<budget.concurrency {
                    let task = Task.detached { [self] in
                        while !Task.isCancelled, let item = await next(id, account:account) {
                            await execute(id:id,workID:item.id,scope:item.scope,fetcher:item.fetcher,deadline:deadline,requireTracked:item.requireTracked,focused:item.focused,peers:item.peers)
                        }
                    }
                    active?.tasks.append(task)
                }
            }
            active?.timer = Task.detached { [self] in
                do { try await ContinuousClock().sleep(until:deadline); await expire(id) } catch {
                    // Expected: a cycle that closes before its deadline cancels this timer.
                    Log.sync.debug("Cycle deadline timer cancelled")
                }
            }
            if work.isEmpty { Task { await finish(id) } }
        } catch { waiter.resume(throwing:error) }
    }
    private func next(_ id: UUID, account: AccountScope) -> Work? {
        guard active?.id == id, active?.queues[account]?.isEmpty == false else { return nil }
        return active?.queues[account]?.removeFirst()
    }
    private func execute(id: UUID, workID: String, scope: PollScope, fetcher: any PollFeatureFetcher, deadline: ContinuousClock.Instant, requireTracked:Bool, focused:Bool = false, peers:Set<RepositoryKey> = []) async {
        var operation: AccountOperation?
        let pollKey = fetcher.featureID + (fetcher.fetchScope == .repository ? ":" + (scope.repositories.first?.repositoryID ?? "") : "")
        do {
            guard active?.id == id, active?.accepting == true, ContinuousClock.now < deadline else { return }
            let reason = active?.request.reason ?? .scheduled
            let interval = fetcher.fetchScope == .repository
                ? fetcher.pollInterval(for:reason,repository:scope.repositories.first,focused:focused).map { PollCadence.interval($0,repositories:max(1,peers.count),focused:focused,perRepository:fetcher.secondsPerRepository) }
                : fetcher.pollInterval(for:reason)
            if let interval, fetcher.fetchScope == .repository, !(await budget.hasPolled(account:scope.account,feature:pollKey)),
               let completed = fetcher.lastCompleted(try store.featureSnapshots(account:scope.account,feature:fetcher.featureID,repositories:scope.repositories)) {
                await budget.seedPoll(account:scope.account,feature:pollKey,completedAt:completed)
            }
            if let interval, !(await budget.beginPoll(account:scope.account,feature:pollKey,interval:interval,force:reason == .manual)) {
                if active?.id == id { active?.notDue += 1 }
                await settled(id,workID:workID,error:nil); return
            }
            guard active?.id == id, active?.accepting == true, ContinuousClock.now < deadline else { return }
            active?.started.insert(workID)
            if let session { operation = try await session.authenticatedOperation(for:scope.account,clientID:try await clientID()) }
            try Task.checkCancellation()
            guard active?.id == id, active?.accepting == true, ContinuousClock.now < deadline else { return }
            let client: GitHubHTTPClient?
            if let session { client = await session.featureClient(account:scope.account,budget:budget) } else { client = nil }
            guard active?.id == id, active?.accepting == true, ContinuousClock.now < deadline else { return }
            let context = PollFetchContext(cycleID:id,account:scope.account,repositories:scope.repositories,featureID:fetcher.featureID,cachedPullRequests:fetcher.usesCachedPullRequests ? try store.pullRequests(repositories:scope.repositories) : [],cachedSnapshots:try store.featureSnapshots(account:scope.account,feature:fetcher.featureID,repositories:scope.repositories),repositoryMetadata:try cycleMetadata(scope.account),
                deadline:deadline,operation:operation,client:client,budget:budget,baselinedRepositories:try store.baselines(account:scope.account,feature:fetcher.featureID),suppressNotifications:!requireTracked || active?.request.reason == .actionReconciliation,cachedResponses:try cycleResponses(scope.account,feature:fetcher.featureID),observationFences:try store.observationFences(account:scope.account),reason:reason,peerRepositories:peers)
            let fetchStarted = ContinuousClock.now
            let result: PollFetchResult
            do { result = try await fetcher.fetch(context) } catch {
                Log.sync.debug("Work \(fetcher.featureID, privacy: .public) failed after \(fetchStarted.duration(to:.now).components.seconds, privacy: .public)s: \(Log.kind(error), privacy: .public)")
                throw error
            }
            Log.sync.debug("Work \(fetcher.featureID, privacy: .public) took \(fetchStarted.duration(to:.now).components.seconds, privacy: .public)s, \(result.pullRequests.count, privacy: .public) rows, more \(result.hasMoreWork, privacy: .public)")
            guard active?.id == id, active?.accepting == true, ContinuousClock.now < deadline else { return }
            let committed: PollCycleChanges
            if let session, let operation {
                let store = self.store, applied = AppliedChanges()
                guard try await session.withCurrentOperation(operation,body:{ _ in
                    let changes = try store.apply(result,context:context,deadline:deadline,requireTracked:requireTracked)
                    applied.value.withLock { $0 = changes }
                }) else { throw CancellationError() }
                committed = applied.value.withLock { $0 }
            } else { committed = try store.apply(result,context:context,deadline:deadline,requireTracked:false) }
            if active?.id == id { active?.changes.formUnion(committed);active?.fetched[fetcher.featureID, default:0] += 1 }
            let continuing = result.hasMoreWork && continuations[pollKey, default:0] < Self.continuationLimit
            continuations[pollKey] = result.hasMoreWork ? continuations[pollKey, default:0] + 1 : nil
            if continuing { active?.backlogged = true }
            else if let interval {
                await budget.completePoll(account:scope.account,feature:pollKey,interval:interval)
            }
            await settled(id,workID:workID,error:nil)
        } catch {
            // A current-token 401 belongs to the credential owner even if this feature
            // cycle expired. The owner rejects stale generations/token rotations.
            if let session, let operation { await session.featureFailed(error,operation:operation) }
            // The cycle records a generic failure for this scope; keep the kind for diagnostics. Cancelled
            // work (a closed cycle, an expired deadline, a superseded account) is not a failure.
            if Self.reportsWorkFailure(error) {
                Log.sync.info("Poll work failed for \(fetcher.featureID, privacy: .public): \(Log.kind(error), privacy: .public)")
            }
            guard active?.id == id, active?.accepting == true, ContinuousClock.now < deadline else { return }
            await settled(id,workID:workID,error:error)
        }
    }
    /// Whether a work item's error is logged as a failure: cancellation is not one.
    static func reportsWorkFailure(_ error: any Error) -> Bool { !(error is CancellationError) }
    private func cycleMetadata(_ account: AccountScope) throws -> [RepositoryKey:Repository] {
        if let value = cycleReads.metadata[account] { return value }
        let value = try store.repositoryMetadata(account:account); cycleReads.metadata[account] = value; return value
    }
    /// Only this feature's validators/bodies are loaded, once per account and cycle.
    private func cycleResponses(_ account: AccountScope, feature: String) throws -> [String:PollResponseCache] {
        let key = "\(account.host)\u{1F}\(account.accountID)\u{1F}\(feature)"
        if let value = cycleReads.responses[key] { return value }
        let value = try store.responses(account:account,feature:feature); cycleReads.responses[key] = value; return value
    }
    private func rotateWork(_ workID: String, account: AccountScope) {
        guard let index = workOrder[account]?.firstIndex(of:workID) else { return }
        workOrder[account]?.remove(at:index); workOrder[account]?.append(workID)
    }
    private func rescheduleUnfinishedWork(_ workID: String, account: AccountScope) {
        guard var order = workOrder[account], let index = order.firstIndex(of: workID) else { return }
        if unfinishedRetries[account, default: []].insert(workID).inserted {
            // A response that missed this deadline can commit when it starts first next cycle.
            order.remove(at: index); order.insert(workID, at: 0); workOrder[account] = order
        } else {
            // After one retry, move repeatedly hung work behind every queued follower.
            unfinishedRetries[account]?.remove(workID)
            rotateWork(workID, account: account)
        }
    }
    private func settled(_ id: UUID, workID: String, error: (any Error)?) async {
        guard active?.id == id, active?.accepting == true else { return }
        if error != nil {
            do { try store.failure(id,workID:workID,message:"Provider work failed; successful scopes remain available.") }
            catch { Log.storage.error("Could not record a failed poll scope: \(Log.kind(error), privacy: .public)") }
        }
        if let account = active?.accounts[workID] {
            unfinishedRetries[account]?.remove(workID)
            rotateWork(workID,account:account)
        }
        active?.started.remove(workID)
        active?.remaining.remove(workID)
        if active?.remaining.isEmpty == true { Task { await finish(id) } }
    }
    private func expire(_ id: UUID) async {
        guard let current = active, current.id == id, current.accepting else { return }
        if !current.remaining.isEmpty { active?.backlogged = true }
        for workID in current.started {
            // Always rotating cutoff work can phase-lock it at the same deadline; always
            // retaining it can starve healthy followers. Alternate one retry with tail rotation.
            if let account = current.accounts[workID] { rescheduleUnfinishedWork(workID,account:account) }
        }
        for workID in current.remaining {
            do { try store.failure(id,workID:workID,message:"Fetch deadline reached; retry in the next cycle.") }
            catch { Log.storage.error("Could not record a poll scope that reached the deadline: \(Log.kind(error), privacy: .public)") }
        }
        Task { await finish(id) }
    }
    private func finish(_ id: UUID) async {
        guard let current = active, current.id == id, current.accepting else { return }
        active?.accepting = false
        current.timer?.cancel(); current.tasks.forEach { $0.cancel() }
        let latest = active ?? current, pacing = await budget.drainPacingStats()
        let read = latest.fetched.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator:" ")
        Log.sync.info("Cycle closed in \(String(format:"%.1f",Double((latest.deadline - self.duration).duration(to:.now).components.seconds)), privacy: .public)s: read \(read, privacy: .public), not due \(latest.notDue, privacy: .public), unfinished \(latest.remaining.count, privacy: .public), backlogged \(latest.backlogged, privacy: .public); \(pacing.requests, privacy: .public) background requests waited spacing \(pacing.spacing.components.seconds, privacy: .public)s quota \(pacing.quota.components.seconds, privacy: .public)s rest \(pacing.rest.components.seconds, privacy: .public)s")
        let result: Result<UUID,Error>
        do {
            var policy = current.request.policy
            if let policyProvider { policy = try await policyProvider() }
            let summary = try store.close(id,at:Date(),policy:policy,suppress:current.request.reason == .actionReconciliation)
            closedChanges.append((id,active?.changes ?? current.changes)); if closedChanges.count > 8 { closedChanges.removeFirst() }
            if active?.backlogged == true { backloggedCycles.append(id); if backloggedCycles.count > 8 { backloggedCycles.removeFirst() } }
            // Delivery failure is durable and normal; never retry or discard committed inbox rows.
            do { try await publisher.publish(summary) } catch {
                Log.notifications.info("Cycle notification delivery failed; the inbox keeps its rows: \(Log.kind(error), privacy: .public)")
            }
            result = .success(id)
        } catch {
            interruptionPending = id
            // Never clear another cycle or alter a closed cycle/attempt. If storage remains
            // unavailable, retry this exact cleanup before admitting the next owned cycle.
            do { try store.interrupt(id); interruptionPending = nil } catch {
                Log.storage.error("Could not mark a poll cycle interrupted; retrying before the next cycle: \(Log.kind(error), privacy: .public)")
            }
            result = .failure(error)
        }
        active = nil
        current.waiter.resume(with:result)
        for waiter in followUpWaiters.removeValue(forKey:id) ?? [] { waiter.resume(with:result) }
        if let pending {
            self.pending = nil
            let first = pending.waiters[0]
            start(pending.request,waiter:first)
            if let nextID = active?.id { followUpWaiters[nextID] = Array(pending.waiters.dropFirst()) }
            else { for waiter in pending.waiters.dropFirst() { waiter.resume(throwing:PollStorageError.closedCycle) } }
        }
    }
}
/// Carries `apply`'s result out of the session's synchronous commit body, which runs before it returns.
private final class AppliedChanges: Sendable { let value = Mutex(PollCycleChanges()) }
