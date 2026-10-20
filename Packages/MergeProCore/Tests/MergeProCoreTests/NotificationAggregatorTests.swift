import Foundation
import XCTest
@testable import MergeProCore

actor RecordingNotificationSink: NotificationSink {
    var summaries: [PollSummary] = []
    var deny = false
    func post(_ summary: PollSummary) async throws {
        summaries.append(summary)
        if deny { throw GitHubFailure.resourceDenied }
    }
    func setDenied() { deny = true }
}
private actor AttemptStoreSpy: NotificationAttemptStore {
    var reserved = Set<UUID>()
    func reserve(_ summary: PollSummary) async throws -> Bool { reserved.insert(summary.cycleID).inserted }
}
func pollEvent(_ i: Int, account: String = "1", repo: String = "1", category: String = "reviews requested") -> ChangeEvent {
    ChangeEvent(key:"\(account):\(repo):\(i):review",object:ProviderKey(host:"github.com",accountID:account,repositoryID:repo,objectID:String(i)),category:category,occurredAt:Date(timeIntervalSince1970:Double(i)))
}
@MainActor
final class NotificationAggregatorTests: XCTestCase {
    func testSamePollCannotPostTwice() async throws {
        let sink = RecordingNotificationSink()
        let publisher = PollNotificationPublisher(store:AttemptStoreSpy(),sink:sink)
        let summary = PollSummary(cycleID:UUID(),eventKeys:["review-1","check-2"],title:"MergePro updates",body:"2 updates across 2 repos")
        async let first: Void = publisher.publish(summary)
        async let second: Void = publisher.publish(summary)
        _ = try await (first,second)
        let count = await sink.summaries.count; XCTAssertEqual(count,1)
    }
    func testUnchangedPollDoesNotPost() async throws {
        let sink = RecordingNotificationSink()
        try await PollNotificationPublisher(store:AttemptStoreSpy(),sink:sink).publish(PollSummary(cycleID:UUID(),eventKeys:[],title:"MergePro updates",body:""))
        let count = await sink.summaries.count; XCTAssertEqual(count,0)
    }
    func test100EventsAcrossAccountsDuplicatePagesAndViewsProduceOneDeterministicSummary() async throws {
        let db = try DatabaseStore(path:":memory:"); let store = PollCycleStore(database:db)
        let events = (0..<100).map { pollEvent($0,account:String($0 % 2),repo:String($0 % 4)) }
        let id = UUID(); try store.begin(id,at:Date(),baseline:false)
        try store.record(events + events.reversed(),cycleID:id)
        let policy = NotificationPolicy(enabled:true,matchingEventKeys:[Set(events.map(\.key)),Set(events.map(\.key))])
        let summary = try store.close(id,at:Date(),policy:policy)
        XCTAssertEqual(summary.eventKeys,events.map(\.key).sorted())
        XCTAssertEqual(summary.body,"100 updates across 4 repos, 2 accounts: 100 reviews requested.")
        let sink = RecordingNotificationSink(); let publisher = PollNotificationPublisher(store:store,sink:sink)
        try await publisher.publish(summary); try await publisher.publish(summary)
        let calls = await sink.summaries.count; XCTAssertEqual(calls,1)
        XCTAssertEqual(try store.inbox().count,100)
    }
    func testBaselineAcknowledgementMuteSnoozeAndDisabledDeliveryPreserveInbox() async throws {
        let db = try DatabaseStore(path:":memory:"); let store = PollCycleStore(database:db)
        let baseline = UUID(); try store.begin(baseline,at:Date(),baseline:true)
        try store.record([pollEvent(1)],cycleID:baseline)
        XCTAssertTrue(try store.close(baseline,at:Date(),policy:NotificationPolicy(enabled:true)).eventKeys.isEmpty)
        let next = UUID(); try store.begin(next,at:Date(),baseline:false)
        try store.record([pollEvent(1),pollEvent(2),pollEvent(3,account:"2")],cycleID:next)
        try store.acknowledge([pollEvent(2).key])
        XCTAssertTrue(try store.close(next,at:Date(),policy:NotificationPolicy(enabled:true,mutedAccounts:[pollEvent(3,account:"2").object.account])).eventKeys.isEmpty)
        let off = UUID(); try store.begin(off,at:Date(),baseline:false)
        XCTAssertTrue(try store.close(off,at:Date(),policy:NotificationPolicy(enabled:false)).eventKeys.isEmpty)
        let snooze = UUID(); try store.begin(snooze,at:Date(),baseline:false)
        XCTAssertTrue(try store.close(snooze,at:Date(),policy:NotificationPolicy(enabled:true,snoozedUntil:Date.distantFuture)).eventKeys.isEmpty)
        XCTAssertEqual(try store.inbox().count,3)
    }
    func testQuietHoursAcrossMidnightDeferThenRevalidate() throws {
        let store = PollCycleStore(database:try DatabaseStore(path:":memory:"))
        var cal = Calendar(identifier:.gregorian); cal.timeZone = TimeZone(secondsFromGMT:0)!
        let quiet = QuietHours(startMinute:22*60,endMinute:7*60,timeZone:cal.timeZone)
        let midnight = cal.date(from:DateComponents(year:2026,month:10,day:2,hour:1))!
        let id = UUID(); try store.begin(id,at:midnight,baseline:false); try store.record([pollEvent(7)],cycleID:id)
        XCTAssertTrue(try store.close(id,at:midnight,policy:NotificationPolicy(enabled:true,quietHours:quiet)).eventKeys.isEmpty)
        let next = UUID(); let morning = midnight.addingTimeInterval(7*3600)
        try store.begin(next,at:morning,baseline:false)
        XCTAssertEqual(try store.close(next,at:morning,policy:NotificationPolicy(enabled:true,quietHours:quiet)).eventKeys,[pollEvent(7).key])
    }
    func testDeniedSinkIsReservedAndNeverRetriedAfterDurableRestart() async throws {
        let path = try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path
        var store: PollCycleStore? = PollCycleStore(database:try DatabaseStore(path:path))
        let id = UUID(); try store!.begin(id,at:Date(),baseline:false); try store!.record([pollEvent(1)],cycleID:id)
        let summary = try store!.close(id,at:Date(),policy:NotificationPolicy(enabled:true))
        let sink = RecordingNotificationSink(); await sink.setDenied()
        do { try await PollNotificationPublisher(store:store!,sink:sink).publish(summary); XCTFail("denial must surface") } catch {}
        store = nil
        let reopened = PollCycleStore(database:try DatabaseStore(path:path))
        try await PollNotificationPublisher(store:reopened,sink:sink).publish(summary)
        let count = await sink.summaries.count; XCTAssertEqual(count,1)
        XCTAssertEqual(try reopened.inbox().count,1)
        XCTAssertEqual(try reopened.attemptState(id),"failed")
        let later = UUID(); try reopened.begin(later,at:Date(),baseline:false)
        XCTAssertTrue(try reopened.close(later,at:Date(),policy:NotificationPolicy(enabled:true)).eventKeys.isEmpty)
    }
    func testCrashBetweenReservationAndSinkRetainsInboxWithoutReplay() async throws {
        let path = try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path
        var store: PollCycleStore? = PollCycleStore(database:try DatabaseStore(path:path))
        let id = UUID(); try store!.begin(id,at:Date(),baseline:false); try store!.record([pollEvent(9)],cycleID:id)
        let summary = try store!.close(id,at:Date(),policy:NotificationPolicy(enabled:true))
        let reserved = try await store!.reserve(summary); XCTAssertTrue(reserved); store = nil
        let restarted = PollCycleStore(database:try DatabaseStore(path:path)); let sink = RecordingNotificationSink()
        try await PollNotificationPublisher(store:restarted,sink:sink).publish(summary)
        let count = await sink.summaries.count; XCTAssertEqual(count,0)
        XCTAssertEqual(try restarted.inbox().count,1)
        XCTAssertEqual(try restarted.attemptState(id),"reserved")
    }
    func testMutedRepoTeamAndSavedViewFiltersRemainDurableAndRevalidate() throws {
        let store = PollCycleStore(database:try DatabaseStore(path:":memory:"))
        let a = pollEvent(1,repo:"1"); let b = pollEvent(2,repo:"2")
        let team = ChangeEvent(key:"team:transition",object:a.object,category:"reviews requested",occurredAt:Date(),teams:["org/team"])
        let id = UUID(); try store.begin(id,at:Date(),baseline:false); try store.record([a,b,team],cycleID:id)
        let summary = try store.close(id,at:Date(),policy:NotificationPolicy(enabled:true,mutedRepositories:[b.object.repository],mutedTeams:["org/team"],matchingEventKeys:[[a.key,b.key,team.key],[a.key]]))
        XCTAssertEqual(summary.eventKeys,[a.key]); XCTAssertEqual(try store.inbox().count,3)
        let next = UUID(); try store.begin(next,at:Date(),baseline:false)
        XCTAssertTrue(try store.close(next,at:Date(),policy:NotificationPolicy(enabled:true,allowedRepositories:[])).eventKeys.isEmpty)
    }
    func testInterruptedOpenCycleCannotReserveAndDoesNotLoseEvents() async throws {
        let store = PollCycleStore(database:try DatabaseStore(path:":memory:"))
        let old = UUID(); try store.begin(old,at:Date(),baseline:false); try store.record([pollEvent(8)],cycleID:old)
        try store.recoverInterruptedCycles()
        do { _ = try await store.reserve(PollSummary(cycleID:old,eventKeys:[pollEvent(8).key],title:"MergePro updates",body:"")); XCTFail("interrupted cycle cannot reserve") } catch {}
        let next = UUID(); try store.begin(next,at:Date(),baseline:false)
        XCTAssertEqual(try store.close(next,at:Date(),policy:NotificationPolicy(enabled:true)).eventKeys,[pollEvent(8).key])
    }

}
