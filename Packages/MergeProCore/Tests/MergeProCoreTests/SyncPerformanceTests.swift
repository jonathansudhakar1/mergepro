import Foundation
import XCTest
@testable import MergeProCore

/// GitHub answers 429 as the sending task is cancelled, as when a poll cycle expires mid-request.
private func cancelOn429Transport() async -> ScriptedTransport {
    let transport = ScriptedTransport(fallback:json("{}",status:429,headers:["Retry-After":"120"]))
    await transport.beforeAnswering { _ in withUnsafeCurrentTask { $0?.cancel() } }
    return transport
}

/// Latency here is checked against the pacing it must not inherit (always) and against absolute budgets
/// (only with MERGEPRO_PERF_TESTS=1). Tests await the budget's waiter counts (`RateBudget.untilWaiting`) to know a
/// competing task reached it.
final class SyncPerformanceTests: XCTestCase {
    let account = AccountScope(host:"github.com",accountID:"1")

    // MARK: P4 interactive latency

    func testInteractiveReadStartsWithin50msOfBackgroundRequestFinishingDespiteQueuedBackgroundWork() async throws {
        // Queued background work is paced a full second; a read that inherited that pacing would start no sooner.
        let spacing = Duration.seconds(1)
        let budget = RateBudget(minimumSpacing:.seconds(1),backgroundReadSpacing:spacing)
        let base = ScriptedTransport.suspended()
        let background = BudgetedGitHubTransport(base:base,budget:budget,account:account)
        let interactive = BudgetedGitHubTransport(base:base,budget:budget,account:account,interactiveRead:true)
        let first = Task { try await background.send(URLRequest(url:URL(string:"https://api.github.com/background-1")!)) }
        await base.waitUntilHolding()
        let queued = Task { try await background.send(URLRequest(url:URL(string:"https://api.github.com/background-2")!)) }
        let read = Task { try await interactive.send(URLRequest(url:URL(string:"https://api.github.com/interactive")!)) }
        // The queued background request sleeps off its pacing while the read waits for the slot.
        await budget.untilWaiting(account:account,slot:1,pacing:1)
        let released = ContinuousClock.now
        await base.release()
        _ = try await first.value; _ = try await read.value
        let arrival = await base.arrival("/interactive")
        let started = try XCTUnwrap(arrival)
        XCTAssertLessThan(released.duration(to:started),spacing / 2,"Interactive work must not inherit background pacing")
        XCTAssertWithinPerformanceBudget(released.duration(to:started),.milliseconds(50),"Interactive work must not inherit background pacing")
        _ = try await queued.value
        let order = await base.paths()
        XCTAssertEqual(order,["/background-1","/interactive","/background-2"])
    }
    func testBackgroundSpacingSleepDoesNotHoldTheAccountSlot() async throws {
        // The second background request sleeps 30 s for spacing (it is cancelled, never sent).
        let budget = RateBudget(minimumSpacing:.seconds(2),backgroundReadSpacing:.seconds(30))
        let base = ScriptedTransport(fallback:json("[]"))
        let background = BudgetedGitHubTransport(base:base,budget:budget,account:account)
        let interactive = BudgetedGitHubTransport(base:base,budget:budget,account:account,interactiveRead:true)
        _ = try await background.send(URLRequest(url:URL(string:"https://api.github.com/one")!))
        // An interactive read must not wait behind the sleeping request.
        let spaced = Task { try await background.send(URLRequest(url:URL(string:"https://api.github.com/two")!)) }
        await budget.untilWaiting(account:account,pacing:1)
        let start = ContinuousClock.now
        _ = try await interactive.send(URLRequest(url:URL(string:"https://api.github.com/read")!))
        let order = await base.paths()
        XCTAssertEqual(order,["/one","/read"],"The read went out while the spaced background request was still sleeping")
        XCTAssertWithinPerformanceBudget(start.duration(to:.now),.milliseconds(200))
        spaced.cancel(); _ = try? await spaced.value
    }
    func testUserWritesTakeInteractiveSlotPriorityAndReserve() async throws {
        let budget = RateBudget(minimumSpacing:.zero,interactiveReserve:100)
        let base = ScriptedTransport.suspended()
        let background = BudgetedGitHubTransport(base:base,budget:budget,account:account)
        let writer = BudgetedGitHubTransport(base:base,budget:budget,account:account,beforeSend:{})
        var write = URLRequest(url:URL(string:"https://api.github.com/notifications/threads/1")!); write.httpMethod = "PATCH"
        let first = Task { try await background.send(URLRequest(url:URL(string:"https://api.github.com/background-1")!)) }
        await base.waitUntilHolding()
        let queued = Task { try await background.send(URLRequest(url:URL(string:"https://api.github.com/background-2")!)) }
        await budget.untilWaiting(account:account,slot:1)
        let mutation = Task { [write] in try await writer.send(write) }
        await budget.untilWaiting(account:account,slot:2)
        await base.release()
        _ = try await first.value; _ = try await mutation.value; _ = try await queued.value
        let order = await base.paths()
        XCTAssertEqual(order,["/background-1","/notifications/threads/1","/background-2"],"User writes take the next free slot ahead of queued polling")
        await budget.observe(GitHubResponse(status:200,headers:["X-RateLimit-Remaining":"50","X-RateLimit-Reset":String(Date().addingTimeInterval(3600).timeIntervalSince1970)]),account:account)
        _ = try await writer.send(write)
        do { _ = try await background.send(URLRequest(url:URL(string:"https://api.github.com/poll")!)); XCTFail("background must keep the reserve") } catch {}
    }
    func testRateLimitArrivingAsCallerIsCancelledStillPausesAccount() async throws {
        let budget = RateBudget(minimumSpacing:.zero)
        let transport = BudgetedGitHubTransport(base:await cancelOn429Transport(),budget:budget,account:account)
        let task = Task { try await transport.send(URLRequest(url:URL(string:"https://api.github.com/poll")!)) }
        _ = try? await task.value
        let retry = await budget.retryAt(account:account)
        XCTAssertNotNil(retry,"A 429 observed during cancellation must still back off the account")
        XCTAssertGreaterThan(retry ?? .distantPast,Date().addingTimeInterval(60))
    }
    func testQuickUserWritesKeepTheWriteGapInsideTheSlotWhileReadsPass() async throws {
        // A one-second write gap: a read held behind the waiting write would take most of it.
        let spacing = Duration.seconds(1)
        let budget = RateBudget(minimumSpacing:spacing)
        let base = ScriptedTransport(fallback:json("[]"))
        let writer = BudgetedGitHubTransport(base:base,budget:budget,account:account,beforeSend:{})
        let reader = BudgetedGitHubTransport(base:base,budget:budget,account:account,interactiveRead:true)
        func write(_ id: Int) -> URLRequest { var request = URLRequest(url:URL(string:"https://api.github.com/notifications/threads/\(id)")!); request.httpMethod = "PATCH"; return request }
        // Both writes pass the pre-slot gap check before either has been sent; the second then waits out the gap
        // with the slot released.
        let first = Task { try await writer.send(write(1)) }, second = Task { try await writer.send(write(2)) }
        await budget.untilWaiting(account:account,pacing:1)
        let start = ContinuousClock.now
        _ = try await reader.send(URLRequest(url:URL(string:"https://api.github.com/read")!))
        let elapsed = start.duration(to:.now)
        let sent = await base.paths()
        XCTAssertLessThanOrEqual(sent.filter { $0.hasPrefix("/notifications/threads/") }.count,1,"The read went out while the second write still waited for its gap")
        XCTAssertLessThan(elapsed,spacing / 2,"A waiting write never holds the slot from interactive reads")
        XCTAssertWithinPerformanceBudget(elapsed,.milliseconds(150),"A waiting write never holds the slot from interactive reads")
        _ = try await first.value; _ = try await second.value
        let firstArrival = await base.arrival("/notifications/threads/1"), secondArrival = await base.arrival("/notifications/threads/2")
        let one = try XCTUnwrap(firstArrival), two = try XCTUnwrap(secondArrival)
        let gap = one < two ? one.duration(to:two) : two.duration(to:one)
        XCTAssertGreaterThanOrEqual(gap,spacing - .milliseconds(10),"User writes stay one spacing apart even when both were admitted together")
    }
}

// MARK: - P2 inventory throughput

/// GitHub-like PR inventory: UPDATED_AT DESC ordering, key-based cursors, honored page sizes, the
/// paginated open-PR volatile alias, targeted node reads, nested review pages, optional merge-evidence
/// answers, and per-request accounting.
private actor WatermarkInventoryTransport: GitHubTransport {
    struct PR {
        var id: Int; var updatedAt: Int; var state = "OPEN"; var checks = "SUCCESS"; var mergeable = "MERGEABLE"; var title = "Fixture"; var labels: [(String,String)] = []
        /// Not yet surfaced by the ordered connection (a late update); open-PR and node reads already see it.
        var hidden = false
        /// Approving reviews on the head; more than 100 continue through the nested `PRConnection` query.
        var approvals = 0
        var reviewDecision: String? = nil
    }
    struct Page { let first: Int; let after: String?; let open: Bool }
    var prs: [PR]
    var pages: [Page] = []
    var teamReads = 0
    var otherReads = 0
    var probeReads = 0
    /// Supplementary open-PR pages (by cursor), PR node reads, nested connection pages and merge-evidence requests.
    var openPages: [String] = []
    var nodeReads: [String] = []
    var connectionReads = 0
    var evidenceReads: [String] = []
    var evidenceRequests = 0
    var answersEvidence = false
    enum NodeFailure: CaseIterable { case partial, nullWithError, malformed, missingConnection, invalidContinuation }
    var nextNodeFailure: NodeFailure?
    /// The next node read fails before any GraphQL data: an HTTP status (5xx, rate limit) or a network error.
    var nextNodeError: TransportOutcome?
    var absentNodes: Set<String> = []
    /// Node reads that always carry field errors alongside their data (e.g. a SAML-protected reviewer).
    var partialNodes: Set<String> = []
    var failCursorPages = 0
    var delay: Duration = .zero
    var teams = "[]"
    init(count: Int, open: Set<Int>) {
        prs = (1...count).map { PR(id:$0,updatedAt:$0 * 60,state:open.contains($0) ? "OPEN" : ($0 % 2 == 0 ? "MERGED" : "CLOSED")) }
    }
    var total: Int { pages.count + teamReads + otherReads + openPages.count + nodeReads.count + connectionReads + evidenceRequests }
    /// Merge-evidence attempts, answered or not.
    var evidenceAttempts: Int { otherReads + evidenceReads.count }
    var answersProbe = false
    func answerProbe() { answersProbe = true }
    func reset() { pages = []; teamReads = 0; otherReads = 0; probeReads = 0; openPages = []; nodeReads = []; connectionReads = 0; evidenceReads = []; evidenceRequests = 0 }
    func update(_ id: Int, at time: Int, _ change: (inout PR) -> Void = { _ in }) {
        guard let index = prs.firstIndex(where:{ $0.id == id }) else { return }
        prs[index].updatedAt = time; change(&prs[index])
    }
    /// Changes provider fields without bumping updatedAt (check rollups, mergeability, branch rules).
    func silently(_ id: Int, _ change: (inout PR) -> Void) {
        guard let index = prs.firstIndex(where:{ $0.id == id }) else { return }
        change(&prs[index])
    }
    func failNextCursorPages(_ count: Int) { failCursorPages = count }
    func setDelay(_ value: Duration) { delay = value }
    func setTeams(_ value: String) { teams = value }
    func answerEvidence() { answersEvidence = true }
    func stopAnsweringEvidence() { answersEvidence = false }
    func failNextNode(_ failure: NodeFailure) { nextNodeFailure = failure }
    func failNextNodeRead(_ outcome: TransportOutcome) { nextNodeError = outcome }
    func makeNodeAbsent(_ id: Int) { absentNodes.insert("PR\(id)") }
    func alwaysPartial(_ id: Int) { partialNodes.insert("PR\(id)") }
    static func iso(_ seconds: Int) -> String { ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:1_790_000_000 + TimeInterval(seconds))) }
    static func cursor(_ pr: PR) -> String { "\(pr.updatedAt):\(pr.id)" }
    private func ordered() -> [PR] { prs.sorted { $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt } }
    /// Key-based cursor (updatedAt + id), as GitHub's ordered connections encode.
    private func start(after cursor: String?, in all: [PR]) -> Int {
        guard let cursor else { return 0 }
        let parts = cursor.split(separator:":").compactMap { Int($0) }
        return all.firstIndex { $0.updatedAt < parts[0] || $0.updatedAt == parts[0] && $0.id < parts[1] } ?? all.count
    }
    private static var empty: [String: Any] { ["nodes": [], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]] }
    private func reviews(_ pr: PR, from start: Int) -> [String: Any] {
        let end = min(pr.approvals,start + 100)
        return ["nodes": (start..<max(start,end)).map { index -> [String: Any] in
            ["id": "R\(pr.id)-\(index)", "state": "APPROVED", "submittedAt": Self.iso(pr.updatedAt), "author": ["id": "U\(index)", "login": "u\(index)"], "commit": ["oid": "sha\(pr.id)"]]
        }, "pageInfo": ["hasNextPage": end < pr.approvals, "endCursor": "reviews:\(end)"]]
    }
    private func node(_ pr: PR) -> [String: Any] {
        var labels = Self.empty
        labels["nodes"] = pr.labels.map { ["name": $0.0, "color": $0.1] }
        var value: [String: Any] = [
            "id": "PR\(pr.id)", "number": pr.id, "url": "https://github.com/o/r/pull/\(pr.id)", "title": pr.title,
            "state": pr.state, "isDraft": false, "headRefOid": "sha\(pr.id)", "baseRefOid": "base", "baseRefName": "main",
            "headRefName": "feature\(pr.id)", "createdAt": Self.iso(0), "updatedAt": Self.iso(pr.updatedAt),
            "author": ["__typename": "User", "id": "AUTHOR", "login": "author"], "mergeable": pr.mergeable,
            "reviewDecision": pr.reviewDecision.map { $0 as Any } ?? NSNull(),
            "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": pr.checks]]]]],
            "reviewRequests": Self.empty, "labels": labels, "assignees": Self.empty, "reviews": reviews(pr,from:0), "timelineItems": Self.empty,
        ]
        if pr.state == "MERGED" { value["mergedAt"] = Self.iso(pr.updatedAt) }
        return value
    }
    private func openNode(_ pr: PR) -> [String: Any] {
        ["id": "PR\(pr.id)", "headRefOid": "sha\(pr.id)", "updatedAt": Self.iso(pr.updatedAt), "mergeable": pr.mergeable,
         "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": pr.checks]]]]],
         "labels": ["nodes": pr.labels.map { ["name": $0.0, "color": $0.1] }, "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]]
    }
    /// The open alias pages 100 at a time and already reflects updates the ordered connection has not surfaced.
    private func openPage(after cursor: String?) -> [String: Any] {
        let open = ordered().filter { $0.state == "OPEN" }
        let first = start(after:cursor,in:open), slice = Array(open[first..<min(open.count,first + 100)])
        return ["nodes": slice.map(openNode), "pageInfo": ["hasNextPage": first + 100 < open.count, "endCursor": slice.last.map { Self.cursor($0) as Any } ?? NSNull()]]
    }
    private func envelope(_ data: [String: Any], errors: [String] = []) throws -> GitHubResponse {
        var data = data; data["rateLimit"] = ["cost": 1, "remaining": 4000, "resetAt": "2030-01-01T00:00:00Z"]
        var value: [String: Any] = ["data": data]
        if !errors.isEmpty { value["errors"] = errors.map { ["message": $0] } }
        return GitHubResponse(status:200,data:try JSONSerialization.data(withJSONObject:value))
    }
    private static var viewer: [String: Any] { ["id": "VIEWER", "databaseId": 1, "login": "viewer"] }
    /// A clean branch is ready to merge; a conflicted one is an authoritative (pending) blocker.
    private func evidence(_ query: String, id: String) throws -> GitHubResponse {
        guard let pr = prs.first(where:{ "PR\($0.id)" == id }) else { return json(#"{"data":{}}"#) }
        let repository: [String: Any] = ["id": "REPO", "databaseId": 1, "nameWithOwner": "o/r1", "viewerPermission": "WRITE", "isPrivate": false,
                                         "mergeCommitAllowed": true, "squashMergeAllowed": true, "rebaseMergeAllowed": true, "autoMergeAllowed": false]
        if query.contains("query MergeIdentity") {
            return try envelope(["viewer": ["databaseId": 1], "node": ["id": id, "headRefOid": "sha\(pr.id)", "baseRefOid": "base", "state": pr.state, "isDraft": false, "repository": repository]])
        }
        evidenceReads.append(id)
        return try envelope(["viewer": Self.viewer, "node": [
            "id": id, "number": pr.id, "title": pr.title, "url": "https://github.com/o/r1/pull/\(pr.id)", "state": pr.state, "isDraft": false,
            "headRefOid": "sha\(pr.id)", "baseRefOid": "base", "headRefName": "feature\(pr.id)", "baseRefName": "main", "mergedAt": NSNull(), "mergeCommit": NSNull(),
            "mergeable": pr.mergeable, "mergeStateStatus": pr.mergeable == "MERGEABLE" ? "CLEAN" : "BEHIND", "reviewDecision": NSNull(),
            "isMergeQueueEnabled": false, "isInMergeQueue": false, "autoMergeRequest": NSNull(), "viewerCanEnableAutoMerge": false,
            "viewerCanDisableAutoMerge": false, "viewerCanUpdateBranch": false, "mergeQueue": NSNull(), "headRepository": ["databaseId": 1],
            "repository": repository, "baseRef": ["branchProtectionRule": NSNull()], "potentialMergeCommit": NSNull(),
            "headRef": ["target": ["oid": "sha\(pr.id)", "parents": Self.empty, "statusCheckRollup": NSNull()]],
            "commits": Self.empty, "reviewThreads": Self.empty, "stack": NSNull()]])
    }
    func send(_ request: URLRequest) async throws -> GitHubResponse {
        if delay > .zero { try await Task.sleep(for:delay) }
        if request.url!.path == "/user/teams" { teamReads += 1; return json(teams) }
        // Merge-evidence branch-rule and ruleset reads.
        guard request.httpMethod == "POST" else {
            guard answersEvidence else { otherReads += 1; return json("[]") }
            evidenceRequests += 1; return json("[]")
        }
        let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String: Any]
        let query = body["query"] as! String, variables = body["variables"] as? [String: Any] ?? [:]
        if query.contains("query MergeEvidence") || query.contains("query MergeIdentity") {
            guard answersEvidence else { otherReads += 1; return json(#"{"data":{}}"#) }
            evidenceRequests += 1
            return try evidence(query,id:variables["id"] as? String ?? "")
        }
        if query.contains("query PRNode") {
            let id = variables["id"] as? String ?? ""; nodeReads.append(id)
            if let outcome = nextNodeError { nextNodeError = nil; return try outcome.resolve() }
            var found: Any = NSNull()
            if let pr = prs.first(where:{ "PR\($0.id)" == id }) { var value = node(pr); value["repository"] = ["databaseId": 1]; found = value }
            if absentNodes.contains(id) { found = NSNull() }
            if partialNodes.contains(id) { return try envelope(["viewer": Self.viewer, "node": found],errors:["Resource protected by organization SAML enforcement"]) }
            if let failure = nextNodeFailure {
                nextNodeFailure = nil
                switch failure {
                case .partial: return try envelope(["viewer": Self.viewer, "node": found],errors:["Temporary resolver failure"])
                case .nullWithError: return try envelope(["viewer": Self.viewer, "node": NSNull()],errors:["Temporary resolver failure"])
                case .malformed:
                    var value = found as! [String: Any]; value["title"] = nil; found = value
                case .missingConnection:
                    var value = found as! [String: Any]; value["labels"] = nil; found = value
                case .invalidContinuation:
                    var value = found as! [String: Any]
                    value["labels"] = ["nodes": [], "pageInfo": ["hasNextPage": true, "endCursor": NSNull()]]
                    found = value
                }
            }
            return try envelope(["viewer": Self.viewer, "node": found])
        }
        if query.contains("query PRConnection") {
            connectionReads += 1
            guard let pr = prs.first(where:{ "PR\($0.id)" == variables["id"] as? String }) else { return json(#"{"data":{}}"#) }
            let from = Int((variables["after"] as? String)?.split(separator:":").last ?? "0") ?? 0
            return try envelope(["node": ["headRefOid": "sha\(pr.id)", "updatedAt": Self.iso(pr.updatedAt), "reviews": reviews(pr,from:from)]])
        }
        if query.contains("query OpenVolatile") {
            let after = variables["after"] as? String; openPages.append(after ?? "")
            return try envelope(["viewer": Self.viewer, "repository": ["openVolatile": openPage(after:after)]])
        }
        // The batched change probe: no signatures, so every repository is read in full.
        if query.contains("query InventoryProbe") {
            probeReads += 1
            guard answersProbe else { return json(#"{"data":{}}"#) }
            // Repository "1" is the first alias; other aliases (peers) are unknown to this fixture.
            let open = ordered().filter { $0.state == "OPEN" }
            let nodes: [[String: Any]] = open.prefix(InventoryProbe.openPerRepository).map { pr in
                ["id": "PR\(pr.id)", "headRefOid": "sha\(pr.id)", "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": pr.checks]]]]]]
            }
            let newest = ordered().first.map { ["updatedAt": Self.iso($0.updatedAt)] }
            return try envelope(["r0": ["databaseId": 1, "latest": ["nodes": newest.map { [$0] } ?? []],
                "open": ["totalCount": open.count, "pageInfo": ["hasNextPage": open.count > InventoryProbe.openPerRepository], "nodes": nodes]]])
        }
        guard query.contains("query Inventory") else { otherReads += 1; return json(#"{"data":{}}"#) }
        let after = variables["after"] as? String
        let first = Int(query.firstMatch(of:/pullRequests\(first:(\d+),after:\$after/)!.1)!
        let open = query.contains("openVolatile:")
        pages.append(Page(first:first,after:after,open:open))
        if after != nil, failCursorPages > 0 { failCursorPages -= 1; throw GitHubFailure.resourceDenied }
        let all = ordered().filter { !$0.hidden }
        let start = start(after:after,in:all)
        let slice = Array(all[start..<min(all.count,start + first)])
        let more = start + first < all.count
        var repository: [String: Any] = ["pullRequests": [
            "nodes": slice.map(node),
            "pageInfo": ["hasNextPage": more, "endCursor": slice.last.map { Self.cursor($0) as Any } ?? NSNull()],
        ]]
        if open { repository["openVolatile"] = openPage(after:nil) }
        return try envelope(["viewer": Self.viewer, "repository": repository])
    }
}

final class InventoryWatermarkTests: XCTestCase {
    let account = AccountScope(host:"github.com",accountID:"1")
    struct Cycle { let result: PollFetchResult; let status: PRInventoryStatus; var changes = PollCycleChanges() }
    func store(_ repositories: [String] = ["1"]) throws -> PollCycleStore {
        let database = try DatabaseStore(path:":memory:")
        try database.saveAccount(Account(scope:account,login:"viewer",tokenReference:nil))
        for id in repositories { try database.saveRepository(Repository(key:RepositoryKey(account:account,repositoryID:id),name:"o/r\(id)",isPrivate:false,capabilities:[])) }
        return PollCycleStore(database:database)
    }
    @discardableResult
    func cycle(_ fetcher: GitHubPRInventoryFetcher, _ transport: any GitHubTransport, _ store: PollCycleStore, repository: String = "1", deadline: Duration = .seconds(10), baseline: Bool = false, reason: PollRequest.Reason = .manual) async throws -> Cycle {
        let repo = RepositoryKey(account:account,repositoryID:repository)
        let context = PollFetchContext(
            cycleID:UUID(),account:account,repositories:[repo],featureID:fetcher.featureID,
            cachedPullRequests:try store.pullRequests(account:account).filter { $0.key.repository == repo },
            cachedSnapshots:try store.featureSnapshots(account:account,feature:fetcher.featureID).filter { $0.key.repository == repo },
            repositoryMetadata:try store.repositoryMetadata(account:account),deadline:.now.advanced(by:deadline),
            operation:AccountOperation(account:account,credential:GitHubCredential(accessToken:"fixture",scopes:["repo"]),generation:UUID()),
            client:GitHubHTTPClient(transport:transport),budget:RateBudget(minimumSpacing:.zero),
            baselinedRepositories:try store.baselines(account:account,feature:fetcher.featureID),suppressNotifications:false,cachedResponses:[:],reason:reason)
        try store.begin(context.cycleID,at:Date(),baseline:baseline)
        let result = try await fetcher.fetch(context)
        let changes = try store.apply(result,context:context,deadline:.now.advanced(by:.seconds(10)),requireTracked:false)
        _ = try store.close(context.cycleID,at:Date(),policy:NotificationPolicy())
        return Cycle(result:result,status:try JSONDecoder().decode(PRInventoryStatus.self,from:result.snapshots[0].payload),changes:changes)
    }
    func checkpoint(_ status: PRInventoryStatus) throws -> GitHubPRInventoryPayload.Checkpoint {
        try JSONDecoder().decode(GitHubPRInventoryPayload.Checkpoint.self,from:XCTUnwrap(status.continuation))
    }
    /// Initial full walk, then (when `settle`) quiet cycles until each open PR's merge-evidence read was tried once.
    fileprivate func synced(_ transport: WatermarkInventoryTransport, _ fetcher: GitHubPRInventoryFetcher, _ store: PollCycleStore, settle: Bool = true) async throws {
        var complete = false
        for index in 0..<10 where !complete { complete = try await cycle(fetcher,transport,store,baseline:index == 0).status.complete }
        XCTAssertTrue(complete)
        var settled = !settle
        for _ in 0..<200 where !settled {
            await transport.reset()
            try await cycle(fetcher,transport,store)
            settled = await transport.evidenceAttempts == 0
        }
        XCTAssertTrue(settled || !settle)
        await transport.reset()
    }
    /// Rewrites the stored inventory checkpoint, e.g. to age it as if a day had passed.
    func rewrite(_ store: PollCycleStore, _ change: (inout GitHubPRInventoryPayload.Checkpoint) throws -> Void) throws {
        let snapshot = try XCTUnwrap(store.featureSnapshots(account:account,feature:"github-pr-inventory").first)
        var status = try JSONDecoder().decode(PRInventoryStatus.self,from:snapshot.payload)
        var saved = try checkpoint(status); try change(&saved); status.continuation = try JSONEncoder.stable.encode(saved)
        let context = PollFetchContext(cycleID:UUID(),account:account,repositories:[snapshot.key.repository],featureID:snapshot.feature,cachedPullRequests:[],
            cachedSnapshots:[snapshot],repositoryMetadata:[:],deadline:.now.advanced(by:.seconds(10)),operation:nil,client:nil,budget:RateBudget(),
            baselinedRepositories:[],suppressNotifications:true,cachedResponses:[:])
        try store.begin(context.cycleID,at:Date(),baseline:true)
        try store.apply(PollFetchResult(snapshots:[PollFeatureSnapshot(key:snapshot.key,feature:snapshot.feature,payload:try JSONEncoder.stable.encode(status))]),context:context,deadline:.now.advanced(by:.seconds(10)),requireTracked:false)
        _ = try store.close(context.cycleID,at:Date(),policy:NotificationPolicy())
    }
    func row(_ store: PollCycleStore, _ id: Int) throws -> PullRequest {
        try XCTUnwrap(store.pullRequests(account:account).first { $0.key.objectID == "pull-request:PR\(id)" })
    }
    /// Ages real cached observations without waiting for the wall clock: by default past the background
    /// renewal interval (well above `MergePolicy.maximumAge`).
    func ageEvidence(_ store: PollCycleStore, by age: TimeInterval = GitHubPRInventoryFetcher.evidenceRenewal + 120) throws {
        let rows = try store.pullRequests(account:account).map { row in
            var metadata = row.metadata
            metadata?.mergeEvidence?.fetchedAt = Date().addingTimeInterval(-age)
            return PullRequest(key:row.key,headRevision:row.headRevision,title:row.title,state:row.state,isDraft:row.isDraft,metadata:metadata)
        }
        let repositories = Set(rows.map(\.key.repository))
        let context = PollFetchContext(cycleID:UUID(),account:account,repositories:repositories,featureID:"github-pr-inventory",cachedPullRequests:[],
            cachedSnapshots:[],repositoryMetadata:[:],deadline:.now.advanced(by:.seconds(10)),operation:nil,client:nil,budget:RateBudget(),
            baselinedRepositories:[],suppressNotifications:true,cachedResponses:[:])
        try store.begin(context.cycleID,at:Date(),baseline:true)
        try store.apply(PollFetchResult(pullRequests:rows),context:context,deadline:context.deadline,requireTracked:false)
        _ = try store.close(context.cycleID,at:Date(),policy:NotificationPolicy())
        try rewrite(store) { checkpoint in
            for key in checkpoint.evidenceTried?.keys.map({ $0 }) ?? [] { checkpoint.evidenceTried?[key]?.at = Date().addingTimeInterval(-age - 10) }
        }
    }

    func testExpiredMergeEvidenceRefreshesWithinBudgetWithoutRepeatingReadiness() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:[1,2,3])
        await transport.answerEvidence()
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        try ageEvidence(store)
        XCTAssertFalse(MergePolicy.evaluate(pr:try row(store,1)).eligible)
        var refreshed = Set<ProviderKey>()
        for _ in 0..<3 {
            await transport.reset()
            let value = try await cycle(fetcher,transport,store)
            for row in value.result.pullRequests where row.state == .open && MergePolicy.evaluate(pr:row).eligible { refreshed.insert(row.key) }
            XCTAssertTrue(value.result.events.filter { $0.category == "ready to merge" }.isEmpty,"Revalidating an unchanged ready PR is not a new readiness transition")
            let reads = await transport.evidenceReads.count, total = await transport.total
            XCTAssertLessThanOrEqual(reads,2); XCTAssertLessThanOrEqual(total,8)
        }
        XCTAssertEqual(refreshed.count,3,"Every expired cached PR is eventually eligible again")
    }

    func testFailedExpiredEvidenceRefreshRetainsCooldown() async throws {
        let transport = WatermarkInventoryTransport(count:1,open:[1])
        await transport.answerEvidence()
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        try ageEvidence(store)
        // A malformed first evidence response makes this revalidation unavailable.
        await transport.stopAnsweringEvidence()
        await transport.reset()
        try await cycle(fetcher,transport,store)
        let attempted = await transport.evidenceAttempts
        XCTAssertGreaterThan(attempted,0)
        await transport.reset()
        try await cycle(fetcher,transport,store)
        let repeated = await transport.evidenceAttempts
        XCTAssertEqual(repeated,0,"Failed revalidation retains the bounded failure cooldown")
        XCTAssertFalse(MergePolicy.evaluate(pr:try row(store,1)).eligible)
    }

    func testTransientTargetedReadFailuresRetryTheSameOpenObservation() async throws {
        for failure in WatermarkInventoryTransport.NodeFailure.allCases {
            let transport = WatermarkInventoryTransport(count:300,open:[5,299])
            let fetcher = GitHubPRInventoryFetcher(), store = try store()
            try await synced(transport,fetcher,store)
            await transport.update(5,at:100_000) { $0.title = "Recovered"; $0.hidden = true }
            await transport.failNextNode(failure)
            let failed = try await cycle(fetcher,transport,store)
            XCTAssertNotNil(failed.status.failureMessage,"\(failure) must remain retryable")
            await transport.reset()
            let recovered = try await cycle(fetcher,transport,store)
            XCTAssertTrue(recovered.status.complete,"\(failure)")
            XCTAssertEqual(try row(store,5).title,"Recovered","The unchanged provider observation retries after \(failure)")
            XCTAssertEqual(try row(store,5).metadata?.partial,false)
            let retried = await transport.nodeReads
            XCTAssertEqual(retried,["PR5"],"\(failure)")
        }
    }

    /// A node read that fails outright (server error, rate limit, network, unreadable response) is not partial
    /// GraphQL data: the repository fails as before, so its freshness is never "Current" while that PR is stale.
    func testThrownTargetedReadFailureFailsTheRepositoryInsteadOfStayingCurrent() async throws {
        let outcomes: [(String, TransportOutcome)] = [
            ("server error", .respond(json("{}", status: 502))),
            ("rate limit", .respond(json("{}", status: 403, headers: ["Retry-After": "60"]))),
            ("network", .fail(URLError(.notConnectedToInternet))),
            ("undecodable", .respond(json("not json"))),
        ]
        for (name, outcome) in outcomes {
            let transport = WatermarkInventoryTransport(count:300,open:[5,6,299])
            let fetcher = GitHubPRInventoryFetcher(), store = try store()
            try await synced(transport,fetcher,store)
            await transport.update(5,at:100_000) { $0.title = "Pushed"; $0.hidden = true }
            await transport.update(6,at:100_001) { $0.title = "Also pushed"; $0.hidden = true }
            await transport.failNextNodeRead(outcome)
            let failed = try await cycle(fetcher,transport,store)
            XCTAssertNotNil(failed.status.lastFailureAt,name)
            XCTAssertFalse(failed.status.complete,name)
            let freshness = PRRepositoryFreshness(repository:RepositoryKey(account:account,repositoryID:"1"),name:"o/r1",status:failed.status,revoked:false,now:Date(),staleAfter:600)
            XCTAssertNotEqual(freshness.state,.fresh,"\(name): a stale PR must not leave its repository Current")
            XCTAssertEqual(try row(store,5).title,"Fixture",name)
            // The next cycle retries the same observation and recovers.
            await transport.reset()
            let recovered = try await cycle(fetcher,transport,store)
            XCTAssertTrue(recovered.status.complete,name)
            XCTAssertEqual(try row(store,5).title,"Pushed",name)
            XCTAssertEqual(try row(store,6).title,"Also pushed",name)
            let fresh = PRRepositoryFreshness(repository:RepositoryKey(account:account,repositoryID:"1"),name:"o/r1",status:recovered.status,revoked:false,now:Date(),staleAfter:600)
            XCTAssertEqual(fresh.state,.fresh,name)
        }
    }

    func testAuthoritativeNullTargetDoesNotRepeatedlyReadTheSameObservation() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:[5,299])
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        await transport.update(5,at:100_000) { $0.hidden = true }
        await transport.makeNodeAbsent(5)
        let absent = try await cycle(fetcher,transport,store)
        XCTAssertTrue(absent.status.complete)
        XCTAssertNil(absent.status.failureMessage)
        XCTAssertEqual(try row(store,5).title,"Fixture","Authoritative absence cannot replace the retained cached row")
        await transport.reset()
        try await cycle(fetcher,transport,store)
        let repeated = await transport.nodeReads
        XCTAssertTrue(repeated.isEmpty,"An error-free null node is distinct from an unavailable read")
    }

    func testFullySyncedRepositoryCostsOneGraphQLRequestPerCycleWithoutRewalkingHistory() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:[297,298,299])
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        for _ in 0..<3 {
            let value = try await cycle(fetcher,transport,store)
            XCTAssertTrue(value.status.complete,"A quiet incremental cycle is complete, not partial")
            XCTAssertTrue(value.result.events.isEmpty)
            XCTAssertEqual(value.result.baselinedRepositories.count,1)
        }
        let pages = await transport.pages, total = await transport.total
        XCTAssertEqual(total,3,"One GraphQL request per quiet cycle")
        XCTAssertEqual(pages.count,3)
        XCTAssertTrue(pages.allSatisfy { $0.after == nil && $0.first == GitHubPRInventoryPayload.incrementalPageSize && $0.open },"History is not re-walked")
    }
    func testIncrementalWalkStopsAtWatermarkAndEmitsKnownTransitions() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:Set(200...300))
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        // 40 PRs change a minute apart (more than the small head page); one of them merges.
        for id in 1...40 { await transport.update(id,at:100_000 + id * 60) { $0.title = "Updated \(id)" } }
        await transport.update(250,at:102_500) { $0.state = "MERGED" }
        let value = try await cycle(fetcher,transport,store)
        XCTAssertTrue(value.status.complete)
        let pages = await transport.pages
        XCTAssertEqual(pages.count,2,"Head page plus one continuation page reaches the watermark")
        XCTAssertNil(pages[0].after); XCTAssertNotNil(pages[1].after)
        let rows = try store.pullRequests(account:account)
        XCTAssertEqual(rows.filter { $0.title.hasPrefix("Updated") }.count,40)
        XCTAssertEqual(value.result.events.filter { $0.category == "merged" }.map(\.object.objectID),["pull-request:PR250"])
        await transport.reset()
        let quiet = try await cycle(fetcher,transport,store)
        XCTAssertTrue(quiet.status.complete); XCTAssertTrue(quiet.result.events.isEmpty)
        let after = await transport.pages.count
        XCTAssertEqual(after,1,"The watermark advanced past the observed changes")
    }
    func testWatermarkWalkCutByDeadlineIsHonestlyPartialAndResumesWithoutLosingChanges() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:[299,300])
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        let before = try checkpoint(try XCTUnwrap(store.featureSnapshots(account:account,feature:fetcher.featureID).first.map { try JSONDecoder().decode(PRInventoryStatus.self,from:$0.payload) }))
        for id in 1...150 { await transport.update(id,at:100_000 + id) { $0.title = "Updated \(id)" } }
        // Each request takes 40 ms; a 100 ms deadline admits two of the three pages needed.
        await transport.setDelay(.milliseconds(40))
        let cut = try await cycle(fetcher,transport,store,deadline:.milliseconds(100))
        XCTAssertFalse(cut.status.complete,"An unfinished watermark walk is partial")
        XCTAssertTrue(cut.result.baselinedRepositories.isEmpty)
        XCTAssertEqual(try checkpoint(cut.status).watermark,before.watermark,"The watermark never advances past unobserved changes")
        XCTAssertTrue(cut.result.events.isEmpty,"Unchanged known PRs never produce transitions")
        await transport.setDelay(.zero)
        let resumed = try await cycle(fetcher,transport,store)
        XCTAssertTrue(resumed.status.complete)
        XCTAssertEqual(try store.pullRequests(account:account).filter { $0.title.hasPrefix("Updated") }.count,150)
        XCTAssertNotEqual(try checkpoint(resumed.status).watermark,before.watermark)
        // A failed continuation page is likewise partial with the old watermark, then recovers.
        for id in 151...200 { await transport.update(id,at:200_000 + id) { $0.title = "Again \(id)" } }
        await transport.failNextCursorPages(1)
        let failed = try await cycle(fetcher,transport,store)
        XCTAssertFalse(failed.status.complete); XCTAssertNotNil(failed.status.failureMessage)
        XCTAssertEqual(try checkpoint(failed.status).watermark,try checkpoint(resumed.status).watermark)
        // Recovery re-walks from the newest page; at 25 PRs a page that can take a second chunk.
        var recovered = try await cycle(fetcher,transport,store)
        if !recovered.status.complete { recovered = try await cycle(fetcher,transport,store) }
        XCTAssertTrue(recovered.status.complete)
        XCTAssertEqual(try store.pullRequests(account:account).filter { $0.title.hasPrefix("Again") }.count,50)
    }
    func testOpenPRCheckChangeWithoutUpdatedAtBumpIsRefreshedBelowWatermark() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:[5,299])
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        await transport.silently(5) { $0.checks = "FAILURE"; $0.mergeable = "CONFLICTING" }
        let value = try await cycle(fetcher,transport,store)
        XCTAssertTrue(value.status.complete)
        let pages = await transport.pages; XCTAssertEqual(pages.count,1,"Volatile fields ride on the single head request")
        let row = try XCTUnwrap(store.pullRequests(account:account).first { $0.key.objectID == "pull-request:PR5" })
        XCTAssertEqual(row.metadata?.checks,"FAILURE"); XCTAssertEqual(row.metadata?.mergeable,"CONFLICTING")
        XCTAssertEqual(value.result.events.map(\.category),["checks"])
    }
    func testRepositoryLabelRecolorWithoutUpdatedAtBumpReachesOpenPRBelowWatermark() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:[5,299])
        await transport.silently(5) { $0.labels = [("bug","d73a4a")] }
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        let before = try XCTUnwrap(store.pullRequests(account:account).first { $0.key.objectID == "pull-request:PR5" })
        // Renaming or recoloring a repository label never bumps a PR's updatedAt.
        await transport.silently(5) { $0.labels = [("defect","0e8a16")] }
        let value = try await cycle(fetcher,transport,store)
        let pages = await transport.pages; XCTAssertEqual(pages.count,1,"Labels ride on the single head request")
        let row = try XCTUnwrap(store.pullRequests(account:account).first { $0.key.objectID == "pull-request:PR5" })
        XCTAssertEqual(row.metadata?.labels,["defect"]); XCTAssertEqual(row.metadata?.labelColors,["defect":"0e8a16"])
        // Labels aren't merge inputs: carried evidence and the column timestamp stay put, and no event fires.
        XCTAssertEqual(row.metadata?.mergeEvidence,before.metadata?.mergeEvidence)
        XCTAssertEqual(row.metadata?.mergeEligible,before.metadata?.mergeEligible)
        XCTAssertEqual(row.metadata?.columnChangedAt,before.metadata?.columnChangedAt)
        XCTAssertTrue(value.result.events.isEmpty)
    }
    func testPeriodicFullSweepRefreshesRowsBelowWatermarkWhileStatusStaysComplete() async throws {
        let transport = WatermarkInventoryTransport(count:250,open:[250])
        let fetcher = GitHubPRInventoryFetcher(fullPassInterval:0), store = try store()
        try await synced(transport,fetcher,store)
        await transport.silently(3) { $0.title = "Renamed without bump" }
        var swept = false
        for _ in 0..<12 {
            let value = try await cycle(fetcher,transport,store)
            XCTAssertTrue(value.status.complete,"A sweep never makes current inventory partial")
            if try store.pullRequests(account:account).contains(where:{ $0.title == "Renamed without bump" }) { swept = true }
        }
        XCTAssertTrue(swept)
        let pages = await transport.pages
        XCTAssertTrue(pages.contains { $0.after != nil && $0.first == GitHubPRInventoryPayload.walkPageSize })
    }
    func testTeamMembershipIsReadOncePerAccountAcrossRepositories() async throws {
        let transport = WatermarkInventoryTransport(count:3,open:[1,2,3])
        let fetcher = GitHubPRInventoryFetcher(), store = try store(["1","2","3"])
        for repository in ["1","2","3"] { try await cycle(fetcher,transport,store,repository:repository) }
        let teams = await transport.teamReads
        XCTAssertEqual(teams,1)
    }
    func testChangedTeamMembershipRewalksBelowWatermark() async throws {
        let transport = WatermarkInventoryTransport(count:150,open:[150])
        let store = try store()
        try await synced(transport,GitHubPRInventoryFetcher(),store)
        // Age the checkpoint's membership past its TTL; a new fetcher has no shared membership yet.
        let snapshot = try XCTUnwrap(store.featureSnapshots(account:account,feature:"github-pr-inventory").first)
        var status = try JSONDecoder().decode(PRInventoryStatus.self,from:snapshot.payload)
        var saved = try checkpoint(status); saved.teamsFetchedAt = Date().addingTimeInterval(-3600)
        XCTAssertNotNil(saved.watermark)
        status.continuation = try JSONEncoder.stable.encode(saved)
        await transport.setTeams(#"[{"node_id":"NEWTEAM"}]"#)
        let repo = RepositoryKey(account:account,repositoryID:"1")
        let context = PollFetchContext(
            cycleID:UUID(),account:account,repositories:[repo],featureID:"github-pr-inventory",
            cachedPullRequests:try store.pullRequests(account:account),
            cachedSnapshots:[PollFeatureSnapshot(key:snapshot.key,feature:snapshot.feature,payload:try JSONEncoder.stable.encode(status))],
            repositoryMetadata:try store.repositoryMetadata(account:account),deadline:.now.advanced(by:.seconds(10)),
            operation:AccountOperation(account:account,credential:GitHubCredential(accessToken:"fixture"),generation:UUID()),
            client:GitHubHTTPClient(transport:transport),budget:RateBudget(minimumSpacing:.zero),baselinedRepositories:[repo],
            suppressNotifications:false,cachedResponses:[:])
        let result = try await GitHubPRInventoryFetcher().fetch(context)
        let pages = await transport.pages
        XCTAssertEqual(pages.map(\.first),Array(repeating:GitHubPRInventoryPayload.walkPageSize,count:6),"Membership changes re-attribute team requests on unchanged PRs: full walk")
        XCTAssertEqual(try checkpoint(JSONDecoder().decode(PRInventoryStatus.self,from:result.snapshots[0].payload)).teamIDs,["NEWTEAM"])
    }
    func testLabelColorsAreNormalizedAndOldCheckpointsWithoutColorsDecode() async throws {
        let transport = WatermarkInventoryTransport(count:1,open:[1])
        await transport.silently(1) { $0.labels = [("bug","D73A4A"),("docs","#0075ca"),("odd","not-a-color")] }
        let value = try await cycle(GitHubPRInventoryFetcher(),transport,try store())
        let metadata = try XCTUnwrap(value.result.pullRequests.first?.metadata)
        XCTAssertEqual(metadata.labels,["bug","docs","odd"])
        XCTAssertEqual(metadata.labelColors,["bug":"d73a4a","docs":"0075ca"])
        // Checkpoints and cached rows written before colors were requested still decode.
        let legacy = #"{"nodes":[{"name":"bug"}],"pageInfo":{"hasNextPage":false}}"#
        let connection = try JSONDecoder().decode(GitHubPRInventoryPayload.Connection.self,from:Data(legacy.utf8))
        XCTAssertNil(connection.nodes.first??.color)
        var old = try JSONSerialization.jsonObject(with:JSONEncoder.stable.encode(metadata)) as! [String: Any]
        old["labelColors"] = nil
        let decoded = try JSONDecoder().decode(PRMetadata.self,from:JSONSerialization.data(withJSONObject:old))
        XCTAssertNil(decoded.labelColors)
        let legacyCheckpoint = #"{"outerFinished":true,"pending":[],"recentComplete":[],"traversalPartial":false,"teamIDs":[],"teamComplete":true}"#
        let checkpoint = try JSONDecoder().decode(GitHubPRInventoryPayload.Checkpoint.self,from:Data(legacyCheckpoint.utf8))
        XCTAssertNil(checkpoint.watermark)
    }

    // MARK: Review fixes: evidence, watermark overlap, open-PR coverage, sweep

    func testInvalidatedEvidenceOnOldOpenPRsIsReReadWithinBudgetAndReportsReadiness() async throws {
        // Ten old open PRs sit far below the 25-PR head page; each is blocked by a conflict.
        let transport = WatermarkInventoryTransport(count:300,open:Set(1...10))
        await transport.answerEvidence()
        for id in 1...10 { await transport.silently(id) { $0.mergeable = "CONFLICTING" } }
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        func withEvidence() throws -> Int { try store.pullRequests(account:account).filter { $0.state == .open && $0.metadata?.mergeEvidence != nil }.count }
        var cycles = 0
        while try withEvidence() < 10, cycles < 18 {
            await transport.reset()
            try await cycle(fetcher,transport,store,baseline:cycles == 0)
            let reads = await transport.evidenceReads.count
            XCTAssertLessThanOrEqual(reads,2,"A small per-cycle evidence cap")
            cycles += 1
        }
        XCTAssertEqual(try withEvidence(),10,"Cached open PRs without evidence are read, not only this cycle's head rows")
        // The 300-PR initial walk takes two chunks of 25-PR pages; then one complete read fits each quiet cycle.
        XCTAssertLessThanOrEqual(cycles,12,"One complete read fits each quiet cycle's eight-request chunk")
        // A push to main resolves every conflict without bumping updatedAt; the open alias invalidates carried evidence.
        for id in 1...10 { await transport.silently(id) { $0.mergeable = "MERGEABLE" } }
        var ready = Set<String>(); cycles = 0
        while ready.count < 10, cycles < 14 {
            await transport.reset()
            let value = try await cycle(fetcher,transport,store)
            XCTAssertTrue(value.status.complete)
            ready.formUnion(value.result.events.filter { $0.category == "ready to merge" }.map(\.object.objectID))
            let reads = await transport.evidenceReads.count, total = await transport.total
            XCTAssertLessThanOrEqual(reads,2); XCTAssertLessThanOrEqual(total,8,"Evidence stays within the inventory chunk")
            cycles += 1
        }
        XCTAssertEqual(ready,Set((1...10).map { "pull-request:PR\($0)" }),"Every invalidated blocked PR reports readiness once re-read")
        XCTAssertLessThanOrEqual(cycles,10)
        let rows = try store.pullRequests(account:account).filter { $0.state == .open }
        XCTAssertTrue(rows.allSatisfy { $0.metadata?.mergeEvidence?.conflictFree == true })
        // Settled: no further evidence reads and no repeated readiness.
        await transport.reset()
        let quiet = try await cycle(fetcher,transport,store)
        let reads = await transport.evidenceReads.count
        XCTAssertEqual(reads,0); XCTAssertTrue(quiet.result.events.isEmpty)
    }
    func testIncrementalWalkOverlapsWatermarkSoLateSurfacedUpdatesAreRead() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:[299,300])
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        // Thirty PRs update within half a minute; the walk commits the newest as its watermark.
        for id in 1...30 { await transport.update(id,at:100_000 + id) }
        let moved = try await cycle(fetcher,transport,store)
        XCTAssertTrue(moved.status.complete)
        // PR 40's earlier update surfaces late: just below the committed watermark and past the head page.
        await transport.update(40,at:99_990) { $0.title = "Surfaced late" }
        await transport.reset()
        let value = try await cycle(fetcher,transport,store)
        XCTAssertTrue(value.status.complete)
        XCTAssertEqual(try row(store,40).title,"Surfaced late","The walk overlaps five minutes below the watermark")
        let pages = await transport.pages
        XCTAssertEqual(pages.count,2)
        XCTAssertTrue(value.result.events.isEmpty,"Re-ingesting unchanged overlap rows is idempotent")
    }
    func testOpenPRUpdateMissingFromTheOrderedWalkIsReadByNode() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:[5,299])
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        // The open alias reports PR 5's newer update; the ordered connection has not surfaced it.
        await transport.update(5,at:100_000) { $0.title = "Pushed"; $0.hidden = true }
        let value = try await cycle(fetcher,transport,store)
        XCTAssertTrue(value.status.complete)
        let reads = await transport.nodeReads
        XCTAssertEqual(reads,["PR5"])
        let row = try row(store,5)
        XCTAssertEqual(row.title,"Pushed"); XCTAssertEqual(row.metadata?.updatedAt,GitHubPRInventoryFetcher.date(WatermarkInventoryTransport.iso(100_000)))
        // Once read, the same observation costs nothing more.
        await transport.reset()
        let settled = try await cycle(fetcher,transport,store)
        XCTAssertTrue(settled.status.complete)
        let quiet = await transport.total
        XCTAssertEqual(quiet,1)
    }
    func testOpenVolatileRotationRefreshesEveryOpenPRWithinBoundedCycles() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:Set(1...300))
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store,settle:false)
        // PR 3 is on the last of three open pages; its checks flip without an updatedAt bump.
        await transport.silently(3) { $0.checks = "FAILURE" }
        var cycles = 0, flipped = false
        while !flipped, cycles < 6 {
            await transport.reset()
            let value = try await cycle(fetcher,transport,store)
            XCTAssertTrue(value.status.complete)
            let pages = await transport.pages, extra = await transport.openPages
            XCTAssertEqual(pages.count,1); XCTAssertTrue(pages[0].open,"The newest open page rides on every head read")
            XCTAssertLessThanOrEqual(extra.count,1,"At most one rotating open page per cycle")
            cycles += 1
            flipped = try row(store,3).metadata?.checks == "FAILURE"
        }
        XCTAssertTrue(flipped)
        XCTAssertLessThanOrEqual(cycles,3,"Every open PR is covered within ceil(open/100) cycles")
    }
    func testSweepKeepsCompleteRowsWhileNestedReviewPagesFinish() async throws {
        let transport = WatermarkInventoryTransport(count:250,open:[3,250])
        await transport.silently(3) { $0.approvals = 101; $0.reviewDecision = "APPROVED" }
        let store = try store()
        try await synced(transport,GitHubPRInventoryFetcher(),store)
        let before = try row(store,3)
        XCTAssertEqual(before.metadata?.reviewDecision,"APPROVED"); XCTAssertEqual(before.metadata?.partial,false)
        // A day later team membership is past its TTL (clearing the recent-completion memo) and the sweep is due.
        try rewrite(store) { $0.teamsFetchedAt = Date().addingTimeInterval(-86_400) }
        let fetcher = GitHubPRInventoryFetcher(fullPassInterval:0)
        var swept = false
        // The sweep reads one page per fetch (`sweepPagesPerFetch`): 250 PRs take up to 10 cycles to reach PR 3.
        for _ in 0..<12 {
            await transport.reset()
            let value = try await cycle(fetcher,transport,store)
            XCTAssertTrue(value.status.complete,"Sweep-originated nested pages never make the inventory partial")
            let row = try row(store,3)
            XCTAssertEqual(row.metadata?.reviewDecision,"APPROVED","A swept complete row is never downgraded")
            XCTAssertEqual(row.metadata?.partial,false)
            XCTAssertEqual(row.metadata?.columnChangedAt,before.metadata?.columnChangedAt)
            XCTAssertTrue(value.result.events.isEmpty)
            if await transport.connectionReads > 0 { swept = true }
        }
        XCTAssertTrue(swept,"The swept row's nested reviews were completed")
    }

    // MARK: Review fixes: one PR never blocks a repository, quiet cycles write nothing, bounded background reads

    func testNodeThatAlwaysReturnsPartialDataNeitherBlocksTheRepositoryNorLaterStaleReads() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:[5,6,299])
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        let before = try checkpoint(try XCTUnwrap(store.featureSnapshots(account:account,feature:fetcher.featureID).first.map { try JSONDecoder().decode(PRInventoryStatus.self,from:$0.payload) }))
        // Both open PRs update without the ordered walk surfacing them. PR 5 (read first) always carries field errors.
        await transport.update(5,at:100_000) { $0.title = "Partly readable"; $0.hidden = true }
        await transport.update(6,at:100_001) { $0.title = "Readable"; $0.hidden = true }
        // Another PR's ordinary update moves the head walk's top, so a completed walk advances the watermark.
        await transport.update(299,at:100_002) { $0.title = "Visible" }
        await transport.alwaysPartial(5)
        var cycles = 0, complete = false
        while !complete, cycles < 3 {
            await transport.reset()
            complete = try await cycle(fetcher,transport,store).status.complete
            cycles += 1
        }
        XCTAssertTrue(complete,"One PR's partial node data never keeps its repository partial")
        XCTAssertEqual(cycles,1)
        XCTAssertEqual(try row(store,6).title,"Readable","A stale PR read after the partial one is still read")
        XCTAssertEqual(try row(store,5).title,"Partly readable","Partial data is kept for that PR only")
        XCTAssertEqual(try row(store,5).metadata?.partial,true,"Unknown fields stay explicitly partial")
        let advanced = try checkpoint(try XCTUnwrap(store.featureSnapshots(account:account,feature:fetcher.featureID).first.map { try JSONDecoder().decode(PRInventoryStatus.self,from:$0.payload) }))
        XCTAssertNotEqual(advanced.watermark,before.watermark,"The completed walk advances the watermark")
        // The unreadable PR is retried on a bounded cooldown rather than every cycle; the repository stays current.
        var retries = 0
        for _ in 0..<5 {
            await transport.reset()
            let value = try await cycle(fetcher,transport,store)
            XCTAssertTrue(value.status.complete)
            XCTAssertNil(value.status.lastFailureAt,"A per-PR problem never marks the repository failed")
            retries += await transport.nodeReads.filter { $0 == "PR5" }.count
        }
        XCTAssertLessThanOrEqual(retries,1,"A persistently partial PR costs at most one retry before its cooldown")
    }

    func testTwoIdenticalCyclesWriteNoPullRequestRowsAndKeepFetchTimes() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:[290,295,299])
        await transport.silently(299) { $0.labels = [("bug","d73a4a"),("docs","0075ca"),("ui","a2eeef")] }
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        let fetched = try store.pullRequests(account:account).map { ($0.key,$0.metadata?.fetchedAt) }
        for _ in 0..<2 {
            await transport.reset()
            let value = try await cycle(fetcher,transport,store)
            XCTAssertTrue(value.status.complete)
            XCTAssertFalse(value.result.pullRequests.isEmpty,"The head page is still re-read")
            XCTAssertTrue(value.changes.pullRequests.isEmpty,"Identical provider data rewrites no PR row")
        }
        let after = Dictionary(try store.pullRequests(account:account).map { ($0.key,$0.metadata?.fetchedAt) },uniquingKeysWith:{ first,_ in first })
        for (key,value) in fetched { XCTAssertEqual(after[key] ?? nil,value,"Unchanged rows keep their fetch time") }
        // A real change is still committed and reported.
        await transport.update(299,at:100_000) { $0.title = "Changed" }
        let changed = try await cycle(fetcher,transport,store)
        XCTAssertEqual(changed.changes.pullRequests.map(\.objectID),["pull-request:PR299"])
        XCTAssertEqual(try row(store,299).title,"Changed")
    }

    func testABatchedProbeSkipsUnchangedRepositoriesAndChecksOnlyChangesAreStillRead() async throws {
        let transport = WatermarkInventoryTransport(count:60,open:[1,2,3])
        await transport.answerProbe()
        let store = try store()
        try await synced(transport,GitHubPRInventoryFetcher(),store,settle:false)
        // The first scheduled read probes, reads in full and records what the probe saw.
        let fetcher = GitHubPRInventoryFetcher()
        await transport.reset()
        var value = try await cycle(fetcher,transport,store,reason:.scheduled)
        XCTAssertTrue(value.status.complete)
        var probes = await transport.probeReads, total = await transport.total
        XCTAssertEqual(probes,1);XCTAssertGreaterThan(total,0)
        // Unchanged: the read is skipped, yet the repository is current.
        await transport.reset()
        value = try await cycle(fetcher,transport,store,reason:.scheduled)
        probes = await transport.probeReads;total = await transport.total
        XCTAssertEqual(total,0,"An unchanged repository costs no read of its own")
        XCTAssertTrue(value.status.complete)
        XCTAssertLessThan(Date().timeIntervalSince(try XCTUnwrap(value.status.lastSuccessAt)),5)
        XCTAssertNotNil(value.status.continuation,"A skip keeps the resumable checkpoint")
        // Checks change without bumping updatedAt: the next probe sees it and the read refreshes that PR's checks.
        await transport.silently(2) { $0.checks = "FAILURE" }
        await transport.reset()
        value = try await cycle(GitHubPRInventoryFetcher(),transport,store,reason:.scheduled)
        probes = await transport.probeReads;total = await transport.total
        XCTAssertEqual(probes,1);XCTAssertGreaterThan(total,0)
        XCTAssertEqual(try row(store,2).metadata?.checks,"FAILURE")
        // A new probe that matches again skips.
        await transport.reset()
        _ = try await cycle(GitHubPRInventoryFetcher(),transport,store,reason:.scheduled)
        total = await transport.total
        XCTAssertEqual(total,0)
        // A manual refresh always reads.
        await transport.reset()
        _ = try await cycle(fetcher,transport,store)
        total = await transport.total
        XCTAssertGreaterThan(total,0)
    }

    func testUnchangedEvidenceIsRenewedOnlyAfterTheRenewalIntervalAndOnlyWhenItLooksMergeable() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:[1,2,3])
        await transport.answerEvidence()
        await transport.silently(3) { $0.checks = "FAILURE" }
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        // Expired for display (past MergePolicy.maximumAge) but within the renewal interval: no background re-read.
        try ageEvidence(store,by:MergePolicy.maximumAge + 60)
        for _ in 0..<3 {
            await transport.reset()
            let value = try await cycle(fetcher,transport,store,reason:.scheduled)
            XCTAssertTrue(value.status.complete)
            let attempts = await transport.evidenceAttempts, total = await transport.total
            XCTAssertEqual(attempts,0,"Merge re-verifies on demand; background reads do not chase the 60 s age")
            XCTAssertEqual(total,1,"A quiet repository costs only its head read")
        }
        // Past the renewal interval, only PRs that look close to mergeable (approved/none required, checks passing) renew.
        try ageEvidence(store)
        var renewed = Set<String>()
        for _ in 0..<3 {
            await transport.reset()
            try await cycle(fetcher,transport,store,reason:.scheduled)
            renewed.formUnion(await transport.evidenceReads)
        }
        XCTAssertEqual(renewed,["PR1","PR2"],"A PR with failing checks is not renewed in the background")
    }

    func testReadyToMergeEventStillMatchesAReadyNotificationRuleAtCycleClose() async throws {
        // An old blocked PR whose conflict clears without an updatedAt bump: the open batch invalidates its evidence,
        // the re-read finds it ready, and a saved "Ready to merge" rule (eligible:true) still matches the event.
        let transport = WatermarkInventoryTransport(count:300,open:[4])
        await transport.answerEvidence()
        await transport.silently(4) { $0.mergeable = "CONFLICTING" }
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store)
        XCTAssertFalse(MergePolicy.evaluate(pr:try row(store,4)).eligible)
        await transport.silently(4) { $0.mergeable = "MERGEABLE" }
        var ready: [ChangeEvent] = []
        for _ in 0..<4 where ready.isEmpty {
            await transport.reset()
            ready = try await cycle(fetcher,transport,store,reason:.scheduled).result.events.filter { $0.category == "ready to merge" }
        }
        let event = try XCTUnwrap(ready.first)
        var rule = PRViewConfiguration(); rule.filter = try FilterExpression.parse("eligible:true")
        // Fixture timestamps are fixed in September 2026; the default 30-day scope would age them out.
        rule.timeScope = .allTime
        let rows = BoardProjection(rows:try store.pullRequests(account:account),view:rule).rows
        XCTAssertEqual(rows.map(\.key),[event.object],"The fresh evidence read in this cycle satisfies the rule at close")
        let policy = NotificationPolicy(enabled:true,matchingEventKeys:[Set(rows.contains { $0.key == event.object } ? [event.key] : [])])
        XCTAssertTrue(policy.permits(event,at:Date()))
    }

    func testScheduledCyclesCarryTheOpenPRBatchEveryFewCyclesAndStillCatchSilentChecks() async throws {
        let transport = WatermarkInventoryTransport(count:300,open:Set(1...150))
        let fetcher = GitHubPRInventoryFetcher(), store = try store()
        try await synced(transport,fetcher,store,settle:false)
        var carried = 0, extra = 0
        for _ in 0..<(GitHubPRInventoryFetcher.openVolatileEvery * 2) {
            await transport.reset()
            let value = try await cycle(fetcher,transport,store,reason:.scheduled)
            XCTAssertTrue(value.status.complete)
            let pages = await transport.pages, open = await transport.openPages
            XCTAssertEqual(pages.count,1)
            if pages[0].open { carried += 1 } else { XCTAssertTrue(open.isEmpty,"The rotating open page only follows a carried batch") }
            extra += open.count
        }
        XCTAssertEqual(carried,2,"Scheduled head reads carry the open-PR batch every \(GitHubPRInventoryFetcher.openVolatileEvery) cycles")
        XCTAssertLessThanOrEqual(extra,2)
        // A check flip without an updatedAt bump still lands within one cadence (newest open page).
        await transport.silently(150) { $0.checks = "FAILURE" }
        var cycles = 0
        while try row(store,150).metadata?.checks != "FAILURE", cycles < GitHubPRInventoryFetcher.openVolatileEvery {
            await transport.reset()
            try await cycle(fetcher,transport,store,reason:.scheduled)
            cycles += 1
        }
        XCTAssertEqual(try row(store,150).metadata?.checks,"FAILURE")
        // A manual refresh always carries it.
        await transport.reset()
        try await cycle(fetcher,transport,store,reason:.manual)
        let manual = await transport.pages
        XCTAssertTrue(manual[0].open)
    }
}

// MARK: - Actions conditional polling and cadence

private actor ActionsETagTransport: GitHubTransport {
    var requests: [URLRequest] = []
    var notModified = 0
    var deleted: Set<Int64> = []
    var active: Int64? = 7
    func setDeleted(_ ids: Set<Int64>) { deleted = ids }
    func setActive(_ id: Int64?) { active = id }
    func reset() { requests = []; notModified = 0 }
    static func run(_ id: Int64, status: String, conclusion: String? = nil) -> [String: Any] {
        ["id": id, "workflow_id": 3, "run_attempt": 1, "name": "CI", "head_branch": "main", "head_sha": "sha", "event": "push",
         "actor": ["login": "dev"], "status": status, "conclusion": conclusion.map { $0 as Any } ?? NSNull(), "created_at": "2026-10-01T10:00:0\(id % 10)Z",
         "updated_at": "2026-10-01T10:05:00Z", "html_url": "https://github.com/o/r/actions/runs/\(id)", "repository": ["id": 1], "pull_requests": []]
    }
    func send(_ request: URLRequest) async throws -> GitHubResponse {
        requests.append(request)
        let url = request.url!, path = url.path
        let status = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "status" }?.value
        let body: Any
        if path == "/repos/o/r/actions/runs" {
            var runs: [[String: Any]] = []
            if let active, status == nil || status == "in_progress" { runs.append(Self.run(active,status:"in_progress")) }
            if status == nil { runs.append(Self.run(8,status:"completed",conclusion:"success")) }
            body = ["total_count": runs.count, "workflow_runs": runs]
        } else if let id = path.split(separator:"/").dropFirst(5).first.flatMap({ Int64($0) }) {
            if deleted.contains(id) { return GitHubResponse(status:404,data:Data(#"{"message":"Not Found"}"#.utf8)) }
            body = Self.run(id,status:active == id ? "in_progress" : "completed",conclusion:active == id ? nil : "success")
        } else { throw GitHubFailure.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject:body,options:.sortedKeys)
        let etag = "W/\"\(data.hashValue)\""
        if request.value(forHTTPHeaderField:"If-None-Match") == etag { notModified += 1; return GitHubResponse(status:304,headers:["ETag":etag]) }
        return GitHubResponse(status:200,headers:["ETag":etag],data:data)
    }
}
/// Records the cadence inputs the coordinator passes for each repository and the run order.
private final class CadenceLog: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = [], focused: [String:Bool] = [:]
    var calls: [String] { lock.withLock { values } }
    var focus: [String:Bool] { lock.withLock { focused } }
    func add(_ id: String) { lock.withLock { values.append(id) } }
    func set(_ id: String, _ value: Bool) { lock.withLock { focused[id] = value } }
}
private struct CadenceProbeFetcher: PollFeatureFetcher {
    let featureID: String
    let schedulingPriority: Int
    let log: CadenceLog
    var fetchScope: PollFetchScope { .repository }
    var allowsVisibleUntrackedReads: Bool { true }
    func pollInterval(for reason: PollRequest.Reason, repository: RepositoryKey?, focused: Bool) -> TimeInterval? {
        log.set(featureID + ":" + (repository?.repositoryID ?? ""),focused)
        return 0
    }
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        log.add(featureID + ":" + context.repositories.first!.repositoryID)
        return PollFetchResult()
    }
}

final class ActionsPollingEfficiencyTests: XCTestCase {
    let account = AccountScope(host:"github.com",accountID:"1")
    var repo: RepositoryKey { RepositoryKey(account:account,repositoryID:"1") }
    func context(_ transport: any GitHubTransport, snapshots: [PollFeatureSnapshot] = [], responses: [PollResponseCache] = []) -> PollFetchContext {
        PollFetchContext(cycleID:UUID(),account:account,repositories:[repo],featureID:"github-actions",cachedPullRequests:[],cachedSnapshots:snapshots,
            repositoryMetadata:[repo:Repository(key:repo,name:"o/r",isPrivate:false,capabilities:[])],deadline:.now.advanced(by:.seconds(20)),
            operation:AccountOperation(account:account,credential:GitHubCredential(accessToken:"fixture"),generation:UUID()),
            client:GitHubHTTPClient(transport:transport),budget:RateBudget(minimumSpacing:.zero),baselinedRepositories:[repo],
            suppressNotifications:false,cachedResponses:Dictionary(responses.map { ($0.url.absoluteString,$0) },uniquingKeysWith:{ _,last in last }))
    }
    func testUnchangedActionsPollRevalidatesWithETagsAndReusesCachedRunsOn304() async throws {
        let transport = ActionsETagTransport(), fetcher = GitHubActionsFetcher()
        let first = try await fetcher.fetch(context(transport))
        XCTAssertFalse(first.responses.isEmpty)
        XCTAssertTrue(first.responses.allSatisfy { $0.body.count < 200 },"Validators keep run keys, never provider bodies")
        await transport.reset()
        let second = try await fetcher.fetch(context(transport,snapshots:first.snapshots,responses:first.responses))
        await transport.reset()
        let third = try await fetcher.fetch(context(transport,snapshots:second.snapshots,responses:first.responses + second.responses))
        let requests = await transport.requests, notModified = await transport.notModified
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField:"If-None-Match") != nil },"Every unchanged read is conditional")
        XCTAssertEqual(notModified,requests.count,"Unchanged repository costs only 304s (free against GitHub's primary limit)")
        XCTAssertTrue(third.events.isEmpty)
        XCTAssertEqual(Set(third.snapshots.map(\.key.objectID)),Set(first.snapshots.map(\.key.objectID)))
        // A changed run still surfaces: the list's ETag changes and its body is read.
        await transport.setActive(nil)
        let changed = try await fetcher.fetch(context(transport,snapshots:third.snapshots,responses:first.responses + second.responses))
        XCTAssertEqual(changed.events.map(\.object.objectID),["run:7:1"])
    }
    func testUnchangedRunListCostsOneConditionalReadWithoutStatusFanOut() async throws {
        let transport = ActionsETagTransport(), fetcher = GitHubActionsFetcher()
        let first = try await fetcher.fetch(context(transport))
        await transport.reset()
        let second = try await fetcher.fetch(context(transport,snapshots:first.snapshots,responses:first.responses))
        let quiet = await transport.requests
        XCTAssertEqual(quiet.count,1,"An unchanged (304) run list answers for the whole repository")
        XCTAssertNil(URLComponents(url:quiet[0].url!,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "status" })
        XCTAssertEqual(Set(second.snapshots.map(\.key.objectID)),Set(first.snapshots.map(\.key.objectID)),"Cached runs are still reported")
        XCTAssertTrue(second.events.isEmpty)
        // A changed list fans out to the status windows and the cached active run's attempt.
        await transport.setActive(nil); await transport.reset()
        let changed = try await fetcher.fetch(context(transport,snapshots:second.snapshots,responses:first.responses + second.responses))
        XCTAssertEqual(changed.events.map(\.object.objectID),["run:7:1"])
        let fanned = await transport.requests.count
        XCTAssertGreaterThan(fanned,1)
    }
    func testDeletedCachedActiveRunBecomesTerminalSilentlyAndStopsCostingRequests() async throws {
        let transport = ActionsETagTransport(), fetcher = GitHubActionsFetcher()
        let first = try await fetcher.fetch(context(transport))
        await transport.setActive(nil); await transport.setDeleted([7]); await transport.reset()
        let second = try await fetcher.fetch(context(transport,snapshots:first.snapshots))
        let run = try XCTUnwrap(second.snapshots.compactMap { try? JSONDecoder().decode(WorkflowRun.self,from:$0.payload) }.first { $0.runID == 7 })
        XCTAssertFalse(run.isActive)
        XCTAssertEqual(run.conclusion,GitHubActionsProvider.deletedConclusion)
        XCTAssertTrue(second.events.isEmpty,"A vanished run is not a workflow outcome")
        await transport.reset()
        _ = try await fetcher.fetch(context(transport,snapshots:second.snapshots))
        let paths = await transport.requests.map { $0.url!.path }
        XCTAssertFalse(paths.contains { $0.contains("/runs/7") },"A deleted run is never polled again")
        // Twenty-plus dead runs can no longer starve a live one of the bounded active-run reads.
        var stale = second.snapshots
        for id in 100..<125 {
            let dead = WorkflowRun(repository:Repository(key:repo,name:"o/r",isPrivate:false,capabilities:[]),runID:Int64(id),workflowID:3,attempt:1,name:"CI",branch:"main",headSHA:"sha",event:"push",actor:"dev",status:"in_progress",conclusion:nil,createdAt:Date(timeIntervalSince1970:0),updatedAt:Date(timeIntervalSince1970:0))
            stale.append(PollFeatureSnapshot(key:dead.key,feature:"github-actions",payload:try JSONEncoder.stable.encode(dead)))
        }
        await transport.setDeleted(Set((100..<125).map(Int64.init)))
        func overlay(_ base: [PollFeatureSnapshot], _ newer: [PollFeatureSnapshot]) -> [PollFeatureSnapshot] {
            Array(Dictionary((base + newer).map { ($0.key,$0) },uniquingKeysWith:{ _,last in last }).values)
        }
        let cleaned = overlay(stale,try await fetcher.fetch(context(transport,snapshots:stale)).snapshots)
        let final = overlay(cleaned,try await fetcher.fetch(context(transport,snapshots:cleaned)).snapshots)
        let runs = final.compactMap { try? JSONDecoder().decode(WorkflowRun.self,from:$0.payload) }
        XCTAssertTrue(runs.filter(\.isActive).isEmpty,"Every deleted run leaves the active set within two polls")
        XCTAssertEqual(runs.filter { $0.conclusion == GitHubActionsProvider.deletedConclusion }.count,26)
    }
    func testQuietBackgroundRepositoryUsesSlowCadenceWhileFocusedOrActiveStayFast() async throws {
        let transport = ActionsETagTransport(), fetcher = GitHubActionsFetcher()
        XCTAssertEqual(fetcher.pollInterval(for:.scheduled,repository:repo,focused:false),60,"Unknown activity polls at the normal cadence")
        _ = try await fetcher.fetch(context(transport))
        XCTAssertEqual(fetcher.pollInterval(for:.scheduled,repository:repo,focused:false),60,"Active runs keep the fast cadence")
        XCTAssertEqual(fetcher.pollInterval(for:.activeRun,repository:repo,focused:false),15)
        await transport.setActive(nil)
        _ = try await fetcher.fetch(context(transport))
        XCTAssertEqual(fetcher.pollInterval(for:.scheduled,repository:repo,focused:false),GitHubActionsFetcher.idleInterval)
        XCTAssertEqual(fetcher.pollInterval(for:.activeRun,repository:repo,focused:false),180)
        XCTAssertEqual(fetcher.pollInterval(for:.activeRun,repository:repo,focused:true),15,"Visible repositories keep their cadence")
        XCTAssertEqual(fetcher.pollInterval(for:.scheduled,repository:repo,focused:true),60)
    }
    func testCoordinatorPassesFocusAndInterleavesNewWorkByRepositoryInventoryFirst() async throws {
        let log = CadenceLog()
        let store = PollCycleStore(database:try DatabaseStore(path:":memory:"))
        let poller = PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:RecordingNotificationSink()),
            fetchers:[CadenceProbeFetcher(featureID:"feed",schedulingPriority:0,log:log),CadenceProbeFetcher(featureID:"inventory",schedulingPriority:100,log:log)],budget:RateBudget(minimumSpacing:.zero))
        let a = RepositoryKey(account:account,repositoryID:"1"), b = RepositoryKey(account:account,repositoryID:"2")
        _ = try await poller.refresh(PollRequest(scopes:[PollScope(account:account,repositories:[a,b])],reason:.scheduled,focusedRepositories:[a]))
        XCTAssertEqual(log.calls,["inventory:1","feed:1","inventory:2","feed:2"],"Every feature advances; none waits out a full pass of another")
        XCTAssertEqual(log.focus["inventory:1"],true); XCTAssertEqual(log.focus["inventory:2"],false)
        // Until the App reports focus, an active-run request keeps every repository fast.
        _ = try await poller.refresh(PollRequest(scopes:[PollScope(account:account,repositories:[a,b])],reason:.activeRun))
        XCTAssertEqual(log.focus["inventory:2"],true)
    }
}
