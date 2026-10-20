import XCTest
@testable import MergeProCore

private struct MixedFeatureFetcher:PollFeatureFetcher {
    let featureID:String
    let category:String
    var allowsVisibleUntrackedReads=false
    var fetchScope:PollFetchScope { allowsVisibleUntrackedReads ? .repository:.account }
    func fetch(_ context:PollFetchContext) async throws -> PollFetchResult {
        let repository = context.repositories.first!
        let key = ProviderKey(host:context.account.host,accountID:context.account.accountID,repositoryID:repository.repositoryID,objectID:featureID)
        let event = ChangeEvent(key:featureID+":transition",object:key,category:category,occurredAt:Date())
        return .init(events:[event,event])
    }
}
@MainActor final class FeaturePollingTests:XCTestCase {
    func testSavedViewRulesDoNotSuppressAnotherFeaturesEvents() {
        let pr = pollEvent(1)
        let workflow = ChangeEvent(key:"run",object:pr.object,category:"workflow status",occurredAt:Date(),locator:.init(subjectType:"WorkflowRun"))
        XCTAssertEqual(FeatureNotificationRules.matchingKeys(events:[pr,workflow],prRules:[[pr.key]],workflowKeys:[workflow.key]),[pr.key,workflow.key])
        XCTAssertEqual(FeatureNotificationRules.matchingKeys(events:[pr,workflow],prRules:[],workflowKeys:[]),[pr.key])
        XCTAssertEqual(FeatureNotificationRules.matchingKeys(events:[pr,workflow],prRules:[[]],workflowKeys:[workflow.key]),[workflow.key])
    }
    func testPRAndWorkflowTransitionsShareOneSummaryAndUnchangedCycleIsSilent() async throws {
        let database = try DatabaseStore(path:":memory:")
        let store = PollCycleStore(database:database),sink = RecordingNotificationSink()
        let poller = PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:sink),fetchers:[MixedFeatureFetcher(featureID:"prs",category:"reviews requested"),MixedFeatureFetcher(featureID:"actions",category:"workflows failed")])
        let account = AccountScope(host:"github.com",accountID:"a")
        let request = PollRequest(scopes:[.init(account:account,repositories:[.init(account:account,repositoryID:"7")])],policy:.init(enabled:true))
        _ = try await poller.refresh(request)
        let first = await sink.summaries
        XCTAssertEqual(first.count,1)
        XCTAssertEqual(first.first?.eventKeys,["actions:transition","prs:transition"])
        _ = try await poller.refresh(request)
        let repeated = await sink.summaries
        XCTAssertEqual(repeated.count,1)
        XCTAssertEqual(try store.inbox().count,2)
    }
    func testVisibleUntrackedActionsShareCollectorWithoutPRReadsOrNotifications() async throws {
        let store=PollCycleStore(database:try DatabaseStore(path:":memory:"))
        let sink=RecordingNotificationSink()
        let account=AccountScope(host:"github.com",accountID:"a"),repository=RepositoryKey(account:.init(host:"github.com",accountID:"a"),repositoryID:"untracked")
        let poller=PollCoordinator(store:store,publisher:PollNotificationPublisher(store:store,sink:sink),fetchers:[MixedFeatureFetcher(featureID:"prs",category:"reviews requested"),MixedFeatureFetcher(featureID:"actions",category:"workflow status",allowsVisibleUntrackedReads:true)])
        _ = try await poller.refresh(.init(scopes:[.init(account:account,repositories:[repository])],policy:.init(enabled:true,allowedRepositories:[]),visibleRepositories:[repository]))
        let summaries=await sink.summaries
        XCTAssertTrue(summaries.isEmpty)
        let events=try store.inbox()
        XCTAssertEqual(events.map(\.id),["actions:transition"])
        XCTAssertTrue(events.allSatisfy(\.surfaced))
    }
    func testActiveCadenceCanShortenLocalScheduleButNeverProviderInterval() async throws {
        let budget = RateBudget(minimumSpacing:.zero)
        let account = AccountScope(host:"github.com",accountID:"a")
        await budget.completePoll(account:account,feature:"actions",interval:60)
        let due = await budget.beginPoll(account:account,feature:"actions",interval:0)
        XCTAssertTrue(due)
        await budget.observePollInterval(GitHubResponse(status:200,headers:["X-Poll-Interval":"60"],data:Data()),account:account,feature:"actions")
        let blocked = await budget.beginPoll(account:account,feature:"actions",interval:0,force:true)
        XCTAssertFalse(blocked)
    }
}
