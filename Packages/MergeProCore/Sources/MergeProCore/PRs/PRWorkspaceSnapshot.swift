import Foundation

/// One value-owned provider cache shared by board, palette, menu queues and cached detail routes.
public struct PRWorkspaceSnapshot: Sendable {
  public private(set) var rows: [PullRequest] { didSet { indexRows() } }
  public private(set) var repositories: [Repository] {
    didSet { names = Dictionary(repositories.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first }) }
  }
  /// First row per key and row positions per repository, so card and route lookups are O(1).
  private var positions: [ProviderKey: Int] = [:]
  private var repositoryPositions: [RepositoryKey: [Int]] = [:]
  private var names: [RepositoryKey: String] = [:]
  public private(set) var accounts: [Account]
  public private(set) var tracked: Set<RepositoryKey>
  public private(set) var pinned: Set<RepositoryKey>
  public private(set) var revoked: Set<AccountScope>
  public private(set) var inventory: [RepositoryKey: PRInventoryStatus]
  public init(
    snapshots: [LocalSnapshot] = [], inventory: [RepositoryKey: PRInventoryStatus] = [:],
    invalidatedAccounts: Set<AccountScope> = [], repositoryScope:RepositoryKey? = nil
  ) {
    accounts = snapshots.compactMap(\.account)
    let current = Set(accounts.map(\.scope))
    let revokedScopes = invalidatedAccounts.intersection(current).union(
      Set(
        snapshots.filter { $0.settings[.authorizationProblem] == "true" }.compactMap {
          $0.account?.scope
        }))
    let trackedKeys = Set(
      snapshots.flatMap(\.trackedRepositories).filter { current.contains($0.account) })
    pinned = Set(
      snapshots.flatMap(\.pins).map(\.repository).filter {
        current.contains($0.account) && !revokedScopes.contains($0.account)
      })
    repositories = snapshots.flatMap(\.repositories).filter {
      current.contains($0.key.account) && !revokedScopes.contains($0.key.account)
    }
    rows = snapshots.flatMap(\.pullRequests).filter {
      (trackedKeys.contains($0.key.repository) || $0.key.repository == repositoryScope) && !revokedScopes.contains($0.key.account)
    }
    self.inventory = inventory.filter { trackedKeys.contains($0.key) || $0.key == repositoryScope }
    revoked = revokedScopes
    tracked = trackedKeys
    indexRows()
    names = Dictionary(repositories.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
  }
  private mutating func indexRows() {
    positions = [:]
    repositoryPositions = [:]
    for (index, row) in rows.enumerated() {
      if positions[row.key] == nil { positions[row.key] = index }
      repositoryPositions[row.key.repository, default: []].append(index)
    }
  }
  /// Session invalidation survives failed SQLite revocation persistence; only verified reauthorization releases it.
  public mutating func refresh(
    snapshots: [LocalSnapshot], inventory: [RepositoryKey: PRInventoryStatus], repositoryScope:RepositoryKey? = nil
  ) {
    self = Self(snapshots: snapshots, inventory: inventory, invalidatedAccounts: revoked,repositoryScope:repositoryScope)
  }
  public mutating func acceptAuthorization(_ account: AccountScope) { revoked.remove(account) }
  public func cached(_ key: ProviderKey) -> PullRequest? { positions[key].map { rows[$0] } }
  /// Rows of one repository in cache order.
  public func rows(in repository: RepositoryKey) -> [PullRequest] {
    repositoryPositions[repository]?.map { rows[$0] } ?? []
  }
  public mutating func invalidate(
    _ account: AccountScope, state: inout PRViewState, pendingRoutes: inout [ProviderKey]
  ) {
    revoked.insert(account)
    rows.removeAll { $0.key.account == account }
    repositories.removeAll { $0.key.account == account }
    pinned = pinned.filter { $0.account != account }
    state.invalidate(account)
    pendingRoutes.removeAll { $0.account == account }
  }
  public mutating func remove(
    _ account: AccountScope, state: inout PRViewState, pendingRoutes: inout [ProviderKey]
  ) {
    invalidate(account, state: &state, pendingRoutes: &pendingRoutes)
    accounts.removeAll { $0.scope == account }
    tracked = tracked.filter { $0.account != account }
    inventory = inventory.filter { $0.key.account != account }
    revoked.remove(account)
  }
  public func reconcile(state: inout PRViewState, pendingRoutes: inout [ProviderKey]) {
    var referenced = Set(state.selection.selected.map(\.account))
    referenced.formUnion(state.recentRoutes.map(\.account))
    referenced.formUnion((state.navigationHistory ?? []).map { $0.key.account })
    referenced.formUnion(pendingRoutes.map(\.account))
    if let scope = state.accountFilter { referenced.insert(scope) }
    if let key = state.scrollAnchor { referenced.insert(key.account) }
    if let key = state.selection.focused { referenced.insert(key.account) }
    let invalid = referenced.subtracting(accounts.map(\.scope)).union(revoked)
    for account in invalid {
      state.invalidate(account)
      pendingRoutes.removeAll { $0.account == account }
    }
    state.selection.preserve(in: rows)
  }
  /// `staleAfter` defaults to `PollCadence.staleAfter` for the repository's account, which stretches with the
  /// number of repositories it tracks.
  public func freshness(account: AccountScope?, now: Date = Date(), staleAfter: TimeInterval? = nil)
    -> [PRRepositoryFreshness]
  {
    let counts = trackedCounts()
    return tracked.filter { account == nil || $0.account == account }.map { key in
      freshness(key, now: now, staleAfter: staleAfter, counts: counts)
    }.sorted {
      ($0.repository.account.host, $0.repository.account.accountID, $0.name)
        < ($1.repository.account.host, $1.repository.account.accountID, $1.name)
    }
  }
  /// One tracked repository's freshness; nil when the repository is not tracked.
  public func freshness(for repository: RepositoryKey, now: Date = Date(), staleAfter: TimeInterval? = nil)
    -> PRRepositoryFreshness?
  {
    tracked.contains(repository) ? freshness(repository, now: now, staleAfter: staleAfter, counts: trackedCounts()) : nil
  }
  /// Every tracked repository's freshness by key, for per-card lookups.
  public func freshnessByRepository(now: Date = Date(), staleAfter: TimeInterval? = nil)
    -> [RepositoryKey: PRRepositoryFreshness]
  {
    let counts = trackedCounts()
    return Dictionary(uniqueKeysWithValues: tracked.map { ($0, freshness($0, now: now, staleAfter: staleAfter, counts: counts)) })
  }
  private func trackedCounts() -> [AccountScope: Int] { tracked.reduce(into: [:]) { $0[$1.account, default: 0] += 1 } }
  private func freshness(_ key: RepositoryKey, now: Date, staleAfter: TimeInterval?, counts: [AccountScope: Int])
    -> PRRepositoryFreshness
  {
    let threshold = staleAfter ?? PollCadence.staleAfter(repositories: counts[key.account] ?? 1)
    return PRRepositoryFreshness(
      repository: key, name: names[key] ?? key.repositoryID, status: inventory[key],
      revoked: revoked.contains(key.account), now: now, staleAfter: threshold)
  }
}
