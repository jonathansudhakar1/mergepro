import Foundation
import XCTest
@testable import MergeProCore

final class NotificationTextTests: XCTestCase {
    private let alice = AccountScope(host: "github.com", accountID: "11")
    private let bob = AccountScope(host: "github.com", accountID: "22")
    private func prEvent(_ number: Int, account: AccountScope? = nil, category: String = "review requested", title: String = "Rotate the signing keys",
                         thread: Bool = false, repository: String = "acme/widgets", repositoryID: String = "7") -> ChangeEvent {
        let account = account ?? alice
        let object = ProviderKey(host: account.host, accountID: account.accountID, repositoryID: repositoryID,
                                 objectID: thread ? "notification-thread:\(number)" : "pull-request:NODE\(number)")
        return ChangeEvent(key: "\(account.accountID):\(repositoryID):\(number):\(category):\(thread)", object: object, category: category,
                           occurredAt: Date(timeIntervalSince1970: Double(number)), title: title,
                           locator: EventLocator(subjectType: "PullRequest", subjectNumber: String(number),
                                                 webURL: URL(string: "https://github.com/\(repository)/pull/\(number)")))
    }

    func testFewPullRequestsNotifyIndividuallyWithRepositoryNumberAndReadableReason() throws {
        let events = [prEvent(12), prEvent(12, category: "review request signals", thread: true), prEvent(12, category: "checks"), prEvent(13, category: "ready to merge")]
        let summary = NotificationAggregator.summary(cycleID: UUID(), events: events)
        XCTAssertEqual(summary.eventKeys, events.map(\.key).sorted())
        XCTAssertEqual(summary.items.count, 2)
        let first = try XCTUnwrap(summary.items.first { $0.number == "12" })
        XCTAssertEqual(first.eventKeys, [events[0].key, events[1].key, events[2].key].sorted())
        XCTAssertEqual(first.pullRequest, events[0].object, "the inventory event carries the pull request's own key")
        let text = first.content(showingTitles: false)
        XCTAssertEqual(text.title, "acme/widgets#12")
        XCTAssertEqual(text.body, "Review requested, checks changed")
        XCTAssertTrue(first.offersReview)
        let second = try XCTUnwrap(summary.items.first { $0.number == "13" }).content(showingTitles: false)
        XCTAssertEqual(second.title, "acme/widgets#13")
        XCTAssertEqual(second.body, "Ready to merge")
    }

    func testPullRequestTitlesAppearOnlyWhenAllowed() throws {
        let item = try XCTUnwrap(NotificationAggregator.summary(cycleID: UUID(), events: [prEvent(4)]).items.first)
        let hidden = item.content(showingTitles: false)
        XCTAssertEqual(hidden.subtitle, "")
        XCTAssertFalse([hidden.title, hidden.subtitle, hidden.body].joined().contains("Rotate"), "private titles must stay off the lock screen by default")
        XCTAssertEqual(item.content(showingTitles: true).subtitle, "Rotate the signing keys")
    }

    func testMergedAndFeedOnlyPullRequestsDoNotOfferReviewOrInventAKey() throws {
        let merged = try XCTUnwrap(NotificationAggregator.summary(cycleID: UUID(), events: [prEvent(5, category: "merged")]).items.first)
        XCTAssertFalse(merged.offersReview)
        XCTAssertEqual(merged.content(showingTitles: false).body, "Merged")
        let signal = try XCTUnwrap(NotificationAggregator.summary(cycleID: UUID(), events: [prEvent(6, category: "mention signals", thread: true)]).items.first)
        XCTAssertNil(signal.pullRequest, "a notification thread is not the pull request")
        XCTAssertEqual(signal.webURL, URL(string: "https://github.com/acme/widgets/pull/6"))
        XCTAssertEqual(signal.content(showingTitles: false).body, "You were mentioned")
    }

    func testSamePullRequestThroughTwoAccountsStaysSeparate() {
        let summary = NotificationAggregator.summary(cycleID: UUID(), events: [prEvent(9), prEvent(9, account: bob)])
        XCTAssertEqual(Set(summary.items.map(\.account)), [alice, bob])
        XCTAssertEqual(Set(summary.items.map(\.id)).count, 2)
    }

    func testWorkflowRunNamesRepositoryAndHidesWorkflowNameByDefault() throws {
        let run = ChangeEvent(key: "run", object: ProviderKey(host: "github.com", accountID: "11", repositoryID: "7", objectID: "run:5:1"), category: "workflow failures",
                              occurredAt: Date(), title: "Deploy", locator: EventLocator(subjectType: "WorkflowRun", subjectNumber: "5", webURL: URL(string: "https://github.com/acme/widgets/actions/runs/5")))
        let item = try XCTUnwrap(NotificationAggregator.summary(cycleID: UUID(), events: [run]).items.first)
        XCTAssertFalse(item.offersReview)
        XCTAssertNil(item.pullRequest)
        XCTAssertEqual(item.content(showingTitles: false), NotificationContent(title: "acme/widgets", subtitle: "", body: "Workflow failed"))
        XCTAssertEqual(item.content(showingTitles: true).subtitle, "Deploy")
    }

    func testFiveSubjectsNotifyIndividuallyAndSixCollapseToOneReadableSummary() {
        let five = NotificationAggregator.summary(cycleID: UUID(), events: (1...5).map { prEvent($0) })
        XCTAssertEqual(five.items.count, NotificationAggregator.individualLimit)
        let events = (1...6).map { prEvent($0) } + [prEvent(6, category: "checks")]
        let six = NotificationAggregator.summary(cycleID: UUID(), events: events)
        XCTAssertTrue(six.items.isEmpty)
        XCTAssertEqual(six.eventKeys.count, 7)
        XCTAssertEqual(six.title, "MergePro updates")
        XCTAssertEqual(six.body, "7 updates across 1 repo, 1 account: 1 check update, 6 review requests.")
        XCTAssertFalse(six.body.contains("Rotate"), "a collapsed summary never carries titles")
    }

    func testSummaryWithoutItemsStillDecodes() throws {
        let legacy = Data(#"{"cycleID":"6A0F2A39-5A46-4F55-9C34-6B8B3E1F2C11","eventKeys":["a"],"title":"MergePro updates","body":"1 updates"}"#.utf8)
        let decoded = try JSONDecoder().decode(PollSummary.self, from: legacy)
        XCTAssertEqual(decoded.items, [])
        XCTAssertEqual(decoded.eventKeys, ["a"])
        let current = NotificationAggregator.summary(cycleID: UUID(), events: [prEvent(1)])
        XCTAssertEqual(try JSONDecoder().decode(PollSummary.self, from: JSONEncoder.stable.encode(current)), current)
    }

    func testSnoozeDurations() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 22, minute: 30)))
        XCTAssertEqual(NotificationSnooze(setting: nil), .fifteenMinutes)
        XCTAssertEqual(NotificationSnooze(setting: "unexpected"), .fifteenMinutes)
        XCTAssertEqual(NotificationSnooze.fifteenMinutes.until(now, calendar: calendar), now.addingTimeInterval(15 * 60))
        XCTAssertEqual(NotificationSnooze(setting: NotificationSnooze.oneHour.rawValue).until(now, calendar: calendar), now.addingTimeInterval(3600))
        XCTAssertEqual(NotificationSnooze.untilTomorrow.until(now, calendar: calendar), calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 8)))
    }
}
