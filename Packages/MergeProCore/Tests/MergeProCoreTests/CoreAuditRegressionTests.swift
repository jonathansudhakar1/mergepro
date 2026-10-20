import XCTest
@testable import MergeProCore

/// Regression coverage for Core correctness fixes (pagination, coalescing, parsing, scoping).
final class CoreAuditRegressionTests: XCTestCase {
    let repo = Repository(key:.init(account:.init(host:"github.com",accountID:"42"),repositoryID:"7"),name:"o/r",isPrivate:false,capabilities:[])
    func runJSON(_ id:Int,status:String = "completed") -> String { #"{"id":\#(id),"workflow_id":2,"name":"CI","head_branch":"main","head_sha":"abc","event":"push","status":"\#(status)","conclusion":null,"run_attempt":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}"# }
    func provider(_ transport:any GitHubTransport) -> GitHubActionsProvider { GitHubActionsProvider(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:[])) }

    // GitHub paginates `/repos/{owner}/{name}/…` lists through `/repositories/{id}/…` Link URLs.
    func testActionsPaginationFollowsRepositoryIDLinksOnlyForSameRepository() async throws {
        let transport=ScriptedTransport([
            json("{\"workflow_runs\":[\(runJSON(1))]}",headers:["Link":"<https://api.github.com/repositories/7/actions/runs?per_page=100&page=2>; rel=\"next\", <https://api.github.com/repositories/7/actions/runs?per_page=100&page=3>; rel=\"last\""]),
            json("{\"workflow_runs\":[\(runJSON(2))]}",headers:["Link":"<https://api.github.com/repositories/7/actions/runs?per_page=100&page=3>; rel=\"next\""]),
            json("{\"workflow_runs\":[\(runJSON(3))]}")])
        let runs=try await provider(transport).runs(repository:repo)
        XCTAssertEqual(Set(runs.map(\.runID)),[1,2,3])
        let other=ScriptedTransport([json("{\"workflow_runs\":[]}",headers:["Link":"<https://api.github.com/repositories/8/actions/runs?page=2>; rel=\"next\""])])
        do { _=try await provider(other).runs(repository:repo);XCTFail("another repository's pages must be rejected") } catch { XCTAssertEqual(error as? GitHubFailure,.unsafeURL) }
        let count=await other.captured().count;XCTAssertEqual(count,1)
    }
    func testMergeRuleListsFollowRepositoryIDPagination() async throws {
        let transport=ScriptedTransport([json(#"[{"type":"deletion"}]"#,headers:["Link":"<https://api.github.com/repositories/7/rulesets?per_page=100&page=2>; rel=\"next\""]),json(#"[{"type":"non_fast_forward"}]"#)])
        let reader=GitHubMergeReader(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:["repo"]))
        let values=try await reader.restList(URL(string:"https://api.github.com/repos/o/r/rulesets?per_page=100")!,repositoryID:"7")
        XCTAssertEqual(values.count,2)
    }
    // A cached active run that was deleted (404) must not fail polling for every other run forever.
    func testDeletedCachedActiveRunDoesNotBlockRepositoryPolling() async throws {
        // Requests in order: the newest-runs list (read first), then the cached active run's attempt (404).
        let transport=ScriptedTransport([json("{\"workflow_runs\":[\(runJSON(4))]}"),json("{}",status:404)])
        let cached=WorkflowRun(repository:repo,runID:3,workflowID:2,attempt:1,name:"CI",branch:"main",headSHA:"abc",event:"push",actor:"",status:"in_progress",conclusion:nil,createdAt:Date(timeIntervalSince1970:0),updatedAt:Date(timeIntervalSince1970:0))
        let runs=try await provider(transport).pollRuns(repository:repo,cached:[cached],deadline:.now.advanced(by:.seconds(30)))
        // The deleted run is returned once as a terminal observation so it leaves the active set.
        XCTAssertEqual(runs.map(\.runID).sorted(),[3,4])
        XCTAssertEqual(runs.first { $0.runID == 3 }?.conclusion,GitHubActionsProvider.deletedConclusion)
        XCTAssertFalse(runs.contains(where:\.isActive))
    }
    func testDeletedCachedActiveRunDoesNotBlockPollingWhenTheListFansOutToStatusWindows() async throws {
        // A full (changed) list fans out to the five status windows before the cached active run's attempt (404).
        let empty=json(#"{"workflow_runs":[]}"#)
        let page=json("{\"workflow_runs\":[\((4...103).map { runJSON($0) }.joined(separator:","))]}")
        let transport=ScriptedTransport([page,empty,empty,empty,empty,empty,json("{}",status:404)])
        let cached=WorkflowRun(repository:repo,runID:3,workflowID:2,attempt:1,name:"CI",branch:"main",headSHA:"abc",event:"push",actor:"",status:"in_progress",conclusion:nil,createdAt:Date(timeIntervalSince1970:0),updatedAt:Date(timeIntervalSince1970:0))
        let runs=try await provider(transport).pollRuns(repository:repo,cached:[cached],deadline:.now.advanced(by:.seconds(30)))
        XCTAssertEqual(runs.count,101)
        XCTAssertEqual(runs.first { $0.runID == 3 }?.conclusion,GitHubActionsProvider.deletedConclusion)
        XCTAssertFalse(runs.contains(where:\.isActive))
        let requests=await transport.captured()
        XCTAssertEqual(requests.count,7)
    }
    func testRepositoryQueryValuesEncodePlusSigns() async throws {
        let transport=ScriptedTransport([json("[]")])
        _=try await GitHubRepoReader(client:.init(transport:transport)).commits(repository:"o/r",sha:String(repeating:"a",count:40),path:"include/c++/a.h",author:"dev+bot@example.com",token:"fixture")
        let captured=await transport.captured();let url=try XCTUnwrap(captured.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("path=include/c%2B%2B/a.h"),url);XCTAssertTrue(url.contains("author=dev%2Bbot@example.com"),url)
    }
    func testCatalogOpenPRSortTreatsUnknownAsZeroAndKeepsNameOrder() {
        func entry(_ name:String,_ open:Int?) -> RepoCatalogEntry {
            var value=RepoCatalogEntry(repository:Repository(key:RepositoryKey(account:AccountScope(host:"github.com",accountID:"a"),repositoryID:name),name:"o/"+name,isPrivate:false,capabilities:[]),accountLogin:"a",pinned:false);value.openPRs=open;return value
        }
        var filter=RepoCatalogFilter();filter.sort = .openPRs
        XCTAssertEqual(filter.apply([entry("c",nil),entry("b",0),entry("a",nil)]).map(\.repository.name),["o/a","o/b","o/c"])
        XCTAssertEqual(filter.apply([entry("c",nil),entry("d",2),entry("b",0),entry("a",nil)]).map(\.repository.name),["o/d","o/a","o/b","o/c"])
    }
    func testQuotedOnKeyAndNullDefaultsParse() throws {
        XCTAssertNoThrow(try WorkflowInputSchema.parse(yaml:"\"on\":\n  workflow_dispatch:\n",workflowID:1,ref:"main",revision:"sha"))
        XCTAssertNoThrow(try WorkflowInputSchema.parse(yaml:"'on': [push, workflow_dispatch]",workflowID:1,ref:"main",revision:"sha"))
        let yaml="on:\n  workflow_dispatch:\n    inputs:\n      name:\n        default: null\n      flag:\n        type: boolean\n        default: ~\n      count:\n        type: number\n        default:\n      literal:\n        default: 'null'\n"
        let schema=try WorkflowInputSchema.parse(yaml:yaml,workflowID:1,ref:"main",revision:"sha")
        XCTAssertEqual(schema.defaults,["literal":.text("null")])
    }
    func testFileAttributeDoubleStarSlashMatchesZeroDirectories() {
        let rules=FileAttributeRules("**/gen/*.swift linguist-generated\ndocs/**/api.md linguist-vendored\n")
        XCTAssertTrue(rules.attributes(for:"gen/a.swift").generated);XCTAssertTrue(rules.attributes(for:"x/y/gen/a.swift").generated)
        XCTAssertFalse(rules.attributes(for:"xgen/a.swift").generated)
        XCTAssertTrue(rules.attributes(for:"docs/api.md").vendored);XCTAssertTrue(rules.attributes(for:"docs/v1/api.md").vendored)
    }
    func testAWSKeyRuleIsCaseSensitiveAndIgnoresProse() {
        let prose=DiffFile(path:"README.md",status:.modified,patch:"@@ -0,0 +1,1 @@\n+Our office in Slovakia handles support")
        XCTAssertFalse(RiskRules.evaluate(files:[prose],viewed:["README.md"],usualSize:nil).contains { $0.kind == .possibleSecret })
        let key=DiffFile(path:"config.txt",status:.modified,patch:"@@ -0,0 +1,1 @@\n+aws_access_key_id AKIAIOSFODNN7EXAMPLE")
        XCTAssertTrue(RiskRules.evaluate(files:[key],viewed:["config.txt"],usualSize:nil).contains { $0.kind == .possibleSecret && $0.line == 1 })
    }
    func testConfiguredSensitivePathsMatchCaseInsensitively() {
        let file=DiffFile(path:"Secure/Keys.swift",status:.modified,patch:nil)
        XCTAssertTrue(RiskRules.evaluate(files:[file],viewed:[],usualSize:nil,sensitivePaths:["Secure/"]).contains { $0.kind == .sensitivePath })
    }
    func testHugePollIntervalHeaderIsClampedInsteadOfTrapping() async {
        let budget=RateBudget(minimumSpacing:.zero),account=AccountScope(host:"github.com",accountID:"1")
        await budget.observePollInterval(GitHubResponse(status:200,headers:["X-Poll-Interval":"1e30"]),account:account,feature:"f")
        let admitted=await budget.beginPoll(account:account,feature:"f",interval:60)
        XCTAssertFalse(admitted)
    }
    func testRemovingAccountRemovesItsInboxEvents() async throws {
        let directory=try makeTemporaryDirectory()
        let db=try DatabaseStore(path:directory.appendingPathComponent("db").path)
        let a=AccountScope(host:"github.com",accountID:"1"),b=AccountScope(host:"github.com",accountID:"2")
        try db.saveAccount(.init(scope:a,login:"a",tokenReference:nil));try db.saveAccount(.init(scope:b,login:"b",tokenReference:nil))
        let store=PollCycleStore(database:db),id=UUID()
        try store.begin(id,at:Date(),baseline:false);try store.record([pollEvent(1,account:"1"),pollEvent(2,account:"2")],cycleID:id)
        try await CacheStore(directory:directory.appendingPathComponent("cache"),database:db).removeAccount(a) { _ in }
        XCTAssertEqual(try store.inbox().map(\.event.object.accountID),["2"])
    }
}

extension PRInventoryTests {
    func testNotificationFeedFollowsAccountFeedPaginationOnly() async throws {
        func thread(_ id:Int) -> String { #"{"id":"\#(id)","reason":"mention","updated_at":"2026-01-01T00:00:00Z","repository":{"id":1},"subject":{"title":"T","type":"PullRequest","url":"https://api.github.com/repos/o/r/pulls/\#(id)"}}"# }
        let transport=ScriptedTransport([json("[\(thread(1))]",headers:["Link":"<https://api.github.com/notifications?all=true&per_page=50&page=2>; rel=\"next\""]),json("[\(thread(2))]")])
        let result=try await GitHubNotificationFeedFetcher().fetch(context(transport))
        XCTAssertEqual(result.events.count,2)
        // A next link off the account feed's path is refused.
        let foreign=ScriptedTransport([json("[\(thread(1))]",headers:["Link":"<https://api.github.com/repositories/1/notifications?page=2>; rel=\"next\""])])
        do { _ = try await GitHubNotificationFeedFetcher().fetch(context(foreign));XCTFail("unsafe pagination must be refused") } catch {}
    }
    func testErroredPageHeaderStaysPartialAfterNestedConnectionCompletes() async throws {
        let result=try await GitHubPRInventoryFetcher().fetch(context(InventoryTransport(partialErrors:true,nestedPage:true)))
        XCTAssertTrue(result.pullRequests.allSatisfy { $0.metadata?.partial == true && $0.metadata?.reviewDecision == nil })
    }
    func testLaterCommentReviewDoesNotHideMembersApprovalOfTeamRequest() async throws {
        let result=try await GitHubPRInventoryFetcher().fetch(context(InventoryTransport(reviewedTeam:true,commentedAfterApproval:true)))
        XCTAssertFalse(result.pullRequests[0].needsViewer,"a COMMENTED reply does not replace the member's APPROVED state")
        XCTAssertEqual(result.pullRequests[0].metadata?.approvalCount,1)
    }
    func testNewHeadOnLatestPageCompletesItsNestedConnectionInSameCycle() async throws {
        let initial=try await GitHubPRInventoryFetcher().fetch(context(InventoryTransport()))
        let result=try await GitHubPRInventoryFetcher().fetch(context(InventoryTransport(headRevision:"new",nestedPage:true,nestedHead:"new"),cached:initial.pullRequests))
        let first=try XCTUnwrap(result.pullRequests.first { $0.metadata?.number == 1 })
        XCTAssertEqual(first.headRevision.rawValue,"new");XCTAssertEqual(first.metadata?.partial,false)
        XCTAssertEqual(first.metadata?.requests.first?.kind,.direct)
    }
}

private actor GatedCountingFetcher: PollFeatureFetcher {
    nonisolated var pollInterval: TimeInterval? { 60 }
    var calls = 0
    var gate: CheckedContinuation<Void,Never>?
    func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        calls += 1
        if calls == 1 { await withCheckedContinuation { gate = $0 } }
        return PollFetchResult()
    }
    func release() { gate?.resume(); gate = nil }
}
extension PollCoordinatorTests {
    func testCoalescedManualRefreshStillForcesReadWhenScheduledRequestArrivesLater() async throws {
        let fetcher = GatedCountingFetcher()
        let (poller, _, _) = try make(fetcher)
        let first = Task { try await poller.refresh(request()) }
        while await fetcher.calls < 1 { await Task.yield() }
        let manual = Task { try await poller.refresh(request()) }
        while await poller.coalescedRequestCount < 1 { await Task.yield() }
        let scheduled = Task { try await poller.refresh(PollRequest(scopes:request().scopes,reason:.scheduled)) }
        while await poller.coalescedRequestCount < 2 { await Task.yield() }
        await fetcher.release()
        _ = try await first.value; _ = try await manual.value; _ = try await scheduled.value
        let calls = await fetcher.calls
        XCTAssertEqual(calls, 2, "a coalesced manual refresh must still force a provider read")
    }
}

extension StackGraphTests {
    func testForkHeadNamedLikeBaseIsNeverAnInferredParent() {
        let original=pr("1","main","main");var m=original.metadata!;m.headRepositoryID="FORK"
        let fork=PullRequest(key:original.key,headRevision:original.headRevision,title:"fork",state:.open,isDraft:false,metadata:m)
        let x=pr("2","x","main"),y=pr("3","y","main")
        let stacks=StackGraph.inferred([fork,x,y])
        XCTAssertTrue(stacks.isEmpty,"\(stacks.map { $0.layers.map(\.title) })")
        XCTAssertEqual(StackGraph.visibleCards([fork,x,y],stacks:stacks).count,3)
    }
    func testNonMergeActionOnWarnedNativeStackValidatesWithoutAffectedLayers() throws {
        let a=pr("1","a","main"),b=pr("2","b","main")
        let stack=StackGraph.native(id:"S",number:1,size:2,entries:[.init(position:1,pr:a),.init(position:2,pr:b)],complete:true,linear:nil)
        XCTAssertFalse(stack.warnings.isEmpty)
        var evidence=MergeEvidence(key:b.key,head:b.headRevision.rawValue,base:"base",branch:"main",fetchedAt:Date());evidence.open=true;evidence.draft=false;evidence.canDisableAutoMerge=true;evidence.autoMergeEnabled=true
        let inspection=MergeInspection(pr:b,evidence:evidence,stack:stack)
        let command=try MergeCommand(selected:inspection,affected:[inspection],method:.squash,action:.disableAutoMerge)
        XCTAssertNoThrow(try command.validate([inspection]))
    }
}
