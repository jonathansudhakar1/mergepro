import Foundation
import GRDB

public extension DatabaseStore {
    /// Capture before a mutable provider read. Ordinary writes do not rotate auth generation.
    func observationFence(for key:ProviderKey) throws -> Int {
        try database.read { try Self.observationFence(key,in:$0) }
    }
    func observationFences(account:AccountScope) throws -> [ProviderKey:Int] {
        try database.read { db in
            Dictionary(uniqueKeysWithValues:try Row.fetchAll(db,sql:"SELECT repositoryID,objectID,epoch FROM prObservationFences WHERE host=? AND accountID=?",arguments:[account.host,account.accountID]).map { row in
                (ProviderKey(host:account.host,accountID:account.accountID,repositoryID:row["repositoryID"],objectID:row["objectID"]),row["epoch"] as Int)
            })
        }
    }
    /// Provider-confirmed truth and its fence advance in one SQLite transaction, without an alert.
    func confirmWrite(_ pr:PullRequest) throws {
        try database.write { try Self.confirmWrite(pr,in:$0) }
    }
    /// Returns false for a response admitted before a confirmed mutation. A later read still applies.
    @discardableResult func saveObservedPullRequests(_ prs:[PullRequest],fences:[ProviderKey:Int]) throws -> Bool {
        try database.write { db in
            guard try prs.allSatisfy({ try Self.observationFence($0.key,in:db) == (fences[$0.key] ?? 0) }) else { return false }
            for pr in prs { try Self.storePullRequest(pr,in:db) };return true
        }
    }
}
extension DatabaseStore {
    static func confirmWrite(_ pr:PullRequest,in db:Database) throws {
        try db.execute(sql:"INSERT INTO prObservationFences VALUES (?,?,?,?,1) ON CONFLICT(host,accountID,repositoryID,objectID) DO UPDATE SET epoch=epoch+1",arguments:[pr.key.host,pr.key.accountID,pr.key.repositoryID,pr.key.objectID])
        try storePullRequest(pr,in:db)
        // Merge completion is immutable public PR state, unlike account-specific permissions,
        // reviews and viewed marks. Share only that minimal truth with already available rows.
        if pr.state == .merged {
            let rows=try Data.fetchAll(db,sql:"SELECT p.json FROM pullRequests p JOIN accounts a ON p.host=a.host AND p.accountID=a.accountID WHERE p.host=? AND p.repositoryID=? AND p.objectID=? AND p.accountID<>?",arguments:[pr.key.host,pr.key.repositoryID,pr.key.objectID,pr.key.accountID])
            for data in rows {
                let old=try JSONDecoder().decode(PullRequest.self,from:data)
                let denied=try DatabaseStore.setting(.authorizationProblem,account:old.key.account,in:db) == "true"
                guard !denied else { continue }
                var metadata=old.metadata;metadata?.mergedAt=pr.metadata?.mergedAt;metadata?.mergeEligible=false;metadata?.mergeEvidence=nil
                let shared=PullRequest(key:old.key,headRevision:old.headRevision,title:old.title,state:.merged,isDraft:false,metadata:metadata)
                try db.execute(sql:"INSERT INTO prObservationFences VALUES (?,?,?,?,1) ON CONFLICT(host,accountID,repositoryID,objectID) DO UPDATE SET epoch=epoch+1",arguments:[old.key.host,old.key.accountID,old.key.repositoryID,old.key.objectID])
                try storePullRequest(shared,in:db)
            }
        }
    }
    static func observationFence(_ key:ProviderKey,in db:Database) throws -> Int {
        try Int.fetchOne(db,sql:"SELECT epoch FROM prObservationFences WHERE host=? AND accountID=? AND repositoryID=? AND objectID=?",arguments:[key.host,key.accountID,key.repositoryID,key.objectID]) ?? 0
    }
    static func contradictsConfirmedMerge(_ pr:PullRequest,in db:Database) throws -> Bool {
        guard pr.state != .merged,let json=try Data.fetchOne(db,sql:"SELECT json FROM pullRequests WHERE host=? AND accountID=? AND repositoryID=? AND objectID=?",arguments:[pr.key.host,pr.key.accountID,pr.key.repositoryID,pr.key.objectID]) else { return false }
        return try JSONDecoder().decode(PullRequest.self,from:json).state == .merged
    }
    /// Stores a row unless it is byte-identical to the stored one; returns whether the row was written. Keys are
    /// sorted so equal values always encode to equal bytes (label colors are a dictionary).
    @discardableResult static func storePullRequest(_ pr:PullRequest,in db:Database) throws -> Bool {
        if try contradictsConfirmedMerge(pr,in:db) { return false }
        let pr=try PRClassificationStore.applyingRules(to:pr,in:db)
        let encoder=JSONEncoder.stable;encoder.outputFormatting = [.sortedKeys]
        try db.execute(sql:"INSERT INTO pullRequests VALUES (?,?,?,?,?) ON CONFLICT(host,accountID,repositoryID,objectID) DO UPDATE SET json=excluded.json WHERE json IS NOT excluded.json",arguments:[pr.key.host,pr.key.accountID,pr.key.repositoryID,pr.key.objectID,try encoder.encode(pr)])
        return db.changesCount > 0
    }
}
