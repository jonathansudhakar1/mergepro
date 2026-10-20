import XCTest
@testable import MergeProCore

@MainActor final class PRDetailContextFixTests:XCTestCase {
    func testOverviewProvidesReviewerStatesMilestoneAndClosingIssuesWithPartialState() async throws {
        let response=json(#"{"data":{"repository":{"pullRequest":{"headRefOid":"head","milestone":{"title":"Ship","url":"https://github.com/o/r/milestone/1","state":"OPEN"},"reviews":{"nodes":[{"id":"PRR_old","author":{"login":"alice"},"state":"COMMENTED","submittedAt":"2026-09-30T10:00:00Z"},{"id":"PRR_alice","author":{"login":"alice"},"state":"APPROVED","submittedAt":"2026-10-01T10:00:00Z"}],"pageInfo":{"hasNextPage":false}},"reviewRequests":{"nodes":[{"requestedReviewer":{"login":"bob"}}],"pageInfo":{"hasNextPage":false}},"closingIssuesReferences":{"nodes":[{"number":3,"title":"Fix defect","url":"https://github.com/o/r/issues/3","state":"OPEN"}],"pageInfo":{"hasNextPage":true}}}}}}"#)
        let transport=ScriptedTransport([response])
        let value=try await GitHubPRDetailFetcher(client:.init(transport:transport)).section(repository:"o/r",number:1,sha:"head",tab:.overview,token:"fixture")
        let overview=try XCTUnwrap(value.overview)
        XCTAssertEqual(overview.reviewers.first(where:{$0.name == "alice"})?.state,"APPROVED")
        XCTAssertTrue(overview.reviewers.first(where:{$0.name == "bob"})?.requested == true)
        XCTAssertEqual(overview.reviewers.first(where:{$0.name == "alice"})?.latestReviewID,"PRR_alice")
        XCTAssertEqual(overview.reviewers.first(where:{$0.name == "alice"})?.latestReviewState,"APPROVED")
        XCTAssertNil(overview.reviewers.first(where:{$0.name == "bob"})?.latestReviewID)
        let requests=await transport.captured()
        let query=try XCTUnwrap(requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }?["query"] as? String)
        XCTAssertTrue(query.contains("nodes { id author"))
        XCTAssertEqual(overview.milestone?.title,"Ship");XCTAssertEqual(overview.issues.first?.number,3)
        XCTAssertFalse(value.complete);XCTAssertFalse(overview.issuesComplete)
    }
    func testCommitAuthorAndChecksAreBoundToProviderCommit() async throws {
        let transport=ScriptedTransport([json(#"{"data":{"repository":{"pullRequest":{"headRefOid":"head","commits":{"nodes":[{"commit":{"oid":"commit","message":"Change","url":"https://github.com/o/r/commit/commit","author":{"name":"A","user":{"login":"alice"}},"statusCheckRollup":{"state":"SUCCESS"}}}],"pageInfo":{"hasNextPage":false}}}}}}"#)])
        let value=try await GitHubPRDetailFetcher(client:.init(transport:transport)).section(repository:"o/r",number:1,sha:"head",tab:.commits,token:"fixture")
        XCTAssertEqual(value.events.first?.sha,"commit");XCTAssertEqual(value.events.first?.commitContext?.authorLogin,"alice")
        XCTAssertEqual(value.events.first?.commitContext?.checksState,"SUCCESS")
    }
    func testCheckDurationPreservesUnknownAndInvalidIntervals() async throws {
        let transport=ScriptedTransport([json(#"{"check_runs":[{"id":1,"name":"Build","status":"completed","started_at":"2026-10-01T10:00:00Z","completed_at":"2026-10-01T10:01:05Z"},{"id":2,"name":"Queued","status":"queued"},{"id":3,"name":"Bad","started_at":"2026-10-01T10:01:00Z","completed_at":"2026-10-01T10:00:00Z"}]}"#),json("[]")])
        let value=try await GitHubPRDetailFetcher(client:.init(transport:transport)).section(repository:"o/r",number:1,sha:"head",tab:.checks,token:"fixture")
        XCTAssertEqual(value.events[0].checkTiming?.duration,65)
        XCTAssertNil(value.events[1].checkTiming?.duration);XCTAssertNil(value.events[2].checkTiming?.duration)
    }
    func testAutomaticContextFailureRetryPartialCancellationAndOldRequest() {
        var source=PRContextSource()
        let first=source.begin();XCTAssertEqual(source.phase,.loading)
        source.fail(GitHubFailure.resourceDenied,request:first);XCTAssertEqual(source.phase,.failed)
        let retry=source.begin();source.succeed(.init(events:[],complete:false),request:retry);XCTAssertEqual(source.phase,.partial)
        let next=source.begin();source.fail(GitHubFailure.invalidResponse,request:retry);XCTAssertEqual(source.phase,.loading)
        source.fail(CancellationError(),request:next);XCTAssertEqual(source.phase,.idle)
        let last=source.begin();source.succeed(.init(events:[],complete:true),request:last);XCTAssertEqual(source.phase,.loaded)
    }
}

extension PRDetailContextFixTests {
    func testMalformedAutomaticContextCannotLookLikeSuccessfulEmptyResult() async throws {
        let transport=ScriptedTransport([json(#"{"unexpected":"shape"}"#),json("[]")])
        var source=PRContextSource();let request=source.begin()
        do {
            let value=try await GitHubPRDetailFetcher(client:.init(transport:transport)).section(repository:"o/r",number:1,sha:"head",tab:.checks,token:"fixture")
            source.succeed(value,request:request)
        } catch { source.fail(error,request:request) }
        XCTAssertEqual(source.phase,.failed)
    }
}

extension PRDetailContextFixTests {
    func testCachedContextStaysVisibleAndLabeledWhileRevalidating() throws {
        let cached=PRDetailSection(events:[.init(id:"c",title:"Build",body:"",url:nil)],complete:true,fetchedAt:Date(timeIntervalSince1970:100),cached:true)
        var source=PRContextSource()
        let first=source.begin(cached:cached)
        XCTAssertEqual(source.phase,.loading);XCTAssertTrue(source.showingCached);XCTAssertEqual(source.section?.fetchedAt,Date(timeIntervalSince1970:100))
        source.fail(GitHubFailure.invalidResponse,request:first)
        XCTAssertEqual(source.phase,.failed);XCTAssertEqual(source.section?.events.first?.id,"c","failed revalidation keeps the labeled cached section")
        let second=source.begin(cached:cached)
        source.succeed(.init(events:[],complete:true,fetchedAt:Date()),request:second)
        XCTAssertEqual(source.phase,.loaded);XCTAssertFalse(source.showingCached);XCTAssertEqual(source.section?.events.count,0)
        let fresh=source.begin();source.fail(GitHubFailure.invalidResponse,request:fresh);XCTAssertNil(source.section)
        let encoded=try JSONEncoder().encode(cached),decoded=try JSONDecoder().decode(PRDetailSection.self,from:encoded)
        XCTAssertEqual(decoded.events,cached.events);XCTAssertTrue(decoded.cached)
    }
}
