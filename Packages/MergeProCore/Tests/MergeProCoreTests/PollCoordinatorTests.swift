import Foundation
import XCTest
import GRDB
@testable import MergeProCore

actor GatePollFetcher: PollFeatureFetcher {
    var calls = 0
    var waiting: [CheckedContinuation<PollFetchResult,Error>] = []
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        calls += 1
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func release(_ result: PollFetchResult) { if !waiting.isEmpty { waiting.removeFirst().resume(returning:result) } }
}
struct FixedPollFetcher: PollFeatureFetcher {
    let failAccount: String?
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        if context.account.accountID == failAccount { throw GitHubFailure.resourceDenied }
        return PollFetchResult(events:[pollEvent(Int(context.account.accountID) ?? 1,account:context.account.accountID)])
    }
}
private actor CountingIntervalPollFetcher: PollFeatureFetcher {
    nonisolated var pollInterval: TimeInterval? { 60 }
    var calls = 0
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        calls += 1
        return PollFetchResult(events:[pollEvent(calls)])
    }
}
private struct FiftyRepoFetcher: PollFeatureFetcher {
    var fetchScope: PollFetchScope { .repository }
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        let repo = context.repositories.first!
        for _ in 0..<10 { try await context.budget.acquire(account:context.account,resource:.rest,priority:.background) }
        let events = [pollEvent(1,account:context.account.accountID,repo:repo.repositoryID),pollEvent(2,account:context.account.accountID,repo:repo.repositoryID,category:"failed checks")]
        return PollFetchResult(events:events + events)
    }
}
/// A reproducible boundary: the configured number of scopes commit, then the next waits for expiry.
private actor DeadlineBoundaryFetcher: PollFeatureFetcher {
    nonisolated var fetchScope: PollFetchScope { .repository }
    private var starts: [UUID:Int] = [:]
    private var version = 0
    private let completionsBeforeExpiry: Int
    init(completionsBeforeExpiry: Int = 2) { self.completionsBeforeExpiry = completionsBeforeExpiry }
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        let repo = context.repositories.first!.repositoryID
        starts[context.cycleID, default: 0] += 1
        if starts[context.cycleID] == completionsBeforeExpiry + 1 {
            try await ContinuousClock().sleep(until: context.deadline.advanced(by: .seconds(1)))
            try context.checkDeadline()
        }
        version += 1
        return PollFetchResult(events: [pollEvent(version, repo: repo)])
    }
}

private struct HungRepositoryFetcher: PollFeatureFetcher {
    var fetchScope: PollFetchScope { .repository }
    var hung: Set<String> = ["0"]
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        let repo = context.repositories.first!.repositoryID
        if hung.contains(repo) {
            try await ContinuousClock().sleep(until: context.deadline.advanced(by: .seconds(1)))
            try context.checkDeadline()
        }
        return PollFetchResult(events: [pollEvent(Int(repo)!, repo: repo)])
    }
}

private actor OnePolicyFailure {
    var calls = 0
    func policy() throws -> NotificationPolicy {
        calls += 1
        if calls == 1 { throw GitHubFailure.invalidResponse }
        return NotificationPolicy(enabled:true)
    }
}
/// Repository-scoped reads through the budgeted client, one changed event per repository and read: exercises
/// the coordinator's per-repository work rotation under a deadline.
private struct PacedRepositoryProbeFetcher: PollFeatureFetcher {
    let interval: TimeInterval
    var featureID: String { "paced-repository-probe" }
    var fetchScope: PollFetchScope { .repository }
    var pollInterval: TimeInterval? { interval }
    var usesCachedPullRequests: Bool { false }
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        guard let client = context.client, let operation = context.operation, let repo = context.repositories.first,
              let name = context.repositoryMetadata[repo]?.name else { throw GitHubFailure.invalidResponse }
        try context.checkDeadline()
        let response = try await client.get(client.origin.appendingPathComponent("repos/"+name+"/notifications"),token:operation.credential.accessToken)
        let stamp = String(decoding:response.data,as:UTF8.self)
        let object = ProviderKey(host:repo.account.host,accountID:repo.account.accountID,repositoryID:repo.repositoryID,objectID:"probe")
        return PollFetchResult(events:[ChangeEvent(key:repo.repositoryID+"|"+stamp,object:object,category:"review request signals",occurredAt:Date(),title:"Fixture change")],
                               baselinedRepositories:context.repositories)
    }
}
private actor PacedChangedTransport: GitHubTransport {
    var versions: [String:Int] = [:]
    func send(_ request: URLRequest) async throws -> GitHubResponse {
        let name = request.url!.path.split(separator:"/")[2]
        let id = Int(name.dropFirst())!
        let version = (versions[String(name)] ?? 0) + 1; versions[String(name)] = version
        let stamp = String(format:"2026-10-01T10:%02d:00Z",version)
        return json("[{\"id\":\"\(id)\",\"reason\":\"review_requested\",\"updated_at\":\"\(stamp)\",\"repository\":{\"id\":\(id)},\"subject\":{\"title\":\"Fixture change\",\"type\":\"PullRequest\",\"url\":\"https://api.github.com/repos/owner/r\(id)/pulls/1\"}}]",headers:["X-Poll-Interval":"0"])
    }
}
private struct AuthFailureWithSiblingGate: PollFeatureFetcher {
    let gate: GatePollFetcher
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        if context.account.accountID == "2" { return try await gate.fetch(context) }
        let client = context.client!
        _ = try await client.get(client.origin.appendingPathComponent("fixture-read"),token:context.operation!.credential.accessToken)
        return PollFetchResult()
    }
}
/// Records each repository's starting checkpoint; while repository 1 is fetched, an interactive repository
/// tab refreshes repository 2 and commits a newer checkpoint for it.
private actor CheckpointProbeFetcher: PollFeatureFetcher {
    nonisolated var featureID: String { "probe-inventory" }
    nonisolated var fetchScope: PollFetchScope { .repository }
    let database: DatabaseStore
    let interactiveRepositories: [String]
    var seen: [String:[String]] = [:]
    init(database: DatabaseStore, interactiveRepositories: [String] = ["2"]) { self.database = database; self.interactiveRepositories = interactiveRepositories }
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        let repo = context.repositories.first!
        seen[repo.repositoryID] = context.cachedSnapshots.map { String(decoding:$0.payload,as:UTF8.self) }
        let key = { (id: String) in ProviderKey(host:repo.account.host,accountID:repo.account.accountID,repositoryID:id,objectID:"checkpoint") }
        if repo.repositoryID == "1" {
            for id in interactiveRepositories {
                let interactive = PollFeatureSnapshot(key:key(id),feature:featureID,payload:Data("interactive".utf8))
                try await database.database.write { db in
                    try db.execute(sql:"INSERT INTO pollFeatureSnapshots VALUES (?,?,?,?,?,?) ON CONFLICT(host,accountID,repositoryID,objectID,feature) DO UPDATE SET json=excluded.json",arguments:["github.com","1",id,"checkpoint",interactive.feature,try JSONEncoder().encode(interactive)])
                }
            }
        }
        let resumed = (context.cachedSnapshots.first.map { String(decoding:$0.payload,as:UTF8.self) } ?? "none") + "+cycle"
        return PollFetchResult(snapshots:[PollFeatureSnapshot(key:key(repo.repositoryID),feature:featureID,payload:Data(resumed.utf8))])
    }
}
@MainActor
final class PollCoordinatorTests: XCTestCase {
    func testManualRefreshReadsAgainWhileScheduledRefreshHonorsCadence() async throws {
        let fetcher = CountingIntervalPollFetcher()
        let (poller, store, _) = try make(fetcher)
        _ = try await poller.refresh(request())
        _ = try await poller.refresh(request())
        let count = await fetcher.calls
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try store.inbox().count, 2)
        let scheduled = PollRequest(scopes: request().scopes, reason: .scheduled)
        _ = try await poller.refresh(scheduled)
        let afterScheduled = await fetcher.calls
        XCTAssertEqual(afterScheduled, 2)
    }
    func make(_ fetcher: any PollFeatureFetcher, deadline: Duration = .seconds(30), scopes: [AccountScope] = [AccountScope(host:"github.com",accountID:"1")]) throws -> (PollCoordinator,PollCycleStore,RecordingNotificationSink) {
        let store = PollCycleStore(database:try DatabaseStore(path:":memory:")); let sink = RecordingNotificationSink()
        let poller = PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:sink),fetchers:[fetcher],deadline:deadline)
        return (poller,store,sink)
    }
    func request(_ accounts: [String] = ["1"], baseline: Bool = false) -> PollRequest {
        PollRequest(scopes:accounts.map { PollScope(account:AccountScope(host:"github.com",accountID:$0),repositories:[RepositoryKey(account:AccountScope(host:"github.com",accountID:$0),repositoryID:"1")]) },baseline:baseline,policy:NotificationPolicy(enabled:true))
    }
    func authFixture(_ transport: any GitHubTransport, deadline: Duration = .seconds(30), gate: GatePollFetcher = GatePollFetcher()) async throws -> (DatabaseStore,GitHubAccountSession,PollCoordinator) {
        let database = try DatabaseStore(path:":memory:")
        let directory = try makeTemporaryDirectory()
        let cache = try CacheStore(directory:directory,database:database)
        let credentials = MemoryCredentials()
        for id in ["1","2"] {
            let account = AccountScope(host:"github.com",accountID:id)
            let repo = RepositoryKey(account:account,repositoryID:"1")
            try database.saveAccount(Account(scope:account,login:"fixture",tokenReference:"fixture"))
            try database.saveRepository(Repository(key:repo,name:"fixture/repo",isPrivate:true,capabilities:ProviderCapabilities()))
            try database.setTracked(repo,tracked:true)
            try database.savePullRequests([PullRequest(key:ProviderKey(host:account.host,accountID:id,repositoryID:"1",objectID:"pr"),headRevision:RevisionID("sha"),title:"Fixture private PR",state:.open,isDraft:false)])
            credentials.save(GitHubCredential(accessToken:"fixture-" + id),account:account)
        }
        try await database.database.write { db in
            try db.execute(sql:"CREATE TRIGGER fixture_failed_invalid_state BEFORE INSERT ON settings WHEN NEW.name = 'authorizationProblem' BEGIN SELECT RAISE(ABORT, 'fixture persistence failure'); END")
        }
        let session = GitHubAccountSession(storage:AccountSessionStore(database:database,cache:cache,credentials:credentials),transport:transport)
        let store = PollCycleStore(database:database)
        let poller = PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:RecordingNotificationSink()),fetchers:[AuthFailureWithSiblingGate(gate:gate)],deadline:deadline,budget:RateBudget(minimumSpacing:.zero),session:session)
        return (database,session,poller)
    }
    func testHTTP401PublishesDeniedUISnapshotBeforeSiblingPollFinishesDespiteFailedSQLiteFlag() async throws {
        let gate = GatePollFetcher()
        let (database,session,poller) = try await authFixture(ScriptedTransport([json("{}",status:401)]),gate:gate)
        let account = AccountScope(host:"github.com",accountID:"1")
        var stream = try await session.authorizationChanges().makeAsyncIterator()
        let initialA = await stream.next(); let initialB = await stream.next()
        XCTAssertEqual(Set([initialA!.account,initialB!.account]),Set(request(["1","2"]).scopes.map(\.account)))
        XCTAssertEqual(initialA?.state,.available); XCTAssertEqual(initialB?.state,.available)
        let task = Task { try await poller.refresh(request(["1","2"])) }
        let deadline = ContinuousClock.now.advanced(by:.seconds(2))
        while try await session.authorizationState(for:account) == .available, ContinuousClock.now < deadline { await Task.yield() }
        let denied = try await session.authorizationState(for:account)
        XCTAssertEqual(denied,.authorizationRequired(localPersistenceFailed:true))
        XCTAssertNotEqual(try database.snapshot(for:account).settings["authorizationProblem"],"true")
        let snapshot = try await session.snapshot(for:account)
        let other = try await session.snapshot(for:AccountScope(host:"github.com",accountID:"2"))
        XCTAssertTrue(snapshot.pullRequests.isEmpty)
        XCTAssertEqual(other.pullRequests.count,1)
        XCTAssertEqual(PRWorkspaceSnapshot(snapshots:[snapshot,other]).rows.count,1)
        while await gate.calls == 0 { await Task.yield() }
        let changesA = await stream.next(); let changesB = await stream.next()
        XCTAssertEqual(changesA?.account,account); XCTAssertEqual(changesB?.account,account)
        XCTAssertEqual(changesB?.state,.authorizationRequired(localPersistenceFailed:true))
        await gate.release(PollFetchResult())
        _ = try await task.value
    }
    func testKnownHTTP401AfterCycleDeadlineStillRevokesCurrentCredential() async throws {
        let transport = ScriptedTransport.suspended()
        let (_,session,poller) = try await authFixture(transport,deadline:.milliseconds(30))
        let account = AccountScope(host:"github.com",accountID:"1")
        let task = Task { try await poller.refresh(request()) }
        await transport.waitUntilHolding()
        _ = try await task.value
        await transport.release(json("{}",status:401))
        let deadline = ContinuousClock.now.advanced(by:.seconds(1))
        while try await session.authorizationState(for:account) == .available, ContinuousClock.now < deadline { await Task.yield() }
        let state = try await session.authorizationState(for:account)
        XCTAssertEqual(state,.authorizationRequired(localPersistenceFailed:true))
    }
    func testOverlappingRefreshCoalescesThenRunsOneFollowUp() async throws {
        let gate = GatePollFetcher(); let (poller,store,sink) = try make(gate)
        let first = Task { try await poller.refresh(request()) }
        while await gate.calls == 0 { await Task.yield() }
        let second = Task { try await poller.refresh(request()) }
        let third = Task { try await poller.refresh(request()) }
        while await poller.coalescedRequestCount < 2 { await Task.yield() }
        await gate.release(PollFetchResult(events:[pollEvent(1)]))
        let firstID = try await first.value
        while await gate.calls < 2 { await Task.yield() }
        await gate.release(PollFetchResult(events:[pollEvent(1),pollEvent(2)]))
        let secondID = try await second.value; let thirdID = try await third.value
        XCTAssertNotEqual(firstID,secondID); XCTAssertEqual(secondID,thirdID)
        let calls = await gate.calls; XCTAssertEqual(calls,2)
        let deliveries = await sink.summaries.count; XCTAssertEqual(deliveries,2)
        XCTAssertEqual(try store.inbox().count,2)
    }
    func testPartialAccountFailureStillCommitsSuccessfulAccount() async throws {
        let (poller,store,sink) = try make(FixedPollFetcher(failAccount:"2"))
        let id = try await poller.refresh(request(["1","2"]))
        XCTAssertEqual(try store.inbox().count,1)
        XCTAssertEqual(try store.failures(id).count,1)
        let calls = await sink.summaries.count; XCTAssertEqual(calls,1)
    }
    func testDeadlineClosesWithoutWaitingForUncooperativeFetcherAndDiscardsLateResponse() async throws {
        let gate = GatePollFetcher(); let (poller,store,sink) = try make(gate,deadline:.milliseconds(30))
        let start = ContinuousClock.now
        let id = try await poller.refresh(request())
        let parked = await gate.waiting.count
        XCTAssertEqual(parked,1,"The cycle closed while its fetcher was still in flight")
        XCTAssertWithinPerformanceBudget(start.duration(to:.now),.seconds(1))
        XCTAssertEqual(try store.failures(id).count,1)
        await gate.release(PollFetchResult(events:[pollEvent(99)]))
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertTrue(try store.inbox().isEmpty)
        let calls = await sink.summaries.count; XCTAssertEqual(calls,0)
        let next = Task { try await poller.refresh(request()) }
        while await gate.calls < 2 { await Task.yield() }
        await gate.release(PollFetchResult(events:[pollEvent(100)]))
        _ = try await next.value; XCTAssertEqual(try store.inbox().map(\.event.key),[pollEvent(100).key])
    }
    func testBaselineAndActionReconciliationDoNotAlert() async throws {
        let (poller,store,sink) = try make(FixedPollFetcher(failAccount:nil))
        _ = try await poller.refresh(request(baseline:true))
        _ = try await poller.refresh(PollRequest(scopes:request().scopes,reason:.actionReconciliation,policy:NotificationPolicy(enabled:true)))
        let calls = await sink.summaries.count; XCTAssertEqual(calls,0)
        XCTAssertEqual(try store.inbox().count,1)
    }
    func test50RepoWorkloadHonorsInteractiveReserveAndSeparateResources() async throws {
        let budget = RateBudget(minimumSpacing:.zero,interactiveReserve:100)
        let account = AccountScope(host:"github.com",accountID:"1")
        await budget.observe(GitHubResponse(status:200,headers:["X-RateLimit-Remaining":"600","X-RateLimit-Reset":String(Date().addingTimeInterval(3600).timeIntervalSince1970)]),account:account)
        var accepted = 0
        // 50 repos: two inventory pages + one signal + two active-run pages + five prefetch reads.
        for _ in 0..<500 {
            do { try await budget.acquire(account:account,resource:.rest,priority:.background); accepted += 1 } catch { break }
        }
        XCTAssertEqual(accepted,500)
        do { try await budget.acquire(account:account,resource:.rest,priority:.background); XCTFail("must preserve 100 write requests") } catch {}
        try await budget.acquire(account:account,resource:.rest,priority:.interactive)
        try await budget.acquire(account:account,resource:.graphql,priority:.background,cost:30)
        await budget.observe(GitHubResponse(status:403,headers:["Retry-After":"60","X-RateLimit-Remaining":"499"]),account:account)
        do { try await budget.acquire(account:account,resource:.rest,priority:.interactive); XCTFail("positive primary budget does not bypass secondary limit") } catch {}
    }
    func testProductionFeedReadsTheAccountFeedOncePerCycleKeepsOnlyTrackedRepositoriesAndIsConditional() async throws {
        let account = AccountScope(host:"github.com",accountID:"1")
        let repo = RepositoryKey(account:account,repositoryID:"7"), other = RepositoryKey(account:account,repositoryID:"9")
        let database = try DatabaseStore(path:":memory:")
        try database.saveAccount(Account(scope:account,login:"fixture",tokenReference:"fixture"))
        try database.saveRepository(Repository(key:repo,name:"owner/tracked",isPrivate:true,capabilities:ProviderCapabilities()))
        try database.saveRepository(Repository(key:other,name:"owner/also-tracked",isPrivate:true,capabilities:ProviderCapabilities()))
        try database.setTracked(repo,tracked:true); try database.setTracked(other,tracked:true)
        let directory = try makeTemporaryDirectory()
        let cache = try CacheStore(directory:directory,database:database)
        let credentials = MemoryCredentials(); credentials.save(GitHubCredential(accessToken:"fixture"),account:account)
        // The account feed also carries a thread of an untracked repository (8); it is never recorded.
        let firstBody = #"[{"id":"1","reason":"review_requested","updated_at":"2026-10-01T10:00:00Z","repository":{"id":7},"subject":{"title":"Fixture PR","type":"PullRequest","url":"https://api.github.com/repos/owner/tracked/pulls/23"}},{"id":"2","reason":"mention","updated_at":"2026-10-01T09:00:00Z","repository":{"id":8},"subject":{"title":"Untracked","type":"Issue","url":"https://api.github.com/repos/owner/untracked/issues/4"}}]"#
        let changedBody = firstBody.replacingOccurrences(of:"10:00:00",with:"11:00:00")
        let transport = ScriptedTransport([json(firstBody,headers:["Last-Modified":"Thu, 01 Oct 2026 10:00:00 GMT","X-Poll-Interval":"0"]),json("",status:304,headers:["X-Poll-Interval":"0"]),json(changedBody,headers:["X-Poll-Interval":"0"])])
        let session = GitHubAccountSession(storage:AccountSessionStore(database:database,cache:cache,credentials:credentials),transport:transport)
        let store = PollCycleStore(database:database); let sink = RecordingNotificationSink()
        let poller = PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:sink),fetchers:[GitHubNotificationFeedFetcher(interval:0)],budget:RateBudget(minimumSpacing:.zero),session:session)
        let request = PollRequest(scopes:[PollScope(account:account,repositories:[repo,other])],policy:NotificationPolicy(enabled:true))
        _ = try await poller.refresh(request)
        _ = try await poller.refresh(request)
        _ = try await poller.refresh(request)
        let requests = await transport.captured()
        XCTAssertEqual(requests.count,3,"One account-wide read per cycle, however many repositories are tracked")
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/notifications" })
        XCTAssertTrue(requests.allSatisfy { URLComponents(url:$0.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "per_page"})?.value == "50" })
        XCTAssertEqual(requests[1].value(forHTTPHeaderField:"If-Modified-Since"),"Thu, 01 Oct 2026 10:00:00 GMT")
        let events = try store.inbox(); XCTAssertEqual(events.count,2)
        XCTAssertTrue(events.allSatisfy { $0.event.object.repositoryID == "7" },"Untracked repositories' threads are dropped")
        XCTAssertEqual(events.first?.event.locator?.subjectNumber,"23")
        XCTAssertEqual(events.first?.event.locator?.webURL?.absoluteString,"https://github.com/owner/tracked/pull/23")
        XCTAssertEqual(events.first?.event.object.objectID,"notification-thread:1")
        let deliveries = await sink.summaries.count; XCTAssertEqual(deliveries,1)
    }
    func testActualRequestsAreSerializedPerAccount() async throws {
        let account = AccountScope(host:"github.com",accountID:"1")
        let base = ScriptedTransport.suspended()
        let budget = RateBudget(minimumSpacing:.zero)
        let transport = BudgetedGitHubTransport(base:base,budget:budget,account:account)
        let first = Task { try await transport.send(URLRequest(url:URL(string:"https://api.github.com/one")!)) }
        await base.waitUntilHolding()
        let second = Task { try await transport.send(URLRequest(url:URL(string:"https://api.github.com/two")!)) }
        await budget.untilWaiting(account:account,slot:1)
        let before = await base.requests.count; XCTAssertEqual(before,1)
        await base.release(json("[]")); _ = try await first.value; _ = try await second.value
        let after = await base.requests.count; XCTAssertEqual(after,2)
    }
    func testZeroTrackedScopeDoesNotFetchOrEstablishUntrackedBaseline() async throws {
        let gate = GatePollFetcher(); let (poller,store,_) = try make(gate)
        _ = try await poller.refresh(PollRequest(scopes:[PollScope(account:AccountScope(host:"github.com",accountID:"1"),repositories:[])],policy:NotificationPolicy(enabled:true)))
        let calls = await gate.calls; XCTAssertEqual(calls,0); XCTAssertTrue(try store.inbox().isEmpty)
    }
    func testNewActionReconciliationEventNeverLeaksIntoLaterSummary() async throws {
        let (poller,store,sink) = try make(FixedPollFetcher(failAccount:nil))
        _ = try await poller.refresh(PollRequest(scopes:request().scopes,reason:.actionReconciliation,policy:NotificationPolicy(enabled:true)))
        _ = try await poller.refresh(request())
        let calls = await sink.summaries.count; XCTAssertEqual(calls,0)
        XCTAssertTrue(try store.inbox()[0].surfaced)
    }

    func test50RepositoryScopedFetchersAcrossTwoAccountsCommit100EventsAndOneSummary() async throws {
        let store = PollCycleStore(database:try DatabaseStore(path:":memory:")); let sink = RecordingNotificationSink()
        let budget = RateBudget(minimumSpacing:.zero)
        let poller = PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:sink),fetchers:[FiftyRepoFetcher()],budget:budget)
        let scopes = ["1","2"].map { id -> PollScope in
            let account = AccountScope(host:"github.com",accountID:id)
            return PollScope(account:account,repositories:Set((0..<25).map { RepositoryKey(account:account,repositoryID:String(Int(id)!*25+$0)) }))
        }
        let id = try await poller.refresh(PollRequest(scopes:scopes,policy:NotificationPolicy(enabled:true)))
        XCTAssertEqual(try store.inbox().count,100)
        XCTAssertTrue(try store.failures(id).isEmpty)
        let summaries = await sink.summaries; XCTAssertEqual(summaries.count,1)
        XCTAssertEqual(summaries[0].eventKeys.count,100)
        XCTAssertEqual(summaries[0].body,"100 updates across 50 repos, 2 accounts: 50 failed checks, 50 reviews requested.")
        _ = try await poller.refresh(PollRequest(scopes:scopes,policy:NotificationPolicy(enabled:true)))
        let after = await sink.summaries.count; XCTAssertEqual(after,1)
    }

    func testFailedPolicyFinalizationInterruptsOwnedCycleAndNextRefreshSucceeds() async throws {
        let path = try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path
        let database = try DatabaseStore(path:path); let store = PollCycleStore(database:database)
        let sink = RecordingNotificationSink(); let policy = OnePolicyFailure()
        let poller = PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:sink),fetchers:[FixedPollFetcher(failAccount:nil)],policyProvider:{ try await policy.policy() })
        do { _ = try await poller.refresh(request()); XCTFail("first policy must fail") } catch {}
        XCTAssertEqual(try store.inbox().count,1)
        let queue = try DatabaseQueue(path:path)
        let states = try await queue.read { try String.fetchAll($0,sql:"SELECT status FROM pollCycles ORDER BY startedAt") }
        XCTAssertEqual(states,["interrupted"])
        let id = try await poller.refresh(request())
        XCTAssertNotNil(try store.summary(id))
        let calls = await sink.summaries.count; XCTAssertEqual(calls,1)
        XCTAssertEqual(try store.inbox().count,1)
    }
    func testFailedSQLiteCloseInterruptsOnlyOwnedCycleAndRetainsInboxForNextRefresh() async throws {
        let path = try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path
        let database = try DatabaseStore(path:path); let store = PollCycleStore(database:database)
        let queue = try DatabaseQueue(path:path)
        try await queue.write { try $0.execute(sql:"CREATE TRIGGER fail_close BEFORE UPDATE OF status ON pollCycles WHEN NEW.status='closed' BEGIN SELECT RAISE(ABORT,'fixture close failure'); END") }
        let sink = RecordingNotificationSink()
        let poller = PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:sink),fetchers:[FixedPollFetcher(failAccount:nil)])
        do { _ = try await poller.refresh(request()); XCTFail("close must fail") } catch {}
        let states = try await queue.read { try String.fetchAll($0,sql:"SELECT status FROM pollCycles") }
        XCTAssertEqual(states,["interrupted"])
        XCTAssertEqual(try store.inbox().count,1)
        try await queue.write { try $0.execute(sql:"DROP TRIGGER fail_close") }
        _ = try await poller.refresh(request())
        let calls = await sink.summaries.count; XCTAssertEqual(calls,1)
    }
    func testDeadlineCutoffScopesEventuallyCommitInsteadOfRepeatingAtTheSameBoundary() async throws {
        let account = AccountScope(host: "github.com", accountID: "1")
        let repositories = Set((0..<6).map { RepositoryKey(account: account, repositoryID: String($0)) })
        let store = PollCycleStore(database: try DatabaseStore(path: ":memory:"))
        let sink = RecordingNotificationSink()
        let fetcher = DeadlineBoundaryFetcher()
        let poller = PollCoordinator(store: store, publisher: PollNotificationPublisher(store: store, sink: sink),
                                     fetchers: [fetcher], deadline: .milliseconds(100), budget: RateBudget(minimumSpacing: .zero))
        let request = PollRequest(scopes: [PollScope(account: account, repositories: repositories)], policy: NotificationPolicy(enabled: true))
        for _ in 0..<4 { _ = try await poller.refresh(request) }
        XCTAssertEqual(Set(try store.inbox().map { $0.event.object.repositoryID }), Set(["0", "1", "2", "3", "4", "5"]),
                       "A started scope whose response missed the deadline must receive a turn early enough to commit")
        let summaries = await sink.summaries
        XCTAssertLessThanOrEqual(summaries.count, 4)
    }

    func testARepeatedlyHungScopeDoesNotPreventOtherScopesFromCommitting() async throws {
        let account = AccountScope(host: "github.com", accountID: "1")
        let repositories = Set((0..<4).map { RepositoryKey(account: account, repositoryID: String($0)) })
        let store = PollCycleStore(database: try DatabaseStore(path: ":memory:"))
        let poller = PollCoordinator(store: store, publisher: PollNotificationPublisher(store: store, sink: RecordingNotificationSink()),
                                     fetchers: [HungRepositoryFetcher()], deadline: .milliseconds(100), budget: RateBudget(minimumSpacing: .zero))
        for _ in 0..<4 { _ = try await poller.refresh(PollRequest(scopes: [PollScope(account: account, repositories: repositories)])) }
        XCTAssertEqual(Set(try store.inbox().map { $0.event.object.repositoryID }), Set(["1", "2", "3"]))
    }

    func testTwoRepeatedlyHungScopesDoNotStarveHealthyScopesBehindThem() async throws {
        let account = AccountScope(host: "github.com", accountID: "1")
        let repositories = Set((0..<4).map { RepositoryKey(account: account, repositoryID: String($0)) })
        let store = PollCycleStore(database: try DatabaseStore(path: ":memory:"))
        let poller = PollCoordinator(store: store, publisher: PollNotificationPublisher(store: store, sink: RecordingNotificationSink()),
                                     fetchers: [HungRepositoryFetcher(hung: ["0", "1"])], deadline: .milliseconds(100), budget: RateBudget(minimumSpacing: .zero))
        for _ in 0..<8 { _ = try await poller.refresh(PollRequest(scopes: [PollScope(account: account, repositories: repositories)])) }
        XCTAssertEqual(Set(try store.inbox().map { $0.event.object.repositoryID }), Set(["2", "3"]),
                       "Consecutive unfinished attempts must move beyond a hung prefix, not swap the same leading scopes forever")
    }

    func testTwoScopesWithOneCompletionPerCycleBothEventuallyCommit() async throws {
        let account = AccountScope(host: "github.com", accountID: "1")
        let repositories = Set(["0", "1"].map { RepositoryKey(account: account, repositoryID: $0) })
        let store = PollCycleStore(database: try DatabaseStore(path: ":memory:"))
        let fetcher = DeadlineBoundaryFetcher(completionsBeforeExpiry: 1)
        let poller = PollCoordinator(store: store, publisher: PollNotificationPublisher(store: store, sink: RecordingNotificationSink()),
                                     fetchers: [fetcher], deadline: .milliseconds(100), budget: RateBudget(minimumSpacing: .zero))
        for _ in 0..<4 { _ = try await poller.refresh(PollRequest(scopes: [PollScope(account: account, repositories: repositories)])) }
        let events = try store.inbox()
        XCTAssertEqual(Set(events.map { $0.event.object.repositoryID }), Set(["0", "1"]),
                       "The cutoff scope needs an immediate retry even when there is only one other queued scope")
        XCTAssertGreaterThan(events.count, 2)
    }

    func testPaced50SingleAccountChangedScopesMakeFairProgressAcrossCycles() async throws {
        let account = AccountScope(host:"github.com",accountID:"1")
        let database = try DatabaseStore(path:":memory:")
        try database.saveAccount(Account(scope:account,login:"fixture",tokenReference:"fixture"))
        let repositories = Set((0..<50).map { RepositoryKey(account:account,repositoryID:String($0)) })
        for repo in repositories {
            try database.saveRepository(Repository(key:repo,name:"owner/r"+repo.repositoryID,isPrivate:true,capabilities:[]))
            try database.setTracked(repo,tracked:true)
        }
        let directory = try makeTemporaryDirectory()
        let cache = try CacheStore(directory:directory,database:database)
        let credentials = MemoryCredentials(); credentials.save(GitHubCredential(accessToken:"fixture"),account:account)
        let transport = PacedChangedTransport()
        let session = GitHubAccountSession(storage:AccountSessionStore(database:database,cache:cache,credentials:credentials),transport:transport)
        let store = PollCycleStore(database:database); let sink = RecordingNotificationSink()
        // 10 ms pacing / 300 ms deadline scales production 1 second / 30 seconds by 100: no cycle reaches all 50.
        let budget = RateBudget(minimumSpacing:.milliseconds(10))
        let poller = PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:sink),fetchers:[PacedRepositoryProbeFetcher(interval:0.4)],deadline:.milliseconds(300),budget:budget,session:session)
        let request = PollRequest(scopes:[PollScope(account:account,repositories:repositories)],policy:NotificationPolicy(enabled:true))
        // How many repositories a cycle reaches depends on machine load, so cycles run until every repository was
        // read and one was read again. Rotation is what gets there: a cycle that restarted from the same prefix
        // would never pass the repositories it cannot reach in time, and the bound would fail the test.
        var cycles = 0, events: [InboxEvent] = [], covered = Set<String>()
        repeat {
            _ = try await poller.refresh(request); cycles += 1
            events = try store.inbox(); covered = Set(events.map { $0.event.object.repositoryID })
        } while (covered.count < 50 || events.count <= 50) && cycles < 60
        XCTAssertEqual(covered,Set((0..<50).map(String.init)))
        // Repeated responses are changed, so successful prior scopes cannot simply be disabled.
        XCTAssertGreaterThan(events.count,50)
        let summaries = await sink.summaries
        XCTAssertLessThanOrEqual(summaries.count,cycles)
        if PerformanceThresholds.enabled { XCTAssertLessThanOrEqual(cycles,4,"An idle machine covers 50 paced repositories in four cycles") }
    }
    func testLaterRepositoryWorkResumesFromCheckpointCommittedEarlierInTheSameCycle() async throws {
        let account = AccountScope(host:"github.com",accountID:"1")
        let database = try DatabaseStore(path:":memory:")
        try database.saveAccount(Account(scope:account,login:"fixture"))
        let repositories = Set(["1","2"].map { RepositoryKey(account:account,repositoryID:$0) })
        for repo in repositories { try database.saveRepository(Repository(key:repo,name:"owner/r"+repo.repositoryID,isPrivate:true,capabilities:[])) }
        let fetcher = CheckpointProbeFetcher(database:database)
        let store = PollCycleStore(database:database)
        let poller = PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:RecordingNotificationSink()),fetchers:[fetcher],budget:RateBudget(minimumSpacing:.zero))
        _ = try await poller.refresh(PollRequest(scopes:[PollScope(account:account,repositories:repositories)]))
        let seen = await fetcher.seen
        XCTAssertEqual(seen["1"],[]); XCTAssertEqual(seen["2"],["interactive"],"Repository 2 starts from the newer interactive checkpoint, not the cycle-start read")
        let stored = try XCTUnwrap(store.snapshot(ProviderKey(host:"github.com",accountID:"1",repositoryID:"2",objectID:"checkpoint"),feature:"probe-inventory"))
        XCTAssertEqual(String(decoding:stored.payload,as:UTF8.self),"interactive+cycle")
    }
    func testWorkItemNeverOverwritesACheckpointCommittedWhileItWasFetching() async throws {
        let account = AccountScope(host:"github.com",accountID:"1")
        let database = try DatabaseStore(path:":memory:")
        try database.saveAccount(Account(scope:account,login:"fixture"))
        let repo = RepositoryKey(account:account,repositoryID:"1")
        try database.saveRepository(Repository(key:repo,name:"owner/r1",isPrivate:true,capabilities:[]))
        let key = ProviderKey(host:"github.com",accountID:"1",repositoryID:"1",objectID:"checkpoint")
        let seed = PollFeatureSnapshot(key:key,feature:"probe-inventory",payload:Data("seed".utf8))
        try await database.database.write { db in
            try db.execute(sql:"INSERT INTO pollFeatureSnapshots VALUES (?,?,?,?,?,?)",arguments:["github.com","1","1","checkpoint",seed.feature,try JSONEncoder().encode(seed)])
        }
        // An interactive refresh of the same repository commits while the poller's work item is in flight.
        let fetcher = CheckpointProbeFetcher(database:database,interactiveRepositories:["1"])
        let store = PollCycleStore(database:database)
        let poller = PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:RecordingNotificationSink()),fetchers:[fetcher],budget:RateBudget(minimumSpacing:.zero))
        _ = try await poller.refresh(PollRequest(scopes:[PollScope(account:account,repositories:[repo])]))
        let seen = await fetcher.seen
        XCTAssertEqual(seen["1"],["seed"])
        let stored = try XCTUnwrap(store.snapshot(key,feature:"probe-inventory"))
        XCTAssertEqual(String(decoding:stored.payload,as:UTF8.self),"interactive","the newer checkpoint is kept; the poller resumes from it next cycle")
        // The next cycle resumes from it (the fixture's repeated interactive write leaves the same value).
        _ = try await poller.refresh(PollRequest(scopes:[PollScope(account:account,repositories:[repo])]))
        let resumed = await fetcher.seen
        XCTAssertEqual(resumed["1"],["interactive"])
        XCTAssertEqual(String(decoding:try XCTUnwrap(store.snapshot(key,feature:"probe-inventory")).payload,as:UTF8.self),"interactive+cycle")
    }

}
