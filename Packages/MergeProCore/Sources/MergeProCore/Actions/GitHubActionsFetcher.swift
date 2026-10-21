import Foundation
import Synchronization
public struct GitHubActionsFetcher:PollFeatureFetcher {
    public let featureID="github-actions"
    public let fetchScope:PollFetchScope = .repository
    public let allowsVisibleUntrackedReads = true
    public var pollInterval:TimeInterval? { 60 }
    public var usesCachedPullRequests:Bool { false }
    /// Repositories that are neither on screen nor running workflows are polled at this slower cadence.
    public static let idleInterval:TimeInterval=180
    private let activity=ActionsActivity()
    public init() {}
    public func pollInterval(for reason:PollRequest.Reason) -> TimeInterval? { reason == .activeRun ? 15:60 }
    /// Visible repositories and repositories with known active runs keep the fast cadence; quiet
    /// background repositories use `idleInterval`. Unknown activity (e.g. after launch) counts as active.
    public func pollInterval(for reason:PollRequest.Reason,repository:RepositoryKey?,focused:Bool) -> TimeInterval? {
        if focused { return pollInterval(for:reason) }
        guard let repository,activity.isIdle(repository) else { return pollInterval(for:reason) }
        return Self.idleInterval
    }
    public func fetch(_ context:PollFetchContext) async throws -> PollFetchResult {
        guard let operation=context.operation,let client=context.client else { throw GitHubFailure.invalidAuthentication }
        let provider=GitHubActionsProvider(client:client,credential:operation.credential)
        var events:[ChangeEvent]=[];var snapshots:[PollFeatureSnapshot]=[];var responses:[PollResponseCache]=[]
        let old=Dictionary(context.cachedSnapshots.compactMap { snapshot -> (ProviderKey,WorkflowRun)? in guard let run=try? JSONDecoder().decode(WorkflowRun.self,from:snapshot.payload) else { return nil };return (snapshot.key,run) },uniquingKeysWith:{ _,latest in latest })
        var idle:[RepositoryKey:Bool]=[:]
        // Sorted keys: an unchanged run encodes to its stored bytes, so the store skips rewriting it.
        let encoder=JSONEncoder.stable;encoder.outputFormatting = [.sortedKeys]
        for key in context.repositories {
            try context.checkDeadline();guard let repository=context.repositoryMetadata[key] else { continue }
            let polled=try await provider.pollRuns(repository:repository,cached:Array(old.values.filter { $0.repository.key==repository.key }),deadline:context.deadline,validators:context.cachedResponses)
            try context.checkDeadline()
            responses += polled.responses
            idle[key] = !polled.runs.contains(where:\.isActive)
            for run in polled.runs {
                snapshots.append(.init(key:run.key,feature:featureID,payload:try encoder.encode(run)))
                let previous=old[run.key]
                // A run GitHub no longer returns leaves the active set silently; it is not a workflow outcome.
                guard run.conclusion != GitHubActionsProvider.deletedConclusion else { continue }
                if previous?.status != run.status || previous?.conclusion != run.conclusion {
                    let account=run.repository.key.account
                    let identity=[account.host,account.accountID,run.repository.key.repositoryID,"workflow",String(run.runID),String(run.attempt),run.status,run.conclusion ?? ""].joined(separator:"|")
                    events.append(.init(key:identity,object:run.key,category:run.conclusion=="failure" ? "workflow failures":"workflow status",occurredAt:run.updatedAt,title:run.name,locator:.init(subjectType:"WorkflowRun",subjectNumber:String(run.runID),webURL:run.webURL)))
                }
            }
        }
        for (key,value) in idle { activity.record(key,idle:value) }
        let new=context.repositories.subtracting(context.baselinedRepositories)
        return .init(events:events,snapshots:snapshots,responses:responses,baselinedRepositories:context.repositories,baselineEventKeys:Set(events.filter { new.contains($0.object.repository) }.map(\.key)))
    }
}
/// Session-local record of which repositories last showed no active runs.
final class ActionsActivity:Sendable {
    private let idle=Mutex<[RepositoryKey:Bool]>([:])
    func isIdle(_ repository:RepositoryKey) -> Bool { idle.withLock { $0[repository] ?? false } }
    func record(_ repository:RepositoryKey,idle value:Bool) { idle.withLock { $0[repository]=value } }
}
