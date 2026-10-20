import Foundation
import XCTest
@testable import MergeProCore

final class WorkspaceRowCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970:1_800_000_000)
    private let first = AccountScope(host:"github.com", accountID:"1")
    private let second = AccountScope(host:"github.com", accountID:"2")
    private func repository(_ id: String, _ account: AccountScope? = nil) -> RepositoryKey { RepositoryKey(account:account ?? first, repositoryID:id) }
    private func pr(_ number: Int, in repository: RepositoryKey, title: String = "Fixture") -> PullRequest {
        PullRequest(key:ProviderKey(host:repository.account.host, accountID:repository.account.accountID, repositoryID:repository.repositoryID,
                                    objectID:"pull-request:\(number)"), headRevision:RevisionID("sha"), title:title, state:.open, isDraft:false)
    }
    /// A store read: every row's fingerprint, and decoded rows for those in `decoded`.
    private func read(_ rows: [(PullRequest, Int)], decoded: Set<ProviderKey>? = nil) -> PullRequestRows {
        PullRequestRows(keys:rows.map(\.0.key), fingerprints:Dictionary(uniqueKeysWithValues:rows.map { ($0.0.key, $0.1) }),
                        decoded:Dictionary(uniqueKeysWithValues:rows.filter { decoded?.contains($0.0.key) ?? true }.map { ($0.0.key, $0.0) }))
    }
    private func status(_ count: Int) -> PRInventoryStatus {
        PRInventoryStatus(complete:true, fetchedCount:count, fetchedAt:now)
    }

    func testUnchangedBytesReuseThePreviousDecodeAndChangedOnesAreNeverServedStale() {
        let alpha = repository("a"), one = pr(1, in:alpha, title:"One"), two = pr(2, in:alpha, title:"Two")
        var cache = WorkspaceRowCache()
        XCTAssertEqual(cache.merge(read([(one, 10), (two, 20)]), repositories:[alpha], complete:true, previous:cache).map(\.title), ["One", "Two"])
        XCTAssertEqual(cache.knownFingerprints, [one.key:10, two.key:20])
        // Nothing decoded: the same bytes reuse the previous rows, changed bytes without a decode drop the row.
        let previous = cache
        let rows = cache.merge(read([(one, 10), (two, 21)], decoded:[]), repositories:[alpha], complete:true, previous:previous)
        XCTAssertEqual(rows.map(\.title), ["One"])
        XCTAssertEqual(cache.rows(of:alpha).map(\.key), [one.key])
        XCTAssertEqual(cache.knownFingerprints, [one.key:10])
    }

    func testApplyFollowsTheAuthorizationOverlayAndTracking() {
        let alpha = repository("b"), beta = repository("a"), gamma = repository("c", second)
        var cache = WorkspaceRowCache()
        let rows = read([(pr(1, in:alpha), 1), (pr(2, in:beta), 2)])
        let served = cache.apply(account:first, available:true, tracked:[alpha, beta], read:rows, refreshed:[alpha, beta], complete:true, previous:cache)
        XCTAssertEqual(served.map(\.key.repositoryID), ["a", "b"], "tracked repositories by ID")
        _ = cache.apply(account:second, available:true, tracked:[gamma], read:read([(pr(3, in:gamma), 3)]), refreshed:[gamma], complete:true, previous:cache)

        // No longer tracked: its rows go. Not refreshed: served from the cache.
        XCTAssertEqual(cache.apply(account:first, available:true, tracked:[beta], read:nil, refreshed:[], complete:true, previous:cache).map(\.key.repositoryID), ["a"])
        XCTAssertTrue(cache.rows(of:alpha).isEmpty)
        // A blocked account shows and keeps no rows.
        XCTAssertEqual(cache.apply(account:first, available:false, tracked:[beta], read:nil, refreshed:[], complete:true, previous:cache), [])
        XCTAssertTrue(cache.rows(of:beta).isEmpty)
        XCTAssertFalse(cache.rows(of:gamma).isEmpty, "another account's rows are untouched")
        cache.retain(accounts:[first])
        XCTAssertTrue(cache.isEmpty, "rows of removed accounts are never served again")
    }

    func testFirstPassIsOnlyForALaunchAndLeavesHistoryPending() {
        let alpha = repository("a")
        var cache = WorkspaceRowCache()
        XCTAssertEqual(cache.firstPassSince(now, requested:true), now.addingTimeInterval(-WorkspaceRowCache.firstPassWindow))
        XCTAssertNil(cache.firstPassSince(now, requested:false))
        _ = cache.apply(account:first, available:true, tracked:[alpha], read:read([(pr(1, in:alpha), 1)]), refreshed:[alpha], complete:false, previous:cache)
        XCTAssertTrue(cache.historyPending)
        XCTAssertEqual(cache.completeRepositories, [])
        XCTAssertNil(cache.firstPassSince(now, requested:true), "a reopened window keeps its decoded history")
        _ = cache.apply(account:first, available:true, tracked:[alpha], read:read([(pr(1, in:alpha), 1)]), refreshed:[alpha], complete:true, previous:cache)
        XCTAssertFalse(cache.historyPending)
        XCTAssertEqual(cache.completeRepositories, [alpha])
    }

    func testCyclesReReadOnlyWhatChangedUntilAFullPassIsDue() {
        let alpha = repository("a"), beta = repository("b"), gamma = repository("c")
        var cache = WorkspaceRowCache()
        XCTAssertEqual(cache.refresh(after:PollCycleChanges(), now:now), .all, "nothing read yet")
        cache.didReadAllRows(startedAt:now)
        XCTAssertEqual(cache.refresh(after:nil, now:now), .all, "unknown changes")
        XCTAssertEqual(cache.refresh(after:PollCycleChanges(), now:now.addingTimeInterval(60)), .none)
        var changes = PollCycleChanges()
        changes.pullRequests = [pr(1, in:alpha).key]
        changes.repositories = ["github-pr-inventory":[beta]]
        XCTAssertEqual(cache.refresh(after:changes, inventoryFeature:"github-pr-inventory", now:now.addingTimeInterval(60)), .repositories([alpha]))
        XCTAssertEqual(cache.refresh(after:PollCycleChanges(), inventoryFeature:"github-pr-inventory", now:now.addingTimeInterval(60)), .none,
                       "an inventory-only change re-reads statuses, not rows")
        // A repository refresh outside a cycle joins the next patch until a read covers it.
        cache.repositoryRefreshed(gamma)
        XCTAssertEqual(cache.refresh(after:PollCycleChanges(), now:now.addingTimeInterval(60)), .repositories([gamma]))
        _ = cache.apply(account:first, available:true, tracked:[gamma], read:nil, refreshed:[gamma], complete:true, previous:cache)
        XCTAssertEqual(cache.refresh(after:PollCycleChanges(), now:now.addingTimeInterval(60)), .none)
        XCTAssertEqual(cache.refresh(after:PollCycleChanges(), now:now.addingTimeInterval(WorkspaceRowCache.fullRefreshInterval)), .all)
        XCTAssertEqual(cache.refresh(after:PollCycleChanges(), now:now.addingTimeInterval(-1)), .all, "a clock moved backwards forces a full read")
    }

    func testStatusesReadFullyOnScheduleAndOtherwiseOnlyWhenStale() {
        let alpha = repository("a"), beta = repository("b")
        var cache = WorkspaceRowCache()
        var plan = cache.statusRead(tracked:[alpha, beta], now:now)
        XCTAssertTrue(plan.full)
        XCTAssertEqual(plan.repositories, [alpha, beta])
        XCTAssertEqual(cache.store(statuses:[alpha:status(1)], read:plan, tracked:[alpha, beta], now:now).keys.sorted { $0.repositoryID < $1.repositoryID }, [alpha])
        // Beta had no stored status, so it stays due; alpha is fresh until a cycle marks it stale.
        plan = cache.statusRead(tracked:[alpha, beta], now:now.addingTimeInterval(30))
        XCTAssertFalse(plan.full)
        XCTAssertEqual(plan.repositories, [beta])
        var changes = PollCycleChanges(); changes.repositories = ["github-pr-inventory":[alpha]]
        cache.didReadAllRows(startedAt:now)
        _ = cache.refresh(after:changes, inventoryFeature:"github-pr-inventory", now:now.addingTimeInterval(30))
        plan = cache.statusRead(tracked:[alpha, beta], now:now.addingTimeInterval(30))
        XCTAssertEqual(plan.repositories, [alpha, beta])
        let stored = cache.store(statuses:[alpha:status(2), beta:status(3)], read:plan, tracked:[beta], now:now.addingTimeInterval(30))
        XCTAssertEqual(stored.keys.map(\.repositoryID), ["b"], "untracked repositories are forgotten")
        XCTAssertEqual(cache.statusRead(tracked:[beta], now:now.addingTimeInterval(WorkspaceRowCache.fullRefreshInterval)).full, true)
    }
}
