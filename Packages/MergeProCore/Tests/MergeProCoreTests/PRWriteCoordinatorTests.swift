import XCTest
import GRDB
@testable import MergeProCore

/// Answers every write with a created receipt until told to lose or deny it.
private func writeTransport() -> ScriptedTransport { ScriptedTransport(fallback:json(#"{"id":"created"}"#)) }
private actor CoordinatorAdapter:PRWriteAdapter {
    var holdPreflight=false
    var gate:CheckedContinuation<Void,Never>?
    var waiting:Bool { gate != nil }
    func hold() { holdPreflight=true }
    func release() { holdPreflight=false;gate?.resume();gate=nil }
    var truth:PRWriteTruth
    var shouldConfirm=true
    func confirming(_ value:Bool) { shouldConfirm=value }
    var wasPreflight=false
    var dispatchAttempted=false
    init(_ truth:PRWriteTruth) { self.truth=truth }
    func read(_ command:PRWriteCommand,operation:PRWriteOperation?,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> PRWriteTruth {
        if operation != nil { var result=truth;result.matchingOperationIDs=shouldConfirm ? ["created"] : [];return result }
        wasPreflight=true;if holdPreflight { await withCheckedContinuation { gate=$0 } };return truth
    }
    func send(_ operation:PRWriteOperation,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse {
        dispatchAttempted=true
        return try await client.mutate(path:"repos/o/r/issues/1/comments",method:"POST",body:Data("{}".utf8),token:credential.accessToken)
    }
    nonisolated func providerIDs(_ response:GitHubResponse) -> [String] { ["created"] }
}
@MainActor final class PRWriteCoordinatorTests:XCTestCase {
    let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"1",objectID:"PR1")
    private func fixture(transport:any GitHubTransport,budget:RateBudget) throws -> (DatabaseStore,GitHubAccountSession,PRWriteCommand,CoordinatorAdapter) {
        let fixture=try makeSessionFixture(account:key.account,repositories:[.fixture(key.repository)],transport:transport)
        let (db,session)=(fixture.database,fixture.session)
        let normalized=PullRequest(key:key,headRevision:.init("h"),title:"confirmed",state:.closed,isDraft:false)
        try db.savePullRequests([normalized])
        let command=PRWriteCommand(key:key,repository:"o/r",number:1,revision:.init(head:"h",origin:"o",target:"t"),intent:.conversation("exact body"))
        let truth=PRWriteTruth(key:key,revision:command.revision,viewerIsAuthor:false,canReview:true,canComment:true,canUpdate:true,canReopen:true,canLabel:true,isOpen:true,normalized:normalized)
        return (db,session,command,CoordinatorAdapter(truth))
    }
    private func coordinator(_ db:DatabaseStore,_ session:GitHubAccountSession,_ budget:RateBudget,_ adapter:CoordinatorAdapter) -> PRWriteCoordinator {
        let account=key.account
        return .init(session:session,budget:budget,database:db,clientID:"fixture",activeAccount:{ try db.applicationSetting("activeActionAccount") == AccountSessionStore.tokenReference(for:account) ? account : nil },adapter:adapter)
    }
    func testActionAccountSwitchWhileBudgetHeldRejectsBeforeActualDispatch() async throws {
        let transport=writeTransport(),budget=RateBudget(minimumSpacing:.zero)
        let (db,session,command,adapter)=try fixture(transport:transport,budget:budget)
        try await budget.beginRequest(account:key.account)
        let subject=coordinator(db,session,budget,adapter)
        let task=Task { try await subject.perform(command) }
        while !(await adapter.wasPreflight) { await Task.yield() }
        try db.setApplicationSetting("other",for:"activeActionAccount")
        await budget.endRequest(account:key.account)
        do { _ = try await task.value;XCTFail("Account change must reject before send") } catch { XCTAssertEqual(error as? PRWriteFailure,.accountChanged) }
        let writes=await transport.count;XCTAssertEqual(writes,0)
        XCTAssertEqual(try DraftReviewStore(database:db).operations(key).first?.state,.rejected)
    }
    func testResponseLossPersistsSentStateAndReadReconciliationDoesNotDuplicatePOST() async throws {
        let transport=writeTransport(),budget=RateBudget(minimumSpacing:.zero)
        await transport.answerRemaining(.lostResponse)
        let (db,session,command,adapter)=try fixture(transport:transport,budget:budget)
        let subject=coordinator(db,session,budget,adapter)
        let first=try await subject.perform(command)
        XCTAssertEqual(first.state,.uncertain)
        XCTAssertEqual(try DraftReviewStore(database:db).operation(first.id)?.command.intent,.conversation("exact body"))
        let restored=try await subject.reconcile(first.id)
        XCTAssertEqual(restored.state,.confirmed)
        let writes=await transport.count;XCTAssertEqual(writes,1)
        XCTAssertEqual(try db.observationFence(for:key),1)
    }
    func testDraftSurvivesPermissionDenialAndNoRequestIsSent() async throws {
        let transport=writeTransport(),budget=RateBudget(minimumSpacing:.zero)
        let (db,session,base,adapter)=try fixture(transport:transport,budget:budget)
        let draft=ReviewDraft(key:key,revision:base.revision,summary:"preserve me");try DraftReviewStore(database:db).save(draft)
        let command=PRWriteCommand(key:key,repository:"o/r",number:1,revision:base.revision,intent:.editComment(id:"not-owned",kind:.review,body:"new text"))
        do { _ = try await coordinator(db,session,budget,adapter).perform(command);XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.permissionDenied) }
        XCTAssertEqual(try DraftReviewStore(database:db).load(key),draft)
        let writes=await transport.count;XCTAssertEqual(writes,0)
    }
    func testConfirmedWritePreservesDescriptionNotObservedByWriteReader() async throws {
        let transport=writeTransport(),budget=RateBudget(minimumSpacing:.zero)
        let (db,session,command,_)=try fixture(transport:transport,budget:budget)
        var metadata=PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r")
        let normalized=PullRequest(key:key,headRevision:.init("h"),title:"confirmed",state:.open,isDraft:false,metadata:metadata)
        metadata.descriptionPreview="Keep this PR summary after a confirmed action."
        try db.savePullRequests([PullRequest(key:key,headRevision:.init("h"),title:"before",state:.open,isDraft:false,metadata:metadata)])
        let adapter=CoordinatorAdapter(PRWriteTruth(key:key,revision:command.revision,viewerIsAuthor:false,canReview:true,canComment:true,canUpdate:true,canReopen:true,canLabel:true,isOpen:true,normalized:normalized))
        let result=try await coordinator(db,session,budget,adapter).perform(command)
        XCTAssertEqual(result.state,.confirmed)
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.metadata?.descriptionPreview,metadata.descriptionPreview)
    }
}

private struct UnrelatedWriteCycleFetcher:PollFeatureFetcher {
    let event:ChangeEvent
    func fetch(_ context:PollFetchContext) async throws -> PollFetchResult { .init(events:[event]) }
}
extension PRWriteCoordinatorTests {
    func testReleasedHeldPreflightAndBudgetCannotSendAfterReplacementReservation() async throws {
        for preflight in [true,false] {
            let transport=writeTransport(),budget=RateBudget(minimumSpacing:.zero)
            let (db,session,command,adapter)=try fixture(transport:transport,budget:budget)
            if preflight { await adapter.hold() } else { try await budget.beginRequest(account:key.account) }
            let subject=coordinator(db,session,budget,adapter),store=DraftReviewStore(database:db)
            let first=Task { try await subject.perform(command) }
            if preflight { while !(await adapter.waiting) { await Task.yield() } }
            else { while !(await adapter.dispatchAttempted) { await Task.yield() } }
            let old=try XCTUnwrap(store.operations(key).first);try store.rejectUnsent(old.id)
            let replacement=PRWriteOperation(command:command);try store.prepare(replacement)
            if preflight { await adapter.release() } else { await budget.endRequest(account:key.account) }
            do { _ = try await first.value;XCTFail("Released command must never dispatch") } catch { XCTAssertEqual(error as? PRWriteFailure,.operationInProgress) }
            let count=await transport.count;XCTAssertEqual(count,0)
            XCTAssertEqual(try store.operation(old.id)?.state,.rejected);XCTAssertEqual(try store.operation(replacement.id)?.state,.prepared)
        }
    }
    func testHeldPollBeforeConfirmedMutationCannotUndoTruthAndUnrelatedCycleEventStillAlerts() async throws {
        let transport=writeTransport(),budget=RateBudget(minimumSpacing:.zero)
        let (db,session,command,adapter)=try fixture(transport:transport,budget:budget)
        let old=PullRequest(key:key,headRevision:.init("h"),title:"before mutation",state:.open,isDraft:false)
        try db.savePullRequests([old]);try db.setTracked(key.repository,tracked:true)
        let gate=GatePollFetcher(),store=PollCycleStore(database:db),sink=RecordingNotificationSink()
        let unrelated=ChangeEvent(key:"unrelated",object:ProviderKey(host:key.host,accountID:key.accountID,repositoryID:key.repositoryID,objectID:"other"),category:"failed checks",occurredAt:Date(),title:"Unrelated check")
        let poll=PollCoordinator(store:store,publisher:.init(store:store,sink:sink),fetchers:[gate],budget:budget,session:session)
        let request=PollRequest(scopes:[.init(account:key.account,repositories:[key.repository])],policy:.init(enabled:true))
        let first=Task { try await poll.refresh(request) }
        while await gate.calls == 0 { await Task.yield() }
        let confirmed=try await coordinator(db,session,budget,adapter).perform(command);XCTAssertEqual(confirmed.state,.confirmed)
        let checkpoint=PollFeatureSnapshot(key:.init(host:key.host,accountID:key.accountID,repositoryID:key.repositoryID,objectID:"inventory"),feature:"inventory",payload:Data("old checkpoint".utf8))
        let unrelatedRow=PullRequest(key:unrelated.object,headRevision:.init("b"),title:"independent B",state:.open,isDraft:false)
        await gate.release(.init(events:[unrelated],pullRequests:[old,unrelatedRow],snapshots:[checkpoint],responses:[.init(url:URL(string:"https://api.github.com/batched")!,etag:"obsolete",body:Data())]))
        let id=try await first.value
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.state,.closed)
        XCTAssertEqual(try store.summary(id)?.eventKeys,["unrelated"])
        XCTAssertEqual(try store.inbox().map(\.id),["unrelated"])
        XCTAssertNotNil(try db.snapshot(for:key.account).pullRequests.first(where:{ $0.key == unrelated.object }))
        XCTAssertNil(try store.snapshot(checkpoint.key,feature:"inventory"),"Shared traversal checkpoint cannot advance from obsolete A")
        XCTAssertTrue(try store.responses(account:key.account).isEmpty,"Shared response cache/checkpoint cannot advance from partially obsolete result")
        let notifications=await sink.summaries;XCTAssertEqual(notifications.count,1)
        let fresh=Task { try await poll.refresh(request) }
        while await gate.calls < 2 { await Task.yield() }
        let later=PullRequest(key:key,headRevision:.init("h"),title:"fresh provider",state:.closed,isDraft:false)
        await gate.release(.init(events:[unrelated],pullRequests:[later]));_ = try await fresh.value
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.title,"fresh provider")
        let after=await sink.summaries;XCTAssertEqual(after.count,1,"Own confirmed mutation and a duplicate unrelated event must not create another summary")
    }
    func testHeldMutableDetailResponseIsRejectedAfterConfirmedSameHeadWrite() async throws {
        let transport=ScriptedTransport.suspended(),budget=RateBudget(minimumSpacing:.zero)
        let (db,session,_,_)=try fixture(transport:transport,budget:budget)
        var metadata=PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r")
        metadata.baseRevision="t"
        let old=PullRequest(key:key,headRevision:.init("h"),title:"before",state:.open,isDraft:false,metadata:metadata)
        try db.savePullRequests([old])
        let service=PRDetailService(session:session,budget:budget,clientID:"fixture")
        let task=Task { try await service.section(old,tab:.conversation) }
        await transport.waitUntilHolding()
        let current=PullRequest(key:key,headRevision:.init("h"),title:"confirmed",state:.closed,isDraft:false,metadata:metadata)
        let operation=try await session.authenticatedOperation(for:key.account,clientID:"fixture")
        let applied=try await session.withCurrentOperation(operation,body:{ try $0.confirmWrite(current) });XCTAssertTrue(applied)
        await transport.release(json("[]"))
        do { _ = try await task.value;XCTFail("Old same-head mutable detail must be fenced") } catch { XCTAssertTrue(error is CancellationError) }
        let fresh=try await service.section(current,tab:.conversation);XCTAssertTrue(fresh.complete)
        XCTAssertEqual(try db.snapshot(for:key.account).pullRequests.first?.title,"confirmed")
    }
}

extension PRWriteCoordinatorTests {
    func testKnownProviderPermissionDenialAfterAdmissionIsRejectedAndDraftPreserved() async throws {
        let transport=writeTransport(),budget=RateBudget(minimumSpacing:.zero);await transport.answerRemaining(json("{}",status:403))
        let (db,session,command,adapter)=try fixture(transport:transport,budget:budget)
        let draft=ReviewDraft(key:key,revision:command.revision,summary:"saved body");try DraftReviewStore(database:db).save(draft)
        do { _ = try await coordinator(db,session,budget,adapter).perform(command);XCTFail() } catch { XCTAssertEqual(error as? GitHubFailure,.resourceDenied) }
        XCTAssertEqual(try DraftReviewStore(database:db).operations(key).first?.state,.rejected)
        XCTAssertEqual(try DraftReviewStore(database:db).load(key),draft)
    }
    func testLocalSentMarkerPersistenceFailureSendsNothingAndIsExplicitlyBeforeSend() async throws {
        let transport=writeTransport(),budget=RateBudget(minimumSpacing:.zero)
        let (db,session,command,adapter)=try fixture(transport:transport,budget:budget)
        try await db.database.write { try $0.execute(sql:"CREATE TRIGGER fail_sent_marker BEFORE UPDATE ON reviewOperations WHEN CAST(NEW.json AS TEXT) LIKE '%\"state\":\"sending\"%' BEGIN SELECT RAISE(ABORT,'fixture disk failure'); END") }
        do { _ = try await coordinator(db,session,budget,adapter).perform(command);XCTFail() } catch { XCTAssertEqual(error as? PRWriteFailure,.persistenceBeforeSend) }
        let writes=await transport.count;XCTAssertEqual(writes,0)
        XCTAssertEqual(try DraftReviewStore(database:db).operations(key).first?.state,.rejected)
    }
}

extension PRWriteCoordinatorTests {
    func testProviderReceiptStaysUncertainWhenPostSendReauthorizationFails() async throws {
        let transport=ScriptedTransport(fallback:json(#"{"id":"created"}"#,status:201)),budget=RateBudget(minimumSpacing:.zero)
        let (db,session,command,adapter)=try fixture(transport:transport,budget:budget)
        let account=key.account
        // GitHub received the POST; the account is then flagged before read-back reconciliation.
        await transport.beforeAnswering { _ in try db.setSetting("true",for:"authorizationProblem",account:account) }
        let result=try await coordinator(db,session,budget,adapter).perform(command)
        XCTAssertEqual(result.state,.uncertain)
        XCTAssertEqual(try DraftReviewStore(database:db).operation(result.id)?.state,.uncertain)
        let writes=await transport.count;XCTAssertEqual(writes,1)
    }
}

extension PRWriteCoordinatorTests {
    func testOtherConfirmedIntentsKeepCachedLabelColorsWhenFreshReadHasNone() async throws {
        let transport=writeTransport(),budget=RateBudget(minimumSpacing:.zero)
        let (db,session,command,_)=try fixture(transport:transport,budget:budget)
        var old=PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r");old.labels=["bug"];old.labelColors=["bug":"d73a4a"]
        try db.savePullRequests([PullRequest(key:key,headRevision:.init("h"),title:"before",state:.open,isDraft:false,metadata:old)])
        var fresh=PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r");fresh.labels=["bug"]
        var truth=PRWriteTruth(key:key,revision:command.revision,viewerIsAuthor:false,canReview:true,canComment:true,canUpdate:true,canReopen:true,canLabel:true,isOpen:true,normalized:PullRequest(key:key,headRevision:.init("h"),title:"after",state:.open,isDraft:false,metadata:fresh))
        truth.labelsComplete=true
        let result=try await coordinator(db,session,budget,CoordinatorAdapter(truth)).perform(command);XCTAssertEqual(result.state,.confirmed)
        let saved=try XCTUnwrap(db.snapshot(for:key.account).pullRequests.first);XCTAssertEqual(saved.title,"after");XCTAssertEqual(saved.metadata?.labelColors,["bug":"d73a4a"])
    }
}

extension PRWriteCoordinatorTests {
    /// Comments, reviews, merges and other non-idempotent intents keep strict semantics: an unmatched read is
    /// never terminal and "Stop waiting" is refused, because resending them is not harmless.
    func testNonIdempotentUncertainWriteStaysUncertainAndCannotStopWaiting() async throws {
        let transport=writeTransport(),budget=RateBudget(minimumSpacing:.zero);await transport.answerRemaining(.lostResponse)
        let (db,session,command,adapter)=try fixture(transport:transport,budget:budget)
        let subject=coordinator(db,session,budget,adapter)
        let first=try await subject.perform(command);XCTAssertEqual(first.state,.uncertain);XCTAssertFalse(first.canStopWaiting)
        await adapter.confirming(false)
        let again=try await subject.reconcile(first.id);XCTAssertEqual(again.state,.uncertain,"An unmatched read never settles a comment")
        XCTAssertThrowsError(try subject.abandonUncertain(first.id)) { XCTAssertEqual($0 as? PRWriteFailure,.uncertain) }
        XCTAssertEqual(try DraftReviewStore(database:db).operation(first.id)?.state,.uncertain)
        let writes=await transport.count;XCTAssertEqual(writes,1)
    }
}
