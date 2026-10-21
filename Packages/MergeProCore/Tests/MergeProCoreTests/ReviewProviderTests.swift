import Foundation
import XCTest
import GRDB
@testable import MergeProCore

/// A fixture implements the documented lack of head/base CAS: every POST can take effect,
/// even when a revision changes between the last client preflight and dispatch.
actor ReviewProviderFixture:GitHubTransport {
    static let head=String(repeating:"a",count:40),origin=String(repeating:"b",count:40),target=String(repeating:"c",count:40),later=String(repeating:"d",count:40)
    var head=ReviewProviderFixture.head,origin=ReviewProviderFixture.origin,target=ReviewProviderFixture.target
    var nodeID="PR1",accountID=42,actorLogin="actor"
    func identity(nodeID:String,accountID:Int) { self.nodeID=nodeID;self.accountID=accountID }
    var reviews:[[String:Any]]=[],threads:[[String:Any]]=[],comments:[[String:Any]]=[]
    var writeCount=0
    var graphDenial=false,graphPartial=false,canReply=true,canMinimize=true,canUnminimize=false
    var requests:[[String:Any]]=[]
    func permissions(reply:Bool,minimize:Bool,unminimize:Bool) { canReply=reply;canMinimize=minimize;canUnminimize=unminimize }
    func graphError(partial:Bool) { graphDenial=true;graphPartial=partial }
    func requestingTeam() { requests=[["requestedReviewer":["__typename":"Team","id":"TEAM","slug":"reviewers","name":"Reviewers display name"]]] }
    func seedPendingReview(id:String,head:String) { reviews.append(["id":id,"body":"stale pending","state":"PENDING","commit":commit(head),"createdAt":ISO8601DateFormatter().string(from:Date()),"author":["login":actorLogin]]) }
    func seedThread() { threads=[["id":"T","path":"new.swift","viewerCanReply":canReply,"comments":page([newComment(id:"C",body:"old")])]] }
    var lostResponse=false
    var holdWrites=false
    var receiptGate:CheckedContinuation<Void,Never>?
    var isHoldingReceipt:Bool { receiptGate != nil }
    func releaseReceipt() { receiptGate?.resume();receiptGate=nil;holdWrites=false }
    var raceHead=false
    var raceBase=false
    var canUpdate=true
    var ownAuthor=false
    func makeAuthor() { ownAuthor=true }
    func duplicateConversation() { if let last=comments.last { var duplicate=last;duplicate["id"]="duplicate";comments.append(duplicate) } }
    func advanceHead() { head=Self.later }
    func changeOrigin() { origin=Self.later;target=String(repeating:"e",count:40) }
    var partialReviews=false
    var viewed=false
    var title="Before",body="Description",state="OPEN",draft=false
    func configure(lost:Bool=false,headRace:Bool=false,baseRace:Bool=false,update:Bool=true,partial:Bool=false,hold:Bool=false) { holdWrites=hold;lostResponse=lost;raceHead=headRace;raceBase=baseRace;canUpdate=update;partialReviews=partial }
    private func response(_ value:Any) throws -> GitHubResponse { .init(status:200,data:try JSONSerialization.data(withJSONObject:value)) }
    private func page(_ nodes:[[String:Any]],partial:Bool=false) -> [String:Any] { ["nodes":nodes,"pageInfo":["hasNextPage":partial]] }
    private func commit(_ sha:String) -> [String:Any] { ["oid":sha] }
    private func newComment(id:String,body:String) -> [String:Any] { ["id":id,"body":body,"createdAt":ISO8601DateFormatter().string(from:Date()),"author":["login":"actor"],"viewerDidAuthor":true,"viewerCanUpdate":true,"viewerCanDelete":true,"viewerCanReact":true,"viewerCanMinimize":canMinimize,"viewerCanUnminimize":canUnminimize,"isMinimized":false,"reactionGroups":[],"url":"https://github.com/o/r/pull/1#discussion"] }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        let path=request.url!.path
        if path == "/graphql" {
            let json=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any],query=json["query"] as! String
            if query.hasPrefix("mutation ") {
                writeCount += 1
                if graphDenial { return try response(["errors":[["type":"FORBIDDEN","message":"Not allowed"]],"data":["mutation":graphPartial ? ["commentEdge":["node":["id":"maybe"]]] as Any : NSNull()]]) }
                let input=((json["variables"] as! [String:Any])["input"] as! [String:Any])
                if let id=input["pullRequestId"] as? String,id != nodeID { return try response(["data":["mutation":NSNull()],"errors":[["type":"NOT_FOUND","message":"Wrong PR node"]]]) }
                if query.contains("addComment("),input["subjectId"] as? String != nodeID { return try response(["data":["mutation":NSNull()],"errors":[["type":"NOT_FOUND","message":"Wrong subject"]]]) }
                var payload:[String:Any]=["clientMutationId":input["clientMutationId"] ?? ""]
                if query.contains("addPullRequestReview(") {
                    let event=input["event"] as? String
                    let review:[String:Any]=["id":"R\(writeCount)","body":input["body"] ?? "","state":event == nil ? "PENDING" : event == "APPROVE" ? "APPROVED" : event == "REQUEST_CHANGES" ? "CHANGES_REQUESTED" : "COMMENTED","commit":commit(input["commitOID"] as! String),"createdAt":ISO8601DateFormatter().string(from:Date()),"author":["login":"actor"]]
                    reviews.append(review);payload["pullRequestReview"]=review
                } else if query.contains("submitPullRequestReview(") {
                    if let index=reviews.firstIndex(where:{ $0["id"] as? String == input["pullRequestReviewId"] as? String }) {
                        reviews[index]["state"]=(input["event"] as? String) == "APPROVE" ? "APPROVED" : (input["event"] as? String) == "REQUEST_CHANGES" ? "CHANGES_REQUESTED" : "COMMENTED";reviews[index]["body"]=input["body"];payload["pullRequestReview"]=reviews[index]
                    }
                } else if query.contains("addPullRequestReviewThread(") {
                    var comment=newComment(id:"C\(writeCount)",body:input["body"] as! String);comment["commit"]=commit(head);comment["originalCommit"]=commit(head);comment["pullRequestReview"]=["id":input["pullRequestReviewId"]!]
                    let thread:[String:Any]=["id":"T\(writeCount)","path":input["path"]!,"subjectType":input["subjectType"]!,"isOutdated":false,"isResolved":false,"viewerCanResolve":true,"viewerCanUnresolve":false,"comments":page([comment])]
                    threads.append(thread);payload["thread"]=thread
                } else if query.contains("addComment(") {
                    let comment=newComment(id:"C\(writeCount)",body:input["body"] as! String);comments.append(comment);payload["commentEdge"]=["node":comment]
                } else if query.contains("deletePullRequestReview(") { reviews.removeAll { $0["id"] as? String == input["pullRequestReviewId"] as? String && $0["state"] as? String == "PENDING" };payload["pullRequestReview"]=["id":input["pullRequestReviewId"] ?? ""]
                } else if query.contains("markFileAsViewed(") { viewed=true;payload["pullRequest"]=["id":nodeID,"headRefOid":head] }
                if raceHead { head=Self.later };if raceBase { origin=Self.later;target=String(repeating:"e",count:40) }
                if holdWrites { await withCheckedContinuation { receiptGate=$0 } }
                if lostResponse { throw URLError(.networkConnectionLost) }
                return try response(["data":["mutation":payload]])
            }
            let vars=json["variables"] as? [String:Any] ?? [:]
            guard vars["id"] as? String == nodeID else { return try response(["data":["node":NSNull(),"viewer":["databaseId":accountID]]]) }
            if query.contains("PRWriteLight") {
                let pending=reviews.filter { $0["state"] as? String == "PENDING" && ($0["author"] as? [String:Any])?["login"] as? String == actorLogin }.map { review -> [String:Any] in var value=review;value["viewerDidAuthor"]=true;value["viewerCanDelete"]=true;return value }
                return try response(["data":["viewer":["id":"U42","databaseId":accountID,"login":actorLogin],"node":["id":nodeID,"number":1,"state":state,"headRefOid":head,"baseRefOid":target,"viewerDidAuthor":ownAuthor,"repository":["databaseId":1,"nameWithOwner":"o/r","viewerPermission":"WRITE"],"pending":page(pending)]]])
            }
            if query.contains("WriteIdentity") {
                if query.contains("isLocked") { return try response(["errors":[["message":"Field 'isLocked' doesn't exist on type 'PullRequest'"]]]) }
                let pr:[String:Any]=["id":nodeID,"number":1,"url":"https://github.com/o/r/pull/1","title":title,"body":body,"state":state,"isDraft":draft,"headRefOid":head,"baseRefOid":target,"baseRefName":"main","headRefName":"feature","locked":false,"viewerDidAuthor":ownAuthor,"viewerCanUpdate":canUpdate,"viewerCanLabel":canUpdate,"viewerCanAssign":canUpdate,"viewerCanClose":canUpdate,"viewerCanReopen":canUpdate,"changedFiles":1,"additions":2,"deletions":2,"repository":["databaseId":1,"nameWithOwner":"o/r"],"baseRef":["branchProtectionRule":["requiresCodeOwnerReviews":true,"requiredApprovingReviewCount":1]],"labels":page([]),"assignees":page([])]
                return try response(["data":["viewer":["id":"U42","databaseId":accountID,"login":"actor"],"node":pr]])
            }
            if query.contains("WriteAfter") { return try response(["data":["viewer":["databaseId":accountID],"node":["id":nodeID,"headRefOid":head,"baseRefOid":target]]]) }
            var node:[String:Any]=["id":nodeID,"headRefOid":head,"baseRefOid":target]
            if query.contains("reviewThreads(first:") { node["reviewThreads"]=page(threads) }
            else if query.contains("reviews(first:") { node["reviews"]=page(reviews,partial:partialReviews) }
            else if query.contains("comments(first:") { node["comments"]=page(comments) }
            else if query.contains("files(first:") { node["files"]=page([["path":"new.swift","viewerViewedState":viewed ? "VIEWED" : "UNVIEWED"]]) }
            else if query.contains("reviewRequests(first:") { node["reviewRequests"]=page(requests) }
            return try response(["data":["node":node]])
        }
        if request.httpMethod == "POST",path.hasSuffix("/comments") {
            writeCount += 1
            let input=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
            let reviewed=input["commit_id"] as! String
            var comment=newComment(id:"C\(writeCount)",body:input["body"] as! String);comment["commit"]=commit(reviewed);comment["originalCommit"]=commit(reviewed);comment["line"]=input["line"];comment["startLine"]=input["start_line"]
            var thread:[String:Any]=["id":"T\(writeCount)","path":input["path"]!,"subjectType":input["subject_type"] as? String == "file" ? "FILE" : "LINE","isOutdated":raceHead,"isResolved":false,"comments":page([comment])]
            thread["line"]=input["line"];thread["originalLine"]=input["line"];thread["startLine"]=input["start_line"];thread["originalStartLine"]=input["start_line"];thread["diffSide"]=input["side"];thread["startDiffSide"]=input["start_side"]
            threads.append(thread)
            if raceHead { head=Self.later };if raceBase { origin=Self.later;target=String(repeating:"e",count:40) }
            if lostResponse { throw URLError(.networkConnectionLost) }
            return try response(["id":writeCount,"node_id":"C\(writeCount)","body":input["body"]!,"commit_id":reviewed,"original_commit_id":reviewed,"path":input["path"]!,"line":input["line"] ?? NSNull(),"original_line":input["line"] ?? NSNull(),"diff_hunk":"@@ original hunk @@"])
        }
        if request.httpMethod == "PATCH" {
            writeCount += 1
            let json=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
            if let value=json["title"] as? String { title=value };if let value=json["body"] as? String { body=value };if let value=json["state"] as? String { state=value.uppercased() }
            return try response(["id":1])
        }
        if path.hasSuffix("/files") { return try response([["filename":"new.swift","previous_filename":"old.swift","status":"renamed","patch":"@@ -1,2 +1,2 @@\n-old\n-deleted\n+new\n+replacement","additions":2,"deletions":2]]) }
        if path.contains("/compare/") { return try response(["merge_base_commit":["sha":origin]]) }
        if path.contains("/rules/branches/") { return try response([]) }
        return try response(["body":body,"head":["sha":head],"base":["sha":target],"changed_files":1])
    }
}
@MainActor final class ReviewProviderTests:XCTestCase {
    let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"1",objectID:"PR1")
    private func fixture(_ provider:ReviewProviderFixture,key selected:ProviderKey?=nil) throws -> (DatabaseStore,PRWriteCoordinator) {
        let key=selected ?? self.key
        let fixture=try makeSessionFixture(account:key.account,repositories:[.fixture(key.repository)],transport:provider),db=fixture.database
        try db.savePullRequests([.init(key:key,headRevision:.init(ReviewProviderFixture.head),title:"Before",state:.open,isDraft:false)])
        let account=key.account
        return (db,.init(session:fixture.session,budget:.init(minimumSpacing:.zero),database:db,clientID:"fixture",activeAccount:{ account }))
    }
    private func command(_ intent:PRWriteIntent) -> PRWriteCommand { .init(key:key,repository:"o/r",number:1,revision:.init(head:ReviewProviderFixture.head,origin:ReviewProviderFixture.origin,target:ReviewProviderFixture.target),intent:intent) }
    func testCanonicalInventoryKeyKeepsFenceIdentityButUsesRawGraphQLNodeIdentity() async throws {
        let provider=ReviewProviderFixture();await provider.identity(nodeID:"NODE1",accountID:1)
        let account=AccountScope(host:"github.com",accountID:"1"),repo=RepositoryKey(account:account,repositoryID:"1")
        let inventory=InventoryTransport(headRevision:ReviewProviderFixture.head,baseRevision:ReviewProviderFixture.target)
        let context=PollFetchContext(cycleID:UUID(),account:account,repositories:[repo],featureID:"github-pr-inventory",cachedPullRequests:[],cachedSnapshots:[],repositoryMetadata:[repo:.init(key:repo,name:"o/r",isPrivate:false,capabilities:[])],deadline:.now.advanced(by:.seconds(10)),operation:.init(account:account,credential:.init(accessToken:"fixture",scopes:[]),generation:UUID()),client:.init(transport:inventory),budget:.init(minimumSpacing:.zero),baselinedRepositories:[],suppressNotifications:false,cachedResponses:[:])
        let fetched=try await GitHubPRInventoryFetcher().fetch(context)
        let normalized=try XCTUnwrap(fetched.pullRequests.first)
        XCTAssertEqual(normalized.key.objectID,"pull-request:NODE1")
        let (db,subject)=try fixture(provider,key:normalized.key);try db.savePullRequests([normalized])
        let command=PRWriteCommand(key:normalized.key,repository:"o/r",number:1,revision:command(.conversation("")).revision,intent:.review(.comment,"canonical"))
        let result=try await subject.perform(command)
        XCTAssertEqual(result.state,.confirmed);XCTAssertEqual(result.command.key,normalized.key)
        XCTAssertEqual(try db.observationFence(for:normalized.key),1)
        let raw=ProviderKey(host:account.host,accountID:account.accountID,repositoryID:repo.repositoryID,objectID:"NODE1")
        XCTAssertEqual(try db.observationFence(for:raw),0)
        let mismatched=ProviderKey(host:account.host,accountID:account.accountID,repositoryID:repo.repositoryID,objectID:"pull-request:OTHER")
        do { _ = try await subject.perform(.init(key:mismatched,repository:"o/r",number:1,revision:command.revision,intent:.conversation("wrong")));XCTFail("Mismatched raw node must be denied") } catch { XCTAssertEqual(error as? PRWriteFailure,.accountChanged) }
        let writes=await provider.writeCount;XCTAssertEqual(writes,1)
    }
    func testRestartRecoversTerminalThreadReceiptBeforeContinuingDraftWithoutAnotherPOST() async throws {
        let provider=ReviewProviderFixture(),(db,coordinator)=try fixture(provider)
        let inspected=try await coordinator.inspect(command(.createPending("summary")))
        let comment=try ReviewDraftComment(fileBody:"exact captured comment",path:"new.swift",document:try XCTUnwrap(inspected.document),revision:inspected.revision)
        let store=DraftReviewStore(database:db),draft=ReviewDraft(key:key,revision:inspected.revision,comments:[comment])
        try store.save(draft)
        let pending=try await coordinator.perform(command(.createPending("summary")))
        let result=try await coordinator.perform(command(.thread(comment,pendingReviewID:try XCTUnwrap(pending.providerIDs.first))))
        XCTAssertEqual(result.state,.confirmed)
        // Exact old crash boundary: terminal ledger persisted but draft adoption did not commit.
        let original=try JSONEncoder.stable.encode(draft)
        try await db.database.write { try $0.execute(sql:"UPDATE reviewDrafts SET json=?",arguments:[original]) }
        let reopened=try DatabaseStore(path:db.database.path),restarted=DraftReviewStore(database:reopened)
        // A stale pre-crash editor cannot stage the captured comment before recovery finishes.
        XCTAssertThrowsError(try restarted.prepare(PRWriteOperation(command:command(.thread(comment,pendingReviewID:pending.providerIDs.first)))))
        _ = try await coordinator.reconcile(result.id)
        XCTAssertEqual(try restarted.load(key)?.comments.first?.postedCommentID,result.providerIDs.first)
        XCTAssertEqual(try restarted.load(key)?.pendingReviewID,pending.providerIDs.first)
        let count=await provider.writeCount;XCTAssertEqual(count,2)
    }
    func testTerminalReceiptDraftAndNormalizedFenceCommitAtomically() async throws {
        let provider=ReviewProviderFixture(),(db,subject)=try fixture(provider)
        let truth=try await subject.inspect(command(.conversation(""))),comment=try ReviewDraftComment(fileBody:"captured",path:"new.swift",document:try XCTUnwrap(truth.document),revision:truth.revision)
        let store=DraftReviewStore(database:db);try store.save(.init(key:key,revision:truth.revision,comments:[comment]))
        try await db.database.write { try $0.execute(sql:"CREATE TRIGGER fail_adoption BEFORE UPDATE ON reviewDrafts WHEN CAST(NEW.json AS TEXT) LIKE '%postedCommentID%' BEGIN SELECT RAISE(ABORT,'exact terminal adoption failure'); END") }
        let sent=try await subject.perform(command(.thread(comment,pendingReviewID:nil)))
        XCTAssertEqual(sent.state,.uncertain);XCTAssertNil(try store.load(key)?.comments.first?.postedCommentID);XCTAssertEqual(try db.observationFence(for:key),0)
        try await db.database.write { try $0.execute(sql:"DROP TRIGGER fail_adoption") }
        let recovered=try await subject.reconcile(sent.id);XCTAssertEqual(recovered.state,.confirmed)
        XCTAssertNotNil(try store.load(key)?.comments.first?.postedCommentID);XCTAssertEqual(try db.observationFence(for:key),1)
        _ = try await subject.reconcile(sent.id);XCTAssertEqual(try db.observationFence(for:key),1)
        let writes=await provider.writeCount;XCTAssertEqual(writes,1)
    }
    func testDedicatedReplyAndUnminimizeCapabilitiesDisagreeWithGenericReviewAndMinimize() async throws {
        let provider=ReviewProviderFixture();await provider.permissions(reply:false,minimize:false,unminimize:true);await provider.seedThread()
        let (_,subject)=try fixture(provider)
        do { _ = try await subject.perform(command(.reply(threadID:"T",body:"reply",pendingReviewID:nil)));XCTFail("Dedicated reply false") } catch { XCTAssertEqual(error as? PRWriteFailure,.permissionDenied) }
        let truth=try await subject.inspect(command(.moderate(subjectID:"C",classifier:nil)))
        XCTAssertNoThrow(try command(.moderate(subjectID:"C",classifier:nil)).validate(truth:truth))
        let minimizing=try await subject.inspect(command(.moderate(subjectID:"C",classifier:"OFF_TOPIC")))
        XCTAssertThrowsError(try command(.moderate(subjectID:"C",classifier:"OFF_TOPIC")).validate(truth:minimizing))
        XCTAssertEqual(truth.threads.first?.canReply,false);XCTAssertEqual(truth.threads.first?.comments.first?.canUnminimize,true)
        let writes=await provider.writeCount;XCTAssertEqual(writes,0)
        let converse=ReviewProviderFixture();await converse.permissions(reply:true,minimize:true,unminimize:false);await converse.seedThread()
        let (_,other)=try fixture(converse)
        let unminimize=try await other.inspect(command(.moderate(subjectID:"C",classifier:nil)))
        XCTAssertThrowsError(try command(.moderate(subjectID:"C",classifier:nil)).validate(truth:unminimize))
    }
    func testHTTP200GraphQLNoEffectDenialIsRejectedButPartialEffectIsUncertain() async throws {
        for partial in [false,true] {
            let provider=ReviewProviderFixture();await provider.graphError(partial:partial)
            let (db,subject)=try fixture(provider)
            if partial { let result=try await subject.perform(command(.conversation("text")));XCTAssertEqual(result.state,.uncertain) }
            else { do { _ = try await subject.perform(command(.conversation("text")));XCTFail("Structured denial") } catch { } }
            let store=DraftReviewStore(database:db),result=try XCTUnwrap(store.operations(key).first)
            XCTAssertEqual(result.state,partial ? .uncertain : .rejected)
            XCTAssertNotNil(result.response);XCTAssertTrue(result.message?.contains("FORBIDDEN") == true)
            if !partial { var replacement=PRWriteOperation(command:command(.conversation("replacement")));try store.prepare(replacement);replacement.state = .rejected;try store.update(replacement) }
        }
    }
    func testUnrelatedTitleAndViewedWritesPreserveVerifiedTeamAndAlreadyReviewedNormalization() async throws {
        let provider=ReviewProviderFixture();await provider.requestingTeam()
        let (db,subject)=try fixture(provider)
        for status in [PRReviewRequest.ViewerStatus.needsReview,.alreadyReviewed] {
            var metadata=PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r")
            metadata.requests=[.init(id:"TEAM",name:"Reviewers display name",kind:.team,isForViewer:status == .needsReview,viewerStatus:status)]
            metadata.approvalCount=2;metadata.reviewEvidenceComplete=true;metadata.outstandingChanges=false;metadata.columnChangedAt=Date(timeIntervalSince1970:10);metadata.lastActivityAt=Date(timeIntervalSince1970:20)
            try db.savePullRequests([.init(key:key,headRevision:.init(ReviewProviderFixture.head),title:"Before",state:.open,isDraft:false,metadata:metadata)])
            for intent in [PRWriteIntent.metadata(.title("After")),.viewed(path:"new.swift",viewed:true)] {
                _ = try await subject.perform(command(intent))
                let pr=try XCTUnwrap(db.snapshot(for:key.account).pullRequests.first)
                XCTAssertEqual(pr.metadata?.requests,metadata.requests);XCTAssertEqual(pr.needsViewer,status == .needsReview)
                XCTAssertEqual(pr.metadata?.approvalCount,2);XCTAssertEqual(pr.metadata?.columnChangedAt,metadata.columnChangedAt);XCTAssertEqual(pr.metadata?.lastActivityAt,metadata.lastActivityAt)
            }
        }
    }
    func testExplicitTeamRequestInvalidatesOnlyAffectedAlreadyReviewedStatusUsingSlug() async throws {
        let provider=ReviewProviderFixture();await provider.requestingTeam()
        let (db,subject)=try fixture(provider)
        var metadata=PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r")
        metadata.requests=[.init(id:"TEAM",name:"Reviewers display name",kind:.team,isForViewer:false,viewerStatus:.alreadyReviewed)]
        try db.savePullRequests([.init(key:key,headRevision:.init(ReviewProviderFixture.head),title:"Before",state:.open,isDraft:false,metadata:metadata)])
        let result=try await subject.perform(command(.metadata(.reviewers(users:[],teams:["reviewers"],remove:false))))
        XCTAssertEqual(result.state,.confirmed)
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.metadata?.requests.first?.viewerStatus,.unknown)
        XCTAssertTrue(try db.snapshot(for:key.account).pullRequests.first?.needsViewer == true)
    }
    func testDocumentedPostPreflightHeadRaceIsPostedOutdatedAndNotRetryableUnsent() async throws {
        let provider=ReviewProviderFixture();await provider.configure(headRace:true)
        let (db,subject)=try fixture(provider)
        let result=try await subject.perform(command(.review(.comment,"race")))
        XCTAssertEqual(result.state,.postedOutdated);XCTAssertEqual(result.command.revision.head,ReviewProviderFixture.head)
        let writes=await provider.writeCount;XCTAssertEqual(writes,1)
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.headRevision.rawValue,ReviewProviderFixture.later)
    }
    func testBaseRaceAtSameHeadKeepsOriginalDiffOriginAndRecordsAlreadyPosted() async throws {
        let provider=ReviewProviderFixture();await provider.configure(baseRace:true)
        let (_,subject)=try fixture(provider)
        let result=try await subject.perform(command(.review(.comment,"base race")))
        XCTAssertEqual(result.state,.postedOutdated);XCTAssertEqual(result.command.revision.origin,ReviewProviderFixture.origin)
    }
    func testLostProviderReviewResponseReconcilesByFreshActorBodyCommitWithoutReposting() async throws {
        let provider=ReviewProviderFixture();await provider.configure(lost:true)
        let (_,subject)=try fixture(provider)
        let uncertain=try await subject.perform(command(.review(.comment,"exact summary")));XCTAssertEqual(uncertain.state,.uncertain)
        let confirmed=try await subject.reconcile(uncertain.id);XCTAssertEqual(confirmed.state,.confirmed);XCTAssertEqual(confirmed.providerIDs,["R1"])
        let writes=await provider.writeCount;XCTAssertEqual(writes,1)
    }
    func testPendingFileCommentIsReconciledIntoDraftAndOnePendingReviewEnforced() async throws {
        let provider=ReviewProviderFixture(),(db,subject)=try fixture(provider)
        let draft=ReviewDraft(key:key,revision:command(.createPending("")).revision,summary:"summary");try DraftReviewStore(database:db).save(draft)
        let pending=try await subject.perform(command(.createPending("summary")));XCTAssertEqual(pending.state,.confirmed)
        XCTAssertEqual(try DraftReviewStore(database:db).load(key)?.pendingReviewID,"R1")
        do { _ = try await subject.perform(command(.createPending("another")));XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.pendingExists) }
        let truth=try await subject.inspect(command(.conversation(""))),file=try ReviewDraftComment(fileBody:"file comment",path:"new.swift",document:try XCTUnwrap(truth.document),revision:truth.revision)
        var local=try XCTUnwrap(DraftReviewStore(database:db).load(key));local.comments=[file];local.editVersion += 1;try DraftReviewStore(database:db).save(local)
        let posted=try await subject.perform(command(.thread(file,pendingReviewID:"R1")));XCTAssertEqual(posted.state,.confirmed)
        XCTAssertEqual(try DraftReviewStore(database:db).load(key)?.comments.first?.postedCommentID,"C2")
    }
    func testChangedObjectPermissionRejectsMetadataAndIncompleteReviewsCannotCreatePending() async throws {
        let provider=ReviewProviderFixture();await provider.configure(update:false,partial:true)
        let (_,subject)=try fixture(provider)
        do { _ = try await subject.perform(command(.metadata(.title("After"))));XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.permissionDenied) }
        do { _ = try await subject.perform(command(.createPending("summary")));XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.permissionDenied) }
        let writes=await provider.writeCount;XCTAssertEqual(writes,0)
    }
    func testMetadataAndViewedMutationReconcileFreshProviderValues() async throws {
        let provider=ReviewProviderFixture(),(db,subject)=try fixture(provider)
        let title=try await subject.perform(command(.metadata(.title("After"))));XCTAssertEqual(title.state,.confirmed)
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.title,"After")
        let viewed=try await subject.perform(command(.viewed(path:"new.swift",viewed:true)));XCTAssertEqual(viewed.state,.confirmed)
        let truth=try await subject.inspect(command(.conversation("")));XCTAssertTrue(truth.filesComplete);XCTAssertEqual(truth.viewed,["new.swift"]);XCTAssertTrue(truth.codeOwnerRequirements?.contains("true") == true,truth.codeOwnerRequirements ?? "missing CODEOWNERS truth")
    }
}

extension ReviewProviderTests {
    func testReceiptAdoptionKeepsNewerBodyAndAddedUnsentDraftAfterActualProviderSend() async throws {
        let provider=ReviewProviderFixture(),(db,subject)=try fixture(provider)
        let store=DraftReviewStore(database:db),truth=try await subject.inspect(command(.conversation("")))
        let comment=try ReviewDraftComment(fileBody:"captured body",path:"new.swift",document:try XCTUnwrap(truth.document),revision:truth.revision)
        var original=ReviewDraft(key:key,revision:command(.createPending("")).revision,summary:"captured summary",comments:[comment]);try store.save(original)
        _ = try await subject.perform(command(.createPending(original.summary)))
        await provider.configure(hold:true)
        let task=Task { try await subject.perform(command(.thread(comment,pendingReviewID:"R1"))) }
        while !(await provider.isHoldingReceipt) { await Task.yield() }
        original=try XCTUnwrap(store.load(key));original.editVersion += 1;original.summary="new summary";original.comments[0].body="newer unsent body"
        original.comments.append(try ReviewDraftComment(fileBody:"added while sending",path:"new.swift",document:try XCTUnwrap(truth.document),revision:truth.revision));try store.save(original)
        await provider.releaseReceipt()
        let result=try await task.value;XCTAssertEqual(result.state,.confirmed)
        let restored=try XCTUnwrap(store.load(key));XCTAssertEqual(restored.summary,"new summary");XCTAssertEqual(restored.comments.count,2)
        XCTAssertEqual(restored.comments[0].body,"newer unsent body");XCTAssertEqual(restored.comments[0].postedBody,"captured body");XCTAssertEqual(restored.comments[0].postedCommentID,"C2");XCTAssertTrue(restored.comments[0].hasUnsentEdit)
        XCTAssertNil(restored.comments[1].postedCommentID)
        XCTAssertThrowsError(try store.save(ReviewDraft(key:key,revision:original.revision,summary:"obsolete autosave")))
    }
    func testReceiptPersistenceFailureAfterProviderSuccessRemainsPossiblySentAndReconcilesWithoutRepost() async throws {
        let provider=ReviewProviderFixture(),(db,subject)=try fixture(provider)
        try await db.database.write { try $0.execute(sql:"CREATE TRIGGER fail_receipt BEFORE UPDATE ON reviewOperations WHEN CAST(NEW.json AS TEXT) LIKE '%\"response\":%' BEGIN SELECT RAISE(ABORT,'fixture receipt persistence failure'); END") }
        let result=try await subject.perform(command(.conversation("exact body")))
        XCTAssertEqual(result.state,.uncertain);XCTAssertNil(result.response)
        let recorded=try XCTUnwrap(DraftReviewStore(database:db).operation(result.id));XCTAssertEqual(recorded.state,.uncertain);XCTAssertEqual(recorded.command.intent,.conversation("exact body"))
        let reconciled=try await subject.reconcile(result.id);XCTAssertEqual(reconciled.state,.confirmed)
        let writes=await provider.writeCount;XCTAssertEqual(writes,1)
    }
}

extension ReviewProviderTests {
    func testRenamedLeftMultilineUsesCurrentProviderPathAndPreservesOriginalEvidence() async throws {
        let provider=ReviewProviderFixture(),(_,subject)=try fixture(provider)
        let truth=try await subject.inspect(command(.conversation(""))),document=try XCTUnwrap(truth.document),file=try XCTUnwrap(document.files.first)
        let draft=try ReviewDraftComment(body:"LEFT multiline",anchor:document.anchor(file:file,side:.left,start:1,end:2),document:document,revision:truth.revision)
        let result=try await subject.perform(command(.thread(draft,pendingReviewID:nil)));XCTAssertEqual(result.state,.confirmed)
        XCTAssertEqual(draft.contentAnchor?.path,"old.swift");XCTAssertEqual(draft.location?.path,"new.swift")
        let response=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(result.response)) as? [String:Any])
        XCTAssertEqual(response["commit_id"] as? String,ReviewProviderFixture.head);XCTAssertEqual(response["original_commit_id"] as? String,ReviewProviderFixture.head);XCTAssertEqual(response["original_line"] as? Int,2)
        XCTAssertNil(response["merge_base_sha"])
    }
    func testPersistedViewedRiskPolicyCannotBeBypassedByCallerAndApprovalStaysSeparateFromMerge() async throws {
        let provider=ReviewProviderFixture(),(db,subject)=try fixture(provider)
        try db.setApplicationSetting("true",for:"requireAllFilesViewedBeforeApprove")
        do { _ = try await subject.perform(command(.review(.approve,"")));XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.viewedIncomplete) }
        _ = try await subject.perform(command(.viewed(path:"new.swift",viewed:true)))
        let approved=try await subject.perform(command(.review(.approve,"")));XCTAssertEqual(approved.state,.confirmed)
        XCTAssertNil(try db.snapshot(for:key.account).pullRequests.first?.metadata?.mergeEligible)
    }
    func testOwnApprovalAndPreflightRevisionMovementCauseZeroWrites() async throws {
        let own=ReviewProviderFixture();await own.makeAuthor();let (_,ownSubject)=try fixture(own)
        do { _ = try await ownSubject.perform(command(.review(.approve,"")));XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.ownApproval) }
        let moved=ReviewProviderFixture();await moved.advanceHead();let (_,movedSubject)=try fixture(moved)
        do { _ = try await movedSubject.perform(command(.review(.comment,"")));XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.revisionChanged) }
        let base=ReviewProviderFixture();await base.changeOrigin();let (_,baseSubject)=try fixture(base)
        do { _ = try await baseSubject.perform(command(.review(.comment,"")));XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.revisionChanged) }
        let writes=await own.writeCount + moved.writeCount + base.writeCount;XCTAssertEqual(writes,0)
    }
    func testAmbiguousLostCommentResponseRemainsUncertainAndDoesNotPostAgain() async throws {
        let provider=ReviewProviderFixture();await provider.configure(lost:true);let (_,subject)=try fixture(provider)
        let first=try await subject.perform(command(.conversation("same body")));XCTAssertEqual(first.state,.uncertain)
        await provider.duplicateConversation()
        let ambiguous=try await subject.reconcile(first.id);XCTAssertEqual(ambiguous.state,.uncertain)
        let writes=await provider.writeCount;XCTAssertEqual(writes,1)
    }
}

extension ReviewProviderTests {
    func testPendingReviewSubmissionBindsExistingReviewAndFreshReadConfirmsItIsSubmitted() async throws {
        let provider=ReviewProviderFixture(),(_,subject)=try fixture(provider)
        _ = try await subject.perform(command(.createPending("draft summary")))
        let submitted=try await subject.perform(command(.submitPending(id:"R1",decision:.requestChanges,summary:"final summary")))
        XCTAssertEqual(submitted.state,.confirmed);XCTAssertEqual(submitted.providerIDs,["R1"])
        let truth=try await subject.inspect(command(.conversation("")));XCTAssertNil(truth.pendingReviewID)
        let writes=await provider.writeCount;XCTAssertEqual(writes,2)
    }
}

extension ReviewProviderTests {
    func testReviewServiceFacadeCannotSilentlyDropDurableUnsentComments() async throws {
        let provider=ReviewProviderFixture(),(db,subject)=try fixture(provider)
        let truth=try await subject.inspect(command(.conversation("")));try db.savePullRequests([try XCTUnwrap(truth.normalized)])
        let file=try ReviewDraftComment(fileBody:"unsent",path:"new.swift",document:try XCTUnwrap(truth.document),revision:truth.revision)
        try DraftReviewStore(database:db).save(.init(key:key,revision:command(.review(.comment,"")).revision,summary:"summary",comments:[file]))
        let service:any ReviewService=GitHubReviewService(coordinator:subject,database:db)
        do { try await service.submit(pr:key,expectedHeadSHA:ReviewProviderFixture.head,decision:.comment,summary:"summary");XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.unsentComments) }
        let writes=await provider.writeCount;XCTAssertEqual(writes,0)
    }
}
