import XCTest
@testable import MergeProCore

final class PollAdmissionTests: XCTestCase {
    func testInteractiveReadChainDoesNotReserveBackgroundDelayButStillHonorsBackoff() async throws {
        // Background reads and writes are both paced two seconds apart: any reservation would cost that much.
        let spacing=Duration.seconds(2)
        let budget=RateBudget(minimumSpacing:spacing,backgroundReadSpacing:spacing)
        let account=AccountScope(host:"github.com",accountID:"1")
        try await budget.acquire(account:account,resource:.rest,priority:.interactive,interactiveRead:true)
        let start=ContinuousClock.now
        try await budget.acquire(account:account,resource:.rest,priority:.interactive,interactiveRead:true)
        XCTAssertLessThan(start.duration(to:.now),spacing/2)
        await budget.observe(json("{}",status:429,headers:["Retry-After":"60"]),account:account)
        do { try await budget.acquire(account:account,resource:.rest,priority:.interactive,interactiveRead:true);XCTFail("Interactive reads must still honor provider backoff") }
        catch { XCTAssertNotNil(error as? GitHubFailure) }
    }
    func testManualRefreshStillHonorsServerNotificationIntervalWithoutBlockingInventory() async {
        let budget = RateBudget(minimumSpacing: .zero)
        let account = AccountScope(host: "github.com", accountID: "1")
        await budget.observePollInterval(json("[]", headers: ["X-Poll-Interval": "60"]), account: account, feature: "notifications:1")
        let notification = await budget.beginPoll(account: account, feature: "notifications:1", interval: 0, force: true)
        let inventory = await budget.beginPoll(account: account, feature: "inventory:1", interval: 60, force: true)
        XCTAssertFalse(notification)
        XCTAssertTrue(inventory)
    }
    func testNotificationResponseDoesNotPostponeDuePRInventory() async {
        let budget = RateBudget(minimumSpacing: .zero)
        let account = AccountScope(host: "github.com", accountID: "1")
        let feature = "github-pr-inventory:1"
        await budget.completePoll(account: account, feature: feature, interval: 0)
        await budget.observe(json("[]", headers: ["X-Poll-Interval": "60"]), account: account)
        let admitted = await budget.beginPoll(account: account, feature: feature, interval: 60)
        XCTAssertTrue(admitted, "Notification pacing must not starve a due inventory read")
    }
}
