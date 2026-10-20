import Foundation
import Synchronization
import GRDB

/// Targeted reads for callers that need one setting, row or scope. Prefer these to
/// `snapshot(for:)`, which decodes every cached PR in the account, including merged history.
/// Pull requests carry the same merge-operation overlay as the snapshot.
public extension DatabaseStore {
    /// A raw name, for tests; production code reads `AccountSettingKey`s.
    internal func setting(_ name: String, account: AccountScope) throws -> String? {
        try database.read { try Self.setting(name,account:account,in:$0) }
    }
    func settings(account: AccountScope) throws -> [String:String] {
        try database.read { try Self.settings(account:account,in:$0) }
    }
    func pullRequest(for key: ProviderKey) throws -> PullRequest? {
        try database.read { try Self.pullRequest(key,in:$0) }
    }
    /// Existence of the exact cached head revision, without decoding the row.
    func pullRequestExists(_ key: ProviderKey, headSHA: String) throws -> Bool {
        try database.read { try Self.pullRequestExists(key,headSHA:headSHA,in:$0) }
    }
    /// Ordered by object ID, like the snapshot. `states: nil` returns every state.
    func pullRequests(repository: RepositoryKey, states: Set<PullRequest.State>? = nil) throws -> [PullRequest] {
        try pullRequests(repositories:[repository],states:states)
    }
    /// Ordered by repository then object ID, like the snapshot.
    func pullRequests(repositories: Set<RepositoryKey>, states: Set<PullRequest.State>? = nil) throws -> [PullRequest] {
        let raw = try database.read { db in
            try RawPullRequests(active:Self.activeReservations(db),rows:repositories.sorted { ($0.account.host,$0.account.accountID,$0.repositoryID) < ($1.account.host,$1.account.accountID,$1.repositoryID) }.flatMap { repo in
                try Data.fetchAll(db,sql:"SELECT json FROM pullRequests WHERE host=? AND accountID=? AND repositoryID=?"+Self.stateFilter(states)+" ORDER BY objectID",arguments:[repo.account.host,repo.account.accountID,repo.repositoryID])
            })
        }
        return try raw.decoded()
    }
    /// Most recently updated first (SQLite sorts unknown update times last under DESC); `limit`
    /// bounds decoding. A single state is read in `pullRequests_account_state_updated` order.
    func pullRequests(account: AccountScope, states: Set<PullRequest.State>? = nil, limit: Int? = nil) throws -> [PullRequest] {
        let raw = try database.read { db in
            try RawPullRequests(active:Self.activeReservations(db),rows:Data.fetchAll(db,sql:"SELECT json FROM pullRequests WHERE host=? AND accountID=?"+Self.stateFilter(states)+" ORDER BY updatedAt DESC, repositoryID, objectID"+(limit.map { " LIMIT \(max(0,$0))" } ?? ""),arguments:[account.host,account.accountID]))
        }
        return try raw.decoded()
    }
    func repositories(account: AccountScope) throws -> [Repository] {
        try database.read { db in
            let decoder = JSONDecoder()
            return try Data.fetchAll(db,sql:"SELECT json FROM repositories WHERE host=? AND accountID=? ORDER BY repositoryID",arguments:[account.host,account.accountID]).map { try decoder.decode(Repository.self,from:$0) }
        }
    }
    func repository(_ key: RepositoryKey) throws -> Repository? {
        try database.read { db in
            try Data.fetchOne(db,sql:"SELECT json FROM repositories WHERE host=? AND accountID=? AND repositoryID=?",arguments:[key.account.host,key.account.accountID,key.repositoryID]).map { try JSONDecoder().decode(Repository.self,from:$0) }
        }
    }
    func trackedRepositories(account: AccountScope) throws -> Set<RepositoryKey> {
        try database.read { try Self.trackedRepositories(account:account,in:$0) }
    }
    func pins(account: AccountScope) throws -> Set<ProviderKey> {
        try database.read { try Self.pins(account:account,in:$0) }
    }
    func reviewOperation(id: UUID) throws -> PRWriteOperation? {
        try database.read { db in
            try Data.fetchOne(db,sql:"SELECT json FROM reviewOperations WHERE id=?",arguments:[id.uuidString]).map { try JSONDecoder().decode(PRWriteOperation.self,from:$0) }
        }
    }
}

extension DatabaseStore {
    /// Repository then object ID order, matching `snapshot(for:).pullRequests`.
    func pullRequestsInSnapshotOrder(account: AccountScope) throws -> [PullRequest] {
        try database.read { db in
            RawPullRequests(active:try Self.activeReservations(db),rows:try Data.fetchAll(db,sql:"SELECT json FROM pullRequests WHERE host=? AND accountID=? ORDER BY repositoryID, objectID",arguments:[account.host,account.accountID]))
        }.decoded()
    }
    static func setting(_ name: String, account: AccountScope, in db: Database) throws -> String? {
        try String.fetchOne(db,sql:"SELECT value FROM settings WHERE host=? AND accountID=? AND name=?",arguments:[account.host,account.accountID,name])
    }
    static func settings(account: AccountScope, in db: Database) throws -> [String:String] {
        Dictionary(uniqueKeysWithValues:try Row.fetchAll(db,sql:"SELECT name, value FROM settings WHERE host=? AND accountID=?",arguments:[account.host,account.accountID]).map { ($0["name"] as String,$0["value"] as String) })
    }
    static func trackedRepositories(account: AccountScope, in db: Database) throws -> Set<RepositoryKey> {
        Set(try String.fetchAll(db,sql:"SELECT repositoryID FROM trackedRepositories WHERE host=? AND accountID=?",arguments:[account.host,account.accountID]).map { RepositoryKey(account:account,repositoryID:$0) })
    }
    static func pins(account: AccountScope, in db: Database) throws -> Set<ProviderKey> {
        Set(try Row.fetchAll(db,sql:"SELECT repositoryID, objectID FROM pins WHERE host=? AND accountID=?",arguments:[account.host,account.accountID]).map { ProviderKey(host:account.host,accountID:account.accountID,repositoryID:$0["repositoryID"],objectID:$0["objectID"]) })
    }
    static func pullRequestExists(_ key: ProviderKey, headSHA: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM pullRequests WHERE host=? AND accountID=? AND repositoryID=? AND objectID=? AND headSHA=?)",arguments:[key.host,key.accountID,key.repositoryID,key.objectID,headSHA]) ?? false
    }
    static func pullRequest(_ key: ProviderKey, in db: Database) throws -> PullRequest? {
        guard let json = try Data.fetchOne(db,sql:"SELECT json FROM pullRequests WHERE host=? AND accountID=? AND repositoryID=? AND objectID=?",arguments:[key.host,key.accountID,key.repositoryID,key.objectID]) else { return nil }
        let pr = try JSONDecoder().decode(PullRequest.self,from:json)
        // Only merge evidence is overlaid; skip the ledger read for rows without it.
        return pr.metadata?.mergeEvidence == nil ? pr : overlaying(pr,active:try activeReservations(db))
    }
    private static func stateFilter(_ states: Set<PullRequest.State>?) -> String {
        guard let states else { return "" }
        // Raw values are a closed enum, never user input.
        return " AND state IN (" + states.map { "'" + $0.rawValue + "'" }.sorted().joined(separator:",") + ")"
    }
    /// Keys reserved by unresolved write operations, across accounts (callers filter by key).
    /// Uses the `reviewOperations_state` expression index (identical expression text); completed history
    /// is not decoded. Malformed or undecodable rows reserve nothing rather than failing every PR read.
    static func activeReservations(_ db: Database) throws -> Set<ProviderKey> {
        let decoder = JSONDecoder()
        return Set(try Row.fetchAll(db,sql:"SELECT id,json FROM reviewOperations WHERE \(Migrations.reviewOperationState) IN ('prepared','sending','uncertain')").flatMap { row -> Set<ProviderKey> in
            do { return try decoder.decode(PRWriteOperation.self,from:row["json"] as Data).command.reservedKeys } catch {
                // Every PR read passes here: report each undecodable row once per process, not on every read.
                if undecodableOperationReports.first(row["id"] as String) {
                    Log.writes.error("An unresolved write operation did not decode and reserves nothing: \(Log.kind(error), privacy: .public)")
                }
                return []
            }
        })
    }
    /// Ledger rows already reported as undecodable in this process.
    static let undecodableOperationReports = ReportedOnce()
    /// Live operation state and derived eligibility are never trusted from the stored row.
    static func overlaying(_ pr: PullRequest, active: Set<ProviderKey>) -> PullRequest {
        guard var m = pr.metadata, m.mergeEvidence != nil else { return pr }
        let affected = Set(m.mergeEvidence?.nativeAffected ?? [pr.key])
        m.mergeEvidence?.operationInProgress = !active.isDisjoint(with:affected)
        if let evidence = m.mergeEvidence { m.mergeEligible = MergePolicy.evaluate(evidence).eligible }
        return PullRequest(key:pr.key,headRevision:pr.headRevision,title:pr.title,state:pr.state,isDraft:pr.isDraft,metadata:m)
    }
}

/// Raw rows captured in one read transaction; JSON decoding happens after the database is released.
struct RawPullRequests: Sendable {
    let active: Set<ProviderKey>
    let rows: [Data]
    func decoded() throws -> [PullRequest] {
        guard rows.count > 256 else { let decoder = JSONDecoder(); return try rows.map { DatabaseStore.overlaying(try decoder.decode(PullRequest.self,from:$0),active:active) } }
        // Large account histories decode in parallel chunks; results keep row order.
        let chunk = 256, count = (rows.count + chunk - 1) / chunk
        let results = DecodeSlots(count:count)
        DispatchQueue.concurrentPerform(iterations:count) { index in
            let decoder = JSONDecoder()
            results.set(index,Result { try rows[index*chunk..<min(rows.count,(index+1)*chunk)].map { DatabaseStore.overlaying(try decoder.decode(PullRequest.self,from:$0),active:active) } })
        }
        return try results.values().flatMap { try $0.get() }
    }
}
private final class DecodeSlots: Sendable {
    private let slots: Mutex<[Result<[PullRequest],any Error>?]>
    init(count: Int) { slots = Mutex(Array(repeating:nil,count:count)) }
    func set(_ index: Int, _ value: Result<[PullRequest],any Error>) { slots.withLock { $0[index] = value } }
    func values() -> [Result<[PullRequest],any Error>] { slots.withLock { $0.map { $0! } } }
}

/// Identities a diagnostic already reported in this process, so a condition that persists across reads is
/// logged once. Bounded: past `limit` identities it starts over (at worst one more report per identity).
final class ReportedOnce: Sendable {
    private let state = Mutex<(reported: Set<String>, reports: [String:Int])>(([], [:]))
    private let limit: Int
    init(limit: Int = 1_000) { self.limit = limit }
    /// True only the first time `id` is seen: the caller reports it then.
    func first(_ id: String) -> Bool {
        state.withLock { state in
            if state.reported.count >= limit, !state.reported.contains(id) { state = ([], [:]) }
            guard state.reported.insert(id).inserted else { return false }
            state.reports[id, default: 0] += 1
            return true
        }
    }
    /// How many times `id` was reported (tests).
    func count(_ id: String) -> Int { state.withLock { $0.reports[id] ?? 0 } }
}
