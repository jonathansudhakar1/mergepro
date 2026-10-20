import Foundation
import XCTest
@testable import MergeProCore

/// GitHub-like account for whole-cycle budgets: GraphQL inventory heads (one open PR per repository), the
/// account notification feed and each repository's Actions run list (a full page of 100 runs), all with ETag
/// revalidation. Latency is scaled with the budget (1/10 of production), and every request is counted by kind.
private actor CycleBudgetTransport: GitHubTransport {
    private(set) var counts: [String:Int] = [:]
    /// Repository whose newest run changes on every read (a running workflow), if any.
    private var busy: Int?
    private var tick = 0
    /// Scaled provider latency, simulated only when wall-clock budgets are checked.
    private let latency = PerformanceThresholds.enabled ? (graphQL: Duration.milliseconds(40), rest: Duration.milliseconds(10)) : (graphQL: .zero, rest: .zero)
    func setBusy(_ id: Int?) { busy = id }
    func reset() { counts = [:] }
    var total: Int { counts.values.reduce(0,+) }
    private static var viewer: [String:Any] { ["id": "VIEWER", "databaseId": 1, "login": "viewer"] }
    private static var empty: [String:Any] { ["nodes": [], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]] }
    private static func pr(_ repository: Int) -> [String:Any] {
        ["id": "R\(repository)PR1", "number": 1, "url": "https://github.com/o/r\(repository)/pull/1", "title": "Fixture", "state": "OPEN", "isDraft": false,
         "headRefOid": "sha", "baseRefOid": "base", "baseRefName": "main", "headRefName": "feature", "createdAt": "2026-10-01T10:00:00Z",
         "updatedAt": "2026-10-01T10:00:00Z", "author": ["__typename": "User", "id": "AUTHOR", "login": "author"], "mergeable": "MERGEABLE",
         "reviewDecision": NSNull(), "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"]]]]],
         "reviewRequests": empty, "labels": empty, "assignees": empty, "reviews": empty, "timelineItems": empty]
    }
    private func respond(_ data: Data, request: URLRequest) -> GitHubResponse {
        var hasher = Hasher(); data.withUnsafeBytes { hasher.combine(bytes:$0) }
        let etag = "W/\"\(hasher.finalize())\""
        if request.value(forHTTPHeaderField:"If-None-Match") == etag { return GitHubResponse(status:304,headers:["ETag":etag]) }
        return GitHubResponse(status:200,headers:["ETag":etag],data:data)
    }
    func send(_ request: URLRequest) async throws -> GitHubResponse {
        let url = request.url!, path = url.path
        if request.httpMethod == "POST" {
            if latency.graphQL > .zero { try await Task.sleep(for:latency.graphQL) }
            let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
            let query = body["query"] as! String, variables = body["variables"] as? [String:Any] ?? [:]
            guard query.contains("query Inventory") else { counts["graphql other",default:0] += 1; return json(#"{"data":{}}"#) }
            counts["inventory",default:0] += 1
            let repository = Int((variables["repo"] as? String ?? "r0").dropFirst()) ?? 0
            var repo: [String:Any] = ["pullRequests": ["nodes": [Self.pr(repository)], "pageInfo": ["hasNextPage": false, "endCursor": "c"]]]
            if query.contains("openVolatile:") {
                repo["openVolatile"] = ["nodes": [["id": "R\(repository)PR1", "headRefOid": "sha", "updatedAt": "2026-10-01T10:00:00Z", "mergeable": "MERGEABLE",
                    "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"]]]]], "labels": Self.empty]],
                    "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]
            }
            let envelope: [String:Any] = ["data": ["viewer": Self.viewer, "repository": repo, "rateLimit": ["cost": 1, "remaining": 4000, "resetAt": "2030-01-01T00:00:00Z"]]]
            return GitHubResponse(status:200,data:try JSONSerialization.data(withJSONObject:envelope))
        }
        if latency.rest > .zero { try await Task.sleep(for:latency.rest) }
        if path == "/user/teams" { counts["teams",default:0] += 1; return json("[]") }
        if path == "/notifications" { counts["notifications",default:0] += 1; return respond(Data("[]".utf8),request:request) }
        let parts = path.split(separator:"/")
        guard parts.count >= 5, parts[3] == "actions", let repository = Int(parts[2].dropFirst()) else {
            counts["other",default:0] += 1; return json(#"{"message":"Not Found"}"#,status:404)
        }
        counts["actions",default:0] += 1
        let status = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "status" }?.value
        var runs: [[String:Any]] = []
        if status == nil {
            if busy == repository { tick += 1 }
            let stamp = busy == repository ? String(format:"2026-10-01T11:%02d:%02dZ",(tick / 60) % 60,tick % 60) : "2026-10-01T10:05:00Z"
            runs = (1...100).map { id in
                ["id": repository * 1000 + id, "workflow_id": 3, "run_attempt": 1, "name": "CI", "head_branch": "main", "head_sha": "sha", "event": "push",
                 "actor": ["login": "dev"], "status": "completed", "conclusion": "success", "created_at": "2026-10-01T10:00:00Z",
                 "updated_at": id == 100 ? stamp : "2026-10-01T10:05:00Z", "html_url": "https://github.com/o/r\(repository)/actions/runs/\(id)",
                 "repository": ["id": repository], "pull_requests": []]
            }
        }
        return respond(try JSONSerialization.data(withJSONObject:["total_count": runs.count, "workflow_runs": runs],options:.sortedKeys),request:request)
    }
}

final class PollCycleBudgetTests: XCTestCase {
    let account = AccountScope(host:"github.com",accountID:"1")

    /// Twenty tracked repositories, every feature on: a cycle's requests are counted and must fit its deadline.
    /// Scaled 1/10 from production (250 ms background read spacing → 25 ms, 30 s deadline → 3 s; GraphQL and REST
    /// latency 400 ms and 100 ms → 40 ms and 10 ms). The counted requests always must fit the scaled deadline at
    /// that latency and spacing; with MERGEPRO_PERF_TESTS=1 the cycles also run against the real 3 s deadline with
    /// the latency simulated (otherwise a 30 s deadline keeps load from cutting cycles and changing the counts).
    func testTwentyRepositoryCycleCountsRequestsAndFitsTheDeadline() async throws {
        let database = try DatabaseStore(path:":memory:")
        try database.saveAccount(Account(scope:account,login:"viewer",tokenReference:"fixture"))
        let repositories = Set((1...20).map { RepositoryKey(account:account,repositoryID:String($0)) })
        for repo in repositories {
            try database.saveRepository(Repository(key:repo,name:"o/r"+repo.repositoryID,isPrivate:false,capabilities:[.readPullRequests,.readWorkflows]))
            try database.setTracked(repo,tracked:true)
        }
        let directory = try makeTemporaryDirectory()
        let credentials = MemoryCredentials(); credentials.save(GitHubCredential(accessToken:"fixture",scopes:["repo"]),account:account)
        let transport = CycleBudgetTransport()
        let session = GitHubAccountSession(storage:AccountSessionStore(database:database,cache:try CacheStore(directory:directory,database:database),credentials:credentials),transport:transport)
        let store = PollCycleStore(database:database)
        let budget = RateBudget(minimumSpacing:.milliseconds(100),backgroundReadSpacing:.milliseconds(25))
        let poller = PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:RecordingNotificationSink()),
            fetchers:[GitHubNotificationFeedFetcher(),GitHubPRInventoryFetcher(),GitHubActionsFetcher()],deadline:PerformanceThresholds.enabled ? .seconds(3) : .seconds(30),budget:budget,session:session)
        // Manual cycles force every feature to run (no cadence skips), so each cycle does its full work.
        let request = PollRequest(scopes:[PollScope(account:account,repositories:repositories)],reason:.manual)
        typealias Cycle = (total: Int, counts: [String:Int], failures: [String], changes: PollCycleChanges)
        func run(busy: Int?) async throws -> Cycle {
            await transport.reset(); await transport.setBusy(busy)
            let id = try await poller.refresh(request)
            return (await transport.total,await transport.counts,try store.failures(id),await poller.changes(for:id) ?? PollCycleChanges())
        }
        // Cold start: first reads of every repository (full run lists, first evidence attempts) may span cycles.
        var warmup: [Cycle] = []
        repeat { warmup.append(try await run(busy:nil)) } while !(warmup.last!.failures.isEmpty) && warmup.count < 4
        XCTAssertTrue(warmup.last!.failures.isEmpty,"Cold-start work finishes within a few cycles")
        let quiet = try await run(busy:nil), busy = try await run(busy:7), again = try await run(busy:7)
        let labels = warmup.indices.map { "warm-up \($0 + 1)" } + ["quiet","busy","busy"]
        for (label,cycle) in zip(labels,warmup + [quiet,busy,again]) {
            print("PollCycleBudget \(label): \(cycle.total) requests \(cycle.counts.sorted { $0.key < $1.key }) deadline misses \(cycle.failures.count) changed PR rows \(cycle.changes.pullRequests.count)")
        }
        for cycle in [quiet,busy,again] {
            XCTAssertTrue(cycle.failures.isEmpty,"A warm cycle never misses its deadline: \(cycle.failures)")
            XCTAssertEqual(cycle.counts["notifications"],1,"One account-wide notifications read")
            XCTAssertEqual(cycle.counts["inventory"],20,"One inventory head read per repository")
            XCTAssertTrue(cycle.changes.pullRequests.isEmpty,"Unchanged PRs rewrite no row")
        }
        // Each request costs at most its latency plus the background spacing (requests go out one at a time).
        func modeled(_ counts: [String:Int]) -> Duration {
            let graphQL = (counts["inventory"] ?? 0) + (counts["graphql other"] ?? 0), rest = counts.values.reduce(0,+) - graphQL
            return .milliseconds(graphQL * (40 + 25) + rest * (10 + 25))
        }
        for cycle in [quiet,busy,again] { XCTAssertLessThan(modeled(cycle.counts),.seconds(3),"A warm cycle's requests fit the scaled deadline: \(cycle.counts)") }
        XCTAssertEqual(quiet.counts["actions"],20,"An unchanged (304) run list answers for its repository")
        XCTAssertEqual(quiet.total,41)
        XCTAssertLessThanOrEqual(busy.counts["actions"] ?? 0,26,"Only the repository whose run list changed fans out")
        XCTAssertEqual(again.changes.repositories(feature:"github-actions"),[RepositoryKey(account:account,repositoryID:"7")])
    }
}
