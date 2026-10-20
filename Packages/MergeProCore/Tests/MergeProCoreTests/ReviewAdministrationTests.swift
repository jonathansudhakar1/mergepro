import XCTest
import GRDB
@testable import MergeProCore

private func graphRequest(_ request:GitHubPRWriteAdapter.Request) throws -> (query:String,input:[String:Any]) {
    let body=try XCTUnwrap(JSONSerialization.jsonObject(with:request.body) as? [String:Any])
    return (try XCTUnwrap(body["query"] as? String),try XCTUnwrap((body["variables"] as? [String:Any])?["input"] as? [String:Any]))
}
@MainActor final class ReviewAdministrationTests:XCTestCase {
    let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"1",objectID:"PR1")
    let alice=PRUserRef(id:"U1",login:"alice"),bob=PRUserRef(id:"U2",login:"bob"),core=PRTeamRef(id:"T1",slug:"core"),infra=PRTeamRef(id:"T2",slug:"infra")
    private func light(_ pr:PullRequest,_ intent:PRWriteIntent) throws -> PRWriteCommand { try .revisionIndependent(actionPR:pr,intent:intent) }
    private func requests(addUsers:[PRUserRef]=[],addTeams:[PRTeamRef]=[],removeUsers:[PRUserRef]=[],removeTeams:[PRTeamRef]=[]) -> PRWriteIntent { .metadata(.reviewRequestChanges(addUsers:addUsers,addTeams:addTeams,removeUsers:removeUsers,removeTeams:removeTeams)) }
    private func review(_ id:String,_ state:String,_ author:String,_ authorID:String?,own:Bool=false) -> LightWriteProvider.Review { .init(id:id,state:state,author:author,authorID:authorID,commit:"older-head",viewerDidAuthor:own) }

    func testReviewRequestAddUsesRequestReviewsUnionTrueAndRemovalUsesRESTDelete() throws {
        let pr=lightCachedPR(key:key)
        let op=PRWriteOperation(command:try light(pr,requests(addUsers:[alice],addTeams:[infra],removeUsers:[bob],removeTeams:[core])))
        let sent=try GitHubPRWriteAdapter.requests(op);XCTAssertEqual(sent.count,2)
        let (query,input)=try graphRequest(sent[0])
        XCTAssertEqual(sent[0].path,"graphql");XCTAssertTrue(query.contains("requestReviews(input:$input)"),query)
        XCTAssertEqual(input["union"] as? Bool,true);XCTAssertEqual(input["userIds"] as? [String],["U1"]);XCTAssertEqual(input["teamIds"] as? [String],["T2"])
        XCTAssertEqual(input["pullRequestId"] as? String,"PR1");XCTAssertEqual(input["clientMutationId"] as? String,op.id.uuidString)
        XCTAssertEqual(sent[1].path,"repos/o/r/pulls/1/requested_reviewers");XCTAssertEqual(sent[1].method,"DELETE")
        let rest=try XCTUnwrap(JSONSerialization.jsonObject(with:sent[1].body) as? [String:Any])
        XCTAssertEqual(rest["reviewers"] as? [String],["bob"]);XCTAssertEqual(rest["team_reviewers"] as? [String],["core"])
        // Re-requesting someone who already reviewed is exactly a union:true add of their user node ID.
        let again=try GitHubPRWriteAdapter.requests(.init(command:try light(pr,requests(addUsers:[bob]))));XCTAssertEqual(again.count,1)
        let (_,rerequest)=try graphRequest(again[0]);XCTAssertEqual(rerequest["union"] as? Bool,true);XCTAssertEqual(rerequest["userIds"] as? [String],["U2"])
        let removal=try GitHubPRWriteAdapter.requests(.init(command:try light(pr,requests(removeTeams:[core]))));XCTAssertEqual(removal.map(\.method),["DELETE"])
    }
    func testReRequestFromReviewerWhoAlreadyReviewedConfirmsByRequestedNodeIDAndKeepsMergeEvidence() async throws {
        let provider=LightWriteProvider()
        await provider.configure { $0.reviews=[.init(id:"R1",state:"APPROVED",author:"bob",authorID:"U2",commit:"older-head",viewerDidAuthor:false)] }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let result=try await subject.perform(try light(cached,requests(addUsers:[bob])));XCTAssertEqual(result.state,.confirmed)
        let m=try XCTUnwrap(db.snapshot(for:key.account).pullRequests.first?.metadata)
        XCTAssertEqual(Set(m.requests.map(\.id)),["T1","U2"]);XCTAssertEqual(m.requests.first { $0.id == "T1" }?.viewerStatus,.alreadyReviewed,"Verified team status survives by stable ID")
        XCTAssertTrue(m.reviewers.contains("bob"));XCTAssertEqual(m.mergeEvidence,cached.metadata?.mergeEvidence);XCTAssertEqual(m.labels,["bug"]);XCTAssertEqual(m.approvalCount,2)
        let writes=await provider.writes,queries=await provider.queries;XCTAssertEqual(writes,1);XCTAssertEqual(queries.count,2)
        XCTAssertTrue(queries.allSatisfy { $0.contains("reviewRequests(first:100)") && !$0.contains("reviewThreads") },queries.joined())
    }
    func testMixedRequestChangeSendsGraphQLAddThenRESTRemovalUnderOneOperationEvenWithSavedDraft() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.requestIDs=["T1","U2"] }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        try DraftReviewStore(database:db).save(.init(key:key,revision:.init(head:"stale-head",origin:"stale-base",target:"stale-base"),summary:"keep me"))
        let result=try await subject.perform(try light(cached,requests(addUsers:[alice],removeUsers:[bob],removeTeams:[core])));XCTAssertEqual(result.state,.confirmed)
        let writes=await provider.writes,rest=await provider.rest;XCTAssertEqual(writes,2);XCTAssertEqual(rest.count,1)
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.metadata?.requests.map(\.id),["U1"])
        XCTAssertEqual(try DraftReviewStore(database:db).load(key)?.summary,"keep me")
    }
    /// Part 1 (GraphQL add) has a definite success receipt; part 2 (REST removal) is definitely refused.
    func testRESTRemovalRefusalAfterProviderAddIsATerminalPartialOutcome() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.requestIDs=["U2"];$0.failRESTRemoval=true }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        do { _ = try await subject.perform(try light(cached,requests(addUsers:[alice],removeUsers:[bob])));XCTFail() } catch {
            XCTAssertEqual((error as? PRWriteRejection)?.kind,.partial)
            XCTAssertEqual(error.localizedDescription,"Requested review from ‘alice’; removing the review request for ‘bob’ was refused by GitHub.")
        }
        XCTAssertEqual(try DraftReviewStore(database:db).operations(key).first?.state,.rejected)
        let writes=await provider.writes;XCTAssertEqual(writes,2)
    }
    func testRESTRemovalValidationRefusalIsADefiniteRejection() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.requestIDs=["U2"];$0.failRESTRemoval=true;$0.restRemovalStatus=422 }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        do { _ = try await subject.perform(try light(cached,requests(removeUsers:[bob])));XCTFail() } catch { XCTAssertEqual((error as? GitHubGraphQLMutationFailure)?.definitelyRejected,true,"\(error)") }
        XCTAssertEqual(try DraftReviewStore(database:db).operations(key).first?.state,.rejected)
        let writes=await provider.writes;XCTAssertEqual(writes,1)
    }
    func testReceiptConfirmedDismissalInvalidatesEvidenceEvenWhenTheRefreshReadFails() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.reviews=[.init(id:"R1",state:"APPROVED",author:"bob",authorID:"U2",commit:"h",viewerDidAuthor:false)];$0.failReadsAfterWrite=true }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let result=try await subject.perform(try light(cached,.dismissReview(reviewID:"R1",message:"stale")));XCTAssertEqual(result.state,.confirmed);XCTAssertEqual(result.providerIDs,["R1"])
        let m=try XCTUnwrap(db.snapshot(for:key.account).pullRequests.first?.metadata)
        XCTAssertNil(m.mergeEvidence);XCTAssertNil(m.approvalCount);XCTAssertFalse(m.reviewEvidenceComplete);XCTAssertEqual(m.reviewDecision,"APPROVED","Unread decision is left to the next poll")
    }
    func testSecondPartRefusedAtAdmissionAfterAnAccountSwitchIsATerminalPartialOutcome() async throws {
        let provider=LightWriteProvider(),cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        await provider.configure { $0.requestIDs=["U2"];$0.afterMutation={ try db.setApplicationSetting("other",for:"activeActionAccount") } }
        do { _ = try await subject.perform(try light(cached,requests(addUsers:[alice],removeUsers:[bob])));XCTFail() } catch {
            XCTAssertEqual((error as? PRWriteRejection)?.kind,.partial)
            XCTAssertEqual(error.localizedDescription,"Requested review from ‘alice’; removing the review request for ‘bob’ was not sent.")
        }
        XCTAssertEqual(try DraftReviewStore(database:db).operations(key).first?.state,.rejected)
        let writes=await provider.writes,rest=await provider.rest;XCTAssertEqual(writes,1);XCTAssertTrue(rest.isEmpty)
    }
    func testReconcileInTheGapBetweenPartsLeavesAnAccurateTerminalPartialOutcome() async throws {
        let provider=LightWriteProvider(),cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let pr=key
        // A user-clicked read moves the in-flight `.sending` row to `.uncertain` between the two parts.
        await provider.configure { $0.requestIDs=["U2"];$0.afterMutation={
            let store=DraftReviewStore(database:db);guard var operation=try store.operations(pr).first,operation.state == .sending else { return }
            operation.state = .uncertain;try store.update(operation,expectedState:.sending)
        } }
        do { _ = try await subject.perform(try light(cached,requests(addUsers:[alice],removeUsers:[bob])));XCTFail() } catch {
            XCTAssertEqual(error.localizedDescription,"Requested review from ‘alice’; removing the review request for ‘bob’ was not sent.")
        }
        XCTAssertEqual(try DraftReviewStore(database:db).operations(key).first?.state,.rejected,"Released rather than wedged")
        let rest=await provider.rest;XCTAssertTrue(rest.isEmpty)
    }
    func testGitHubReplacingATeamRequestWithMembersConfirmsFromTheReceiptOrSettlesAfterALostReceipt() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.replaceTeamsWithMembers=true }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let confirmed=try await subject.perform(try light(cached,requests(addTeams:[infra])));XCTAssertEqual(confirmed.state,.confirmed)
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.metadata?.requests.map(\.id),["T1"],"The disagreeing read leaves the row to the next poll")
        let lost=LightWriteProvider();await lost.configure { $0.replaceTeamsWithMembers=true;$0.loseResponse=true }
        let (_,other)=try lightWriteFixture(lost,key:key,cached:cached)
        let pending=try await other.perform(try light(cached,requests(addTeams:[infra])));XCTAssertEqual(pending.state,.uncertain)
        let settled=try await other.reconcile(pending.id);XCTAssertEqual(settled.state,.rejected)
        XCTAssertTrue(settled.message?.contains("GitHub doesn't show this change") == true,settled.message ?? "")
    }
    func testLostDiscardDismissAndSubscriptionReceiptsSettleOnTheCheckedState() async throws {
        let rows=[review("R1","APPROVED","bob","U2"),review("R3","PENDING","actor","U42",own:true)]
        for intent in [PRWriteIntent.discardPendingReview(reviewID:"R3"),.dismissReview(reviewID:"R1",message:"stale"),.subscription(state:.ignored)] {
            let provider=LightWriteProvider();await provider.configure { $0.reviews=rows;$0.loseResponse=true;$0.dropWrite=true }
            let cached=lightCachedPR(key:key);let (_,subject)=try lightWriteFixture(provider,key:key,cached:cached)
            let pending=try await subject.perform(try light(cached,intent));XCTAssertEqual(pending.state,.uncertain,"\(intent)")
            let settled=try await subject.reconcile(pending.id);XCTAssertEqual(settled.state,.rejected,"\(intent): still pending / not dismissed / other subscription")
            let writes=await provider.writes;XCTAssertEqual(writes,1)
        }
    }
    func testReviewRequestChangesRequireTriageOrWritePermission() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.permission="READ" }
        let cached=lightCachedPR(key:key);let (_,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        do { _ = try await subject.perform(try light(cached,requests(addUsers:[alice])));XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.permissionDenied) }
        let writes=await provider.writes;XCTAssertEqual(writes,0)
        let triage=LightWriteProvider();await triage.configure { $0.permission="TRIAGE" }
        let (_,triaged)=try lightWriteFixture(triage,key:key,cached:cached)
        let result=try await triaged.perform(try light(cached,requests(addUsers:[alice])));XCTAssertEqual(result.state,.confirmed)
    }
    func testDiscardingStalePendingReviewOnOlderHeadUnblocksNewReviewOnCurrentHead() async throws {
        let provider=ReviewProviderFixture();await provider.seedPendingReview(id:"STALE",head:ReviewProviderFixture.later)
        var metadata=PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r");metadata.baseRevision=ReviewProviderFixture.target
        let cached=PullRequest(key:key,headRevision:.init(ReviewProviderFixture.head),title:"Before",state:.open,isDraft:false,metadata:metadata)
        let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let review=PRWriteCommand(key:key,repository:"o/r",number:1,revision:.init(head:ReviewProviderFixture.head,origin:ReviewProviderFixture.origin,target:ReviewProviderFixture.target),intent:.review(.comment,"fresh review"))
        do { _ = try await subject.perform(review);XCTFail("Stale pending review blocks") } catch { XCTAssertEqual(error as? PRWriteFailure,.pendingExists) }
        let discard=try await subject.perform(try light(cached,.discardPendingReview(reviewID:"STALE")));XCTAssertEqual(discard.state,.confirmed);XCTAssertEqual(discard.providerIDs,["STALE"])
        XCTAssertEqual(try db.observationFence(for:key),0,"Discarding a private pending review changes no cached PR row")
        let truth=try await subject.inspect(review);XCTAssertNil(truth.pendingReviewID);XCTAssertNoThrow(try review.validate(truth:truth))
        let posted=try await subject.perform(review);XCTAssertEqual(posted.state,.confirmed)
        let writes=await provider.writeCount;XCTAssertEqual(writes,2)
    }
    func testDiscardRequiresTheViewersOwnPendingReview() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.reviews=[.init(id:"R1",state:"APPROVED",author:"actor",authorID:"U42",commit:"h",viewerDidAuthor:true),.init(id:"R2",state:"PENDING",author:"bob",authorID:"U2",commit:"h",viewerDidAuthor:false)] }
        let cached=lightCachedPR(key:key);let (_,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        for id in ["R1","R2","missing"] {
            do { _ = try await subject.perform(try light(cached,.discardPendingReview(reviewID:id)));XCTFail(id) } catch { XCTAssertEqual(error as? PRWriteFailure,.permissionDenied) }
        }
        let writes=await provider.writes;XCTAssertEqual(writes,0)
    }
    func testDismissRequiresANonEmptyMessageBeforeAnyRead() async throws {
        let provider=LightWriteProvider(),cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        XCTAssertThrowsError(try PRWriteIntent.dismissReview(reviewID:"R1",message:"").validateShape()) { XCTAssertEqual($0 as? PRWriteFailure,.messageRequired) }
        do { _ = try await subject.perform(try light(cached,.dismissReview(reviewID:"R1",message:" \n ")));XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.messageRequired) }
        let writes=await provider.writes,queries=await provider.queries;XCTAssertEqual(writes,0);XCTAssertEqual(queries.count,0)
        XCTAssertTrue(try DraftReviewStore(database:db).operations(key).isEmpty)
    }
    func testDismissConfirmsDismissedStateAndInvalidatesReviewAndMergeEvidenceOnly() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.reviews=[.init(id:"R1",state:"APPROVED",author:"bob",authorID:"U2",commit:"older-head",viewerDidAuthor:false)] }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let result=try await subject.perform(try light(cached,.dismissReview(reviewID:"R1",message:"Approval predates the force-push")));XCTAssertEqual(result.state,.confirmed);XCTAssertEqual(result.providerIDs,["R1"])
        let sent=await provider.mutations;let body=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(sent.first)) as? [String:Any])
        let input=try XCTUnwrap((body["variables"] as? [String:Any])?["input"] as? [String:Any])
        XCTAssertTrue((body["query"] as? String)?.contains("dismissPullRequestReview(input:$input)") == true);XCTAssertEqual(input["pullRequestReviewId"] as? String,"R1");XCTAssertEqual(input["message"] as? String,"Approval predates the force-push")
        let m=try XCTUnwrap(db.snapshot(for:key.account).pullRequests.first?.metadata)
        XCTAssertNil(m.mergeEvidence);XCTAssertNil(m.mergeEligible);XCTAssertNil(m.approvalCount);XCTAssertFalse(m.reviewEvidenceComplete);XCTAssertEqual(m.reviewDecision,"REVIEW_REQUIRED")
        XCTAssertEqual(m.labels,["bug"]);XCTAssertEqual(m.descriptionPreview,cached.metadata?.descriptionPreview)
        let queries=await provider.queries;XCTAssertTrue(queries.allSatisfy { $0.contains("review: node(id:$review)") },queries.joined())
    }
    func testDismissDeniedForCommentedReviewOrInsufficientRepositoryPermission() async throws {
        let commented=LightWriteProvider();await commented.configure { $0.reviews=[.init(id:"R1",state:"COMMENTED",author:"bob",authorID:"U2",commit:"h",viewerDidAuthor:false)] }
        let reader=LightWriteProvider();await reader.configure { $0.permission="READ";$0.reviews=[.init(id:"R1",state:"APPROVED",author:"bob",authorID:"U2",commit:"h",viewerDidAuthor:false)] }
        let cached=lightCachedPR(key:key)
        for provider in [commented,reader] {
            let (_,subject)=try lightWriteFixture(provider,key:key,cached:cached)
            do { _ = try await subject.perform(try light(cached,.dismissReview(reviewID:"R1",message:"no")));XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.permissionDenied) }
            let writes=await provider.writes;XCTAssertEqual(writes,0)
        }
    }
    func testLostDismissResponseReconcilesByReadWithoutSecondPOST() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.loseResponse=true;$0.reviews=[.init(id:"R1",state:"CHANGES_REQUESTED",author:"bob",authorID:"U2",commit:"h",viewerDidAuthor:false)] }
        let cached=lightCachedPR(key:key);let (_,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let first=try await subject.perform(try light(cached,.dismissReview(reviewID:"R1",message:"stale")));XCTAssertEqual(first.state,.uncertain)
        let confirmed=try await subject.reconcile(first.id);XCTAssertEqual(confirmed.state,.confirmed)
        let writes=await provider.writes;XCTAssertEqual(writes,1)
    }
    func testSubscriptionStatesAreSentAndConfirmedFromViewerSubscription() async throws {
        let provider=LightWriteProvider(),cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        for (index,state) in [PRSubscriptionState.subscribed,.ignored,.unsubscribed].enumerated() {
            let result=try await subject.perform(try light(cached,.subscription(state:state)));XCTAssertEqual(result.state,.confirmed)
            let sent=await provider.mutations;let body=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(sent.last)) as? [String:Any]),input=try XCTUnwrap((body["variables"] as? [String:Any])?["input"] as? [String:Any])
            XCTAssertTrue((body["query"] as? String)?.contains("updateSubscription(input:$input)") == true);XCTAssertEqual(input["state"] as? String,state.rawValue);XCTAssertEqual(input["subscribableId"] as? String,"PR1")
            let current=await provider.subscription;XCTAssertEqual(current,state.rawValue);let writes=await provider.writes;XCTAssertEqual(writes,index+1)
        }
        XCTAssertEqual(try db.observationFence(for:key),0)
        let denied=LightWriteProvider();await denied.configure { $0.canSubscribe=false }
        let (_,deniedSubject)=try lightWriteFixture(denied,key:key,cached:cached)
        do { _ = try await deniedSubject.perform(try light(cached,.subscription(state:.subscribed)));XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.permissionDenied) }
    }
    func testReviewAdministrationReadExposesRowsWithDismissDiscardAndReRequestEvidence() async throws {
        let rows=[review("R1","APPROVED","bob","U2"),review("R2","COMMENTED","carol","U3"),review("R3","PENDING","actor","U42",own:true)]
        let provider=LightWriteProvider();await provider.configure { $0.reviews=rows }
        let cached=lightCachedPR(key:key);let (_,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let admin=try await subject.reviewAdministration(for:cached)
        XCTAssertEqual(admin.key,key);XCTAssertEqual(admin.viewerLogin,"actor");XCTAssertEqual(admin.reviews.map(\.id),["R1","R2","R3"]);XCTAssertTrue(admin.reviewsComplete)
        let approved=try XCTUnwrap(admin.reviews.first)
        XCTAssertEqual(approved.authorLogin,"bob");XCTAssertEqual(approved.authorID,"U2");XCTAssertEqual(approved.state,.approved);XCTAssertEqual(approved.commitOID,"older-head");XCTAssertNotNil(approved.submittedAt)
        XCTAssertEqual(approved.viewerCanDismiss,true);XCTAssertEqual(admin.reviews[1].viewerCanDismiss,false);XCTAssertFalse(approved.viewerCanDiscard)
        XCTAssertEqual(admin.pendingReview?.id,"R3");XCTAssertEqual(admin.reviews[2].viewerCanDiscard,true);XCTAssertEqual(admin.reviews[2].viewerCanDismiss,false)
        XCTAssertEqual(admin.requestedTeams,[core]);XCTAssertTrue(admin.requestsComplete);XCTAssertTrue(admin.canRequestReviews);XCTAssertEqual(admin.viewerSubscription,.unsubscribed);XCTAssertTrue(admin.canSubscribe);XCTAssertEqual(admin.reviewDecision,"APPROVED")
        let queries=await provider.queries;XCTAssertEqual(queries.count,1)
        for (permission,restricted,expected) in [("WRITE",true,nil),("ADMIN",true,true),("READ",false,false),("MAINTAIN",nil,nil)] as [(String,Bool?,Bool?)] {
            let other=LightWriteProvider();await other.configure { $0.reviews=rows;$0.permission=permission;$0.restrictsDismissals=restricted }
            let (_,reader)=try lightWriteFixture(other,key:key,cached:cached)
            let value=try await reader.reviewAdministration(for:cached);XCTAssertEqual(value.reviews.first?.viewerCanDismiss,expected,"\(permission) \(String(describing:restricted))")
        }
    }
}
