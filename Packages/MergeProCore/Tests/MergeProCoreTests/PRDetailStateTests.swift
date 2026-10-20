import XCTest
@testable import MergeProCore

final class PRDetailStateTests:XCTestCase {
    private let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"1",objectID:"PR1")
    private func file(_ path:String,_ patch:String?) -> DiffFile { DiffFile(path:path,status:.modified,patch:patch) }
    private func document(_ head:String,_ files:[DiffFile],expected:Int?=nil,comparison:DiffDocument.Comparison = .pullRequest) -> DiffDocument {
        DiffDocument(baseSHA:"base",headSHA:head,files:files,expectedFiles:expected ?? files.count,comparison:comparison)
    }
    private func database() throws -> DatabaseStore {
        let directory=try makeTemporaryDirectory()
        return try DatabaseStore(path:directory.appendingPathComponent("db").path)
    }
    private let a1=DiffFile(path:"a.swift",status:.modified,patch:"@@ -1 +1 @@\n-a\n+b")
    private let b1=DiffFile(path:"b.swift",status:.modified,patch:"@@ -1 +1 @@\n-c\n+d")
    private let b2=DiffFile(path:"b.swift",status:.modified,patch:"@@ -1 +1 @@\n-c\n+e")

    // MARK: Viewed marks keyed by path and content

    func testNewPushKeepsViewedMarksOnlyForFilesWhoseContentDidNotChange() {
        let first=document("h1",[a1,b1])
        var state=PRDetailState(headSHA:"h1")
        XCTAssertTrue(state.markViewed("a.swift",viewed:true,displayed:first,canonical:first))
        XCTAssertTrue(state.markViewed("b.swift",viewed:true,displayed:first,canonical:first))
        state.acceptRevision("h2")
        XCTAssertTrue(state.viewed.isEmpty,"Carried marks wait for a content comparison against the new head")
        XCTAssertTrue(state.reconcile(document("h2",[a1,b2])))
        XCTAssertEqual(state.viewed,["a.swift"])
        XCTAssertFalse(state.reconcile(document("h2",[a1,b2])),"A second pass changes nothing")
    }
    func testMarksSurviveStorageRoundTripAcrossAPush() throws {
        let store=PRDetailStore(database:try database()),first=document("h1",[a1,b1])
        var state=PRDetailState(headSHA:"h1")
        state.markViewed("a.swift",viewed:true,displayed:first,canonical:first);state.markViewed("b.swift",viewed:true,displayed:first,canonical:first)
        try store.save(state,key:key)
        var next=try store.load(key,headSHA:"h2")
        XCTAssertTrue(next.viewed.isEmpty)
        next.reconcile(document("h2",[a1,b2]))
        try store.save(next,key:key)
        XCTAssertEqual(try store.load(key,headSHA:"h2").viewed,["a.swift"])
    }
    func testUnknownContentIsNeverCarriedToANewHead() {
        let missing=file("big.bin",nil),first=document("h1",[missing,a1])
        var state=PRDetailState(headSHA:"h1")
        state.markViewed("big.bin",viewed:true,displayed:first,canonical:first)
        state.markViewed("old.swift",viewed:true)
        state.acceptRevision("h2")
        state.reconcile(document("h2",[missing,a1,file("old.swift","@@ -1 +1 @@\n-x\n+y")]))
        XCTAssertTrue(state.viewed.isEmpty,"Content that was never known can't prove the file is unchanged")
    }
    func testUnloadedFilesKeepWaitingUntilTheirPageLoads() {
        let first=document("h1",[a1,b1])
        var state=PRDetailState(headSHA:"h1")
        state.markViewed("a.swift",viewed:true,displayed:first,canonical:first);state.markViewed("b.swift",viewed:true,displayed:first,canonical:first)
        state.acceptRevision("h2")
        state.reconcile(document("h2",[a1],expected:2))
        XCTAssertEqual(state.viewed,["a.swift"])
        state.reconcile(document("h2",[a1,b1]))
        XCTAssertEqual(state.viewed,["a.swift","b.swift"])
    }
    func testCompleteInventoryDropsMarksForFilesNoLongerChanged() {
        let first=document("h1",[a1,b1])
        var state=PRDetailState(headSHA:"h1")
        state.markViewed("b.swift",viewed:true,displayed:first,canonical:first)
        state.acceptRevision("h2")
        state.reconcile(document("h2",[a1]))
        state.acceptRevision("h3")
        state.reconcile(document("h3",[a1,b1]))
        XCTAssertTrue(state.viewed.isEmpty,"A file that left the pull request and came back is new content to review")
    }
    func testComparisonsAndOtherHeadsNeverReconcile() {
        let first=document("h1",[a1])
        var state=PRDetailState(headSHA:"h1")
        state.markViewed("a.swift",viewed:true,displayed:first,canonical:first)
        state.acceptRevision("h2")
        XCTAssertFalse(state.reconcile(document("h2",[a1],comparison:.snapshot)))
        XCTAssertFalse(state.reconcile(document("h1",[a1])))
        XCTAssertTrue(state.viewed.isEmpty)
        XCTAssertTrue(state.reconcile(document("h2",[a1])))
        XCTAssertEqual(state.viewed,["a.swift"])
    }
    func testUnmarkingRemovesTheCarriedContent() {
        let first=document("h1",[a1])
        var state=PRDetailState(headSHA:"h1")
        state.markViewed("a.swift",viewed:true,displayed:first,canonical:first)
        state.markViewed("a.swift",viewed:false,displayed:first,canonical:first)
        state.acceptRevision("h2");state.reconcile(document("h2",[a1]))
        XCTAssertTrue(state.viewed.isEmpty)
    }
    func testLegacyPayloadDecodesAndGainsContentOnTheSameHead() throws {
        let legacy=Data(#"{"headSHA":"h1","viewed":["a.swift"],"lastReviewedSHA":"r"}"#.utf8)
        var state=try JSONDecoder().decode(PRDetailState.self,from:legacy)
        XCTAssertEqual(state.viewed,["a.swift"]);XCTAssertEqual(state.lastReviewedSHA,"r")
        XCTAssertTrue(state.reconcile(document("h1",[a1])),"Same-head legacy marks record their content once")
        state.acceptRevision("h2");state.reconcile(document("h2",[a1]))
        XCTAssertEqual(state.viewed,["a.swift"])
    }
    func testContentIdentityCoversPatchStatusAndRename() {
        XCTAssertEqual(a1.viewedContentIdentity,file("a.swift","@@ -1 +1 @@\n-a\n+b").viewedContentIdentity)
        XCTAssertNotEqual(b1.viewedContentIdentity,b2.viewedContentIdentity)
        XCTAssertNotEqual(a1.viewedContentIdentity,DiffFile(path:"a.swift",previousPath:"z.swift",status:.renamed,patch:a1.patch).viewedContentIdentity)
        XCTAssertNil(file("a.swift",nil).viewedContentIdentity)
        XCTAssertNil(file("a.swift","not a patch").viewedContentIdentity,"A truncated or unparsable patch is unknown content")
    }

    // MARK: Reviewed head

    func testRecordedReviewHeadIsPerAccountAndSurvivesProgressSaves() throws {
        let db=try database(),store=PRDetailStore(database:db)
        let other=ProviderKey(host:"github.com",accountID:"7",repositoryID:"1",objectID:"PR1")
        let stale=try store.load(key,headSHA:"h1")
        let at=Date(timeIntervalSince1970:1_000)
        try store.recordReview(key,headSHA:"h1",at:at)
        // A window that loaded progress before the review saves it afterwards.
        try store.save(stale,key:key)
        XCTAssertEqual(try store.reviewedHead(key),PRReviewedHead(head:"h1",at:at))
        XCTAssertNil(try store.reviewedHead(other))
        try store.purge(account:key.account)
        XCTAssertNil(try store.reviewedHead(key))
    }
    func testPurgeKeepsOtherAccountsReviewedHeads() throws {
        let store=PRDetailStore(database:try database())
        let other=ProviderKey(host:"github.com",accountID:"7",repositoryID:"1",objectID:"PR1")
        try store.recordReview(other,headSHA:"h9")
        try store.purge(account:key.account)
        XCTAssertEqual(try store.reviewedHead(other)?.head,"h9")
    }

    // MARK: Changes since your review

    private func review(_ commit:String?,_ minutes:Double,state:PRReviewState = .approved,mine:Bool=true) -> PRReviewSummary {
        .init(id:UUID().uuidString,authorLogin:"me",authorID:"U1",state:state,submittedAt:Date(timeIntervalSince1970:minutes*60),commitOID:commit,viewerDidAuthor:mine,viewerCanDismiss:nil,viewerCanDiscard:false)
    }
    func testNoKnownReviewOffersNothing() {
        XCTAssertNil(PRReReviewState.resolve(currentHead:"h2",local:nil,ledger:[],providerReviews:nil,viewerRequested:true))
        XCTAssertNil(PRReReviewState.resolve(currentHead:"h2",local:nil,ledger:[],providerReviews:[review("x",1,mine:false),review("y",2,state:.pending)],viewerRequested:true),
                     "Other reviewers' reviews and your pending review are not your submitted review")
    }
    func testLatestReviewWinsAndKeepsItsSource() throws {
        let local=PRReviewedHead(head:"h1",at:Date(timeIntervalSince1970:60))
        let provider=try XCTUnwrap(PRReReviewState.resolve(currentHead:"h3",local:local,ledger:[],providerReviews:[review("h0",0),review("h2",5)],viewerRequested:nil))
        XCTAssertEqual(provider.reviewedHead,"h2");XCTAssertEqual(provider.source,.provider)
        let newerLocal=try XCTUnwrap(PRReReviewState.resolve(currentHead:"h3",local:.init(head:"h1",at:Date(timeIntervalSince1970:600)),ledger:[],providerReviews:[review("h2",5)],viewerRequested:nil))
        XCTAssertEqual(newerLocal.reviewedHead,"h1");XCTAssertEqual(newerLocal.source,.local)
        XCTAssertTrue(newerLocal.hasNewCommits);XCTAssertFalse(newerLocal.opensOnInterdiff,"Unknown request state never opens the comparison by itself")
    }
    func testConfirmedLedgerReviewCountsButOtherWritesDoNot() throws {
        let revision=PRWriteRevision(head:"h1",origin:"o",target:"t")
        var approve=PRWriteOperation(command:PRWriteCommand(key:key,repository:"o/r",number:1,revision:revision,intent:.review(.approve,"")));approve.state = .confirmed
        var uncertain=PRWriteOperation(command:PRWriteCommand(key:key,repository:"o/r",number:1,revision:.init(head:"h2",origin:"o",target:"t"),intent:.review(.comment,"x")));uncertain.state = .uncertain
        var comment=PRWriteOperation(command:PRWriteCommand(key:key,repository:"o/r",number:1,revision:.init(head:"h2",origin:"o",target:"t"),intent:.conversation("x")));comment.state = .confirmed
        let value=try XCTUnwrap(PRReReviewState.resolve(currentHead:"h2",local:nil,ledger:[approve,uncertain,comment],providerReviews:nil,viewerRequested:false))
        XCTAssertEqual(value.reviewedHead,"h1");XCTAssertEqual(value.source,.local)
    }
    func testReRequestedReviewWithNewCommitsOpensOnTheInterdiff() throws {
        let local=PRReviewedHead(head:"h1",at:Date())
        XCTAssertTrue(try XCTUnwrap(PRReReviewState.resolve(currentHead:"h2",local:local,ledger:[],providerReviews:nil,viewerRequested:true)).opensOnInterdiff)
        let current=try XCTUnwrap(PRReReviewState.resolve(currentHead:"h1",local:local,ledger:[],providerReviews:nil,viewerRequested:true))
        XCTAssertFalse(current.hasNewCommits);XCTAssertFalse(current.opensOnInterdiff)
    }
    func testViewerRequestNeedsACompleteListToProveAbsence() {
        func admin(_ users:[PRUserRef],complete:Bool) -> PRReviewAdministration {
            .init(key:key,viewerLogin:"Me",reviews:[],reviewsComplete:true,requestedUsers:users,requestedTeams:[],requestsComplete:complete,canRequestReviews:true,viewerSubscription:nil,canSubscribe:false,reviewDecision:nil)
        }
        XCTAssertEqual(PRReReviewState.viewerRequested(admin([.init(id:"U1",login:"me")],complete:false)),true)
        XCTAssertEqual(PRReReviewState.viewerRequested(admin([],complete:true)),false)
        XCTAssertNil(PRReReviewState.viewerRequested(admin([],complete:false)))
        XCTAssertNil(PRReReviewState.viewerRequested(nil))
    }
}
