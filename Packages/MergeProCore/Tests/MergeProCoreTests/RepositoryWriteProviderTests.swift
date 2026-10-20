import XCTest
@testable import MergeProCore

private actor RepoWriteFixture:GitHubTransport {
    var writes=0
    var lost=false
    var existing=false
    var denied=false
    var protected=false
    var switched:(@Sendable () throws -> Void)?
    var forkRelated=true
    var closed=false
    var malformed=false
    var rateLimited=false
    var repoID=1
    var defaultBranch="main"
    let sha=String(repeating:"a",count:40)
    func configure(lost:Bool=false,existing:Bool=false,denied:Bool=false,protected:Bool=false,forkRelated:Bool=true,repoID:Int=1,defaultBranch:String="main",malformed:Bool=false,closed:Bool=false,rateLimited:Bool=false,switched:(@Sendable () throws -> Void)?=nil) { self.rateLimited=rateLimited;self.lost=lost;self.existing=existing;self.denied=denied;self.protected=protected;self.forkRelated=forkRelated;self.repoID=repoID;self.defaultBranch=defaultBranch;self.malformed=malformed;self.closed=closed;self.switched=switched }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        let path=request.url!.path
        if ["POST","DELETE"].contains(request.httpMethod ?? "") {
            if rateLimited { writes+=1;return .init(status:429,headers:["Retry-After":"30"]) }
            writes+=1;existing=true
            if lost { throw URLError(.networkConnectionLost) }
            return .init(status:201,data:Data((malformed ? "{}":pr).utf8))
        }
        let json:String
        if path.hasSuffix("/pulls") { json=existing ? "[\(pr)]" : "[]" }
        else if path.contains("/commits/") { json="{\"sha\":\"\(sha)\",\"commit\":{\"tree\":{\"sha\":\"\(sha)\"}}}" }
        else if path.contains("/branches/") { json="{\"name\":\"feature\",\"protected\":\(protected),\"commit\":{\"sha\":\"\(sha)\"}}" }
        else if path.hasSuffix("/branches") { json="[]" }
        else if path=="/repos/fork/r" { json="{\"id\":2,\"permissions\":{\"push\":\(!denied)},\"fork\":true,\"source\":{\"id\":\(forkRelated ? 1:3),\"full_name\":\"\(forkRelated ? "o/r":"other/repo")\"}}" }
        else { try switched?();json="{\"id\":\(repoID),\"permissions\":{\"push\":\(!denied)},\"default_branch\":\"\(defaultBranch)\"}" }
        return .init(status:200,data:Data(json.utf8))
    }
    var pr:String { "{\"state\":\"\(closed ? "closed":"open")\",\"number\":7,\"node_id\":\"PR7\",\"title\":\"Feature\",\"draft\":true,\"html_url\":\"https://github.com/o/r/pull/7\",\"head\":{\"ref\":\"feature\",\"sha\":\"\(sha)\"},\"base\":{\"ref\":\"main\",\"sha\":\"\(sha)\"}}" }
}
@MainActor final class RepositoryWriteProviderTests:XCTestCase {
    let repository=RepoCatalogEntry(repository:Repository(key:RepositoryKey(account:AccountScope(host:"github.com",accountID:"42"),repositoryID:"1"),name:"o/r",isPrivate:true,capabilities:[]),accountLogin:"actor")
    private func fixture(_ transport:RepoWriteFixture) throws -> (DatabaseStore,RepositoryBrowserService) {
        let fixture=try makeSessionFixture(account:repository.key.account,repositories:[repository.repository],transport:transport)
        return (fixture.database,RepositoryBrowserService(session:fixture.session,budget:RateBudget(minimumSpacing:.zero),database:fixture.database,clientID:"fixture",activeAccount:fixture.activeAccount))
    }
    func command(fork:Bool=false) -> CreatePRCommand { CreatePRCommand(repository:repository.providerKey,repositoryName:"o/r",head:fork ? "fork:feature":"feature",base:"main",title:"Feature",body:"",draft:true,reviewers:[],headRepository:fork ? "fork/r":nil) }
    func testExistingPRIsStoredAndReturnedWithoutPost() async throws {
        let transport=RepoWriteFixture();await transport.configure(existing:true)
        let (db,service)=try fixture(transport)
        let created=try await service.createPR(command())
        XCTAssertTrue(created.existing);XCTAssertEqual(created.number,7)
        let writes=await transport.writes;XCTAssertEqual(writes,0)
        XCTAssertEqual(try db.snapshot(for:repository.key.account).pullRequests.first?.key,created.key)
    }
    func testLostCreationResponseReconcilesWithoutSecondPost() async throws {
        let transport=RepoWriteFixture();await transport.configure(lost:true)
        let (_,service)=try fixture(transport)
        let result=try await service.createPR(command())
        XCTAssertTrue(result.existing)
        _ = try await service.createPR(command())
        let writes=await transport.writes;XCTAssertEqual(writes,1)
    }
    func testChangedActiveAccountDuringFreshPermissionReadNeverPosts() async throws {
        let transport=RepoWriteFixture();let (db,service)=try fixture(transport)
        await transport.configure(switched:{ try db.setApplicationSetting("other",for:"activeActionAccount") })
        do { _ = try await service.createPR(command());XCTFail() } catch {}
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testProtectedBranchFreshResponseRejectsDeletion() async throws {
        let transport=RepoWriteFixture();await transport.configure(protected:true)
        let (_,service)=try fixture(transport)
        do { try await service.deleteBranch(repository:repository,branch:RepositoryBranch(name:"feature",sha:String(repeating:"a",count:40),protected:false));XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.protectedBranch) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testBranchUsedByOpenPRIsNotDeleted() async throws {
        let transport=RepoWriteFixture();await transport.configure(existing:true)
        let (_,service)=try fixture(transport)
        do { try await service.deleteBranch(repository:repository,branch:RepositoryBranch(name:"feature",sha:String(repeating:"a",count:40),protected:false));XCTFail() } catch { XCTAssertEqual(error as? RepositoryPRActionFailure,.branchInUse(pullRequests:[7])) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testUnusedBranchIsDeleted() async throws {
        let transport=RepoWriteFixture()
        let (_,service)=try fixture(transport)
        try await service.deleteBranch(repository:repository,branch:RepositoryBranch(name:"feature",sha:String(repeating:"a",count:40),protected:false))
        let writes=await transport.writes;XCTAssertEqual(writes,1)
    }
    func testUnrelatedForkCannotCreatePR() async throws {
        let transport=RepoWriteFixture();await transport.configure(forkRelated:false)
        let (_,service)=try fixture(transport)
        do { _ = try await service.createPR(command(fork:true));XCTFail("Unrelated fork must be rejected") } catch {}
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testDeniedHeadPermissionNeverPosts() async throws {
        let transport=RepoWriteFixture();await transport.configure(denied:true)
        let (_,service)=try fixture(transport)
        do { _ = try await service.createPR(command());XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.permissionDenied) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
}

extension RepositoryWriteProviderTests {
    func testUnknownBranchDeletionReconcilesByCompleteBranchCatalogWithoutResending() async throws {
        let transport=RepoWriteFixture();let (db,service)=try fixture(transport)
        let mutation=RepositoryBranchMutation.delete(name:"feature",sha:String(repeating:"a",count:40))
        let store=try RepositoryBrowserPersistence(database:db)
        try store.record("branch-delete|1|feature|"+String(repeating:"a",count:40),account:repository.key.account,state:"unknown",data:Data())
        let pending=try await service.pendingBranchMutations(repository:repository)
        XCTAssertEqual(pending,[mutation])
        let result=try await service.reconcileBranch(repository:repository,mutation:mutation)
        XCTAssertEqual(result,.applied)
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
}

extension RepositoryWriteProviderTests {
    func testStaleRepositoryNameWithDifferentProviderIDNeverPosts() async throws {
        let transport=RepoWriteFixture();await transport.configure(repoID:2)
        let (_,service)=try fixture(transport)
        do { _ = try await service.createPR(command());XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.permissionDenied) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testFreshDefaultBranchMoveRejectsDeletion() async throws {
        let transport=RepoWriteFixture();await transport.configure(defaultBranch:"feature")
        let (_,service)=try fixture(transport)
        do { try await service.deleteBranch(repository:repository,branch:RepositoryBranch(name:"feature",sha:String(repeating:"a",count:40),protected:false));XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.defaultBranch) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testRelatedForkWithHeadPushPermissionCreatesOnePR() async throws {
        let transport=RepoWriteFixture();let (_,service)=try fixture(transport)
        let result=try await service.createPR(command(fork:true))
        XCTAssertFalse(result.existing)
        let writes=await transport.writes;XCTAssertEqual(writes,1)
    }
}

extension RepositoryWriteProviderTests {
    func testMalformedSuccessReceiptReconcilesExistingPRInsteadOfResending() async throws {
        let transport=RepoWriteFixture();await transport.configure(malformed:true)
        let (_,service)=try fixture(transport)
        let result=try await service.createPR(command())
        XCTAssertTrue(result.existing)
        let writes=await transport.writes;XCTAssertEqual(writes,1)
    }
}

extension RepositoryWriteProviderTests {
    func testLinkedClosedPRPreservesClosedInventoryState() async throws {
        let transport=RepoWriteFixture();await transport.configure(existing:true,closed:true)
        let (db,service)=try fixture(transport)
        let prs=try await service.linkedPRs(repository:repository,sha:String(repeating:"a",count:40))
        XCTAssertEqual(prs.count,1)
        XCTAssertEqual(try db.snapshot(for:repository.key.account).pullRequests.first?.state,.closed)
    }
}

extension RepositoryWriteProviderTests {
    func testStrandedPreparedWriteIsListedAndReleasableWithoutNetwork() async throws {
        let transport=RepoWriteFixture();let (db,service)=try fixture(transport)
        let sha=String(repeating:"a",count:40),ref=ResolvedRepositoryRef(name:"main",commitSHA:sha,treeSHA:sha)
        try RepositoryBrowserPersistence(database:db).record("branch-create|1|feature",account:repository.key.account,state:"prepared",data:JSONSerialization.data(withJSONObject:["ref":"refs/heads/feature","sha":sha]))
        let pending=try await service.pendingWrites(repository:repository)
        XCTAssertEqual(pending.map(\.identity),["branch-create|1|feature"]);XCTAssertEqual(pending.first?.state,.prepared);XCTAssertEqual(pending.first?.unsent,true)
        let branches=try await service.pendingBranchMutations(repository:repository);XCTAssertEqual(branches,[.create(name:"feature",sha:sha)])
        do { try await service.createBranch(repository:repository,name:"feature",from:ref);XCTFail("a stranded intent still blocks its target") } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        let before=await transport.writes;XCTAssertEqual(before,0)
        try await service.releaseUnsentWrite(repository:repository,identity:"branch-create|1|feature")
        let released=try await service.pendingWrites(repository:repository);XCTAssertTrue(released.isEmpty)
        try await service.createBranch(repository:repository,name:"feature",from:ref)
        let writes=await transport.writes;XCTAssertEqual(writes,1)
    }
    func testDispatchedOrUnknownWritesCannotBeReleasedLocally() async throws {
        let transport=RepoWriteFixture();let (db,service)=try fixture(transport)
        for (identity,state) in [("branch-create|1|a","sending"),("branch-create|1|b","unknown")] {
            try RepositoryBrowserPersistence(database:db).record(identity,account:repository.key.account,state:state,data:Data())
            do { try await service.releaseUnsentWrite(repository:repository,identity:identity);XCTFail(identity) } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        }
        do { try await service.releaseUnsentWrite(repository:repository,identity:"branch-create|2|other");XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.permissionDenied) }
        let pending=try await service.pendingWrites(repository:repository)
        XCTAssertEqual(Set(pending.map(\.identity)),["branch-create|1|a","branch-create|1|b"])
    }
    func testRateLimitedWriteIsARejectionNotAnUnknownOutcome() async throws {
        let transport=RepoWriteFixture();await transport.configure(rateLimited:true)
        let (db,service)=try fixture(transport)
        let sha=String(repeating:"a",count:40)
        do { try await service.createBranch(repository:repository,name:"feature",from:ResolvedRepositoryRef(name:"main",commitSHA:sha,treeSHA:sha));XCTFail() } catch { if case .rateLimited = error as? GitHubFailure {} else { XCTFail("\(error)") } }
        XCTAssertEqual(try RepositoryBrowserPersistence(database:db).operationState("branch-create|1|feature",account:repository.key.account),"rejected")
    }
    func testCreatedPRUsesTheCanonicalInventoryObjectID() async throws {
        let transport=RepoWriteFixture();let (_,service)=try fixture(transport)
        let created=try await service.createPR(command())
        XCTAssertEqual(created.key.objectID,"pull-request:PR7")
    }
}

/// Every list page advertises another `rel="next"` page, forever.
private actor EndlessPagesTransport:GitHubTransport {
    private(set) var lists:[String:Int]=[:]
    let sha=String(repeating:"a",count:40)
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        let url=request.url!, path=url.path
        let page=Int(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "page" }?.value ?? "1") ?? 1
        let next=["Link":"<https://api.github.com\(path)?page=\(page+1)>; rel=\"next\""]
        if path.hasSuffix("/branches") {
            lists[path,default:0]+=1
            return .init(status:200,headers:next,data:Data("[{\"name\":\"b\(page)\",\"commit\":{\"sha\":\"\(sha)\"},\"protected\":false}]".utf8))
        }
        if path == "/user/repos" {
            lists[path,default:0]+=1
            return .init(status:200,headers:next,data:Data("[{\"id\":\(page),\"full_name\":\"o/r\(page)\",\"private\":false}]".utf8))
        }
        if path.contains("/commits/") { return .init(status:200,data:Data("{\"sha\":\"\(sha)\",\"commit\":{\"tree\":{\"sha\":\"\(sha)\"}}}".utf8)) }
        return .init(status:200,data:Data("{\"id\":1,\"permissions\":{\"push\":true},\"default_branch\":\"main\"}".utf8))
    }
}
extension RepositoryWriteProviderTests {
    func testEndlessNextLinksStopAtThePageCap() async throws {
        let transport=EndlessPagesTransport()
        let fixture=try makeSessionFixture(account:repository.key.account,repositories:[repository.repository],transport:transport)
        let service=RepositoryBrowserService(session:fixture.session,budget:RateBudget(minimumSpacing:.zero),database:fixture.database,clientID:"fixture",activeAccount:fixture.activeAccount)
        let mutation=RepositoryBranchMutation.delete(name:"feature",sha:String(repeating:"a",count:40))
        do { _ = try await service.reconcileBranch(repository:repository,mutation:mutation);XCTFail("an incomplete branch catalog proves nothing") }
        catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        var lists=await transport.lists
        XCTAssertEqual(lists["/repos/o/r/branches"],RepositoryBrowserService.pageLimit)
        _ = try await service.catalog()
        lists=await transport.lists
        XCTAssertEqual(lists["/user/repos"],RepositoryBrowserService.pageLimit)
    }
}
