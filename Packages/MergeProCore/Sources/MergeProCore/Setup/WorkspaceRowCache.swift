import Foundation

/// The workspace's decoded PR rows of tracked repositories, with their stored-byte fingerprints so later reads decode
/// only rows whose bytes changed (`PollCycleStore.pullRequestRows`), plus the display status per tracked repository and
/// what the workspace must re-read after a poll cycle. A value type without I/O: its owner reads the store and applies
/// the results here.
public struct WorkspaceRowCache: Sendable {
    /// A full pass over every tracked repository at least this often, whatever cycles reported.
    public static let fullRefreshInterval: TimeInterval = 600
    /// A launch's first pass decodes open PRs and PRs updated within this window (the default board scope).
    public static let firstPassWindow: TimeInterval = 30 * 86_400

    /// What the workspace must re-read after a cycle: nothing, these repositories' rows (statuses and account
    /// metadata are always re-read; an empty set reads no PR rows), or every tracked repository.
    public enum Refresh: Equatable, Sendable { case none, repositories(Set<RepositoryKey>), all }

    struct RepositoryRows: Sendable {
        var keys: [ProviderKey]
        var fingerprints: [ProviderKey:Int]
        var rows: [ProviderKey:PullRequest]
        /// False while only a launch's first pass (open and recent rows) was read.
        var complete: Bool
    }
    private(set) var repositories: [RepositoryKey:RepositoryRows] = [:]
    /// Repositories whose rows or status changed outside a poll cycle (interactive repository refreshes).
    private var externallyChanged: Set<RepositoryKey> = []
    private var rowsReadAt: Date?
    private var statuses: [RepositoryKey:PRInventoryStatus] = [:]
    /// Statuses re-read by the next `statusRead(tracked:now:)`.
    private var staleStatuses: Set<RepositoryKey> = []
    private var statusesReadAt: Date?

    public init() {}

    public var isEmpty: Bool { repositories.isEmpty }
    /// True while some tracked repository only has its first-pass (open and recent) rows.
    public var historyPending: Bool { repositories.values.contains { !$0.complete } }
    /// Fingerprints of every cached row: pass them as `known` to the next row read.
    public var knownFingerprints: [ProviderKey:Int] { repositories.values.reduce(into:[:]) { $0.merge($1.fingerprints) { _,new in new } } }
    /// Repositories whose full history is cached.
    public var completeRepositories: Set<RepositoryKey> { Set(repositories.filter(\.value.complete).keys) }
    /// One repository's cached rows, in stored order.
    public func rows(of repository: RepositoryKey) -> [PullRequest] {
        repositories[repository].map { cache in cache.keys.compactMap { cache.rows[$0] } } ?? []
    }
    /// When a launch's read starts at `now`, the lower bound of its first pass; nil when rows are already cached
    /// (a reopened window keeps its decoded history) or no first pass was asked for.
    public func firstPassSince(_ now: Date, requested: Bool) -> Date? {
        requested && isEmpty ? now.addingTimeInterval(-Self.firstPassWindow) : nil
    }

    /// Replaces these repositories' rows with `read`: decoded rows, or `previous`'s decode of unchanged bytes.
    /// - Returns: the read rows, in read order.
    @discardableResult
    public mutating func merge(_ read: PullRequestRows, repositories merged: Set<RepositoryKey>, complete: Bool, previous: WorkspaceRowCache) -> [PullRequest] {
        let grouped = Dictionary(grouping:read.keys, by:\.repository)
        for repository in merged {
            let old = previous.repositories[repository]
            var rows: [ProviderKey:PullRequest] = [:], fingerprints: [ProviderKey:Int] = [:]
            for key in grouped[repository] ?? [] {
                guard let row = read.decoded[key] ?? (old?.fingerprints[key] == read.fingerprints[key] ? old?.rows[key] : nil) else { continue }
                rows[key] = row; fingerprints[key] = read.fingerprints[key]
            }
            repositories[repository] = RepositoryRows(keys:(grouped[repository] ?? []).filter { rows[$0] != nil }, fingerprints:fingerprints, rows:rows, complete:complete)
        }
        return read.keys.compactMap { repositories[$0.repository]?.rows[$0] }
    }

    /// One account's read under the authorization overlay: a blocked account keeps no rows, an untracked repository
    /// loses its rows, and `refreshed` repositories take `read`.
    /// - Returns: the account's rows (tracked repositories by ID); none when it is not available.
    public mutating func apply(account: AccountScope, available: Bool, tracked: Set<RepositoryKey>, read: PullRequestRows?,
                               refreshed: Set<RepositoryKey>, complete: Bool, previous: WorkspaceRowCache) -> [PullRequest] {
        for key in repositories.keys where key.account == account && (!available || !tracked.contains(key)) { repositories[key] = nil }
        if let read { merge(read, repositories:refreshed, complete:complete, previous:previous) }
        externallyChanged.subtract(refreshed)
        guard available else { return [] }
        return tracked.sorted { $0.repositoryID < $1.repositoryID }.flatMap(rows(of:))
    }
    /// Rows of removed accounts are never served again.
    public mutating func retain(accounts: Set<AccountScope>) { repositories = repositories.filter { accounts.contains($0.key.account) } }
    /// A read of every tracked repository's full history finished; it started at `date`.
    public mutating func didReadAllRows(startedAt date: Date) { rowsReadAt = date }
    /// An interactive repository refresh fetched new rows and status outside a poll cycle.
    public mutating func repositoryRefreshed(_ key: RepositoryKey) { externallyChanged.insert(key); staleStatuses.insert(key) }

    /// What to re-read after a cycle that committed `changes` (nil when unknown): everything when unknown or when the
    /// last full read is `fullRefreshInterval` old (or in the future), else only what the cycle or a repository refresh changed.
    public mutating func refresh(after changes: PollCycleChanges?, inventoryFeature: String = GitHubPRInventoryFetcher().featureID,
                                 now: Date) -> Refresh {
        guard let changes, !Self.due(rowsReadAt, now:now) else { staleStatuses.formUnion(statuses.keys); return .all }
        let rows = Set(changes.pullRequests.map(\.repository)).union(externallyChanged)
        let changedStatuses = changes.repositories(feature:inventoryFeature).union(rows)
        staleStatuses.formUnion(changedStatuses)
        return rows.isEmpty && changedStatuses.isEmpty ? .none : .repositories(rows)
    }

    /// Which `tracked` statuses to read now: all of them on a full pass (every `fullRefreshInterval`), else only stale
    /// or never-read ones.
    public func statusRead(tracked: Set<RepositoryKey>, now: Date) -> (repositories: Set<RepositoryKey>, full: Bool) {
        let full = Self.due(statusesReadAt, now:now)
        return (full ? tracked : tracked.filter { staleStatuses.contains($0) || statuses[$0] == nil }, full)
    }
    /// Records the statuses read for `read` (a missing one clears its entry) and forgets untracked repositories.
    /// - Returns: every tracked repository's status.
    public mutating func store(statuses fresh: [RepositoryKey:PRInventoryStatus], read: (repositories: Set<RepositoryKey>, full: Bool),
                               tracked: Set<RepositoryKey>, now: Date) -> [RepositoryKey:PRInventoryStatus] {
        for key in read.repositories { statuses[key] = fresh[key] }
        staleStatuses.subtract(read.repositories)
        if read.full { statusesReadAt = now }
        statuses = statuses.filter { tracked.contains($0.key) }
        return statuses
    }

    private static func due(_ last: Date?, now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) >= fullRefreshInterval || $0 > now } ?? true
    }
}
