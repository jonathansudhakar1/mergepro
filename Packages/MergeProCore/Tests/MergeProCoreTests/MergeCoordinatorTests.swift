import XCTest
@testable import MergeProCore
final class MergeCoordinatorTests:XCTestCase {
    func testConfirmedMergedIsTerminalAndSharedAcrossAvailableReadAccountWithoutViewerCopy() throws {
        let db=try DatabaseStore(path:":memory:")
        let a=AccountScope(host:"github.com",accountID:"A"),b=AccountScope(host:"github.com",accountID:"B")
        for account in [a,b] { try db.saveAccount(.init(scope:account,login:account.accountID,tokenReference:nil));try db.saveRepository(.init(key:.init(account:account,repositoryID:"R"),name:"o/r",isPrivate:true,capabilities:[])) }
        func row(_ account:AccountScope,_ state:PullRequest.State) -> PullRequest {
            var m=PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r");m.viewerID=account.accountID;m.reviewDecision=account.accountID
            return .init(key:.init(host:account.host,accountID:account.accountID,repositoryID:"R",objectID:"pull-request:P"),headRevision:.init("h"),title:"PR",state:state,isDraft:false,metadata:m)
        }
        let oldA=row(a,.open),oldB=row(b,.open);try db.savePullRequests([oldA,oldB])
        let oldFence=try db.observationFence(for:oldA.key)
        try db.confirmWrite(row(b,.merged))
        XCTAssertFalse(try db.saveObservedPullRequests([oldA],fences:[oldA.key:oldFence]))
        let readA=try XCTUnwrap(db.snapshot(for:a).pullRequests.first)
        XCTAssertEqual(readA.state,.merged);XCTAssertEqual(readA.metadata?.viewerID,"A");XCTAssertEqual(readA.metadata?.reviewDecision,"A")
        let fresh=try db.observationFence(for:oldB.key)
        _ = try db.saveObservedPullRequests([oldB],fences:[oldB.key:fresh])
        XCTAssertEqual(try db.snapshot(for:b).pullRequests.first?.state,.merged)
    }
}

/// Accepts every merge request (202) until `answerRemaining(.lostResponse)`.
private func mergeTransport() -> ScriptedTransport {
    ScriptedTransport(fallback:json(#"{"status":"pending","details":{"uuid":"11111111-1111-1111-1111-111111111111","expected_head_sha":"h","merge_method":"squash","merge_action":"direct_merge","bypass_rules":false}}"#,status:202))
}
private actor MergeTestAdapter:MergeAdapter {
    var value:MergeInspection
    var sent=false
    var dispatched=false
    var terminal:MergeOutcome?
    var reads=0
    var autoMergeOptions:MergeAutoMergeRequest? = .init(method:.squash)
    var defaults:MergeMessageDefaults?
    var defaultReads=0
    var updatedParents:[String]=[]
    var updatedLinearBase:String?
    var updatedBase="b"
    init(_ value:MergeInspection) { self.value=value }
    func updated(parents:[String],linearBase:String?,base:String="b") { updatedParents=parents;updatedLinearBase=linearBase;updatedBase=base }
    func enabledAutoMerge(_ options:MergeAutoMergeRequest?) { autoMergeOptions=options }
    func provide(_ value:MergeMessageDefaults?) { defaults=value }
    func messageDefaults(_ target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> MergeMessageDefaults? { defaultReads += 1;return defaults }
    func requireQueue() { value.evidence.queueRequired=true;value.evidence.queueMethod = .squash }
    func alterPermission() { value.evidence.actorAllowed=false }
    func alterHead() { value.evidence = MergeEvidence(key:value.evidence.key,head:"changed",base:"b",branch:"main",fetchedAt:Date()) }
    func finish(_ result:MergeOutcome) { terminal=result }
    func inspect(_ target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> MergeInspection {
        reads += 1;var v=value
        if dispatched,let terminal {
            switch terminal {
            case .merged(let sha):v.pr = .init(key:v.pr.key,headRevision:v.pr.headRevision,title:v.pr.title,state:.merged,isDraft:false,metadata:v.pr.metadata);v.mergeCommitSHA=sha
            case .queued:v.evidence.queued=true
            case .autoMergeEnabled:v.evidence.autoMergeEnabled=true;v.autoMergeRequest=autoMergeOptions
            case .branchUpdated(let head):v.evidence = .init(key:v.pr.key,head:head,base:updatedBase,branch:"main",fetchedAt:Date());v.headParents=updatedParents;v.linearBase=updatedLinearBase
            default:break
            }
        }
        return v
    }
    func send(_ operation:PRWriteOperation,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse {
        sent=true;defer { dispatched=true }
        return try await GitHubMergeAdapter().send(operation,client:client,credential:credential)
    }
    func status(_ id:UUID,target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse {
        json(#"{"status":"pending","details":{"uuid":"11111111-1111-1111-1111-111111111111","expected_head_sha":"h","merge_method":"squash","merge_action":"direct_merge"}}"#)
    }
}
@MainActor final class MergeDispatchTests:XCTestCase {
    private func fixture() throws -> (DatabaseStore,MergeCoordinator,MergeCommand,ScriptedTransport,MergeTestAdapter,RateBudget) {
        let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"1",objectID:"pull-request:PR1"),transport=mergeTransport()
        let fixture=try makeSessionFixture(account:key.account,repositories:[.fixture(key.repository)],transport:transport,credential:.init(accessToken:"offline",scopes:["repo"])),db=fixture.database
        let m=PRMetadata(number:17,webURL:URL(string:"https://github.com/o/r/pull/17")!,repositoryName:"o/r")
        let pr=PullRequest(key:key,headRevision:.init("h"),title:"PR",state:.open,isDraft:false,metadata:m);try db.savePullRequests([pr])
        var e=MergeEvidence(key:key,head:"h",base:"b",branch:"main",fetchedAt:Date());e.open=true;e.draft=false;e.actorAllowed=true;e.tokenCanWrite=true;e.conflictFree=true;e.rulesComplete=true;e.asyncSupported=true;e.methods=[.squash];e.canEnableAutoMerge=true;e.canUpdateBranch=true
        let inspection=MergeInspection(pr:pr,evidence:e),adapter=MergeTestAdapter(inspection),budget=RateBudget(minimumSpacing:.zero)
        let coordinator=MergeCoordinator(session:fixture.session,budget:budget,database:db,clientID:"offline",activeAccount:fixture.activeAccount,adapter:adapter)
        return (db,coordinator,try .init(selected:inspection,affected:[inspection],method:.squash,action:.direct),transport,adapter,budget)
    }
    func testPostBudgetAccountPermissionAndHeadChangeSendNothing() async throws {
        for change in 0..<3 {
            let (db,coordinator,command,transport,adapter,budget)=try fixture()
            try await budget.beginRequest(account:command.pr.account)
            let task=Task { try await coordinator.perform(command) }
            while !(await adapter.sent) { await Task.yield() }
            if change == 0 { try db.setApplicationSetting("other",for:"activeActionAccount") }
            else if change == 1 { await adapter.alterPermission() } else { await adapter.alterHead() }
            await budget.endRequest(account:command.pr.account)
            do { _ = try await task.value;XCTFail("Changed preflight must reject") } catch { XCTAssertTrue(error is PRWriteFailure) }
            let count=await transport.count;XCTAssertEqual(count,0)
            XCTAssertEqual(try DraftReviewStore(database:db).operations(command.pr).first?.state,.rejected)
        }
    }
    func testPendingLossRestartAndSharedReviewAdmissionNeverRepeatMutation() async throws {
        let (db,coordinator,command,transport,adapter,_)=try fixture();await transport.answerRemaining(.lostResponse)
        let result=try await coordinator.perform(command);XCTAssertEqual(result.state,.uncertain)
        let review=PRWriteOperation(command:.init(key:command.pr,repository:"o/r",number:17,revision:command.writeCommand.revision,intent:.review(.approve,"")))
        XCTAssertThrowsError(try DraftReviewStore(database:db).prepare(review))
        _ = try await coordinator.reconcile(result.id)
        XCTAssertEqual(try db.snapshot(for:command.pr.account).pullRequests.first?.state,.open)
        await adapter.finish(.merged(commitSHA:"merge-sha"))
        let reconciled=try await coordinator.reconcile(result.id);XCTAssertEqual(reconciled.mergeOutcome,.merged(commitSHA:"merge-sha"))
        _ = try await coordinator.reconcile(result.id)
        let count=await transport.count;XCTAssertEqual(count,1);XCTAssertEqual(try db.observationFence(for:command.pr),1)
    }
    func testAcceptedPendingIsNotMergedAndCanReleaseOnlyUnsent() async throws {
        let (db,coordinator,command,transport,_,_)=try fixture()
        let result=try await coordinator.perform(command)
        XCTAssertEqual(result.state,.uncertain);XCTAssertNotNil(result.mergeOperationID)
        XCTAssertThrowsError(try DraftReviewStore(database:db).rejectUnsent(result.id))
        XCTAssertEqual(try db.snapshot(for:command.pr.account).pullRequests.first?.state,.open)
        let count=await transport.count;XCTAssertEqual(count,1)
    }
    func testProviderQueuedAndAutoMergeEnabledRemainOpen() async throws {
        for action in [MergeAction.queue,.enableAutoMerge] {
            let (db,coordinator,_,transport,adapter,_)=try fixture()
            if action == .queue { await adapter.requireQueue() }
            let snapshot=await adapter.value
            let command=try MergeCommand(selected:snapshot,affected:[snapshot],method:.squash,action:action)
            await transport.answerRemaining(.lostResponse)
            let pending=try await coordinator.perform(command)
            await adapter.finish(action == .queue ? .queued : .autoMergeEnabled)
            let confirmed=try await coordinator.reconcile(pending.id)
            XCTAssertEqual(confirmed.state,.confirmed)
            XCTAssertEqual(confirmed.mergeOutcome,action == .queue ? .queued : .autoMergeEnabled)
            XCTAssertEqual(try db.snapshot(for:command.pr.account).pullRequests.first?.state,.open)
            let count=await transport.count;XCTAssertEqual(count,1)
        }
    }
    func testChangedHeadAloneCannotConfirmAcceptedBranchUpdate() async throws {
        let (db,coordinator,command,_,adapter,_)=try fixture()
        let snapshot=await adapter.value
        let update=try MergeCommand(selected:snapshot,affected:[snapshot],method:.squash,action:.updateBranch)
        await adapter.finish(.branchUpdated(head:"unrelated-push"))
        let result=try await coordinator.perform(update)
        XCTAssertEqual(result.state,.uncertain,"Unrelated push is not evidence that the requested nonforce update completed")
        XCTAssertEqual(try db.snapshot(for:command.pr.account).pullRequests.first?.state,.open)
    }
    func testPrepareIsReadOnlyAndReleasedBudgetWaitCannotReviveIntent() async throws {
        let (db,coordinator,command,transport,adapter,budget)=try fixture()
        let pr=try XCTUnwrap(db.snapshot(for:command.pr.account).pullRequests.first)
        _ = try await coordinator.prepare(pr)
        XCTAssertTrue(try DraftReviewStore(database:db).operations(command.pr).isEmpty)
        let countBefore=await transport.count;XCTAssertEqual(countBefore,0)
        try await budget.beginRequest(account:command.pr.account)
        let task=Task { try await coordinator.perform(command) }
        while !(await adapter.sent) { await Task.yield() }
        let store=DraftReviewStore(database:db),old=try XCTUnwrap(store.operations(command.pr).first)
        try store.rejectUnsent(old.id)
        let replacement=PRWriteOperation(command:.init(key:command.pr,repository:"o/r",number:17,revision:command.writeCommand.revision,intent:.review(.approve,"")))
        try store.prepare(replacement);await budget.endRequest(account:command.pr.account)
        do { _ = try await task.value;XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.operationInProgress) }
        let count=await transport.count;XCTAssertEqual(count,0);XCTAssertEqual(try store.operation(replacement.id)?.state,.prepared)
    }
    func testCancellationWhileWaitingReleasesReservationAndBudgetSlot() async throws {
        let (db,coordinator,command,transport,adapter,budget)=try fixture()
        try await budget.beginRequest(account:command.pr.account)
        let task=Task { try await coordinator.perform(command) }
        while !(await adapter.sent) { await Task.yield() }
        task.cancel()
        do { _ = try await task.value;XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await budget.endRequest(account:command.pr.account)
        try await budget.beginRequest(account:command.pr.account);await budget.endRequest(account:command.pr.account)
        let count=await transport.count;XCTAssertEqual(count,0)
        XCTAssertEqual(try DraftReviewStore(database:db).operations(command.pr).first?.state,.rejected)
    }
    func testCanonicalGraphQLMappingExpectedSHAAndConflicting409() async throws {
        let (_,_,command,_,adapter,_)=try fixture(),snapshot=await adapter.value
        let auto=try MergeCommand(selected:snapshot,affected:[snapshot],method:.squash,action:.enableAutoMerge)
        let request=try GitHubMergeAdapter.request(.init(command:auto.writeCommand))
        let root=try XCTUnwrap(JSONSerialization.jsonObject(with:request.body) as? [String:Any]),variables=root["variables"] as! [String:Any],input=variables["input"] as! [String:Any]
        XCTAssertEqual(input["pullRequestId"] as? String,"PR1");XCTAssertEqual(input["expectedHeadOid"] as? String,"h");XCTAssertNil(input["bypass_rules"])
        let wrong=json(#"{"status":"pending","details":{"uuid":"11111111-1111-1111-1111-111111111111","expected_head_sha":"other","merge_method":"merge","merge_action":"direct_merge"}}"#,status:409)
        XCTAssertThrowsError(try GitHubMergeAdapter.pendingID(wrong,command:command))
        let mergeRequest=try GitHubMergeAdapter.request(.init(command:command.writeCommand));XCTAssertEqual(mergeRequest.path,"repos/o/r/pulls/17/merge-async")
        let body=try JSONSerialization.jsonObject(with:mergeRequest.body) as! [String:Any];XCTAssertEqual(body["bypass_rules"] as? Bool,false)
    }
    func testAutoMergeReconcileConfirmsOnlyMatchingMethodAndText() async throws {
        let cases:[(MergeAutoMergeRequest?,String?,String?,Bool)]=[
            (.init(method:.merge),nil,nil,false),
            (.init(method:.squash),"Ship it",nil,false),
            (.init(method:.squash,commitHeadline:"Other"),"Ship it",nil,false),
            (.init(method:.squash,commitHeadline:"Ship it",commitBody:"Old"),"Ship it","New",false),
            (nil,nil,nil,false),
            (.init(method:.squash,commitHeadline:"Provider default"),nil,nil,true),
            (.init(method:.squash,commitHeadline:"Ship it",commitBody:"Body\r\n"),"Ship it","Body",true)]
        for (options,title,message,confirmed) in cases {
            let (db,coordinator,_,transport,adapter,_)=try fixture(),snapshot=await adapter.value
            let command=try MergeCommand(selected:snapshot,affected:[snapshot],method:.squash,action:.enableAutoMerge,title:title,message:message)
            await transport.answerRemaining(.lostResponse)
            let pending=try await coordinator.perform(command)
            await adapter.finish(.autoMergeEnabled);await adapter.enabledAutoMerge(options)
            let result=try await coordinator.reconcile(pending.id)
            XCTAssertEqual(result.state,confirmed ? .confirmed : .uncertain,"\(String(describing:options)) \(title ?? "-") \(message ?? "-")")
            XCTAssertEqual(result.mergeOutcome,confirmed ? .autoMergeEnabled : nil)
            if !confirmed { XCTAssertTrue(result.message?.contains("differ") == true || options == nil,result.message ?? "") }
            XCTAssertEqual(try db.snapshot(for:command.pr.account).pullRequests.first?.state,.open)
            let count=await transport.count;XCTAssertEqual(count,1,"Reconciliation reads; it never resends")
        }
    }
    func testExisting409CannotProveAnyCustomTextIncludingMessageOnly() throws {
        let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"1",objectID:"pull-request:PR1")
        var e=MergeEvidence(key:key,head:"h",base:"b",branch:"main",fetchedAt:Date());e.methods=[.squash]
        let value=MergeInspection(pr:.init(key:key,headRevision:.init("h"),title:"PR",state:.open,isDraft:false,metadata:PRMetadata(number:17,webURL:URL(string:"https://github.com/o/r/pull/17")!,repositoryName:"o/r")),evidence:e)
        let existing=json(#"{"status":"pending","details":{"uuid":"11111111-1111-1111-1111-111111111111","expected_head_sha":"h","merge_method":"squash","merge_action":"direct_merge","bypass_rules":false}}"#,status:409)
        XCTAssertNotNil(try GitHubMergeAdapter.pendingID(existing,command:MergeCommand(selected:value,affected:[value],method:.squash,action:.direct)))
        XCTAssertThrowsError(try GitHubMergeAdapter.pendingID(existing,command:MergeCommand(selected:value,affected:[value],method:.squash,action:.direct,message:"")),"A deliberately blank body is still an override")
    }
    func testRebaseUpdateConfirmsOnlyALinearChainOnTheCapturedBase() async throws {
        // (update method, new head parents, linear base, confirmed)
        let cases:[(MergeUpdateMethod,[String],String?,Bool)]=[
            (.rebase,[],"b",true),
            (.rebase,[],"older-base",false),
            (.rebase,[],nil,false),
            (.rebase,["h","b"],nil,false),
            (.merge,["h","b"],nil,true),
            (.merge,[],"b",false)]
        for (update,parents,linearBase,confirmed) in cases {
            let (_,coordinator,_,transport,adapter,_)=try fixture(),snapshot=await adapter.value
            let command=try MergeCommand(selected:snapshot,affected:[snapshot],method:.squash,action:.updateBranch,updateMethod:update)
            await transport.answerRemaining(.lostResponse)
            let pending=try await coordinator.perform(command)
            XCTAssertEqual(pending.state,.uncertain)
            await adapter.finish(.branchUpdated(head:"updated"));await adapter.updated(parents:parents,linearBase:linearBase)
            let result=try await coordinator.reconcile(pending.id)
            XCTAssertEqual(result.state,confirmed ? .confirmed : .uncertain,"\(update) \(parents) \(linearBase ?? "-")")
            XCTAssertEqual(result.mergeOutcome,confirmed ? .branchUpdated(head:"updated") : nil)
            let count=await transport.count;XCTAssertEqual(count,1,"Reconciliation never resends")
        }
    }
    /// GitHub updates onto the base tip at execution time. When the base moved after preflight, the
    /// proof accepts the captured base OR the base tip read at reconcile time; anything else stays uncertain.
    func testUpdateProofAcceptsBaseTipThatMovedBetweenPreflightAndExecution() async throws {
        // (update method, new head parents, linear base, reconcile-time base tip, confirmed)
        let cases:[(MergeUpdateMethod,[String],String?,String,Bool)]=[
            (.rebase,[],"moved-base","moved-base",true),
            (.rebase,[],"b","moved-base",true),
            (.rebase,[],"other-base","moved-base",false),
            (.merge,["h","moved-base"],nil,"moved-base",true),
            (.merge,["h","b"],nil,"moved-base",true),
            (.merge,["h","other-base"],nil,"moved-base",false),
            (.merge,["x","moved-base"],nil,"moved-base",false)]
        for (update,parents,linearBase,tip,confirmed) in cases {
            let (_,coordinator,_,transport,adapter,_)=try fixture(),snapshot=await adapter.value
            let command=try MergeCommand(selected:snapshot,affected:[snapshot],method:.squash,action:.updateBranch,updateMethod:update)
            await transport.answerRemaining(.lostResponse)
            let pending=try await coordinator.perform(command);XCTAssertEqual(pending.state,.uncertain)
            await adapter.finish(.branchUpdated(head:"updated"));await adapter.updated(parents:parents,linearBase:linearBase,base:tip)
            let result=try await coordinator.reconcile(pending.id)
            XCTAssertEqual(result.state,confirmed ? .confirmed : .uncertain,"\(update) \(parents) \(linearBase ?? "-") \(tip)")
            XCTAssertEqual(result.mergeOutcome,confirmed ? .branchUpdated(head:"updated") : nil)
            let count=await transport.count;XCTAssertEqual(count,1,"Reconciliation never resends")
        }
    }
    func testAutoMergeTextComparisonTreatsNilAndEmptyAsEqual() throws {
        let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"1",objectID:"pull-request:PR1")
        var e=MergeEvidence(key:key,head:"h",base:"b",branch:"main",fetchedAt:Date());e.methods=[.squash]
        let value=MergeInspection(pr:.init(key:key,headRevision:.init("h"),title:"PR",state:.open,isDraft:false,metadata:PRMetadata(number:17,webURL:URL(string:"https://github.com/o/r/pull/17")!,repositoryName:"o/r")),evidence:e)
        let blankBody=try MergeCommand(selected:value,affected:[value],method:.squash,action:.enableAutoMerge,title:"Ship it",message:"")
        XCTAssertEqual(blankBody.message,"")
        XCTAssertTrue(MergeAutoMergeRequest(method:.squash,commitHeadline:"Ship it",commitBody:nil).matches(blankBody),"GitHub reports a blank body as null")
        XCTAssertTrue(MergeAutoMergeRequest(method:.squash,commitHeadline:"Ship it",commitBody:"").matches(blankBody))
        XCTAssertTrue(MergeAutoMergeRequest(method:.squash,commitHeadline:"Ship it",commitBody:" \r\n").matches(blankBody),"Whitespace-only normalizes to empty")
        XCTAssertFalse(MergeAutoMergeRequest(method:.squash,commitHeadline:"Ship it",commitBody:"Body").matches(blankBody))
        let newline=try MergeCommand(selected:value,affected:[value],method:.squash,action:.enableAutoMerge,title:"Ship it",message:"\n")
        XCTAssertTrue(MergeAutoMergeRequest(method:.squash,commitHeadline:"Ship it",commitBody:nil).matches(newline))
        XCTAssertFalse(MergeAutoMergeRequest(method:.squash,commitHeadline:nil,commitBody:nil).matches(blankBody),"A missing headline never equals a requested one")
    }
    func testMessageDefaultsAreReadOnlyAccountCheckedAndHeadBound() async throws {
        let (db,coordinator,command,transport,adapter,_)=try fixture()
        let pr=try XCTUnwrap(db.snapshot(for:command.pr.account).pullRequests.first)
        let fence=try db.observationFence(for:pr.key)
        let defaults=MergeMessageDefaults(head:"h",titles:[.squash:"PR (#17)"],bodies:[.squash:""])
        await adapter.provide(defaults)
        let read=try await coordinator.messageDefaults(pr)
        XCTAssertEqual(read,defaults)
        await adapter.provide(.init(head:"moved",titles:[.squash:"Other"],bodies:[:]))
        let moved=try await coordinator.messageDefaults(pr)
        XCTAssertNil(moved,"Defaults for another head are discarded")
        await adapter.provide(defaults)
        try db.setApplicationSetting("other",for:"activeActionAccount")
        do { _ = try await coordinator.messageDefaults(pr);XCTFail("Another action account cannot read this PR's defaults") } catch { XCTAssertEqual(error as? PRWriteFailure,.accountChanged) }
        let reads=await adapter.defaultReads;XCTAssertEqual(reads,2)
        XCTAssertTrue(try DraftReviewStore(database:db).operations(command.pr).isEmpty)
        XCTAssertEqual(try db.observationFence(for:pr.key),fence)
        let writes=await transport.count;XCTAssertEqual(writes,0)
    }
}

final class MergeLeaseTests:XCTestCase {
    func testMixedRESTAndGraphQLRevalidationUsesSameLeaseAndObservesQuotaHeaders() async throws {
        let budget=RateBudget(minimumSpacing:.zero),account=AccountScope(host:"github.com",accountID:"fixture")
        // Every answer carries a nearly exhausted REST quota; GraphQL answers report their own.
        let until=Date().addingTimeInterval(600),headers=["X-RateLimit-Remaining":"4","X-RateLimit-Reset":String(Int(until.timeIntervalSince1970))]
        let base=RoutingTransport()
        await base.route(method:"POST",try json(object:["data":["rateLimit":["cost":2,"remaining":900,"resetAt":ISO8601DateFormatter().string(from:until)]]],headers:headers))
        await base.route(json("{}",headers:headers))
        let reader=GitHubHTTPClient(transport:BudgetedGitHubTransport(base:base,budget:budget,account:account,ownsRequestSlot:false,beforeSend:{}))
        let writer=GitHubHTTPClient(transport:BudgetedGitHubTransport(base:base,budget:budget,account:account,beforeSend:{
            _ = try await reader.get(URL(string:"https://api.github.com/repos/o/r/pulls/1")!,token:"offline")
            _ = try await reader.readQuery("query Lease { viewer { id } }",variables:[:],token:"offline")
        }))
        _ = try await writer.mutate(path:"repos/o/r/pulls/1/merge-async",method:"PUT",body:Data("{}".utf8),token:"offline")
        let methods=await base.methods();XCTAssertEqual(methods,["GET","POST","PUT"])
        do { try await budget.acquire(account:account,resource:.rest,priority:.interactive,cost:5);XCTFail("REST header quota must be retained") } catch { XCTAssertTrue(error is GitHubFailure) }
        try await budget.acquire(account:account,resource:.graphql,priority:.interactive,cost:800)
        try await budget.beginRequest(account:account);await budget.endRequest(account:account)
    }
}
