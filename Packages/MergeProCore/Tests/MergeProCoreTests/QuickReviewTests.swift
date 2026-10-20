import XCTest
import GRDB
@testable import MergeProCore

/// Confirms a reconcile read only when `confirms` is set, so an ambiguous receipt stays uncertain.
private actor ReviewAdapter:PRWriteAdapter {
    let truth:PRWriteTruth
    var confirms=true
    init(_ truth:PRWriteTruth) { self.truth=truth }
    func confirming(_ value:Bool) { confirms=value }
    func read(_ command:PRWriteCommand,operation:PRWriteOperation?,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> PRWriteTruth {
        var result=truth;result.revision=command.revision
        if operation != nil { result.matchingOperationIDs=confirms ? ["review"] : [] }
        return result
    }
    func send(_ operation:PRWriteOperation,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse {
        try await client.mutate(path:"repos/o/r/pulls/1/reviews",method:"POST",body:Data("{}".utf8),token:credential.accessToken)
    }
    nonisolated func providerIDs(_ response:GitHubResponse) -> [String] { ["review"] }
}

@MainActor final class QuickReviewTests:XCTestCase {
    let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"1",objectID:"PR1")
    let revision=PRWriteRevision(head:"h2",origin:"o",target:"t")
    private func fixture(confirms:Bool=true,loseResponse:Bool=false) async throws -> (DatabaseStore,GitHubReviewService,ScriptedTransport) {
        let transport=ScriptedTransport(fallback:json(#"{"id":"review"}"#));if loseResponse { await transport.answerRemaining(.lostResponse) }
        let fixture=try makeSessionFixture(account:key.account,login:"reviewer",repositories:[.fixture(key.repository)],transport:transport),db=fixture.database
        let row=PullRequest(key:key,headRevision:.init("h2"),title:"PR",state:.open,isDraft:false,metadata:.init(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r"))
        try db.savePullRequests([row])
        let adapter=ReviewAdapter(PRWriteTruth(key:key,revision:revision,viewerIsAuthor:false,canReview:true,canComment:true,canUpdate:true,canReopen:true,canLabel:true,isOpen:true,normalized:row))
        await adapter.confirming(confirms)
        let coordinator=PRWriteCoordinator(session:fixture.session,budget:RateBudget(minimumSpacing:.zero),database:db,clientID:"fixture",activeAccount:fixture.activeAccount,adapter:adapter)
        return (db,GitHubReviewService(coordinator:coordinator,database:db),transport)
    }
    func testConfirmedQuickApprovalRecordsTheReviewedHeadThroughTheLedger() async throws {
        let (db,service,transport)=try await fixture()
        let result=try await service.submitQuick(pr:key,revision:revision,decision:.approve,summary:"")
        XCTAssertEqual(result.state,.confirmed)
        XCTAssertEqual(result.command.intent,.review(.approve,""))
        XCTAssertEqual(try PRDetailStore(database:db).reviewedHead(key)?.head,"h2")
        XCTAssertEqual(try DraftReviewStore(database:db).operations(key).map(\.state),[.confirmed])
        let writes=await transport.count;XCTAssertEqual(writes,1)
    }
    func testUncertainOutcomeIsReturnedNotRecordedAndNotResent() async throws {
        let (db,service,transport)=try await fixture(confirms:false,loseResponse:true)
        let result=try await service.submitQuick(pr:key,revision:revision,decision:.approve,summary:"Looks good")
        XCTAssertEqual(result.state,.uncertain)
        XCTAssertNil(try PRDetailStore(database:db).reviewedHead(key))
        let writes=await transport.count;XCTAssertEqual(writes,1)
    }
    func testQuickReviewMovesOnlyAnEmptyDraftAndKeepsItsSummary() throws {
        let store=DraftReviewStore(database:try makeTemporaryDatabase().database)
        let old=PRWriteRevision(head:"h1",origin:"o",target:"t")
        try GitHubReviewService.prepareDraft(store,key:key,revision:revision)
        XCTAssertEqual(try store.load(key)?.revision,revision)
        var earlier=ReviewDraft(key:key,revision:old,summary:"keep me");let saved=try XCTUnwrap(store.load(key)?.editVersion);earlier.editVersion=saved+1
        try store.save(earlier,expectedVersion:saved)
        try GitHubReviewService.prepareDraft(store,key:key,revision:revision)
        let moved=try XCTUnwrap(store.load(key))
        XCTAssertEqual(moved.revision,revision);XCTAssertEqual(moved.summary,"keep me");XCTAssertEqual(moved.priorRevisions,[old])
        let file=DiffFile(path:"a",status:.modified,patch:"@@ -1 +1 @@\n-a\n+b"),document=DiffDocument(baseSHA:"o",headSHA:"h1",files:[file],expectedFiles:1)
        var commented=ReviewDraft(key:key,revision:old,comments:[try ReviewDraftComment(fileBody:"note",path:"a",document:document,revision:old)])
        commented.editVersion=moved.editVersion+1
        try store.save(commented,expectedVersion:moved.editVersion)
        XCTAssertThrowsError(try GitHubReviewService.prepareDraft(store,key:key,revision:revision)) { XCTAssertEqual($0 as? PRWriteFailure,.revisionChanged) }
        XCTAssertEqual(try store.load(key)?.revision,old,"A draft with comments is relocated only explicitly")
    }
}
