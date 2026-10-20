import XCTest
import GRDB
@testable import MergeProCore

/// Light-intent provider: answers only `PRWriteLight*` single queries, the light GraphQL
/// mutations and REST requested_reviewers DELETE. Any heavy full-reader read is an error.
actor LightWriteProvider:GitHubTransport {
    struct Review:Sendable { var id:String;var state:String;var author:String;var authorID:String?;var commit:String;var viewerDidAuthor:Bool }
    static let catalog:[[String:String]]=[["id":"L1","name":"bug","color":"d73a4a"],["id":"L2","name":"feature","color":"a2eeef"],["id":"L3","name":"docs","color":"0075ca"]]
    static let users:[String:String]=["U1":"alice","U2":"bob","U3":"carol"],teams:[String:String]=["T1":"core","T2":"infra"]
    var state="OPEN",head=String(repeating:"a",count:40),target=String(repeating:"c",count:40)
    var labelIDs=["L1"],assigneeIDs=["U1"],requestIDs=["T1"],subscription="UNSUBSCRIBED",reviewDecision="APPROVED"
    var reviews:[Review]=[]
    var canLabel=true,canAssign=true,canSubscribe=true,permission="WRITE",restrictsDismissals:Bool?=false,labelsPartial=false,assigneesPartial=false,requestsPartial=false
    var loseResponse=false,failRemoveAlias=false,failRESTRemoval=false,restRemovalStatus=403
    /// Receipts still report success, but GitHub state does not change (a read then disagrees).
    var dropWrite=false
    /// The mutation payload is null with no `errors`: not a definite success receipt.
    var nullPayload=false
    /// Light reads after the first write fail.
    var failReadsAfterWrite=false
    /// GitHub replaces a requested team with its members.
    var replaceTeamsWithMembers=false
    /// Runs after a GraphQL mutation is applied, before its receipt returns (e.g. an account switch between parts).
    var afterMutation:(@Sendable () throws -> Void)?
    private(set) var writes=0,unexpected=0
    private(set) var queries:[String]=[],mutations:[Data]=[],rest:[String]=[]
    func configure(_ change:@Sendable (isolated LightWriteProvider) -> Void) { change(self) }
    private func respond(_ value:Any,status:Int=200) throws -> GitHubResponse { .init(status:status,data:try JSONSerialization.data(withJSONObject:value)) }
    private func page(_ nodes:[[String:Any]],partial:Bool=false) -> [String:Any] { ["nodes":nodes,"pageInfo":["hasNextPage":partial,"hasPreviousPage":false]] }
    private func reviewNode(_ r:Review) -> [String:Any] { ["id":r.id,"state":r.state,"submittedAt":r.state == "PENDING" ? NSNull() as Any : "2026-10-01T10:00:00Z","viewerDidAuthor":r.viewerDidAuthor,"viewerCanDelete":r.viewerDidAuthor,"author":["login":r.author,"id":r.authorID.map { $0 as Any } ?? NSNull()],"commit":["oid":r.commit],"pullRequest":["id":"PR1"]] }
    private func reviewer(_ id:String) -> [String:Any] { Self.teams[id].map { ["__typename":"Team","id":id,"slug":$0,"name":$0.capitalized] } ?? ["__typename":"User","id":id,"login":Self.users[id] ?? id] }
    private func light(_ vars:[String:Any]) -> [String:Any] {
        let labels=labelIDs.compactMap { id in Self.catalog.first { $0["id"] == id } }
        let visible=reviews.filter { $0.state != "PENDING" || $0.viewerDidAuthor }
        var latest:[Review]=[];for review in visible.reversed() where review.state != "PENDING" && !latest.contains(where:{ $0.author == review.author }) { latest.insert(review,at:0) }
        let node:[String:Any]=["id":"PR1","number":1,"state":state,"headRefOid":head,"baseRefOid":target,"viewerDidAuthor":false,"viewerCanUpdate":true,"viewerCanLabel":canLabel,"viewerCanAssign":canAssign,"viewerCanSubscribe":canSubscribe,"viewerSubscription":subscription,"reviewDecision":reviewDecision,
            "repository":["databaseId":1,"nameWithOwner":"o/r","viewerPermission":permission,"labels":page(Self.catalog),"assignableUsers":page(Self.users.sorted { $0.key < $1.key }.map { ["id":$0.key,"login":$0.value] })],
            "baseRef":["branchProtectionRule":restrictsDismissals.map { ["restrictsReviewDismissals":$0] as Any } ?? NSNull()],
            "labels":page(labels,partial:labelsPartial),"assignees":page(assigneeIDs.map { ["id":$0,"login":Self.users[$0] ?? $0] },partial:assigneesPartial),"reviewRequests":page(requestIDs.map { ["requestedReviewer":reviewer($0)] },partial:requestsPartial),
            "pending":page(reviews.filter { $0.state == "PENDING" && $0.viewerDidAuthor }.map(reviewNode)),"latest":page(latest.map(reviewNode)),"reviews":page(visible.map(reviewNode))]
        var data:[String:Any]=["viewer":["id":"U42","databaseId":42,"login":"actor"],"node":node,"rateLimit":["cost":1,"remaining":4999,"resetAt":"2026-10-07T00:00:00Z"]]
        if let id=vars["review"] as? String { data["review"]=reviews.first { $0.id == id }.map { reviewNode($0) as Any } ?? NSNull() }
        return data
    }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        let path=request.url?.path ?? ""
        if path == "/graphql" {
            let body=try JSONSerialization.jsonObject(with:request.httpBody ?? Data()) as? [String:Any] ?? [:],query=body["query"] as? String ?? "",vars=body["variables"] as? [String:Any] ?? [:]
            if query.hasPrefix("mutation ") { return try mutate(query,vars,raw:request.httpBody ?? Data()) }
            queries.append(query)
            guard query.contains("PRWriteLight") else { unexpected += 1;return try respond(["errors":[["message":"Unexpected heavy read"]]]) }
            if failReadsAfterWrite,writes > 0 { return try respond(["errors":[["message":"Something went wrong"]]]) }
            return try respond(["data":light(vars)])
        }
        if request.httpMethod == "DELETE",path == "/repos/o/r/pulls/1/requested_reviewers" {
            writes += 1
            let body=try JSONSerialization.jsonObject(with:request.httpBody ?? Data()) as? [String:Any] ?? [:]
            rest.append("DELETE "+path+" "+String(decoding:request.httpBody ?? Data(),as:UTF8.self))
            if failRESTRemoval { return try respond(["message":restRemovalStatus == 422 ? "Validation Failed" : "Forbidden"],status:restRemovalStatus) }
            let logins=body["reviewers"] as? [String] ?? [],slugs=body["team_reviewers"] as? [String] ?? []
            requestIDs.removeAll { logins.contains(Self.users[$0] ?? "") || slugs.contains(Self.teams[$0] ?? "") }
            return try respond(["id":1,"node_id":"PR1"])
        }
        unexpected += 1;return try respond(["message":"Not Found"],status:404)
    }
    private func mutate(_ query:String,_ vars:[String:Any],raw:Data) throws -> GitHubResponse {
        writes += 1;mutations.append(raw)
        func input(_ name:String) -> [String:Any] { vars[name] as? [String:Any] ?? [:] }
        func receipt(_ name:String) -> [String:Any] { ["clientMutationId":input(name)["clientMutationId"] ?? NSNull()] }
        var data:[String:Any]=[:],errors:[[String:Any]]=[]
        let before=(labelIDs,assigneeIDs,requestIDs,subscription,reviews,reviewDecision)
        defer { if dropWrite { (labelIDs,assigneeIDs,requestIDs,subscription,reviews,reviewDecision)=before } }
        if query.contains("addLabelsToLabelable(") { labelIDs += (input("add")["labelIds"] as? [String] ?? []).filter { !labelIDs.contains($0) };data["add"]=receipt("add") }
        if query.contains("removeLabelsFromLabelable(") {
            if failRemoveAlias { data["remove"]=NSNull();errors.append(["type":"FORBIDDEN","path":["remove"],"message":"Cannot remove label"]) }
            else { let ids=input("remove")["labelIds"] as? [String] ?? [];labelIDs.removeAll { ids.contains($0) };data["remove"]=receipt("remove") }
        }
        if query.contains("addAssigneesToAssignable(") { assigneeIDs += (input("add")["assigneeIds"] as? [String] ?? []).filter { !assigneeIDs.contains($0) };data["add"]=receipt("add") }
        if query.contains("removeAssigneesFromAssignable(") { let ids=input("remove")["assigneeIds"] as? [String] ?? [];assigneeIDs.removeAll { ids.contains($0) };data["remove"]=receipt("remove") }
        if query.contains("requestReviews(") {
            let i=input("input");guard i["union"] as? Bool == true else { return try respond(["data":["requestReviews":NSNull()],"errors":[["type":"UNPROCESSABLE","message":"Replace-all is not allowed in this fixture"]]]) }
            let teams=replaceTeamsWithMembers ? (i["teamIds"] as? [String] ?? []).map { _ in "U3" } : (i["teamIds"] as? [String] ?? [])
            requestIDs += ((i["userIds"] as? [String] ?? [])+teams).filter { !requestIDs.contains($0) };data["requestReviews"]=receipt("input")
        }
        if query.contains("deletePullRequestReview(") { let id=input("input")["pullRequestReviewId"] as? String;reviews.removeAll { $0.id == id && $0.state == "PENDING" };data["deletePullRequestReview"]=receipt("input") }
        if query.contains("dismissPullRequestReview(") { let id=input("input")["pullRequestReviewId"] as? String;if let index=reviews.firstIndex(where:{ $0.id == id }) { reviews[index].state="DISMISSED";reviewDecision="REVIEW_REQUIRED" };data["dismissPullRequestReview"]=receipt("input") }
        if query.contains("updateSubscription(") { subscription=input("input")["state"] as? String ?? subscription;data["updateSubscription"]=receipt("input") }
        try afterMutation?()
        if loseResponse { throw URLError(.networkConnectionLost) }
        if nullPayload { for key in data.keys { data[key]=NSNull() } }
        var envelope:[String:Any]=["data":data];if !errors.isEmpty { envelope["errors"]=errors }
        return try respond(envelope)
    }
}
extension XCTestCase {
    /// Same account/session wiring as ReviewProviderTests, for any light-intent transport.
    @MainActor func lightWriteFixture(_ transport:any GitHubTransport,key:ProviderKey,cached:PullRequest?) throws -> (DatabaseStore,PRWriteCoordinator) {
        let fixture=try makeSessionFixture(account:key.account,repositories:[.fixture(key.repository)],transport:transport),db=fixture.database
        if let cached { try db.savePullRequests([cached]) }
        let account=key.account
        return (db,.init(session:fixture.session,budget:.init(minimumSpacing:.zero),database:db,clientID:"fixture",activeAccount:{ account }))
    }
    /// A cached action-account row with stale head/base and merge evidence that labels must not touch.
    func lightCachedPR(key:ProviderKey,head:String="stale-head") -> PullRequest {
        var m=PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r")
        m.baseRevision="stale-base";m.labels=["bug"];m.labelColors=["bug":"d73a4a"];m.assignees=["alice"];m.reviewers=["alice"];m.reviewDecision="APPROVED"
        m.descriptionPreview="Keep this summary";m.approvalCount=2;m.reviewEvidenceComplete=true;m.outstandingChanges=false;m.mergeEligible=true;m.checks="SUCCESS"
        m.mergeEvidence=MergeEvidence(key:key,head:head,base:"stale-base",branch:"main",fetchedAt:Date(timeIntervalSince1970:100))
        m.requests=[.init(id:"T1",name:"core",kind:.team,isForViewer:true,viewerStatus:.alreadyReviewed)]
        return PullRequest(key:key,headRevision:.init(head),title:"Cached title",state:.open,isDraft:false,metadata:m)
    }
}
private func graphBody(_ data:Data) throws -> (query:String,variables:[String:Any]) {
    let body=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);return (try XCTUnwrap(body["query"] as? String),body["variables"] as? [String:Any] ?? [:])
}

@MainActor final class LabelWriteTests:XCTestCase {
    let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"1",objectID:"PR1")
    let bug=PRLabelRef(id:"L1",name:"bug"),feature=PRLabelRef(id:"L2",name:"feature"),docs=PRLabelRef(id:"L3",name:"docs")
    let alice=PRUserRef(id:"U1",login:"alice"),bob=PRUserRef(id:"U2",login:"bob")
    private func labels(_ pr:PullRequest,add:[PRLabelRef],remove:[PRLabelRef]) throws -> PRWriteCommand { try .labelChanges(actionPR:pr,add:add,remove:remove) }

    func testLabelDeltaIsOneAliasedGraphQLDocumentWithNodeIDsAndOmitsAnEmptyAlias() throws {
        let pr=lightCachedPR(key:key),both=PRWriteOperation(command:try labels(pr,add:[feature],remove:[bug]))
        let requests=try GitHubPRWriteAdapter.requests(both);XCTAssertEqual(requests.count,1)
        let request=try GitHubPRWriteAdapter.request(both);XCTAssertEqual(request.path,"graphql");XCTAssertEqual(request.method,"POST")
        let (query,vars)=try graphBody(request.body)
        XCTAssertTrue(query.hasPrefix("mutation "));XCTAssertTrue(query.contains("add: addLabelsToLabelable(input:$add)"),query);XCTAssertTrue(query.contains("remove: removeLabelsFromLabelable(input:$remove)"),query)
        let add=try XCTUnwrap(vars["add"] as? [String:Any]),remove=try XCTUnwrap(vars["remove"] as? [String:Any])
        XCTAssertEqual(add["labelableId"] as? String,"PR1");XCTAssertEqual(add["labelIds"] as? [String],["L2"]);XCTAssertEqual(remove["labelableId"] as? String,"PR1");XCTAssertEqual(remove["labelIds"] as? [String],["L1"])
        XCTAssertEqual(add["clientMutationId"] as? String,both.id.uuidString);XCTAssertEqual(remove["clientMutationId"] as? String,both.id.uuidString)
        let (addOnly,addVars)=try graphBody(GitHubPRWriteAdapter.request(.init(command:try labels(pr,add:[feature],remove:[]))).body)
        XCTAssertFalse(addOnly.contains("remove"),addOnly);XCTAssertNil(addVars["remove"]);XCTAssertNotNil(addVars["add"])
        let (removeOnly,removeVars)=try graphBody(GitHubPRWriteAdapter.request(.init(command:try labels(pr,add:[],remove:[bug]))).body)
        XCTAssertFalse(removeOnly.contains("addLabelsToLabelable"),removeOnly);XCTAssertNil(removeVars["add"])
        // The canonical inventory key keeps its identity; GraphQL receives the raw node ID.
        let canonical=PullRequest(key:.init(host:"github.com",accountID:"42",repositoryID:"1",objectID:"pull-request:NODE"),headRevision:pr.headRevision,title:pr.title,state:.open,isDraft:false,metadata:pr.metadata)
        let (_,canonicalVars)=try graphBody(GitHubPRWriteAdapter.request(.init(command:try labels(canonical,add:[feature],remove:[]))).body)
        XCTAssertEqual((canonicalVars["add"] as? [String:Any])?["labelableId"] as? String,"NODE")
    }
    func testAssigneeDeltaUsesAssignableMutationsWithUserNodeIDs() throws {
        let op=PRWriteOperation(command:try .revisionIndependent(actionPR:lightCachedPR(key:key),intent:.metadata(.assigneeChanges(add:[bob],remove:[alice]))))
        let (query,vars)=try graphBody(GitHubPRWriteAdapter.request(op).body)
        XCTAssertTrue(query.contains("add: addAssigneesToAssignable(input:$add)"),query);XCTAssertTrue(query.contains("remove: removeAssigneesFromAssignable(input:$remove)"),query)
        XCTAssertEqual((vars["add"] as? [String:Any])?["assigneeIds"] as? [String],["U2"]);XCTAssertEqual((vars["remove"] as? [String:Any])?["assigneeIds"] as? [String],["U1"]);XCTAssertEqual((vars["add"] as? [String:Any])?["assignableId"] as? String,"PR1")
    }
    func testLabelChangesIgnoreRevisionMovementAndUseOneLightQueryPerReadWithoutDetailFetch() async throws {
        let provider=LightWriteProvider(),cached=lightCachedPR(key:key,head:"stale-head")
        let (_,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let command=try labels(cached,add:[feature],remove:[bug])
        XCTAssertTrue(command.intent.isRevisionIndependent);XCTAssertFalse(PRWriteIntent.metadata(.labels(["bug"])).isRevisionIndependent);XCTAssertFalse(PRWriteIntent.review(.comment,"").isRevisionIndependent)
        XCTAssertEqual(command.revision.head,"stale-head")
        var moved=PRWriteTruth(key:key,revision:.init(head:"moved",origin:"",target:"moved-base"),viewerIsAuthor:false,canReview:false,canComment:false,canUpdate:false,canReopen:false,canLabel:true,isOpen:true)
        XCTAssertThrowsError(try command.validate(truth:moved)) { XCTAssertEqual($0 as? PRWriteFailure,.listIncomplete,"Unknown completeness cannot admit a delta") }
        moved.labelsComplete=true
        XCTAssertNoThrow(try command.validate(truth:moved))
        let replaceAll=PRWriteCommand(key:key,repository:"o/r",number:1,revision:command.revision,intent:.metadata(.labels(["bug"])))
        XCTAssertThrowsError(try replaceAll.validate(truth:moved)) { XCTAssertEqual($0 as? PRWriteFailure,.revisionChanged) }
        let result=try await subject.perform(command);XCTAssertEqual(result.state,.confirmed);XCTAssertEqual(result.providerIDs,["PR1"])
        let queries=await provider.queries,writes=await provider.writes,unexpected=await provider.unexpected
        XCTAssertEqual(queries.count,2,"One preflight and one post-receipt refresh read");XCTAssertEqual(writes,1);XCTAssertEqual(unexpected,0)
        for query in queries { XCTAssertTrue(query.contains("labels(first:100)") && query.contains("viewerCanLabel") && !query.contains("reviewThreads") && !query.contains("files(") && !query.contains("comments("),query) }
    }
    func testLabelChangesRequireViewerCanLabelButNotAnOpenPullRequest() async throws {
        let denied=LightWriteProvider();await denied.configure { $0.canLabel=false }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(denied,key:key,cached:cached)
        do { _ = try await subject.perform(try labels(cached,add:[feature],remove:[]));XCTFail("Denied without viewerCanLabel") } catch { XCTAssertEqual(error as? PRWriteFailure,.permissionDenied) }
        let deniedWrites=await denied.writes;XCTAssertEqual(deniedWrites,0)
        XCTAssertEqual(try DraftReviewStore(database:db).operations(key).first?.state,.rejected)
        let closed=LightWriteProvider();await closed.configure { $0.state="CLOSED" }
        let (_,other)=try lightWriteFixture(closed,key:key,cached:cached)
        let result=try await other.perform(try labels(cached,add:[feature],remove:[]));XCTAssertEqual(result.state,.confirmed)
    }
    func testEmptyOrContradictoryDeltaIsRejectedBeforeAnyProviderRequestOrReservation() async throws {
        let provider=LightWriteProvider(),cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let commands=[try labels(cached,add:[],remove:[]),try labels(cached,add:[bug],remove:[bug]),try PRWriteCommand.revisionIndependent(actionPR:cached,intent:.metadata(.assigneeChanges(add:[alice],remove:[alice])))]
        for command in commands {
            XCTAssertThrowsError(try command.intent.validateShape()) { XCTAssertEqual($0 as? PRWriteFailure,.invalidChange) }
            do { _ = try await subject.perform(command);XCTFail("Invalid delta") } catch { XCTAssertEqual(error as? PRWriteFailure,.invalidChange) }
        }
        let queries=await provider.queries,writes=await provider.writes;XCTAssertEqual(queries.count,0);XCTAssertEqual(writes,0)
        XCTAssertTrue(try DraftReviewStore(database:db).operations(key).isEmpty)
        XCTAssertThrowsError(try PRWriteCommand.revisionIndependent(actionPR:cached,intent:.metadata(.labels(["bug"]))))
    }
    func testLostLabelResponseIsUncertainAndReadOnlyReconcileConfirmsWithoutSecondPOST() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.loseResponse=true }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let first=try await subject.perform(try labels(cached,add:[feature],remove:[bug]));XCTAssertEqual(first.state,.uncertain)
        let reconciled=try await subject.reconcile(first.id);XCTAssertEqual(reconciled.state,.confirmed);XCTAssertEqual(reconciled.providerIDs,["PR1"])
        let writes=await provider.writes,queries=await provider.queries;XCTAssertEqual(writes,1);XCTAssertEqual(queries.count,2)
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.metadata?.labels,["feature"])
    }
    /// Add applied, remove FORBIDDEN in the same aliased document: a definite split is terminal, not uncertain.
    func testPartialGraphQLLabelRefusalIsTerminalAndNamesWhatAppliedAndWhatDidNot() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.failRemoveAlias=true }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        do { _ = try await subject.perform(try labels(cached,add:[feature],remove:[bug]));XCTFail("A partial outcome is reported") } catch {
            XCTAssertEqual(error.localizedDescription,"Added ‘feature’; removing ‘bug’ was refused by GitHub (FORBIDDEN: Cannot remove label).")
            XCTAssertEqual((error as? PRWriteRejection)?.kind,.partial)
        }
        let saved=try XCTUnwrap(DraftReviewStore(database:db).operations(key).first)
        XCTAssertEqual(saved.state,.rejected);XCTAssertEqual(saved.message,"Added ‘feature’; removing ‘bug’ was refused by GitHub (FORBIDDEN: Cannot remove label).");XCTAssertNotNil(saved.response)
        let writes=await provider.writes;XCTAssertEqual(writes,1)
        // The pull request is released: a later write is admitted.
        await provider.configure { $0.failRemoveAlias=false }
        let next=try await subject.perform(try labels(cached,add:[docs],remove:[]));XCTAssertEqual(next.state,.confirmed)
    }
    func testDefiniteReceiptConfirmsEvenWhenTheRefreshReadDisagreesOrFails() async throws {
        for failing in [false,true] {
            let provider=LightWriteProvider();await provider.configure { $0.dropWrite = !failing;$0.failReadsAfterWrite=failing }
            let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
            let result=try await subject.perform(try labels(cached,add:[feature],remove:[bug]))
            XCTAssertEqual(result.state,.confirmed,"Receipt-based confirmation (read \(failing ? "failed" : "disagreed"))");XCTAssertEqual(result.providerIDs,["PR1"])
            XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.metadata?.labels,["bug"],"The next poll refreshes the row")
            XCTAssertEqual(try db.observationFence(for:key),0)
            let queries=await provider.queries,writes=await provider.writes;XCTAssertEqual(queries.count,2);XCTAssertEqual(writes,1)
        }
    }
    func testNullPayloadIsNotADefiniteReceiptAndAFreshCompleteReadDecides() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.nullPayload=true }
        let cached=lightCachedPR(key:key);let (_,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let applied=try await subject.perform(try labels(cached,add:[feature],remove:[]));XCTAssertEqual(applied.state,.confirmed,"Matched by the decisive read")
        await provider.configure { $0.dropWrite=true }
        do { _ = try await subject.perform(try labels(cached,add:[docs],remove:[]));XCTFail("Not shown by GitHub") } catch {
            XCTAssertEqual((error as? PRWriteRejection)?.kind,.notShown);XCTAssertTrue(error.localizedDescription.contains("GitHub doesn't show this change"),error.localizedDescription)
        }
        let writes=await provider.writes;XCTAssertEqual(writes,2)
    }
    func testLostReceiptReconcileIsDecisiveOnACompleteRead() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.loseResponse=true;$0.dropWrite=true }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let first=try await subject.perform(try labels(cached,add:[feature],remove:[bug]));XCTAssertEqual(first.state,.uncertain)
        XCTAssertTrue(first.canStopWaiting)
        let reconciled=try await subject.reconcile(first.id)
        XCTAssertEqual(reconciled.state,.rejected);XCTAssertTrue(reconciled.message?.contains("GitHub doesn't show this change") == true,reconciled.message ?? "")
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.metadata?.labels,["bug"])
        let writes=await provider.writes;XCTAssertEqual(writes,1,"Never resent")
        await provider.configure { $0.loseResponse=false;$0.dropWrite=false }
        let next=try await subject.perform(try labels(cached,add:[feature],remove:[]));XCTAssertEqual(next.state,.confirmed,"Released")
    }
    func testIncompleteReconcileStaysUncertainUntilStopWaitingReleasesThePullRequest() async throws {
        let provider=LightWriteProvider();await provider.configure { $0.loseResponse=true }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let first=try await subject.perform(try labels(cached,add:[feature],remove:[]));XCTAssertEqual(first.state,.uncertain)
        await provider.configure { $0.labelsPartial=true;$0.loseResponse=false }
        let again=try await subject.reconcile(first.id);XCTAssertEqual(again.state,.uncertain,"More than 100 current labels proves nothing")
        do { _ = try await subject.perform(try labels(cached,add:[docs],remove:[]));XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.operationInProgress) }
        let stopped=try subject.abandonUncertain(first.id)
        XCTAssertEqual(stopped.state,.rejected);XCTAssertEqual(stopped.message,"Stopped waiting; check the pull request on GitHub.");XCTAssertFalse(stopped.canStopWaiting)
        XCTAssertEqual(try DraftReviewStore(database:db).operation(first.id)?.state,.rejected)
        XCTAssertEqual(try subject.abandonUncertain(first.id),stopped,"Idempotent once terminal")
        await provider.configure { $0.labelsPartial=false }
        let next=try await subject.perform(try labels(cached,add:[docs],remove:[]));XCTAssertEqual(next.state,.confirmed,"Stop waiting releases the pull request")
        let writes=await provider.writes;XCTAssertEqual(writes,2)
    }
    func testConfirmedLabelReceiptReplacesOnlyLabelsAndKeepsMergeEvidenceAndOtherMetadata() async throws {
        let provider=LightWriteProvider(),cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let eligibleBefore=try XCTUnwrap(db.snapshot(for:key.account).pullRequests.first?.metadata?.mergeEligible,"Snapshot derives eligibility from the kept evidence")
        let result=try await subject.perform(try labels(cached,add:[feature,docs],remove:[bug]));XCTAssertEqual(result.state,.confirmed)
        let pr=try XCTUnwrap(db.snapshot(for:key.account).pullRequests.first),m=try XCTUnwrap(pr.metadata),old=try XCTUnwrap(cached.metadata)
        XCTAssertEqual(m.labels,["feature","docs"]);XCTAssertEqual(m.labelColors,["feature":"a2eeef","docs":"0075ca"])
        XCTAssertEqual(m.mergeEvidence,old.mergeEvidence);XCTAssertEqual(m.mergeEligible,eligibleBefore);XCTAssertEqual(m.approvalCount,2);XCTAssertEqual(m.reviewEvidenceComplete,true)
        XCTAssertEqual(m.descriptionPreview,old.descriptionPreview);XCTAssertEqual(m.requests,old.requests);XCTAssertEqual(m.assignees,old.assignees);XCTAssertEqual(m.reviewDecision,"APPROVED");XCTAssertEqual(m.checks,"SUCCESS");XCTAssertEqual(m.baseRevision,"stale-base")
        XCTAssertEqual(pr.title,cached.title);XCTAssertEqual(pr.headRevision,cached.headRevision);XCTAssertEqual(pr.state,.open)
        XCTAssertEqual(try db.observationFence(for:key),1,"A confirmed label change still fences older polls")
    }
    func testAdmissionRefusesDeltasWhenTheAffectedCurrentListIsIncomplete() async throws {
        let cached=lightCachedPR(key:key)
        let cases:[(String,PRWriteIntent)]=[("labels",.metadata(.labelChanges(add:[feature],remove:[]))),("assignees",.metadata(.assigneeChanges(add:[bob],remove:[]))),("requests",.metadata(.reviewRequestChanges(addUsers:[bob],addTeams:[],removeUsers:[],removeTeams:[])))]
        for (list,intent) in cases {
            let provider=LightWriteProvider();await provider.configure { $0.labelsPartial = list == "labels";$0.assigneesPartial = list == "assignees";$0.requestsPartial = list == "requests" }
            let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
            do { _ = try await subject.perform(try .revisionIndependent(actionPR:cached,intent:intent));XCTFail(list) } catch { XCTAssertEqual(error as? PRWriteFailure,.listIncomplete,list) }
            XCTAssertTrue(PRWriteFailure.listIncomplete.localizedDescription.contains("more than 100"))
            let writes=await provider.writes;XCTAssertEqual(writes,0,list)
            XCTAssertEqual(try DraftReviewStore(database:db).operations(key).first?.state,.rejected,"Released before any send")
            XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.metadata?.labels,["bug"])
        }
    }
    /// A `.sending` row (process death mid-send, or still in flight) is not settled by its first unmatched read.
    func testSendingRowSettlesOnlyOnASecondCompleteRead() async throws {
        let provider=LightWriteProvider(),cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let store=DraftReviewStore(database:db)
        var operation=PRWriteOperation(command:try labels(cached,add:[feature],remove:[]));try store.prepare(operation)
        operation.state = .sending;try store.update(operation,expectedState:.prepared)
        let first=try await subject.reconcile(operation.id)
        XCTAssertEqual(first.state,.uncertain);XCTAssertTrue(first.message?.contains("may still be in flight") == true,first.message ?? "")
        let second=try await subject.reconcile(operation.id);XCTAssertEqual(second.state,.rejected)
        let writes=await provider.writes;XCTAssertEqual(writes,0)
    }
    func testStopWaitingIsOnlyForUncertainIdempotentDeltas() async throws {
        XCTAssertTrue(PRWriteIntent.metadata(.labelChanges(add:[feature],remove:[])).isIdempotent);XCTAssertTrue(PRWriteIntent.subscription(state:.ignored).isIdempotent)
        XCTAssertTrue(PRWriteIntent.metadata(.reviewRequestChanges(addUsers:[bob],addTeams:[],removeUsers:[],removeTeams:[])).isIdempotent)
        for intent in [PRWriteIntent.dismissReview(reviewID:"R1",message:"m"),.discardPendingReview(reviewID:"R1"),.conversation("x"),.metadata(.title("t"))] { XCTAssertFalse(intent.isIdempotent,"\(intent)") }
        let provider=LightWriteProvider();await provider.configure { $0.loseResponse=true;$0.reviews=[.init(id:"R1",state:"APPROVED",author:"bob",authorID:"U2",commit:"h",viewerDidAuthor:false)] }
        let cached=lightCachedPR(key:key);let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let dismissal=try await subject.perform(try .revisionIndependent(actionPR:cached,intent:.dismissReview(reviewID:"R1",message:"stale")))
        XCTAssertEqual(dismissal.state,.uncertain);XCTAssertFalse(dismissal.canStopWaiting)
        XCTAssertThrowsError(try subject.abandonUncertain(dismissal.id)) { XCTAssertEqual($0 as? PRWriteFailure,.uncertain) }
        XCTAssertEqual(try DraftReviewStore(database:db).operation(dismissal.id)?.state,.uncertain)
    }
    func testAssigneeDeltaRequiresViewerCanAssignAndConfirmsOnlyAssignees() async throws {
        let denied=LightWriteProvider();await denied.configure { $0.canAssign=false }
        let cached=lightCachedPR(key:key),command=try PRWriteCommand.revisionIndependent(actionPR:cached,intent:.metadata(.assigneeChanges(add:[bob],remove:[alice])))
        let (_,deniedSubject)=try lightWriteFixture(denied,key:key,cached:cached)
        do { _ = try await deniedSubject.perform(command);XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.permissionDenied) }
        let deniedWrites=await denied.writes;XCTAssertEqual(deniedWrites,0)
        let provider=LightWriteProvider();let (db,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let result=try await subject.perform(command);XCTAssertEqual(result.state,.confirmed)
        let m=try XCTUnwrap(db.snapshot(for:key.account).pullRequests.first?.metadata)
        XCTAssertEqual(m.assignees,["bob"]);XCTAssertEqual(m.labels,["bug"]);XCTAssertEqual(m.mergeEvidence,cached.metadata?.mergeEvidence)
        let queries=await provider.queries;XCTAssertTrue(queries.allSatisfy { $0.contains("assignees(first:100)") && $0.contains("viewerCanAssign") })
    }
    func testMetadataOptionsExposeNodeIDsForLabelAndAssigneePickersInOneRead() async throws {
        let provider=LightWriteProvider(),cached=lightCachedPR(key:key);let (_,subject)=try lightWriteFixture(provider,key:key,cached:cached)
        let options=try await subject.metadataOptions(for:cached)
        XCTAssertEqual(options.key,key);XCTAssertEqual(options.labels,[bug]);XCTAssertTrue(options.labelsComplete);XCTAssertEqual(options.availableLabels,[bug,feature,docs]);XCTAssertTrue(options.availableLabelsComplete)
        XCTAssertEqual(options.labelColors["feature"],"a2eeef");XCTAssertEqual(options.assignees,[alice]);XCTAssertEqual(options.assignableUsers.map(\.login),["alice","bob","carol"])
        XCTAssertTrue(options.canLabel);XCTAssertTrue(options.canAssign)
        let queries=await provider.queries,writes=await provider.writes;XCTAssertEqual(queries.count,1);XCTAssertEqual(writes,0)
    }
}
