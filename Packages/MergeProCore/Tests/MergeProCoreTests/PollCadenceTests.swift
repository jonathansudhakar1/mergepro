import Foundation
import XCTest
@testable import MergeProCore

/// A repository-scoped fetcher on a 60 s cadence that reports more history to read for its first `continuing` calls.
private actor ContinuingWalkFetcher: PollFeatureFetcher {
    nonisolated var fetchScope: PollFetchScope { .repository }
    nonisolated var pollInterval: TimeInterval? { 60 }
    let continuing: Int
    var calls = 0
    init(continuing: Int) { self.continuing = continuing }
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        calls += 1
        return PollFetchResult(hasMoreWork: calls <= continuing)
    }
}
/// Each repository read takes `delay`, so a short cycle deadline cuts the account's queue off.
private struct SlowRepositoryFetcher: PollFeatureFetcher {
    var fetchScope: PollFetchScope { .repository }
    var pollInterval: TimeInterval? { 60 }
    let delay: Duration
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        try await Task.sleep(for: delay)
        return PollFetchResult()
    }
}

@MainActor
final class PollCadenceTests: XCTestCase {
    private let account = AccountScope(host: "github.com", accountID: "1")
    private func make(_ fetcher: any PollFeatureFetcher, deadline: Duration = .seconds(30)) throws -> PollCoordinator {
        let store = PollCycleStore(database: try DatabaseStore(path: ":memory:"))
        return PollCoordinator(store: store, publisher: PollNotificationPublisher(store: store, sink: RecordingNotificationSink()),
                               fetchers: [fetcher], deadline: deadline)
    }
    private func request(repositories: Int, reason: PollRequest.Reason = .scheduled) -> PollRequest {
        let keys = Set((1...repositories).map { RepositoryKey(account: account, repositoryID: String($0)) })
        return PollRequest(scopes: [PollScope(account: account, repositories: keys)], reason: reason)
    }

    func testBackgroundCadenceStretchesWithTrackedRepositoriesButOnScreenOnesStayFast() {
        XCTAssertEqual(PollCadence.interval(60, repositories: 10, focused: false), 60)
        XCTAssertEqual(PollCadence.interval(60, repositories: 168, focused: false), 168 * PollCadence.secondsPerRepository, accuracy: 0.001)
        XCTAssertEqual(PollCadence.interval(180, repositories: 168, focused: false), 302.4, accuracy: 0.001)
        XCTAssertEqual(PollCadence.interval(60, repositories: 168, focused: true), 60)
        // Active-run cadences are already short-lived and on purpose; they are never stretched.
        XCTAssertEqual(PollCadence.interval(15, repositories: 168, focused: false), 15)
        XCTAssertEqual(PollCadence.staleAfter(repositories: 10), 300)
        XCTAssertEqual(PollCadence.staleAfter(repositories: 168), 3 * 168 * PollCadence.secondsPerRepository, accuracy: 0.001)
    }

    func testRepositoriesAreNotStaleWhileTheirStretchedCadenceIsOnTime() {
        let key = RepositoryKey(account: account, repositoryID: "1")
        let read = Date().addingTimeInterval(-600)
        let status = PRInventoryStatus(complete: true, fetchedCount: 1, fetchedAt: read, message: nil, lastSuccessAt: read)
        let few = PRRepositoryFreshness(repository: key, name: "o/r", status: status, revoked: false, now: Date(), staleAfter: PollCadence.staleAfter(repositories: 10))
        let many = PRRepositoryFreshness(repository: key, name: "o/r", status: status, revoked: false, now: Date(), staleAfter: PollCadence.staleAfter(repositories: 168))
        XCTAssertEqual(few.state, .stale)
        XCTAssertTrue(few.isSyncing)
        XCTAssertFalse(few.needsAttention, "a late read is sync catching up, not something to act on")
        XCTAssertEqual(many.state, .fresh)
        let never = PRRepositoryFreshness(repository: key, name: "o/r", status: nil, revoked: false, now: Date(), staleAfter: 300)
        XCTAssertTrue(never.isSyncing)
        XCTAssertFalse(never.needsAttention)
    }

    func testAWalkWithMoreToReadStaysDueAndMarksTheCycleBacklogged() async throws {
        let fetcher = ContinuingWalkFetcher(continuing: 2)
        let poller = try make(fetcher)
        let first = try await poller.refresh(request(repositories: 1))
        let firstBacklogged = await poller.backlogged(first)
        XCTAssertTrue(firstBacklogged)
        let second = try await poller.refresh(request(repositories: 1))
        let secondBacklogged = await poller.backlogged(second)
        XCTAssertTrue(secondBacklogged)
        let third = try await poller.refresh(request(repositories: 1))
        let thirdBacklogged = await poller.backlogged(third)
        XCTAssertFalse(thirdBacklogged, "the walk finished")
        let callsAfterWalk = await fetcher.calls
        XCTAssertEqual(callsAfterWalk, 3, "a continuing walk does not wait out its 60 s interval")
        _ = try await poller.refresh(request(repositories: 1))
        let callsAfterIdle = await fetcher.calls
        XCTAssertEqual(callsAfterIdle, 3, "a finished walk waits out its interval again")
    }

    func testAContinuationThatNeverEndsFallsBackToItsInterval() async throws {
        let fetcher = ContinuingWalkFetcher(continuing: .max)
        let poller = try make(fetcher)
        for _ in 0...PollCoordinator.continuationLimit { _ = try await poller.refresh(request(repositories: 1)) }
        let calls = await fetcher.calls
        XCTAssertEqual(calls, PollCoordinator.continuationLimit + 1)
        _ = try await poller.refresh(request(repositories: 1))
        let after = await fetcher.calls
        XCTAssertEqual(after, calls, "after the limit, the scope waits out its interval")
    }

    func testACycleCutOffByItsDeadlineIsBackloggedAndTheNextOneContinues() async throws {
        let poller = try make(SlowRepositoryFetcher(delay: .milliseconds(60)), deadline: .milliseconds(300))
        let cut = try await poller.refresh(request(repositories: 20))
        let cutBacklogged = await poller.backlogged(cut)
        XCTAssertTrue(cutBacklogged)
        let quick = try make(SlowRepositoryFetcher(delay: .milliseconds(1)))
        let done = try await quick.refresh(request(repositories: 2))
        let doneBacklogged = await quick.backlogged(done)
        XCTAssertFalse(doneBacklogged)
    }
}

final class QuotaPacingTests: XCTestCase {
    private let account = AccountScope(host: "github.com", accountID: "1")
    private func graphQL(remaining: Int, cost: Int, resetIn: TimeInterval) -> GitHubResponse {
        let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(resetIn))
        return GitHubResponse(status: 200, headers: [:], data: Data(#"{"data":{"rateLimit":{"cost":\#(cost),"remaining":\#(remaining),"resetAt":"\#(reset)"}}}"#.utf8))
    }

    func testBackgroundReadsSpreadTheRemainingQuotaUntilItResets() async {
        let budget = RateBudget(minimumSpacing: .zero, interactiveReserve: 100)
        let none = await budget.quotaSpacing(account: account, resource: .graphql)
        XCTAssertEqual(none, .zero, "No observed quota: no pacing")
        // 3,600 s to spend 3,700 spendable points at 2 points a query: one query every ~1.95 s.
        await budget.observeGraphQL(graphQL(remaining: 3800, cost: 2, resetIn: 3600), account: account)
        let paced = await budget.quotaSpacing(account: account, resource: .graphql)
        XCTAssertEqual(Double(paced.components.seconds) + Double(paced.components.attoseconds) / 1e18, 1.95, accuracy: 0.05)
        // Plenty left near the reset: barely paced.
        await budget.observeGraphQL(graphQL(remaining: 4000, cost: 1, resetIn: 60), account: account)
        let relaxed = await budget.quotaSpacing(account: account, resource: .graphql)
        XCTAssertLessThan(relaxed, .milliseconds(50))
        // A reset beyond GitHub's hourly window is not a real quota; it never stalls reads.
        await budget.observeGraphQL(graphQL(remaining: 5000, cost: 1, resetIn: 86_400), account: account)
        let ignored = await budget.quotaSpacing(account: account, resource: .graphql)
        XCTAssertEqual(ignored, .zero)
        // REST is paced from its own headers and is unaffected by GraphQL.
        let rest = await budget.quotaSpacing(account: account, resource: .rest)
        XCTAssertEqual(rest, .zero)
    }
}
