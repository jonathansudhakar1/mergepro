import Foundation
import XCTest
@testable import MergeProCore

final class NotificationPolicyAssemblyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970:1_800_000_000)
    private let live = AccountScope(host:"github.com", accountID:"1")
    private let blocked = AccountScope(host:"github.com", accountID:"2")
    private var alpha: RepositoryKey { RepositoryKey(account:live, repositoryID:"10") }
    private var beta: RepositoryKey { RepositoryKey(account:live, repositoryID:"11") }
    private var gamma: RepositoryKey { RepositoryKey(account:blocked, repositoryID:"20") }

    private func pr(_ number: Int, in repository: RepositoryKey, name: String) -> PullRequest {
        var metadata = PRMetadata(number:number, webURL:URL(string:"https://github.com/\(name)/pull/\(number)")!, repositoryName:name)
        metadata.updatedAt = now; metadata.createdAt = now
        return PullRequest(key:ProviderKey(host:repository.account.host, accountID:repository.account.accountID, repositoryID:repository.repositoryID,
                                           objectID:"pull-request:\(number)"), headRevision:RevisionID("sha"), title:"Fixture \(number)", state:.open, isDraft:false, metadata:metadata)
    }
    private func event(_ key: String, object: ProviderKey, locator: EventLocator? = nil) -> ChangeEvent {
        ChangeEvent(key:key, object:object, category:"update", occurredAt:now, locator:locator)
    }
    private func database(rule: Bool) throws -> DatabaseStore {
        let database = try DatabaseStore(path:":memory:")
        for (account, repositories) in [(live, [(alpha, "o/alpha"), (beta, "o/beta")]), (blocked, [(gamma, "o/gamma")])] {
            try database.saveAccount(Account(scope:account, login:"fixture-" + account.accountID))
            for (key, name) in repositories {
                try database.saveRepository(Repository(key:key, name:name, isPrivate:false, capabilities:ProviderCapabilities()))
                try database.setTracked(key, tracked:true)
            }
        }
        try database.setSetting("true", for:.notificationsMuted, account:blocked)
        try database.setSetting("true", for:.notificationsMuted(repositoryID:beta.repositoryID), account:live)
        try database.setSetting("false", for:.notificationsMuted(repositoryID:alpha.repositoryID), account:live)
        try database.setSetting("true", for:.notificationsMuted(repositoryID:gamma.repositoryID), account:blocked)
        try database.setPinned(ProviderKey(host:live.host, accountID:live.accountID, repositoryID:alpha.repositoryID, objectID:"repository"), pinned:true)
        if rule {
            var state = PRViewState()
            var view = PRSavedView(name:"Alpha rule")
            view.notificationRule = true
            view.configuration.filter = try FilterExpression.parse("repo:o/alpha")
            state.views.append(view)
            try PullRequestStore(database:database).save(state)
        }
        return database
    }
    private let available: @Sendable (AccountScope) async throws -> Bool = { $0.accountID == "1" }

    func testScopeAppliesTheAuthorizationOverlayButKeepsEveryMute() async throws {
        let scope = try await NotificationPolicyAssembly.scope(database:database(rule:true), isAvailable:available)
        XCTAssertEqual(scope.mutedAccounts, [blocked])
        XCTAssertEqual(scope.mutedRepositories, [beta, gamma])
        XCTAssertEqual(scope.allowedRepositories, [alpha, beta], "a blocked account's repositories are never allowed")
        XCTAssertEqual(Set(scope.liveRepositories.map(\.key)), [alpha, beta])
        XCTAssertEqual(scope.livePins, [alpha])
        XCTAssertEqual(scope.rules.map(\.name), ["Alpha rule"])
    }

    func testSettingsBecomeThePolicyAndUnsetOnesStayOff() async throws {
        let database = try database(rule:false)
        let scope = try await NotificationPolicyAssembly.scope(database:database, isAvailable:available)
        var policy = try NotificationPolicyAssembly.policy(scope:scope, ruleRows:[], pendingEvents:[], database:database, now:now)
        XCTAssertFalse(policy.enabled)
        XCTAssertNil(policy.snoozedUntil)
        XCTAssertNil(policy.quietHours)
        try database.setApplicationSetting("true", for:.notificationsEnabled)
        try database.setApplicationSetting("1900000000", for:.notificationSnoozedUntil)
        try database.setApplicationSetting("1320", for:.quietHoursStartMinute)
        policy = try NotificationPolicyAssembly.policy(scope:scope, ruleRows:[], pendingEvents:[], database:database, now:now)
        XCTAssertNil(policy.quietHours, "quiet hours need both bounds")
        try database.setApplicationSetting("420", for:.quietHoursEndMinute)
        policy = try NotificationPolicyAssembly.policy(scope:scope, ruleRows:[], pendingEvents:[], database:database, now:now)
        XCTAssertTrue(policy.enabled)
        XCTAssertEqual(policy.snoozedUntil, Date(timeIntervalSince1970:1_900_000_000))
        XCTAssertEqual(policy.quietHours?.startMinute, 1320)
        XCTAssertEqual(policy.quietHours?.endMinute, 420)
        XCTAssertEqual(policy.mutedAccounts, [blocked])
        XCTAssertEqual(policy.mutedRepositories, [beta, gamma])
        XCTAssertEqual(policy.allowedRepositories, [alpha, beta])
    }

    func testRuleViewsSelectEventsByPullRequestKeyOrRepositoryAndNumber() async throws {
        let rows = [pr(1, in:alpha, name:"o/alpha"), pr(2, in:beta, name:"o/beta")]
        let thread = ProviderKey(host:live.host, accountID:live.accountID, repositoryID:alpha.repositoryID, objectID:"thread-9")
        let otherThread = ProviderKey(host:live.host, accountID:live.accountID, repositoryID:beta.repositoryID, objectID:"thread-10")
        let events = [
            event("by-key", object:rows[0].key),
            event("by-number", object:thread, locator:EventLocator(subjectType:"PullRequest", subjectNumber:"1")),
            event("other-repository", object:rows[1].key),
            event("number-in-other-repository", object:otherThread, locator:EventLocator(subjectType:"PullRequest", subjectNumber:"1")),
            event("workflow", object:ProviderKey(host:live.host, accountID:live.accountID, repositoryID:alpha.repositoryID, objectID:"run:5"),
                  locator:EventLocator(subjectType:"WorkflowRun")),
        ]
        let database = try database(rule:true)
        let scope = try await NotificationPolicyAssembly.scope(database:database, isAvailable:available)
        let ruled = try NotificationPolicyAssembly.policy(scope:scope, ruleRows:rows, pendingEvents:events, database:database, now:now)
        XCTAssertEqual(ruled.matchingEventKeys, [["by-key", "by-number"]])

        // Without PR rules every PR event matches; workflow events need an Actions rule match (no catalog here).
        var unruled = scope; unruled.rules = []
        let open = try NotificationPolicyAssembly.policy(scope:unruled, ruleRows:[], pendingEvents:events, database:database, now:now)
        XCTAssertEqual(open.matchingEventKeys, [["by-key", "by-number", "other-repository", "number-in-other-repository"]])
    }

    func testRuleRowsOutsideTheViewsTimeScopeSelectNothing() async throws {
        var stale = pr(1, in:alpha, name:"o/alpha")
        var metadata = try XCTUnwrap(stale.metadata)
        metadata.updatedAt = now.addingTimeInterval(-90 * 86_400); metadata.createdAt = metadata.updatedAt
        stale = PullRequest(key:stale.key, headRevision:stale.headRevision, title:stale.title, state:stale.state, isDraft:false, metadata:metadata)
        let database = try database(rule:true)
        let scope = try await NotificationPolicyAssembly.scope(database:database, isAvailable:available)
        let policy = try NotificationPolicyAssembly.policy(scope:scope, ruleRows:[stale], pendingEvents:[event("by-key", object:stale.key)],
                                                           database:database, now:now)
        XCTAssertEqual(policy.matchingEventKeys, [[]])
    }
}
