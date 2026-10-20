import XCTest
@testable import MergeProCore

private actor ThreadTransport:GitHubTransport {
    var requests:[URLRequest]=[]
    var unread=true
    var lose=false,denied=false,missing=false
    var readsDenied=false
    var holdRead=false
    var gate:CheckedContinuation<Void,Never>?
    func configure(lose:Bool=false,denied:Bool=false,missing:Bool=false,hold:Bool=false) { self.lose=lose;self.denied=denied;self.missing=missing;holdRead=hold }
    func release() { holdRead=false;gate?.resume();gate=nil }
    var waiting:Bool { gate != nil }
    func denyReads() { readsDenied=true }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        requests.append(request)
        guard request.url?.host == "api.github.com",request.url?.path == "/notifications/threads/99" else { throw GitHubFailure.unsafeURL }
        if request.httpMethod == "GET" {
            if holdRead { await withCheckedContinuation { gate=$0 } }
            if readsDenied { return .init(status:401) }
            if missing { return .init(status:404) }
            return .init(status:200,data:Data("{\"id\":\"99\",\"unread\":\(unread),\"repository\":{\"id\":7}}".utf8))
        }
        if denied { return .init(status:403) }
        unread=false
        if lose { throw URLError(.networkConnectionLost) }
        return .init(status:request.httpMethod == "DELETE" ? 204 : 205)
    }
    var methods:[String] { requests.map { $0.httpMethod ?? "GET" } }
}
@MainActor final class NotificationThreadTests:XCTestCase {
    let scope=AccountScope(host:"github.com",accountID:"42")
    func event(object:String="notification-thread:99",key:String="event") -> ChangeEvent {
        .init(key:key,object:.init(host:scope.host,accountID:scope.accountID,repositoryID:"7",objectID:object),category:"repository activity signals",occurredAt:Date())
    }
    private func fixture(_ transport:ThreadTransport,token:String="fixture",scopes:Set<String>=["notifications"],budget:RateBudget = .init(minimumSpacing:.zero)) throws -> (DatabaseStore,GitHubAccountSession,NotificationThreadCoordinator) {
        let fixture=try makeSessionFixture(account:scope,repositories:[.fixture(.init(account:scope,repositoryID:"7"))],transport:transport,credential:.init(accessToken:token,scopes:scopes))
        let (db,session)=(fixture.database,fixture.session)
        let cycle=UUID(),poll=PollCycleStore(database:db)
        try poll.begin(cycle,at:Date(),baseline:false);try poll.record([event(),event(key:"unrelated")],cycleID:cycle)
        let subject=NotificationThreadCoordinator(database:db,session:session,budget:budget,clientID:"fixture",activeAccount:fixture.activeAccount)
        return (db,session,subject)
    }
    func testExplicitReleaseOnlyAbandonsPreparedAndPreservesPossiblySent() async throws {
        let transport=ThreadTransport(),(db,_,subject)=try fixture(transport)
        let prepared=NotificationThreadOperation(command:try .init(event:event(),intent:.read))
        try db.prepareNotificationThread(prepared)
        try db.releaseUnsentNotificationThread(prepared.id)
        XCTAssertEqual(try db.notificationThreadOperation(prepared.id)?.state,.rejected)
        await transport.configure(lose:true)
        let sent=try await subject.perform(.init(event:event(),intent:.done))
        XCTAssertThrowsError(try db.releaseUnsentNotificationThread(sent.id))
        XCTAssertEqual(try db.notificationThreadOperation(sent.id)?.state,.uncertain)
        let methods=await transport.methods;XCTAssertEqual(methods,["GET","DELETE"])
    }
    func testExplicitReadAndDoneUseThreadTransportAndOnlyAcknowledgeTheirRow() async throws {
        let transport=ThreadTransport(),(db,_,subject)=try fixture(transport)
        let read=try await subject.perform(.init(event:event(),intent:.read))
        XCTAssertEqual(read.state,.confirmed)
        let done=try await subject.perform(.init(event:event(),intent:.done))
        XCTAssertEqual(done.state,.confirmed)
        let methods=await transport.methods;XCTAssertEqual(methods,["GET","PATCH","GET","DELETE"])
        let inbox=try PollCycleStore(database:db).inbox()
        XCTAssertTrue(inbox.first { $0.id == "event" }!.acknowledged)
        XCTAssertFalse(inbox.first { $0.id == "unrelated" }!.acknowledged)
        XCTAssertEqual(inbox.count,2,"Receipts never generate poll events or summaries")
    }
    func testLostReadResponseReconcilesWithoutRepeatingMutation() async throws {
        let transport=ThreadTransport();await transport.configure(lose:true)
        let (db,_,subject)=try fixture(transport)
        let sent=try await subject.perform(.init(event:event(),intent:.read))
        XCTAssertEqual(sent.state,.uncertain)
        XCTAssertFalse(try PollCycleStore(database:db).inbox().first { $0.id == "event" }!.acknowledged)
        let confirmed=try await subject.reconcile(sent.id);XCTAssertEqual(confirmed.state,.confirmed)
        let methods=await transport.methods;XCTAssertEqual(methods,["GET","PATCH","GET"])
    }
    func testLostDoneResponseCannotBeProvenByReadOrMissingThreadAndCannotReplay() async throws {
        let transport=ThreadTransport();await transport.configure(lose:true)
        let (db,_,subject)=try fixture(transport)
        let sent=try await subject.perform(.init(event:event(),intent:.done))
        XCTAssertEqual(sent.state,.uncertain)
        let uncertain=try await subject.reconcile(sent.id);XCTAssertEqual(uncertain.state,.uncertain)
        await transport.configure(missing:true)
        let missing=try await subject.reconcile(sent.id);XCTAssertEqual(missing.state,.uncertain)
        do { _=try await subject.perform(.init(event:event(),intent:.done));XCTFail("Unresolved Done must not replay") } catch { }
        XCTAssertFalse(try PollCycleStore(database:db).inbox().first { $0.id == "event" }!.acknowledged)
        let methods=await transport.methods;XCTAssertEqual(methods.filter { $0 == "DELETE" }.count,1)
    }
    func testAccountSwitchDuringPreflightRejectsBeforeSend() async throws {
        let transport=ThreadTransport();await transport.configure(hold:true)
        let (db,_,subject)=try fixture(transport)
        let command=try NotificationThreadCommand(event:event(),intent:.read)
        let task=Task { try await subject.perform(command) }
        while !(await transport.waiting),!task.isCancelled { await Task.yield() }
        try db.setApplicationSetting("other",for:"activeActionAccount");await transport.release()
        do { _=try await task.value;XCTFail() } catch { }
        XCTAssertEqual(try db.notificationThreadOperations().first?.state,.rejected)
        let methods=await transport.methods;XCTAssertEqual(methods,["GET"])
    }
    func testMutationDenialIsRejectedButPostSendReadDenialKeepsUncertainty() async throws {
        let transport=ThreadTransport();await transport.configure(denied:true)
        let (db,_,subject)=try fixture(transport)
        do { _=try await subject.perform(.init(event:event(),intent:.read));XCTFail() } catch { }
        XCTAssertEqual(try db.notificationThreadOperations().last?.state,.rejected)
        await transport.configure(lose:true)
        let lost=try await subject.perform(.init(event:event(),intent:.done))
        await transport.denyReads()
        let denied=try await subject.reconcile(lost.id);XCTAssertEqual(denied.state,.uncertain)
        XCTAssertEqual(try db.notificationThreadOperation(lost.id)?.state,.uncertain)
    }
    func testUserMarkReadIsInteractiveSoThePollingReserveCannotBlockIt() async throws {
        let budget=RateBudget(minimumSpacing:.zero,interactiveReserve:100)
        // Background polling has spent the quota down to the interactive reserve.
        await budget.observe(.init(status:200,headers:["X-RateLimit-Remaining":"50","X-RateLimit-Reset":String(Date().addingTimeInterval(3600).timeIntervalSince1970)]),account:scope)
        let transport=ThreadTransport(),(_,_,subject)=try fixture(transport,budget:budget)
        let read=try await subject.perform(.init(event:event(),intent:.read))
        XCTAssertEqual(read.state,.confirmed)
        let methods=await transport.methods;XCTAssertEqual(methods,["GET","PATCH"])
    }
    func testSyntheticThreadSpoofAndUnsupportedTokensNeverDispatch() async throws {
        XCTAssertThrowsError(try NotificationThreadCommand(event:event(object:"pull-request:99"),intent:.read))
        XCTAssertThrowsError(try NotificationThreadCommand(event:event(object:"notification-thread:99/other"),intent:.done))
        let transport=ThreadTransport(),(_,_,subject)=try fixture(transport,token:"github_pat_fixture")
        do { _=try await subject.perform(.init(event:event(),intent:.read));XCTFail() } catch { }
        let methods=await transport.methods;XCTAssertTrue(methods.isEmpty)
    }
}
