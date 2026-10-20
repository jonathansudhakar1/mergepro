import XCTest

@testable import MergeProCore

final class PRWorkspaceSnapshotTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  func snapshot(_ accountID: String, revoked: Bool = false) -> LocalSnapshot {
    let account = AccountScope(host: "github.com", accountID: accountID)
    let repo = RepositoryKey(account: account, repositoryID: "r")
    let key = ProviderKey(
      host: account.host, accountID: accountID, repositoryID: "r", objectID: "pr")
    var metadata = PRMetadata(
      number: 1, webURL: URL(string: "https://github.com/o/r/pull/1")!,
      repositoryName: "private/\(accountID)")
    metadata.requests = [.init(id: "viewer", name: "Viewer", kind: .direct, isForViewer: true)]
    return LocalSnapshot(
      account: Account(scope: account, login: accountID, tokenReference: nil),
      repositories: [
        Repository(
          key: repo, name: metadata.repositoryName, isPrivate: true,
          capabilities: ProviderCapabilities())
      ], trackedRepositories: [repo], pins: [],
      settings: revoked ? ["authorizationProblem": "true"] : [:],
      pullRequests: [
        PullRequest(
          key: key, headRevision: RevisionID("sha"), title: "Private \(accountID)", state: .open,
          isDraft: false, metadata: metadata)
      ], drafts: [])
  }
  func testRepositoryScopeReadsUntrackedRowsAndSurvivesClearingUserFilters() {
    let first=snapshot("a"),second=snapshot("b")
    let key=first.repositories[0].key
    let untracked=LocalSnapshot(account:first.account,repositories:first.repositories,trackedRepositories:[],pins:[],settings:[:],pullRequests:first.pullRequests,drafts:[])
    var cache=PRWorkspaceSnapshot(snapshots:[untracked,second])
    XCTAssertNil(cache.cached(first.pullRequests[0].key))
    cache.refresh(snapshots:[untracked,second],inventory:[:],repositoryScope:key)
    let scoped=cache.rows.filter { $0.key.repository==key }
    var view=PRViewConfiguration()
    view.timeScope = .allTime
    view.filter = .init()
    XCTAssertEqual(BoardProjection(rows:scoped,view:view).rows.map(\.key),first.pullRequests.map(\.key))
    view=PRViewConfiguration()
    view.timeScope = .allTime
    XCTAssertEqual(BoardProjection(rows:scoped,view:view).rows.map(\.key),first.pullRequests.map(\.key))
    XCTAssertTrue(cache.tracked.isDisjoint(with:[key]))
  }
  func testRemovingAccountImmediatelyInvalidatesCachedDetailQueuesAndNavigation() {
    let first = snapshot("a")
    let second = snapshot("b")
    var cache = PRWorkspaceSnapshot(snapshots: [first, second], inventory: [:])
    let removed = first.pullRequests[0].key
    let kept = second.pullRequests[0].key
    var state = PRViewState()
    state.selection = PRSelection(focused: removed, selected: [removed, kept])
    state.scrollAnchor = removed
    state.accountFilter = removed.account
    state.recentRoutes = [removed, kept]
    state.recordVisit(removed)
    state.recordVisit(kept)
    var routes = [removed, kept]
    cache.remove(removed.account, state: &state, pendingRoutes: &routes)
    XCTAssertNil(cache.cached(removed))
    XCTAssertEqual(cache.rows.map(\.key), [kept])
    XCTAssertEqual(cache.rows.filter(\.needsViewer).map(\.key), [kept])
    XCTAssertEqual(state.selection.selected, [kept])
    XCTAssertNil(state.selection.focused)
    XCTAssertNil(state.scrollAnchor)
    XCTAssertNil(state.accountFilter)
    XCTAssertEqual(state.recentRoutes, [kept])
    XCTAssertEqual(state.navigationHistory?.map(\.key), [kept])
    XCTAssertEqual(routes, [kept])
    XCTAssertEqual(
      PRRouteResolver.resolve(removed.routeURL, cached: cache.rows, activeAccount: nil),
      .unavailable)
  }
  func testKeyAndRepositoryIndexesFollowInvalidation() {
    let first = snapshot("a")
    let second = snapshot("b")
    var cache = PRWorkspaceSnapshot(snapshots: [first, second], inventory: [:])
    let kept = second.pullRequests[0]
    XCTAssertEqual(cache.cached(kept.key), kept)
    XCTAssertEqual(cache.rows(in: kept.key.repository), [kept])
    XCTAssertEqual(cache.freshness(for: kept.key.repository, now: now)?.name, "private/b")
    var state = PRViewState()
    var routes: [ProviderKey] = []
    cache.invalidate(first.account!.scope, state: &state, pendingRoutes: &routes)
    XCTAssertEqual(cache.cached(kept.key), kept, "positions shift after rows are removed")
    XCTAssertNil(cache.cached(first.pullRequests[0].key))
    XCTAssertTrue(cache.rows(in: first.repositories[0].key).isEmpty)
    XCTAssertEqual(cache.freshness(for: first.repositories[0].key, now: now)?.state, .revoked)
    XCTAssertEqual(
      cache.freshness(for: first.repositories[0].key, now: now)?.name, "r",
      "a revoked account's repository names are dropped with its repositories")
  }
  func testRevokedSnapshotCannotRetainPrivatePRCache() {
    let revoked = snapshot("a", revoked: true)
    let kept = snapshot("b")
    let cache = PRWorkspaceSnapshot(snapshots: [revoked, kept], inventory: [:])
    XCTAssertNil(cache.cached(revoked.pullRequests[0].key))
    XCTAssertEqual(cache.rows.map(\.key), kept.pullRequests.map(\.key))
  }
  func testSessionRevocationSurvivesUnchangedDatabaseUntilVerifiedAuthorization() {
    let saved = snapshot("a")
    var cache = PRWorkspaceSnapshot(snapshots: [saved])
    var state = PRViewState()
    var routes: [ProviderKey] = []
    cache.invalidate(saved.account!.scope, state: &state, pendingRoutes: &routes)
    cache.refresh(snapshots: [saved], inventory: [:])
    XCTAssertNil(cache.cached(saved.pullRequests[0].key))
    XCTAssertTrue(cache.revoked.contains(saved.account!.scope))
    cache.acceptAuthorization(saved.account!.scope)
    cache.refresh(snapshots: [saved], inventory: [:])
    XCTAssertEqual(cache.cached(saved.pullRequests[0].key), saved.pullRequests[0])
    XCTAssertTrue(cache.revoked.isEmpty)
  }
  func testFreshLaunchPrunesRestoredRemovedScope() {
    let removed = snapshot("gone").pullRequests[0].key
    var state = PRViewState()
    state.accountFilter = removed.account
    state.scrollAnchor = removed
    state.selection = PRSelection(focused: removed, selected: [removed])
    state.recordVisit(removed)
    state.recentRoutes = [removed]
    var routes = [removed]
    PRWorkspaceSnapshot(snapshots: [snapshot("kept")]).reconcile(
      state: &state, pendingRoutes: &routes)
    XCTAssertNil(state.accountFilter)
    XCTAssertNil(state.scrollAnchor)
    XCTAssertNil(state.selection.focused)
    XCTAssertTrue(state.selection.selected.isEmpty)
    XCTAssertTrue(state.recentRoutes.isEmpty)
    XCTAssertTrue(routes.isEmpty)
    XCTAssertTrue(state.navigationHistory?.isEmpty == true)
  }
  func testOwnerDeniedAvailabilityHidesCachedDetailAndNavigationEvenWithUnchangedDBFlag() {
    let first = snapshot("a")
    let other = snapshot("b")
    let denied = AccountAuthorizationState.authorizationRequired(localPersistenceFailed:true)
    let effective = denied.applying(to:first)
    XCTAssertNil(first.settings["authorizationProblem"])
    XCTAssertEqual(effective.settings["authorizationProblem"],"true")
    XCTAssertEqual(effective.settings["authorizationPersistenceFailed"],"true")
    var cache = PRWorkspaceSnapshot(snapshots:[first,other])
    let key = first.pullRequests[0].key
    var state = PRViewState()
    state.selection = PRSelection(focused:key,selected:[key])
    var routes = [key]
    cache.refresh(snapshots:[effective,other],inventory:[:])
    cache.reconcile(state:&state,pendingRoutes:&routes)
    XCTAssertNil(cache.cached(key))
    XCTAssertEqual(cache.rows,other.pullRequests)
    XCTAssertTrue(state.selection.selected.isEmpty)
    XCTAssertNil(state.selection.focused)
    XCTAssertTrue(routes.isEmpty)
    cache.refresh(snapshots:[first,other],inventory:[:])
    XCTAssertNil(cache.cached(key),"Unchanged DB cannot resurrect a revoked detail")
  }
  func testScopedFreshRepositoryDoesNotMaskStaleOrFailedRepository() {
    let first = snapshot("a")
    let second = snapshot("b")
    let a = first.repositories[0].key
    let b = second.repositories[0].key
    var statuses: [RepositoryKey: PRInventoryStatus] = [
      a: .init(complete: true, fetchedCount: 1, fetchedAt: now, message: nil),
      b: .init(
        complete: true, fetchedCount: 1, fetchedAt: now.addingTimeInterval(-600), message: nil),
    ]
    let unrelated = RepositoryKey(account: a.account, repositoryID: "untracked")
    statuses[unrelated] = .init(
      complete: false, fetchedCount: 0, fetchedAt: now, message: "Unrelated partial")
    let cache = PRWorkspaceSnapshot(snapshots: [first, second], inventory: statuses)
    let all = cache.freshness(account: nil, now: now)
    XCTAssertEqual(all.count, 2)
    XCTAssertFalse(cache.inventory.keys.contains(unrelated))
    XCTAssertEqual(all.first { $0.repository == b }?.state, .stale)
    XCTAssertEqual(cache.freshness(account: a.account, now: now).map(\.state), [.fresh])
    statuses[b] = PRInventoryStatus(
      complete: false, fetchedCount: 0, fetchedAt: now, message: "Provider inaccessible",
      lastSuccessAt: now.addingTimeInterval(-600), lastFailureAt: now,
      failureMessage: "Provider inaccessible")
    let failed = PRWorkspaceSnapshot(snapshots: [first, second], inventory: statuses).freshness(
      account: nil, now: now)
    XCTAssertEqual(failed.first { $0.repository == b }?.state, .failed)
    XCTAssertEqual(failed.first { $0.repository == b }?.lastSuccessAt, now.addingTimeInterval(-600))
  }
}
