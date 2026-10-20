import XCTest
@testable import MergeProCore

@MainActor final class PRCommitDetailTests:XCTestCase {
    let sha=String(repeating:"a",count:40),parent=String(repeating:"b",count:40),other=String(repeating:"c",count:40)
    func response(sha:String? = nil,parents:[String]? = nil,path:String = "a.swift",headers:[String:String] = [:]) -> GitHubResponse {
        let root=parents?.isEmpty == true
        let value:[String:Any] = ["sha":sha ?? self.sha,"html_url":"https://github.com/o/r/commit/\(sha ?? self.sha)","commit":["message":"Subject\n\nBody","author":["name":"Alice","date":"2026-10-01T10:00:00Z"]],"author":["login":"alice"],"parents":(parents ?? [parent]).map { ["sha":$0] },"files":[["filename":path,"status":root ? "added" : "modified","patch":root ? "@@ -0,0 +1 @@\n+new" : "@@ -1 +1 @@\n-old\n+new","additions":1,"deletions":root ? 0 : 1]]]
        return json(String(data:try! JSONSerialization.data(withJSONObject:value),encoding:.utf8)!,headers:headers)
    }
    func testSelectedCommitMetadataAndDiffUseCommitAndFirstParent() async throws {
        let transport=ScriptedTransport([response(parents:[parent,other])])
        let value=try await GitHubPRDetailFetcher(client:.init(transport:transport)).commitDetail(repository:"o/r",sha:sha,token:"fixture")
        XCTAssertEqual(value.message,"Subject\n\nBody");XCTAssertEqual(value.authorLogin,"alice")
        XCTAssertNotNil(value.authoredAt);XCTAssertEqual(value.parents,[parent,other])
        XCTAssertEqual(value.document.baseSHA,parent);XCTAssertEqual(value.document.headSHA,sha)
        XCTAssertEqual(value.document.comparison,.snapshot,"Historical commits must never admit current PR comments or viewed writes")
        XCTAssertEqual(value.files.first?.patchState,.available)
        let requests=await transport.captured();XCTAssertEqual(requests.count,1)
        XCTAssertEqual(requests[0].url?.path,"/repos/o/r/commits/\(sha)");XCTAssertEqual(requests[0].httpMethod,"GET")
    }
    func testRootCommitUsesEmptyTreeAndAddedFiles() async throws {
        let transport=ScriptedTransport([response(parents:[])])
        let value=try await GitHubPRDetailFetcher(client:.init(transport:transport)).commitDetail(repository:"o/r",sha:sha,token:"fixture")
        XCTAssertTrue(value.parents.isEmpty)
        XCTAssertEqual(value.document.baseSHA,"4b825dc642cb6eb9a060e54bf8d69288fbee4904")
        XCTAssertEqual(value.files.first?.status,.added,"A root has no old source to fetch")
        XCTAssertTrue(value.files[0].lines.allSatisfy { $0.oldLine == nil })
    }
    func testPagesKeepImmutableOriginAndAppendWithoutHidingPartialState() async throws {
        let transport=ScriptedTransport([response(headers:["Link":"<https://api.github.com/ignored>; rel=\"next\""]),response(path:"b.swift")])
        let fetcher=GitHubPRDetailFetcher(client:.init(transport:transport))
        let first=try await fetcher.commitDetail(repository:"o/r",sha:sha,token:"fixture")
        XCTAssertEqual(first.nextPage,2);XCTAssertFalse(first.complete)
        let second=try await fetcher.moreCommitDetail(repository:"o/r",snapshot:first,token:"fixture")
        XCTAssertEqual(second.files.map(\.path),["a.swift","b.swift"]);XCTAssertTrue(second.complete);XCTAssertNil(second.nextPage)
        let requests=await transport.captured()
        XCTAssertEqual(URLComponents(url:requests[1].url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "page"})?.value,"2")
        XCTAssertEqual(requests[1].url?.host,"api.github.com","Provider links must not be followed")
    }
    func testWrongCommitOrChangedParentOnContinuationIsRejected() async throws {
        for next in [response(sha:other,path:"b.swift"),response(parents:[other],path:"b.swift"),response()] {
            let transport=ScriptedTransport([response(headers:["Link":"<x>; rel=\"next\""]),next])
            let fetcher=GitHubPRDetailFetcher(client:.init(transport:transport))
            let first=try await fetcher.commitDetail(repository:"o/r",sha:sha,token:"fixture")
            do { _ = try await fetcher.moreCommitDetail(repository:"o/r",snapshot:first,token:"fixture");XCTFail("Mixed or duplicate inventory accepted") }
            catch { XCTAssertTrue(error is PRDetailFailure) }
        }
    }
    func testSymbolicCommitAndUnsafeRepositoryDoNotReachTransport() async {
        let transport=ScriptedTransport([])
        let fetcher=GitHubPRDetailFetcher(client:.init(transport:transport))
        for (repository,sha) in [("o/r","main"),("o/../r",self.sha)] {
            do { _ = try await fetcher.commitDetail(repository:repository,sha:sha,token:"fixture");XCTFail("Unsafe identity accepted") }
            catch { XCTAssertEqual(error as? PRDetailFailure,.invalidPath) }
        }
        let requests=await transport.captured();XCTAssertTrue(requests.isEmpty)
    }
    func testCancelledCommitReadCannotReturnItsLateProviderResult() async throws {
        try await heldRead { _,_,task in task.cancel() }
    }
    func testCommitReadIsRejectedAfterPRHeadChanges() async throws {
        try await heldRead { db,pr,_ in
            try db.savePullRequests([.init(key:pr.key,headRevision:.init("new-head"),title:pr.title,state:pr.state,isDraft:pr.isDraft,metadata:pr.metadata)])
        }
    }
    func testMergeFileDiffIsComputedFromExactFirstParentSources() async throws {
        let key=ProviderKey(host:"github.com",accountID:"a",repositoryID:"1",objectID:"p")
        let before=Data("first parent\n".utf8).base64EncodedString(),after=Data("merged result\n".utf8).base64EncodedString()
        let transport=ScriptedTransport([response(parents:[parent,other]),json("{\"type\":\"file\",\"encoding\":\"base64\",\"content\":\"\(before)\"}"),json("{\"type\":\"file\",\"encoding\":\"base64\",\"content\":\"\(after)\"}")])
        let fixture=try makeSessionFixture(account:key.account,login:"a",tokenReference:"fixture",repositories:[.fixture(key.repository)],transport:transport,credential:.init(accessToken:"fixture"),active:false)
        let (db,session)=(fixture.database,fixture.session)
        let pr=PullRequest(key:key,headRevision:.init(sha),title:"PR",state:.open,isDraft:false,metadata:.init(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r"))
        try db.savePullRequests([pr])
        let service=PRDetailService(session:session,budget:.init(minimumSpacing:.zero,interactiveReserve:0),clientID:"",memory:PRDetailMemoryCache())
        let detail=try await service.commitDetail(pr,sha:sha)
        let file=try await service.snapshotFile(pr,document:detail.document,file:detail.files[0])
        XCTAssertEqual(file.lines.map(\.text),["first parent","merged result"],"The original REST patch must not substitute for the explicit parent snapshots")
        let requests=await transport.captured()
        let revisions=requests.dropFirst().map { URLComponents(url:$0.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "ref"})?.value }
        XCTAssertEqual(revisions,[parent,sha]);XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
    private func heldRead(change:(DatabaseStore,PullRequest,Task<PRCommitDetail,any Error>) throws -> Void) async throws {
        let key=ProviderKey(host:"github.com",accountID:"a",repositoryID:"1",objectID:"p")
        let transport=ScriptedTransport(fallback:response(),holdingFirst:1)
        let fixture=try makeSessionFixture(account:key.account,login:"a",tokenReference:"fixture",repositories:[.fixture(key.repository)],transport:transport,credential:.init(accessToken:"fixture"),active:false)
        let (db,session)=(fixture.database,fixture.session)
        let pr=PullRequest(key:key,headRevision:.init(sha),title:"PR",state:.open,isDraft:false,metadata:.init(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r"))
        try db.savePullRequests([pr])
        let service=PRDetailService(session:session,budget:.init(minimumSpacing:.zero,interactiveReserve:0),clientID:"",memory:PRDetailMemoryCache())
        let task=Task { try await service.commitDetail(pr,sha:sha) }
        await transport.waitUntilHolding()
        try change(db,pr,task)
        await transport.release()
        do { _ = try await task.value;XCTFail("Late result escaped cancellation/head fence") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

