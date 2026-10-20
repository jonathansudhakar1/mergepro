import XCTest
@testable import MergeProCore

private actor PRActionFixture:GitHubTransport {
    let headSHA=String(repeating:"a",count:40)
    var branchSHA:String?=String(repeating:"a",count:40)
    var merged=true
    var providerState="closed"
    var headRepositoryID=1
    var existingRevert=false
    var historicalRevert=false
    func useHistoricalRevert() { historicalRevert=true }
    var lost=false
    var applies=true
    var requests:[URLRequest]=[]
    var writes=0
    /// Other open PRs: (number, head ref, base ref). Served for `pulls?head=` / non-revert `pulls?base=` reads.
    var openPRs:[(Int,String,String)]=[]
    var branchName="feature"
    var pullsStatus=200
    var endlessPulls=false
    func use(openPRs:[(Int,String,String)]=[],branchName:String="feature",pullsStatus:Int=200,endlessPulls:Bool=false) { self.openPRs=openPRs;self.branchName=branchName;self.pullsStatus=pullsStatus;self.endlessPulls=endlessPulls }
    func pullQueries() -> [String] { requests.filter { $0.url!.path=="/repos/o/r/pulls" && $0.httpMethod ?? "GET"=="GET" }.compactMap { $0.url!.query(percentEncoded:true) } }
    func configure(branchSHA:String?=String(repeating:"a",count:40),merged:Bool=true,providerState:String="closed",headRepositoryID:Int=1,existingRevert:Bool=false,lost:Bool=false,applies:Bool=true) { self.branchSHA=branchSHA;self.merged=merged;self.providerState=providerState;self.headRepositoryID=headRepositoryID;self.existingRevert=existingRevert;self.lost=lost;self.applies=applies }
    var revertJSON:String { "{\"number\":99,\"node_id\":\"PR_99\",\"title\":\"Revert \\\"Feature\\\"\",\"state\":\"open\",\"draft\":true,\"html_url\":\"https://github.com/o/r/pull/99\",\"head\":{\"ref\":\"revert-12-feature\",\"sha\":\"\(headSHA)\",\"repo\":{\"id\":1}},\"base\":{\"ref\":\"main\",\"sha\":\"\(headSHA)\"},\"created_at\":\"\(ISO8601DateFormatter().string(from:Date()))\"}" }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        requests.append(request)
        let path=request.url!.path,method=request.httpMethod ?? "GET"
        if path=="/graphql" {
            writes+=1;if applies { existingRevert=true }
            if lost { throw URLError(.networkConnectionLost) }
            return .init(status:200,data:Data("{\"data\":{\"revertPullRequest\":{\"revertPullRequest\":{\"id\":\"PR_99\",\"number\":99,\"url\":\"https://github.com/o/r/pull/99\",\"title\":\"Revert \\\"Feature\\\"\",\"isDraft\":true,\"state\":\"OPEN\",\"headRefName\":\"revert-12-feature\",\"headRefOid\":\"\(headSHA)\",\"baseRefName\":\"main\",\"baseRefOid\":\"\(headSHA)\"}}}}".utf8))
        }
        if method=="DELETE" { writes+=1;branchSHA=nil;return .init(status:204) }
        if method=="POST",path=="/repos/o/r/git/refs" {
            writes+=1
            let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any];branchSHA=body["sha"] as? String
            return .init(status:201,data:Data("{\"ref\":\"refs/heads/feature\",\"object\":{\"sha\":\"\(branchSHA!)\"}}".utf8))
        }
        if path=="/repos/o/r/pulls/12" { return .init(status:200,data:Data("{\"number\":12,\"node_id\":\"PR_12\",\"state\":\"\(providerState)\",\"merged\":\(merged),\"merged_at\":\(merged ? "\"2026-10-01T00:00:00Z\"":"null"),\"title\":\"Feature\",\"head\":{\"ref\":\"\(branchName)\",\"sha\":\"\(headSHA)\",\"repo\":{\"id\":\(headRepositoryID)}},\"base\":{\"ref\":\"main\",\"sha\":\"\(headSHA)\",\"repo\":{\"id\":1}}}".utf8)) }
        if path=="/repos/o/r/pulls" {
            let items=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems ?? []
            func value(_ name:String) -> String? { items.first { $0.name==name }?.value }
            if value("head") != nil || value("base") != "main" {
                guard pullsStatus==200 else { return .init(status:pullsStatus,data:Data("{\"message\":\"Unavailable\"}".utf8)) }
                let head=value("head"),base=value("base")
                let matching=openPRs.filter { pr in head.map { "o:"+pr.1==$0 } ?? (pr.2==base) }
                let json=matching.map { "{\"number\":\($0.0),\"state\":\"open\",\"head\":{\"ref\":\"\($0.1)\"},\"base\":{\"ref\":\"\($0.2)\"}}" }.joined(separator:",")
                return .init(status:200,headers:endlessPulls ? ["Link":"<https://api.github.com/repositories/1/pulls?page=2>; rel=\"next\""]:[:],data:Data("[\(json)]".utf8))
            }
            if historicalRevert,value("state") == "all",!existingRevert {
                var historical=try JSONSerialization.jsonObject(with:Data(revertJSON.utf8)) as! [String:Any]
                historical["state"]="closed";historical["created_at"]="2025-01-01T00:00:00Z"
                return .init(status:200,data:try JSONSerialization.data(withJSONObject:[historical]))
            }
            return .init(status:200,data:Data((existingRevert ? "[\(revertJSON)]":"[]").utf8))
        }
        if path=="/repos/o/r/branches/"+branchName {
            guard let branchSHA else { return .init(status:404,data:Data("{\"message\":\"Branch not found\"}".utf8)) }
            return .init(status:200,data:try JSONSerialization.data(withJSONObject:["name":branchName,"protected":false,"commit":["sha":branchSHA]]))
        }
        if path.hasPrefix("/repos/o/r/commits/") { return .init(status:200,data:Data("{\"sha\":\"\(headSHA)\",\"commit\":{\"tree\":{\"sha\":\"\(headSHA)\"}}}".utf8)) }
        return .init(status:200,data:Data("{\"id\":1,\"permissions\":{\"push\":true},\"default_branch\":\"main\"}".utf8))
    }
}

@MainActor final class RepositoryPRActionTests:XCTestCase {
    let repository=RepoCatalogEntry(repository:Repository(key:RepositoryKey(account:AccountScope(host:"github.com",accountID:"42"),repositoryID:"1"),name:"o/r",isPrivate:true,capabilities:[]),accountLogin:"actor")
    let headSHA=String(repeating:"a",count:40)
    private func fixture(_ transport:PRActionFixture) throws -> (DatabaseStore,RepositoryBrowserService) {
        let fixture=try makeSessionFixture(account:repository.key.account,repositories:[repository.repository],transport:transport)
        return (fixture.database,RepositoryBrowserService(session:fixture.session,budget:RateBudget(minimumSpacing:.zero),database:fixture.database,clientID:"fixture",activeAccount:fixture.activeAccount))
    }
    func pr(state:PullRequest.State = .merged,headRepositoryID:String?="1",branch:String="feature") -> PullRequest {
        var metadata=PRMetadata(number:12,webURL:URL(string:"https://github.com/o/r/pull/12")!,repositoryName:"o/r")
        metadata.headBranch=branch;metadata.baseBranch="main";metadata.headRepositoryID=headRepositoryID
        return PullRequest(key:ProviderKey(host:"github.com",accountID:"42",repositoryID:"1",objectID:"pull-request:PR_12"),headRevision:RevisionID(headSHA),title:"Feature",state:state,isDraft:false,metadata:metadata)
    }
    func revert(_ service:RepositoryBrowserService) async throws -> RepositoryRevertResult {
        try await service.revertPullRequest(repository:repository,pullRequestNodeID:"pull-request:PR_12",number:12,title:"Revert \"Feature\"",body:"Reverts #12",draft:true)
    }

    func testRevertSendsGraphQLMutationAndStoresCreatedPR() async throws {
        let transport=PRActionFixture();let (db,service)=try fixture(transport)
        let result=try await revert(service)
        XCTAssertEqual(result.number,99);XCTAssertFalse(result.existing)
        XCTAssertEqual(result.key,ProviderKey(host:"github.com",accountID:"42",repositoryID:"1",objectID:"pull-request:PR_99"))
        XCTAssertEqual(result.webURL,URL(string:"https://github.com/o/r/pull/99"))
        let request=await transport.requests.first { $0.url!.path=="/graphql" }!
        let envelope=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        XCTAssertTrue((envelope["query"] as! String).hasPrefix("mutation"));XCTAssertTrue((envelope["query"] as! String).contains("revertPullRequest(input:$input)"))
        let input=(envelope["variables"] as! [String:Any])["input"] as! [String:Any]
        XCTAssertEqual(input["pullRequestId"] as? String,"PR_12");XCTAssertEqual(input["title"] as? String,"Revert \"Feature\"");XCTAssertEqual(input["body"] as? String,"Reverts #12");XCTAssertEqual(input["draft"] as? Bool,true)
        let stored=try db.snapshot(for:repository.key.account).pullRequests.first { $0.key==result.key }
        XCTAssertEqual(stored?.metadata?.number,99);XCTAssertEqual(stored?.metadata?.headRepositoryID,"1");XCTAssertEqual(stored?.isDraft,true)
        let writes=await transport.writes;XCTAssertEqual(writes,1)
    }
    func testRevertRefusesUnmergedPullRequestWithoutMutation() async throws {
        let transport=PRActionFixture();await transport.configure(merged:false)
        let (_,service)=try fixture(transport)
        do { _ = try await revert(service);XCTFail() } catch { XCTAssertEqual(error as? RepositoryPRActionFailure,.notMerged) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testExistingOpenRevertIsReturnedWithoutMutation() async throws {
        let transport=PRActionFixture();await transport.configure(existingRevert:true)
        let (_,service)=try fixture(transport)
        let result=try await revert(service)
        XCTAssertTrue(result.existing);XCTAssertEqual(result.number,99);XCTAssertEqual(result.key.objectID,"pull-request:PR_99")
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testLostRevertResponseReconcilesByFreshReadWithoutResending() async throws {
        let transport=PRActionFixture();await transport.configure(lost:true)
        let (_,service)=try fixture(transport)
        let first=try await revert(service)
        XCTAssertTrue(first.existing);XCTAssertEqual(first.number,99)
        let second=try await revert(service)
        XCTAssertEqual(second.number,99)
        let writes=await transport.writes;XCTAssertEqual(writes,1)
        let pending=try await service.pendingWrites(repository:repository);XCTAssertTrue(pending.isEmpty)
    }
    func testLostRevertWithoutVisibleResultStaysUnknownUntilReconciled() async throws {
        let transport=PRActionFixture();await transport.configure(lost:true,applies:false)
        let (_,service)=try fixture(transport)
        do { _ = try await revert(service);XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        let pending=try await service.pendingWrites(repository:repository)
        XCTAssertEqual(pending.map(\.identity),["pr-revert|1|12"]);XCTAssertEqual(pending.first?.state,.unknown)
        do { _ = try await revert(service);XCTFail("an unknown revert must never be resent") } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        let reconciled=try await service.reconcileRevert(repository:repository,number:12)
        XCTAssertEqual(reconciled,.notApplied)
        let writes=await transport.writes;XCTAssertEqual(writes,1)
        let after=try await service.pendingWrites(repository:repository);XCTAssertTrue(after.isEmpty)
    }
    func testLostRevertResponseDoesNotAdoptHistoricalClosedRevert() async throws {
        let transport=PRActionFixture();await transport.configure(lost:true,applies:false);await transport.useHistoricalRevert()
        let (_,service)=try fixture(transport)
        do { _ = try await revert(service);XCTFail("historical closed revert confirmed a new unsuccessful attempt") }
        catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        let pending=try await service.pendingWrites(repository:repository)
        XCTAssertEqual(pending.map(\.identity),["pr-revert|1|12"])
    }
    func testReconcileRevertDoesNotAdoptHistoricalClosedRevert() async throws {
        let transport=PRActionFixture();await transport.configure(lost:true,applies:false)
        let (_,service)=try fixture(transport)
        do { _ = try await revert(service);XCTFail() }
        catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        await transport.useHistoricalRevert()
        let result=try await service.reconcileRevert(repository:repository,number:12)
        XCTAssertEqual(result,.notApplied,"only PRs created in the attempt window can confirm it")
        let writes=await transport.writes;XCTAssertEqual(writes,1,"reconciliation never resends")
    }
    /// DELETE carries no SHA condition: the head SHA and branch users are preflight READS, then the
    /// unconditional DELETE goes through the branch-delete ledger keyed by that SHA.
    func testDeleteHeadBranchPreflightReadsHeadSHAAndOpenPRUsersThenDeletesThroughBranchLedger() async throws {
        let transport=PRActionFixture();let (db,service)=try fixture(transport)
        try await service.deleteHeadBranch(repository:repository,pr:pr())
        let delete=await transport.requests.first { $0.httpMethod=="DELETE" }
        XCTAssertEqual(delete?.url?.path,"/repos/o/r/git/refs/heads/feature")
        XCTAssertEqual(try RepositoryBrowserPersistence(database:db).operationState("branch-delete|1|feature|"+headSHA,account:repository.key.account),"applied")
        let queries=await transport.pullQueries()
        XCTAssertTrue(queries.contains { $0.contains("state=open") && $0.contains("head=o:feature") },queries.joined(separator:"\n"))
        XCTAssertTrue(queries.contains { $0.contains("state=open") && $0.contains("base=feature") },queries.joined(separator:"\n"))
    }
    func testDeleteHeadRefusesWhileAnotherOpenPRUsesTheBranchAsHead() async throws {
        let transport=PRActionFixture();await transport.use(openPRs:[(15,"feature","release")])
        let (_,service)=try fixture(transport)
        do { try await service.deleteHeadBranch(repository:repository,pr:pr());XCTFail() } catch {
            XCTAssertEqual(error as? RepositoryPRActionFailure,.branchInUse(pullRequests:[15]))
            XCTAssertTrue(error.localizedDescription.contains("open PR #15"),error.localizedDescription)
        }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testDeleteHeadRefusesWhileAStackedOpenPRTargetsTheBranch() async throws {
        let transport=PRActionFixture();await transport.use(openPRs:[(16,"child","feature"),(17,"other","feature")])
        let (_,service)=try fixture(transport)
        do { try await service.deleteHeadBranch(repository:repository,pr:pr());XCTFail() } catch {
            XCTAssertEqual(error as? RepositoryPRActionFailure,.branchInUse(pullRequests:[16,17]))
            XCTAssertTrue(error.localizedDescription.contains("#16") && error.localizedDescription.contains("#17"),error.localizedDescription)
        }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testDeleteHeadRefusesWhenOpenPRUsersAreUnknown() async throws {
        for (status,endless) in [(500,false),(403,false),(200,true)] {
            let transport=PRActionFixture();await transport.use(pullsStatus:status,endlessPulls:endless)
            let (_,service)=try fixture(transport)
            do { try await service.deleteHeadBranch(repository:repository,pr:pr());XCTFail("\(status) \(endless)") } catch {
                if endless { XCTAssertEqual(error as? RepositoryPRActionFailure,.branchUsageUnknown) } else { XCTAssertNotNil(error as? GitHubFailure,"\(error)") }
            }
            let writes=await transport.writes;XCTAssertEqual(writes,0,"Unknown means don't delete")
        }
    }
    func testOpenPRUsageQueryEncodesSpecialBranchCharacters() async throws {
        let branch="fix+1&x=y"
        let transport=PRActionFixture();await transport.use(branchName:branch)
        let (_,service)=try fixture(transport)
        try await service.deleteHeadBranch(repository:repository,pr:pr(branch:branch))
        let queries=await transport.pullQueries()
        XCTAssertTrue(queries.contains { $0.contains("head=o:fix%2B1%26x%3Dy") },queries.joined(separator:"\n"))
        XCTAssertTrue(queries.contains { $0.contains("base=fix%2B1%26x%3Dy") },queries.joined(separator:"\n"))
    }
    func testDeleteHeadRefusesWhenBranchMovedSinceTheHead() async throws {
        let transport=PRActionFixture();await transport.configure(branchSHA:String(repeating:"b",count:40))
        let (_,service)=try fixture(transport)
        do { try await service.deleteHeadBranch(repository:repository,pr:pr());XCTFail() } catch { XCTAssertEqual(error as? RepositoryPRActionFailure,.headMoved) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testHeadCleanupRefusesCrossRepositoryAndOpenPRsWithoutNetwork() async throws {
        let transport=PRActionFixture();let (_,service)=try fixture(transport)
        do { try await service.deleteHeadBranch(repository:repository,pr:pr(headRepositoryID:"2"));XCTFail() } catch { XCTAssertEqual(error as? RepositoryPRActionFailure,.crossRepositoryHead) }
        do { try await service.restoreHeadBranch(repository:repository,pr:pr(headRepositoryID:nil));XCTFail() } catch { XCTAssertEqual(error as? RepositoryPRActionFailure,.crossRepositoryHead) }
        do { try await service.deleteHeadBranch(repository:repository,pr:pr(state:.open));XCTFail() } catch { XCTAssertEqual(error as? RepositoryPRActionFailure,.stillOpen) }
        let requests=await transport.requests;XCTAssertTrue(requests.isEmpty)
    }
    func testProviderReopenedPullRequestBlocksDeletion() async throws {
        let transport=PRActionFixture();await transport.configure(providerState:"open")
        let (_,service)=try fixture(transport)
        do { try await service.deleteHeadBranch(repository:repository,pr:pr());XCTFail() } catch { XCTAssertEqual(error as? RepositoryPRActionFailure,.stillOpen) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testRestoreRecreatesBranchAtHeadSHA() async throws {
        let transport=PRActionFixture();await transport.configure(branchSHA:nil)
        let (db,service)=try fixture(transport)
        let before=try await service.headBranch(repository:repository,pr:pr());XCTAssertNil(before)
        try await service.restoreHeadBranch(repository:repository,pr:pr(state:.closed))
        let post=await transport.requests.first { $0.httpMethod=="POST" && $0.url!.path=="/repos/o/r/git/refs" }!
        let body=try JSONSerialization.jsonObject(with:post.httpBody!) as! [String:Any]
        XCTAssertEqual(body["ref"] as? String,"refs/heads/feature");XCTAssertEqual(body["sha"] as? String,headSHA)
        XCTAssertEqual(try RepositoryBrowserPersistence(database:db).operationState("branch-create|1|feature",account:repository.key.account),"applied")
        let after=try await service.headBranch(repository:repository,pr:pr());XCTAssertEqual(after?.sha,headSHA)
    }
    func testRestoreRefusesWhenBranchStillExists() async throws {
        let transport=PRActionFixture();let (_,service)=try fixture(transport)
        do { try await service.restoreHeadBranch(repository:repository,pr:pr());XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.existingBranch) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
}
