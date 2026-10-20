import XCTest
@testable import MergeProCore

final class ReviewServiceTests:XCTestCase {
    func testBeginningReplacementLoadRetiresPriorPrivateAccountIdentityImmediately() {
        let b=ProviderKey(host:"github.com",accountID:"B",repositoryID:"repo",objectID:"PR1")
        var load=PRActionLoadState();let prior=load.begin();load.select(b,request:prior)
        XCTAssertTrue(load.accepts(b,request:prior,available:true))
        _ = load.begin()
        XCTAssertNil(load.key,"A replacement read must retire the old private identity before its first suspension")
        XCTAssertFalse(load.accepts(b,request:prior,available:true))
    }
    func testLoadedBThenHeldReplacementAInvalidationSuccessFailureAndStaleCompletions() throws {
        let a=ProviderKey(host:"github.com",accountID:"A",repositoryID:"repo",objectID:"PR1"),b=ProviderKey(host:"github.com",accountID:"B",repositoryID:"repo",objectID:"PR1")
        func snapshot(_ key:ProviderKey) -> LocalSnapshot {
            .init(account:.init(scope:key.account,login:key.accountID,tokenReference:nil),repositories:[],trackedRepositories:[key.repository],pins:[],settings:[:],pullRequests:[.init(key:key,headRevision:.init("h"),title:key.accountID+" private",state:.open,isDraft:false)],drafts:[])
        }
        for succeeds in [true,false] {
            var workspace=PRWorkspaceSnapshot(snapshots:[snapshot(a),snapshot(b)])
            var load=PRActionLoadState();let prior=load.begin();load.select(b,request:prior)
            XCTAssertTrue(load.present(b,request:prior,available:workspace.cached(b) != nil))
            XCTAssertTrue(load.canDisplay(b,available:true))
            let replacement=load.begin();load.select(a,request:replacement)
            // All four native surfaces use this exact gate, while old B values may remain
            // in memory for local-save/conflict safety. The replacement read is held here.
            XCTAssertNil(load.presentedKey);XCTAssertFalse(load.canDisplay(b,available:true))
            var state=PRViewState(),routes:[ProviderKey]=[];workspace.invalidate(b.account,state:&state,pendingRoutes:&routes)
            XCTAssertNotNil(workspace.cached(a));XCTAssertNil(workspace.cached(b))
            XCTAssertFalse(load.canDisplay(b,available:workspace.cached(b) != nil))
            if succeeds { XCTAssertTrue(load.present(a,request:replacement,available:workspace.cached(a) != nil)) }
            else { XCTAssertTrue(load.fail(request:replacement)) }
            XCTAssertEqual(load.presentedKey,succeeds ? a : nil)
            XCTAssertFalse(load.canDisplay(b,available:true),"Reauthorization cannot restore retired B presentation")
            XCTAssertFalse(load.present(b,request:prior,available:true))
            XCTAssertFalse(load.fail(request:prior),"Old failure cannot clear or relabel A's presentation")
            XCTAssertEqual(load.presentedKey,succeeds ? a : nil)
            XCTAssertEqual(load.canDisplay(a,available:true),succeeds)
        }
    }
    func testRetiredRenderedRequestCannotAdmitOperationStatusRefresh() {
        let a=ProviderKey(host:"github.com",accountID:"A",repositoryID:"repo",objectID:"PR1"),b=ProviderKey(host:"github.com",accountID:"B",repositoryID:"repo",objectID:"PR1")
        var load=PRActionLoadState();let prior=load.begin();load.select(b,request:prior)
        XCTAssertNil(load.presentationRequest(for:b,available:true))
        XCTAssertTrue(load.present(b,request:prior,available:true))
        let statusRequest=load.presentationRequest(for:b,available:true)
        XCTAssertEqual(statusRequest,prior)
        XCTAssertNil(load.presentationRequest(for:b,available:false))
        let replacement=load.begin();load.select(a,request:replacement)
        XCTAssertTrue(load.present(a,request:replacement,available:true))
        XCTAssertFalse(load.accepts(b,request:statusRequest!,available:true),"An old status callback remains retired after B reauthorization")
        XCTAssertNil(load.presentationRequest(for:b,available:true))
        XCTAssertEqual(load.presentationRequest(for:a,available:true),replacement)
    }
    func testReadAActionBAvailabilityInvalidationRejectsLateLoadAndViewedCommandUsesB() throws {
        let a=ProviderKey(host:"github.com",accountID:"A",repositoryID:"repo",objectID:"PR1"),b=ProviderKey(host:"github.com",accountID:"B",repositoryID:"repo",objectID:"PR1")
        func pr(_ key:ProviderKey) -> PullRequest { .init(key:key,headRevision:.init("h"),title:"private",state:.open,isDraft:false,metadata:.init(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r")) }
        let rows=[pr(a),pr(b)]
        var workspace=PRWorkspaceSnapshot(snapshots:rows.map { .init(account:.init(scope:$0.key.account,login:$0.key.accountID,tokenReference:nil),repositories:[],trackedRepositories:[$0.key.repository],pins:[],settings:[:],pullRequests:[$0],drafts:[]) })
        var load=PRActionLoadState();let token=load.begin();load.select(b,request:token)
        XCTAssertTrue(load.accepts(b,request:token,available:workspace.cached(b) != nil))
        var state=PRViewState(),routes:[ProviderKey]=[];workspace.invalidate(b.account,state:&state,pendingRoutes:&routes);load.invalidate()
        XCTAssertNotNil(workspace.cached(a));XCTAssertNil(workspace.cached(b))
        XCTAssertFalse(load.accepts(b,request:token,available:false))
        XCTAssertFalse(load.accepts(b,request:token,available:true),"A late result stays invalid after B reauthorization")
        let revision=PRWriteRevision(head:"h",origin:"o",target:"t")
        let command=try PRWriteCommand.viewed(readPR:rows[0],actionPR:rows[1],revision:revision,path:"file",viewed:true)
        XCTAssertEqual(command.key,b);XCTAssertEqual(command.revision,revision);XCTAssertNotEqual(command.key,a)
        var truth=PRWriteTruth.fixture(key:b,revision:revision);truth.files=["file"];truth.filesComplete=true
        XCTAssertNoThrow(try command.validate(truth:truth));truth.revision = .init(head:"new",origin:"o",target:"t")
        XCTAssertThrowsError(try command.validate(truth:truth))
        let otherAccount=PRWriteTruth.fixture(key:a,revision:revision)
        XCTAssertThrowsError(try command.validate(truth:otherAccount),"A's viewed evidence never transfers to B")
    }
    func testEachCommentRetainsFullSelectedRevisionIncludingFileAndPartialRelocation() throws {
        let file=DiffFile(path:"a",status:.modified,patch:"@@ -1 +1 @@\n-old\n+new")
        let old=DiffDocument(baseSHA:"o",headSHA:"h",files:[file],expectedFiles:1)
        let next=DiffDocument(baseSHA:"next-origin",headSHA:"h",files:[file],expectedFiles:1)
        let right=try ReviewDraftComment(body:"old right",anchor:old.anchor(file:file,side:.right,start:1,end:1),document:old,revision:.init(head:old.headSHA,origin:old.baseSHA,target:old.baseSHA))
        let oldFile=try ReviewDraftComment(fileBody:"old file",path:"a",document:old,revision:.init(head:old.headSHA,origin:old.baseSHA,target:old.baseSHA))
        let current=try ReviewDraftComment(fileBody:"current selection",path:"a",document:next,revision:.init(head:next.headSHA,origin:next.baseSHA,target:next.baseSHA))
        let revision=PRWriteRevision(head:"h",origin:"next-origin",target:"next-origin")
        var truth=PRWriteTruth.fixture(key:key,revision:revision);truth.files=["a"];truth.document=next
        for comment in [right,oldFile] {
            XCTAssertThrowsError(try PRWriteCommand(key:key,repository:"o/r",number:1,revision:revision,intent:.thread(comment,pendingReviewID:nil)).validate(truth:truth))
        }
        let relocated=oldFile.relocated(to:current)
        XCTAssertNoThrow(try PRWriteCommand(key:key,repository:"o/r",number:1,revision:revision,intent:.thread(relocated,pendingReviewID:nil)).validate(truth:truth))
        XCTAssertThrowsError(try PRWriteCommand(key:key,repository:"o/r",number:1,revision:revision,intent:.thread(right,pendingReviewID:nil)).validate(truth:truth),"Relocating FILE must not adopt another RIGHT comment")
        truth.revision = .init(head:"new-head",origin:"o",target:"o")
        XCTAssertThrowsError(try PRWriteCommand(key:key,repository:"o/r",number:1,revision:truth.revision,intent:.thread(oldFile,pendingReviewID:nil)).validate(truth:truth))
    }
    let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"repo",objectID:"PR1")
    func testPreflightRejectsChangedHeadOriginTargetPermissionAndOwnApproval() throws {
        let revision=PRWriteRevision(head:"h",origin:"o",target:"t")
        let command=PRWriteCommand(key:key,repository:"o/r",number:1,revision:revision,intent:.review(.approve,"summary"))
        var truth=PRWriteTruth.fixture(key:key,revision:revision)
        XCTAssertNoThrow(try command.validate(truth:truth))
        truth.revision = .init(head:"new",origin:"o",target:"t");XCTAssertThrowsError(try command.validate(truth:truth))
        truth.revision = .init(head:"h",origin:"new",target:"t");XCTAssertThrowsError(try command.validate(truth:truth))
        truth.revision = .init(head:"h",origin:"o",target:"new");XCTAssertThrowsError(try command.validate(truth:truth))
        truth.revision=revision;truth.viewerIsAuthor=true;XCTAssertThrowsError(try command.validate(truth:truth))
        truth.viewerIsAuthor=false;truth.canReview=false;XCTAssertThrowsError(try command.validate(truth:truth))
    }
    func testLateRaceAfterProviderWriteIsPostedOutdatedNeverUnsent() throws {
        let command=PRWriteCommand(key:key,repository:"o/r",number:1,revision:.init(head:"h",origin:"o",target:"t"),intent:.review(.comment,"summary"))
        var truth=PRWriteTruth.fixture(key:key,revision:.init(head:"new",origin:"other",target:"t"))
        truth.matchingOperationIDs=["R1"]
        XCTAssertEqual(command.reconciliation(truth:truth),.postedOutdated)
        truth.matchingOperationIDs=["R1","R2"];XCTAssertEqual(command.reconciliation(truth:truth),.uncertain)
    }
    func testSentOperationCannotBeBlindlyRetriedAfterCrashOrLostResponse() throws {
        let store=DraftReviewStore(database:try DatabaseStore(path:":memory:"))
        let command=PRWriteCommand(key:key,repository:"o/r",number:1,revision:.init(head:"h",origin:"o",target:"t"),intent:.conversation("one comment"))
        var operation=PRWriteOperation(command:command);try store.prepare(operation)
        operation.state = .sending;try store.update(operation)
        XCTAssertThrowsError(try store.prepare(PRWriteOperation(command:command)))
        XCTAssertEqual(try store.operation(operation.id)?.command,command)
        XCTAssertEqual(try store.operation(operation.id)?.state,.sending)
    }
    func testHeldOldObservationCannotUndoConfirmedWriteButFreshReadApplies() throws {
        let db=try DatabaseStore(path:":memory:")
        try db.saveAccount(.init(scope:key.account,login:"fixture",tokenReference:nil))
        try db.saveRepository(.init(key:key.repository,name:"o/r",isPrivate:true,capabilities:[]))
        let before=PullRequest(key:key,headRevision:.init("h"),title:"before",state:.open,isDraft:false)
        try db.savePullRequests([before]);let fence=try db.observationFence(for:key)
        let confirmed=PullRequest(key:key,headRevision:.init("h"),title:"confirmed",state:.closed,isDraft:false)
        try db.confirmWrite(confirmed)
        XCTAssertFalse(try db.saveObservedPullRequests([before],fences:[key:fence]))
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.title,"confirmed")
        let fresh=try db.observationFence(for:key)
        XCTAssertTrue(try db.saveObservedPullRequests([before],fences:[key:fresh]))
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.title,"before")
    }
    func testApprovalViewedGateRequiresCompleteAccountSpecificProviderEvidence() throws {
        let command=PRWriteCommand(key:key,repository:"o/r",number:1,revision:.init(head:"h",origin:"o",target:"t"),intent:.review(.approve,""),requireAllViewed:true)
        var truth=PRWriteTruth.fixture(key:key,revision:command.revision)
        truth.files=["a"];truth.viewed=["a"];truth.filesComplete=false
        XCTAssertThrowsError(try command.validate(truth:truth))
        truth.filesComplete=true;XCTAssertNoThrow(try command.validate(truth:truth))
        truth.viewed=[];XCTAssertThrowsError(try command.validate(truth:truth))
    }
}

private extension PRWriteTruth {
    static func fixture(key:ProviderKey,revision:PRWriteRevision) -> Self { .init(key:key,revision:revision,viewerIsAuthor:false,canReview:true,canComment:true,canUpdate:true,canReopen:true,canLabel:true,isOpen:true) }
}
