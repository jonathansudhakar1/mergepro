import XCTest
@testable import MergeProCore

final class ActionsRepositoryFilterTests: XCTestCase {
    private func repository(_ account: String, host: String = "github.com", id: String = "1") -> Repository {
        .init(key: .init(account: .init(host: host, accountID: account), repositoryID: id), name: "team/project", isPrivate: false, capabilities: [])
    }
    private func run(_ repository: Repository) -> WorkflowRun {
        .init(repository: repository, runID: 3, workflowID: 2, attempt: 1, name: "CI", branch: "main", headSHA: "abc", event: "push", actor: "actor", status: "completed", conclusion: "success", createdAt: .distantPast, updatedAt: .distantPast)
    }
    func testRepositorySelectionExcludesSameRepositoryThroughAnotherAccountOrHost() {
        let selected = repository("alice")
        var filter = ActionsFilter()
        filter.repositoryKey = selected.key
        XCTAssertTrue(filter.matches(run(selected)))
        XCTAssertFalse(filter.matches(run(repository("bob"))))
        XCTAssertFalse(filter.matches(run(repository("alice", host: "enterprise.example"))))
        XCTAssertFalse(filter.matches(run(repository("alice", id: "2"))))
        XCTAssertTrue(filter.matches(repository: selected))
        XCTAssertFalse(filter.matches(repository: repository("bob")))
    }
    func testAllRepositoriesRestoresBothAccountsWithoutClearingOtherFilters() {
        var filter = ActionsFilter()
        filter.repositoryKey = repository("alice").key
        filter.branch = "main"
        filter.repositoryKey = nil
        XCTAssertTrue(filter.matches(run(repository("alice"))))
        XCTAssertTrue(filter.matches(run(repository("bob"))))
        XCTAssertEqual(filter.branch, "main")
    }
    func testSelectedRepositoryStillRespectsOrganizationFilter() {
        var filter = ActionsFilter()
        filter.repositoryKey = repository("alice").key
        filter.organization = "other-team"
        XCTAssertFalse(filter.matches(repository: repository("alice")))
        XCTAssertFalse(filter.matches(run(repository("alice"))))
    }
    func testScopedSelectionSurvivesSavedViewEncoding() throws {
        var state = ActionsViewState()
        state.filter.repositoryKey = repository("alice").key
        state.savedViews = [.init(name: "Project", filter: state.filter)]
        let decoded = try JSONDecoder().decode(ActionsViewState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.filter.repositoryKey, repository("alice").key)
        XCTAssertFalse(decoded.savedViews[0].filter.matches(run(repository("bob"))))
    }
    func testViewForAnotherAccountsRepositoryIsSavedWithThatAccount() {
        let alice = repository("alice"), bob = repository("bob")
        let states: [AccountScope: ActionsViewState] = [alice.key.account: .init(), bob.key.account: .init()]
        let previous = ActionsViewState.aggregate(states)
        var filter = ActionsFilter()
        filter.repositoryKey = bob.key
        var edited = previous
        edited.savedViews = [.init(name: "Bob CI", filter: filter, notificationRule: true), .init(name: "Everything", filter: .init())]
        // "Save view for account" still points at the first account.
        let distributed = ActionsViewState.distributingEdits(from: previous, to: edited, states: states, newViewsAccount: alice.key.account)
        XCTAssertEqual(distributed[bob.key.account]?.savedViews.map(\.name), ["Bob CI"])
        XCTAssertEqual(distributed[alice.key.account]?.savedViews.map(\.name), ["Everything"])
        XCTAssertEqual(ActionsViewState.owner(of: filter, newViewsAccount: alice.key.account), bob.key.account)
        XCTAssertEqual(ActionsViewState.owner(of: .init(), newViewsAccount: alice.key.account), alice.key.account)
    }
    func testRuleFiledUnderAnotherAccountDoesNotSilenceThatAccountsRuns() throws {
        let store = try ActionsStore(database: DatabaseStore(path: ":memory:"))
        let alice = repository("alice"), bob = repository("bob", id: "2")
        let aliceRun = run(alice), bobRun = run(bob)
        try store.save(ActionsCatalog(repository: alice, runs: [aliceRun], workflows: [], deployments: [], environments: []))
        try store.save(ActionsCatalog(repository: bob, runs: [bobRun], workflows: [], deployments: [], environments: []))
        // Saved before the fix: Alice's account holds a notification rule for Bob's repository.
        var filter = ActionsFilter()
        filter.repositoryKey = bob.key
        var misfiled = ActionsViewState()
        misfiled.savedViews = [.init(name: "Bob CI", filter: filter, notificationRule: true)]
        try store.saveViewState(misfiled, account: alice.key.account)
        let events = [aliceRun, bobRun].map {
            ChangeEvent(key: "run:" + $0.repository.key.account.accountID, object: $0.key, category: "workflow status", occurredAt: .distantPast,
                        locator: .init(subjectType: "WorkflowRun", subjectNumber: String($0.runID)))
        }
        XCTAssertEqual(try store.matchingEventKeys(events: events, repositories: [alice, bob]), Set(events.map(\.key)))
        // Filed with its own account, the rule keeps selecting only matching runs.
        var bobRule = ActionsViewState()
        var other = filter
        other.branch = "release"
        bobRule.savedViews = [.init(name: "Bob release", filter: other, notificationRule: true)]
        try store.saveViewState(bobRule, account: bob.key.account)
        XCTAssertEqual(try store.matchingEventKeys(events: events, repositories: [alice, bob]), ["run:alice"])
    }
    func testLegacySavedRepositoryIDDecodesAndKeepsItsFilter() throws {
        var old = ActionsFilter()
        old.repositoryID = "1"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "repositoryKey")
        let decoded = try JSONDecoder().decode(ActionsFilter.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.repositoryKey)
        XCTAssertTrue(decoded.matches(run(repository("alice"))))
        XCTAssertFalse(decoded.matches(run(repository("alice", id: "2"))))
    }
}
