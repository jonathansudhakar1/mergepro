import Foundation
import GRDB
import Synchronization

/// Interactive repository tabs can read accessible, untracked repositories without changing tracking.
/// This reuses PR normalization and caches provider truth; system events remain owned by the collector.
public actor RepositoryPRInventoryService {
    private let session:GitHubAccountSession
    private let budget:RateBudget
    private let database:DatabaseStore
    private let clientID:String
    /// Tracked repositories are refreshed by the poller every 60 s; a tab open within that reuses it.
    public static let trackedFreshness:TimeInterval=60
    /// An untracked repository tab reuses its own complete read for 2 minutes.
    public static let untrackedFreshness:TimeInterval=120
    /// Per account-session proof that `repos/{name}` still names this repository ID. Keyed by the session
    /// generation, so reconnects and invalidations re-verify; shared because callers create services per use.
    private static let verifiedIdentities=Mutex<Set<String>>([])
    public init(session:GitHubAccountSession,budget:RateBudget,database:DatabaseStore,clientID:String) {
        self.session=session;self.budget=budget;self.database=database;self.clientID=clientID
    }
    public func refresh(_ key:RepositoryKey) async throws -> PRInventoryStatus {
        let ticket=try await session.authenticatedOperation(for:key.account,clientID:clientID)
        var proof:String?
        do {
            // Repository-scoped reads (same merge-operation overlay as the snapshot), not an account-wide decode.
            guard let repository=try database.repository(key) else { throw GitHubFailure.resourceDenied }
            let client=await session.interactiveReadClient(account:key.account,budget:budget)
            let identity=[key.account.host,key.account.accountID,ticket.generation.uuidString,key.repositoryID,repository.name].joined(separator:"|");proof=identity
            if !Self.verifiedIdentities.withLock({ $0.contains(identity) }) {
                let info=try await client.get(client.origin.appendingPathComponent("repos/"+repository.name),token:ticket.credential.accessToken)
                guard let object=try JSONSerialization.jsonObject(with:info.data) as? [String:Any],let id=object["id"] as? NSNumber,String(id.int64Value)==key.repositoryID else { throw GitHubFailure.resourceDenied }
                Self.verifiedIdentities.withLock { if $0.count>=1_024 { $0.removeAll() };$0.insert(identity) }
            }
            let store=PollCycleStore(database:database)
            let fetcher=GitHubPRInventoryFetcher()
            let context=PollFetchContext(cycleID:UUID(),account:key.account,repositories:[key],featureID:fetcher.featureID,
                cachedPullRequests:try database.pullRequests(repository:key),
                cachedSnapshots:try store.featureSnapshots(account:key.account,feature:fetcher.featureID,repositories:[key]),
                repositoryMetadata:[key:repository],deadline:.now.advanced(by:.seconds(30)),operation:ticket,client:client,budget:budget,
                baselinedRepositories:[],suppressNotifications:true,cachedResponses:[:],observationFences:try database.observationFences(account:key.account))
            let result=try await fetcher.fetch(context)
            let status=try result.snapshots.first.map { try JSONDecoder().decode(PRInventoryStatus.self,from:$0.payload) }
            guard let status,try await session.withCurrentOperation(ticket,body:{ db in
                try db.database.write { sql in
                    var obsolete=false
                    for pr in result.pullRequests where pr.key.repository == key {
                        guard (try DatabaseStore.observationFence(pr.key,in:sql))==(context.observationFences[pr.key] ?? 0),!(try DatabaseStore.contradictsConfirmedMerge(pr,in:sql)) else { obsolete=true;continue }
                        try DatabaseStore.storePullRequest(pr,in:sql)
                    }
                    for value in result.snapshots where value.key.repository == key && !obsolete {
                        // Compare-and-swap, like the poller's commit: a checkpoint the poller committed while this
                        // refresh read the provider is newer than the one it resumed from, so it is kept.
                        let started=context.cachedSnapshots.first { $0.key == value.key && $0.feature == value.feature }?.payload
                        if let stored=try Data.fetchOne(sql,sql:"SELECT json FROM pollFeatureSnapshots WHERE host=? AND accountID=? AND repositoryID=? AND objectID=? AND feature=?",arguments:[value.key.host,value.key.accountID,value.key.repositoryID,value.key.objectID,value.feature]),
                           try JSONDecoder().decode(PollFeatureSnapshot.self,from:stored).payload != started { continue }
                        try sql.execute(sql:"INSERT INTO pollFeatureSnapshots VALUES (?,?,?,?,?,?) ON CONFLICT(host,accountID,repositoryID,objectID,feature) DO UPDATE SET json=excluded.json",arguments:[value.key.host,value.key.accountID,value.key.repositoryID,value.key.objectID,value.feature,try JSONEncoder().encode(value)])
                    }
                }
            }) else { throw CancellationError() }
            return status
        } catch {
            // A vanished or renamed repository must be re-identified on the next attempt.
            if error as? GitHubFailure == .resourceDenied,let proof { _ = Self.verifiedIdentities.withLock { $0.remove(proof) } }
            await session.featureFailed(error,operation:ticket);throw error
        }
    }
    /// Skips the network when the stored inventory is fresh: tracked within 60 s (poller-owned, so a partial
    /// traversal is continued there), untracked within 2 min and complete. A failure newer than the last
    /// success, a missing status or a clock that moved backwards is stale.
    public func refreshIfStale(_ key:RepositoryKey,now:Date=Date()) async throws -> (status:PRInventoryStatus,didFetch:Bool) {
        let ticket=try await session.authenticatedOperation(for:key.account,clientID:clientID)
        let tracked=try database.trackedRepositories(account:key.account).contains(key)
        if let status=try cachedStatus(key),let success=status.lastSuccessAt,status.lastFailureAt.map({ $0<=success }) ?? true,tracked || status.complete {
            let age=now.timeIntervalSince(success)
            if age>=0,age<(tracked ? Self.trackedFreshness : Self.untrackedFreshness) {
                guard try await session.withCurrentOperation(ticket,body:{ _ in }) else { throw CancellationError() }
                return (status,false)
            }
        }
        return (try await refresh(key),true)
    }
    /// The stored inventory status for a repository tab, without network.
    public func cachedStatus(_ key:RepositoryKey) throws -> PRInventoryStatus? {
        try database.database.read { db in
            try Data.fetchOne(db,sql:"SELECT json FROM pollFeatureSnapshots WHERE host=? AND accountID=? AND repositoryID=? AND objectID='pull-request-inventory' AND feature=?",arguments:[key.account.host,key.account.accountID,key.repositoryID,GitHubPRInventoryFetcher().featureID])
        }.map { try JSONDecoder().decode(PRInventoryStatus.self,from:JSONDecoder().decode(PollFeatureSnapshot.self,from:$0).payload) }
    }
    /// Stored rows for one repository, without network or an account-wide decode.
    public func cachedRows(_ key:RepositoryKey) async throws -> [PullRequest] {
        let ticket=try await session.authenticatedOperation(for:key.account,clientID:clientID)
        let rows=try database.pullRequests(repository:key)
        guard try await session.withCurrentOperation(ticket,body:{ _ in }) else { throw CancellationError() }
        return rows
    }
}
