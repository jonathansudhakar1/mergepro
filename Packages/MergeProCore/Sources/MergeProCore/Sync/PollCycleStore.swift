import Foundation
import GRDB
import Synchronization

public enum PollStorageError: Error { case closedCycle, invalidSummary, outOfScope, obsoleteObservation }
public struct PollResponseCache: Sendable {
    public let url: URL
    public let etag: String?
    public let lastModified: String?
    public let body: Data
    public let nextURL: URL?
    public init(url: URL, etag: String?, body: Data, nextURL: URL? = nil, lastModified: String? = nil) { self.url = url; self.etag = etag; self.body = body; self.nextURL = nextURL; self.lastModified = lastModified }
}
public struct PollFeatureSnapshot: Codable, Sendable {
    public let key: ProviderKey
    public let feature: String
    public let payload: Data
    public init(key: ProviderKey, feature: String, payload: Data) { self.key = key; self.feature = feature; self.payload = payload }
}

private struct SnapshotIdentity: Hashable { let key: ProviderKey; let feature: String }

/// What a poll cycle (or one of its work items) actually committed: PR rows and feature snapshots whose stored
/// bytes changed, and newly recorded events. Re-reading unchanged provider data is not a change.
public struct PollCycleChanges: Sendable, Equatable {
    public var pullRequests: Set<ProviderKey> = []
    /// Repositories with a changed PR row or feature snapshot, by feature ID.
    public var repositories: [String:Set<RepositoryKey>] = [:]
    /// Events recorded for the first time.
    public var events = 0
    public init() {}
    public var isEmpty: Bool { pullRequests.isEmpty && repositories.isEmpty && events == 0 }
    public func repositories(feature: String) -> Set<RepositoryKey> { repositories[feature] ?? [] }
    public var changedRepositories: Set<RepositoryKey> { repositories.values.reduce(into:[]) { $0.formUnion($1) } }
    public mutating func formUnion(_ other: PollCycleChanges) {
        pullRequests.formUnion(other.pullRequests); events += other.events
        for (feature,keys) in other.repositories { repositories[feature,default:[]].formUnion(keys) }
    }
}

/// Stored PR rows read by byte fingerprint (see `PollCycleStore.pullRequestRows`).
public struct PullRequestRows: Sendable {
    /// Every matching stored row, in snapshot order (repository, then object ID).
    public let keys: [ProviderKey]
    /// In-process fingerprints of each row's stored bytes; pass them back as `known` on the next read.
    public let fingerprints: [ProviderKey:Int]
    /// Rows whose bytes differ from `known` (or that carry merge evidence), decoded with the snapshot overlay.
    public let decoded: [ProviderKey:PullRequest]
}

/// One shared database; all feature payloads/events/checkpoints from a response commit together.
public final class PollCycleStore: NotificationAttemptStore, Sendable {
    /// The only feature whose cached response validators survive `CacheStore.invalidatePrivatePayloads`.
    /// A confirmed-invalid credential (`purgePrivateContent`) and account removal delete these rows too.
    public static let notificationFeedFeature = "github-notification-signals"
    private let database: DatabaseStore
    public init(database: DatabaseStore) { self.database = database }
    public func recoverInterruptedCycles(at date: Date = Date()) throws {
        try database.database.write { db in
            try db.execute(sql:"UPDATE pollCycles SET status = 'interrupted', closedAt = ? WHERE status = 'open'",arguments:[date.timeIntervalSince1970])
        }
    }
    /// Abandon only this coordinator's failed open cycle, retaining events and any closed attempt.
    public func interrupt(_ id: UUID, at date: Date = Date()) throws {
        try database.database.write { db in
            try db.execute(sql:"UPDATE pollCycles SET status='interrupted',closedAt=? WHERE id=? AND status='open'",arguments:[date.timeIntervalSince1970,id.uuidString])
        }
    }
    public func begin(_ id: UUID, at date: Date, baseline: Bool) throws {
        try database.database.write { db in
            try db.execute(sql:"INSERT INTO pollCycles(id,startedAt,baseline,status) VALUES (?,?,?,'open')",arguments:[id.uuidString,date.timeIntervalSince1970,baseline])
        }
    }
    private static func requireOpen(_ db: Database, _ id: UUID) throws {
        guard try String.fetchOne(db,sql:"SELECT status FROM pollCycles WHERE id = ?",arguments:[id.uuidString]) == "open" else { throw PollStorageError.closedCycle }
    }
    @discardableResult private static func record(_ events: [ChangeEvent], baselineKeys: Set<String>, cycleID: UUID, in db: Database) throws -> Int {
        let baseline = try Bool.fetchOne(db,sql:"SELECT baseline FROM pollCycles WHERE id = ?",arguments:[cycleID.uuidString]) ?? false
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Sort duplicate payloads as well as keys so contradictory page order cannot change the ledger.
        let ordered = try events.map { ($0,try encoder.encode($0)) }.sorted {
            $0.0.key == $1.0.key ? $0.1.lexicographicallyPrecedes($1.1) : $0.0.key < $1.0.key
        }
        var recorded = 0
        for (event,json) in ordered {
            try db.execute(sql:"INSERT OR IGNORE INTO changeEvents(eventKey,cycleID,host,accountID,repositoryID,json,surfaced) VALUES (?,?,?,?,?,?,?)",arguments:[event.key,cycleID.uuidString,event.object.host,event.object.accountID,event.object.repositoryID,json,baseline || baselineKeys.contains(event.key)])
            recorded += db.changesCount
        }
        return recorded
    }
    public func record(_ events: [ChangeEvent], cycleID: UUID) throws {
        try database.database.write { db in
            try Self.requireOpen(db,cycleID)
            try Self.record(events,baselineKeys:[],cycleID:cycleID,in:db)
        }
    }
    /// Called only after coordinator generation/account checks; repeats monotonic deadline and
    /// durable open-cycle checks inside the transaction, including after waiting for an account lock.
    /// Byte-identical rows and snapshots are not rewritten; the result names what actually changed.
    @discardableResult
    public func apply(_ result: PollFetchResult, context: PollFetchContext, deadline: ContinuousClock.Instant, requireTracked: Bool) throws -> PollCycleChanges {
        try database.database.write { db in
            var changes = PollCycleChanges()
            guard ContinuousClock.now < deadline else { throw PollStorageError.closedCycle }
            try Self.requireOpen(db,context.cycleID)
            func allowed(_ key: RepositoryKey) throws -> Bool {
                guard key.account == context.account, context.repositories.contains(key) else { return false }
                if !requireTracked { return true }
                return try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM trackedRepositories WHERE host=? AND accountID=? AND repositoryID=?)",arguments:[key.account.host,key.account.accountID,key.repositoryID]) ?? false
            }
            let eventRepos = result.events.map { $0.object.repository }
            let payloadRepos = result.pullRequests.map { $0.key.repository } + result.snapshots.map { $0.key.repository } + Array(result.baselinedRepositories)
            for repo in eventRepos + payloadRepos { guard try allowed(repo) else { throw PollStorageError.outOfScope } }
            let keys=Set(result.pullRequests.map(\.key)+result.events.map(\.object)+result.snapshots.map(\.key))
            var obsolete=try Set(keys.filter { try DatabaseStore.observationFence($0,in:db) != (context.observationFences[$0] ?? 0) })
            for pr in result.pullRequests where try DatabaseStore.contradictsConfirmedMerge(pr,in:db) { obsolete.insert(pr.key) }
            for pr in result.pullRequests where !obsolete.contains(pr.key) {
                if try DatabaseStore.storePullRequest(pr,in:db) {
                    changes.pullRequests.insert(pr.key); changes.repositories[context.featureID,default:[]].insert(pr.key.repository)
                }
            }
            // Unknown/repository-wide snapshots carry shared traversal checkpoints. Do not
            // advance them from a batch with any obsolete observation in that repository.
            let rowKeys=Set(result.pullRequests.map(\.key))
            // Compare-and-swap: a snapshot this work item started from is replaced only while it is still the
            // stored one. An interactive repository refresh (or a purge) that committed meanwhile wins; the
            // next cycle resumes from it rather than this item overwriting it with an older continuation.
            let started=Dictionary(context.cachedSnapshots.map { (SnapshotIdentity(key:$0.key,feature:$0.feature),$0.payload) },uniquingKeysWith:{ _,last in last })
            // Sorted keys: an unchanged snapshot encodes to the stored bytes and is not rewritten.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            for snapshot in result.snapshots where !obsolete.contains(snapshot.key) && (rowKeys.contains(snapshot.key) || !obsolete.contains(where:{ $0.repository == snapshot.key.repository })) {
                let key = snapshot.key
                if let payload=started[SnapshotIdentity(key:key,feature:snapshot.feature)],
                   let stored=try Data.fetchOne(db,sql:"SELECT json FROM pollFeatureSnapshots WHERE host=? AND accountID=? AND repositoryID=? AND objectID=? AND feature=?",arguments:[key.host,key.accountID,key.repositoryID,key.objectID,snapshot.feature]),
                   try JSONDecoder().decode(PollFeatureSnapshot.self,from:stored).payload != payload { continue }
                try db.execute(sql:"INSERT INTO pollFeatureSnapshots VALUES (?,?,?,?,?,?) ON CONFLICT(host,accountID,repositoryID,objectID,feature) DO UPDATE SET json=excluded.json WHERE json IS NOT excluded.json",arguments:[key.host,key.accountID,key.repositoryID,key.objectID,snapshot.feature,try encoder.encode(snapshot)])
                if db.changesCount > 0 { changes.repositories[snapshot.feature,default:[]].insert(key.repository) }
            }
            let currentEvents=result.events.filter { !obsolete.contains($0.object) }
            changes.events = try Self.record(currentEvents,baselineKeys:context.suppressNotifications ? Set(result.events.map(\.key)) : result.baselineEventKeys,cycleID:context.cycleID,in:db)
            for repo in result.baselinedRepositories where !obsolete.contains(where:{ $0.repository == repo }) {
                try db.execute(sql:"INSERT OR IGNORE INTO pollBaselines VALUES (?,?,?,?)",arguments:[repo.account.host,repo.account.accountID,repo.repositoryID,context.featureID])
            }
            for response in result.responses where obsolete.isEmpty {
                try db.execute(sql:"INSERT INTO pollResponses(host,accountID,url,etag,lastModified,body,nextURL,feature) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(host,accountID,url) DO UPDATE SET etag=excluded.etag,lastModified=excluded.lastModified,body=excluded.body,nextURL=excluded.nextURL,feature=excluded.feature",arguments:[context.account.host,context.account.accountID,response.url.absoluteString,response.etag,response.lastModified,response.body,response.nextURL?.absoluteString,context.featureID])
            }
            return changes
        }
    }
    public func observationFences(account:AccountScope) throws -> [ProviderKey:Int] { try database.observationFences(account:account) }
    /// Every cached PR in the account, in snapshot order, without settings/drafts/repositories.
    public func pullRequests(account: AccountScope) throws -> [PullRequest] {
        try database.pullRequestsInSnapshotOrder(account:account)
    }
    /// A work item's cached rows: decoding is proportional to its scope, not the account history.
    public func pullRequests(repositories: Set<RepositoryKey>) throws -> [PullRequest] { try database.pullRequests(repositories:repositories) }
    /// These repositories' stored PR rows, decoding only what the caller has not already decoded: rows whose stored
    /// bytes differ from `known` (fingerprints returned by an earlier call), new rows, and rows carrying merge
    /// evidence (their overlay depends on the live write ledger and the clock, not only on their bytes).
    /// `openOrUpdatedSince` limits the read to open PRs and PRs updated since then (a launch's first pass).
    public func pullRequestRows(repositories: Set<RepositoryKey>, known: [ProviderKey:Int] = [:], openOrUpdatedSince: Date? = nil) throws -> PullRequestRows {
        let evidenceMarker = Data("\"mergeEvidence\"".utf8)
        let (active,rows) = try database.database.read { db -> (Set<ProviderKey>,[(ProviderKey,Data)]) in
            var rows: [(ProviderKey,Data)] = []
            let window = openOrUpdatedSince.map { _ in " AND (state='open' OR updatedAt >= ?)" } ?? ""
            for repo in repositories.sorted(by:{ ($0.account.host,$0.account.accountID,$0.repositoryID) < ($1.account.host,$1.account.accountID,$1.repositoryID) }) {
                var arguments: StatementArguments = [repo.account.host,repo.account.accountID,repo.repositoryID]
                if let since = openOrUpdatedSince { arguments += [since.timeIntervalSinceReferenceDate] }
                for row in try Row.fetchAll(db,sql:"SELECT objectID,json FROM pullRequests WHERE host=? AND accountID=? AND repositoryID=?"+window+" ORDER BY objectID",arguments:arguments) {
                    rows.append((ProviderKey(host:repo.account.host,accountID:repo.account.accountID,repositoryID:repo.repositoryID,objectID:row["objectID"]),row["json"]))
                }
            }
            return (try DatabaseStore.activeReservations(db),rows)
        }
        var fingerprints: [ProviderKey:Int] = [:], pending: [(ProviderKey,Data)] = []
        fingerprints.reserveCapacity(rows.count)
        for (key,json) in rows {
            var hasher = Hasher(); hasher.combine(json.count); json.withUnsafeBytes { hasher.combine(bytes:$0) }
            let fingerprint = hasher.finalize()
            fingerprints[key] = fingerprint
            if known[key] != fingerprint || json.range(of:evidenceMarker) != nil { pending.append((key,json)) }
        }
        let decoded = try RawPullRequests(active:active,rows:pending.map(\.1)).decoded()
        return PullRequestRows(keys:rows.map(\.0),fingerprints:fingerprints,decoded:Dictionary(zip(pending.map(\.0),decoded),uniquingKeysWith:{ _,last in last }))
    }
    /// PR inventory display status for these repositories, without decoding each status's resumable checkpoint.
    public func inventoryStatuses(repositories: Set<RepositoryKey>) throws -> [RepositoryKey:PRInventoryStatus] {
        let feature = GitHubPRInventoryFetcher().featureID
        let rows = try database.database.read { db in
            try repositories.compactMap { key in
                try Data.fetchOne(db,sql:"SELECT json FROM pollFeatureSnapshots WHERE host=? AND accountID=? AND repositoryID=? AND objectID='pull-request-inventory' AND feature=?",arguments:[key.account.host,key.account.accountID,key.repositoryID,feature]).map { (key,$0) }
            }
        }
        let decoder = JSONDecoder()
        return Dictionary(try rows.map { key,json in
            let summary = try decoder.decode(InventoryStatusSummary.self,from:decoder.decode(PollFeatureSnapshot.self,from:json).payload)
            return (key,PRInventoryStatus(complete:summary.complete,fetchedCount:summary.fetchedCount,fetchedAt:summary.fetchedAt,message:summary.message,
                lastSuccessAt:summary.lastSuccessAt,lastFailureAt:summary.lastFailureAt,failureMessage:summary.failureMessage))
        },uniquingKeysWith:{ first,_ in first })
    }
    /// `PRInventoryStatus` without its resumable checkpoint (`continuation`, up to megabytes per repository).
    private struct InventoryStatusSummary: Decodable {
        var complete: Bool
        var fetchedCount: Int
        var fetchedAt: Date
        var message: String?
        var lastSuccessAt: Date?
        var lastFailureAt: Date?
        var failureMessage: String?
    }
    public func featureSnapshots(account: AccountScope, feature: String) throws -> [PollFeatureSnapshot] {
        try database.database.read { db in
            try Data.fetchAll(db,sql:"SELECT json FROM pollFeatureSnapshots WHERE host=? AND accountID=? AND feature=? ORDER BY repositoryID,objectID",arguments:[account.host,account.accountID,feature]).map { try JSONDecoder().decode(PollFeatureSnapshot.self,from:$0) }
        }
    }
    /// One feature's snapshots for these repositories only (primary-key prefix reads), in repository then
    /// object order. Proportional to the scope, so a work item can read its checkpoint when it starts.
    public func featureSnapshots(account: AccountScope, feature: String, repositories: Set<RepositoryKey>) throws -> [PollFeatureSnapshot] {
        try database.database.read { db in
            let decoder = JSONDecoder()
            return try repositories.filter { $0.account == account }.map(\.repositoryID).sorted().flatMap { repository in
                try Data.fetchAll(db,sql:"SELECT json FROM pollFeatureSnapshots WHERE host=? AND accountID=? AND repositoryID=? AND feature=? ORDER BY objectID",arguments:[account.host,account.accountID,repository,feature]).map { try decoder.decode(PollFeatureSnapshot.self,from:$0) }
            }
        }
    }
    public func repositoryMetadata(account: AccountScope) throws -> [RepositoryKey:Repository] {
        Dictionary(uniqueKeysWithValues:try database.repositories(account:account).map { ($0.key,$0) })
    }
    public func baselines(account: AccountScope, feature: String) throws -> Set<RepositoryKey> {
        try database.database.read { db in
            Set(try String.fetchAll(db,sql:"SELECT repositoryID FROM pollBaselines WHERE host=? AND accountID=? AND feature=?",arguments:[account.host,account.accountID,feature]).map { RepositoryKey(account:account,repositoryID:$0) })
        }
    }
    public func responses(account: AccountScope) throws -> [String:PollResponseCache] { try responses(account:account,feature:nil) }
    /// Only the bodies a fetcher can reuse; other features' private bodies are not loaded.
    public func responses(account: AccountScope, feature: String?) throws -> [String:PollResponseCache] {
        try database.database.read { db in
            Dictionary(uniqueKeysWithValues:try Row.fetchAll(db,sql:"SELECT url,etag,lastModified,body,nextURL FROM pollResponses WHERE host=? AND accountID=?"+(feature == nil ? "" : " AND feature=?"),arguments:StatementArguments([account.host,account.accountID]+(feature.map { [$0] } ?? []))).compactMap { row in
                guard let url = URL(string:row["url"]) else { return nil }
                return (url.absoluteString,PollResponseCache(url:url,etag:row["etag"],body:row["body"],nextURL:(row["nextURL"] as String?).flatMap(URL.init(string:)),lastModified:row["lastModified"]))
            })
        }
    }
    public func snapshot(_ key: ProviderKey, feature: String) throws -> PollFeatureSnapshot? {
        try database.database.read { db in
            try Data.fetchOne(db,sql:"SELECT json FROM pollFeatureSnapshots WHERE host=? AND accountID=? AND repositoryID=? AND objectID=? AND feature=?",arguments:[key.host,key.accountID,key.repositoryID,key.objectID,feature]).map { try JSONDecoder().decode(PollFeatureSnapshot.self,from:$0) }
        }
    }
    public func failure(_ cycleID: UUID, workID: String, message: String) throws {
        try database.database.write { db in
            try Self.requireOpen(db,cycleID)
            try db.execute(sql:"INSERT OR IGNORE INTO pollFailures VALUES (?,?,?)",arguments:[cycleID.uuidString,workID,message])
        }
    }
    public func failures(_ cycleID: UUID) throws -> [String] {
        try database.database.read { try String.fetchAll($0,sql:"SELECT message FROM pollFailures WHERE cycleID=? ORDER BY workID",arguments:[cycleID.uuidString]) }
    }
    /// Recorded events never change (INSERT OR IGNORE); only their flags do. Decoded events are kept by key and
    /// byte length, so repeated inbox reads and cycle closes decode only newly recorded rows.
    private let decodedEvents = Mutex<[String:(length:Int,event:ChangeEvent)]>([:])
    /// Event JSON decodes performed by this store (measurement).
    var eventDecodes: Int { eventDecodeCount.withLock { $0 } }
    private let eventDecodeCount = Mutex(0)
    private struct EventRow { let key: String; let length: Int; let acknowledged: Bool; let surfaced: Bool }
    private static func eventRows(_ db: Database, where filter: String = "", order: String = "eventKey", limit: Int? = nil, offset: Int = 0) throws -> [EventRow] {
        try Row.fetchAll(db,sql:"SELECT eventKey,length(json) AS length,acknowledged,surfaced FROM changeEvents"+filter+" ORDER BY "+order+(limit.map { " LIMIT \(max(0,$0)) OFFSET \(max(0,offset))" } ?? "")).map {
            EventRow(key:$0["eventKey"],length:$0["length"],acknowledged:$0["acknowledged"],surfaced:$0["surfaced"])
        }
    }
    /// Reads the JSON of rows missing from (or stale in) the decode cache, in the same read transaction.
    private func events(for rows: [EventRow], in db: Database) throws -> [String:Data] {
        let cached = decodedEvents.withLock { cache in Set(rows.filter { cache[$0.key]?.length == $0.length }.map(\.key)) }
        var missing: [String:Data] = [:]
        for row in rows where !cached.contains(row.key) {
            if let json = try Data.fetchOne(db,sql:"SELECT json FROM changeEvents WHERE eventKey=?",arguments:[row.key]) { missing[row.key] = json }
        }
        return missing
    }
    /// Decodes outside the database transaction, then serves every row from the cache.
    private func inboxEvents(_ rows: [EventRow], _ missing: [String:Data]) throws -> [InboxEvent] {
        let decoder = JSONDecoder()
        let fresh = try missing.mapValues { (length:$0.count,event:try decoder.decode(ChangeEvent.self,from:$0)) }
        eventDecodeCount.withLock { $0 += fresh.count }
        return decodedEvents.withLock { cache in
            if cache.count + fresh.count > 50_000 { cache = [:] }
            cache.merge(fresh) { _,new in new }
            return rows.compactMap { row in cache[row.key].map { InboxEvent(event:$0.event,acknowledged:row.acknowledged,surfaced:row.surfaced) } }
        }
    }
    private func readInbox(where filter: String = "", order: String = "eventKey", limit: Int? = nil, offset: Int = 0) throws -> [InboxEvent] {
        let (rows,missing) = try database.database.read { db in
            let rows = try Self.eventRows(db,where:filter,order:order,limit:limit,offset:offset)
            return (rows,try events(for:rows,in:db))
        }
        return try inboxEvents(rows,missing)
    }
    public func inbox(eventKeys: [String]? = nil) throws -> [InboxEvent] {
        let events = try readInbox()
        guard let eventKeys else { return events }
        let keys = Set(eventKeys); return events.filter { keys.contains($0.id) }
    }
    /// One page of the inbox, most recently recorded first.
    public func inbox(limit: Int, offset: Int = 0) throws -> [InboxEvent] {
        try readInbox(order:"rowid DESC",limit:limit,offset:offset)
    }
    /// Events not yet acknowledged or surfaced: the only ones a cycle summary can deliver.
    public func pendingInbox() throws -> [InboxEvent] {
        try readInbox(where:" WHERE acknowledged=0 AND surfaced=0")
    }
    public func acknowledge(_ eventKeys: [String]) throws {
        try database.database.write { db in
            for key in Set(eventKeys) { try db.execute(sql:"UPDATE changeEvents SET acknowledged=1 WHERE eventKey=?",arguments:[key]) }
        }
    }
    /// Candidate events (unacknowledged, unsurfaced) are read and decoded before the write transaction; inside
    /// it, only their still-pending keys are rechecked (no JSON) along with the open cycle.
    public func close(_ id: UUID, at date: Date, policy: NotificationPolicy, suppress: Bool = false) throws -> PollSummary {
        let baseline = try database.database.read { try Bool.fetchOne($0,sql:"SELECT baseline FROM pollCycles WHERE id=?",arguments:[id.uuidString]) } ?? false
        let candidates = baseline || suppress ? [] : try pendingInbox().map(\.event).filter { policy.permits($0,at:date) }
        return try database.database.write { db in
            try Self.requireOpen(db,id)
            var events = candidates
            if !events.isEmpty {
                let pending = Set(try String.fetchAll(db,sql:"SELECT eventKey FROM changeEvents WHERE acknowledged=0 AND surfaced=0"))
                events = events.filter { pending.contains($0.key) }
            }
            let summary = NotificationAggregator.summary(cycleID:id,events:events)
            try db.execute(sql:"UPDATE pollCycles SET status='closed',closedAt=?,summary=? WHERE id=?",arguments:[date.timeIntervalSince1970,try JSONEncoder().encode(summary),id.uuidString])
            return summary
        }
    }
    public func summary(_ id: UUID) throws -> PollSummary? {
        try database.database.read { db in
            try Data.fetchOne(db,sql:"SELECT summary FROM pollCycles WHERE id=?",arguments:[id.uuidString]).map { try JSONDecoder().decode(PollSummary.self,from:$0) }
        }
    }
    public func reserve(_ summary: PollSummary) async throws -> Bool {
        guard !summary.eventKeys.isEmpty else { return false }
        return try await database.database.write { db in
            guard let json = try Data.fetchOne(db,sql:"SELECT summary FROM pollCycles WHERE id=? AND status='closed'",arguments:[summary.cycleID.uuidString]),
                  try JSONDecoder().decode(PollSummary.self,from:json) == summary else { throw PollStorageError.invalidSummary }
            try db.execute(sql:"INSERT OR IGNORE INTO notificationAttempts VALUES (?,?,'reserved')",arguments:[summary.cycleID.uuidString,json])
            guard db.changesCount == 1 else { return false }
            for key in summary.eventKeys {
                try db.execute(sql:"UPDATE changeEvents SET surfaced=1 WHERE eventKey=?",arguments:[key])
            }
            return true
        }
    }
    public func finishAttempt(_ cycleID: UUID, delivered: Bool) async throws {
        try await database.database.write { db in
            try db.execute(sql:"UPDATE notificationAttempts SET state=? WHERE cycleID=? AND state='reserved'",arguments:[delivered ? "delivered" : "failed",cycleID.uuidString])
        }
    }
    public func attemptState(_ id: UUID) throws -> String? {
        try database.database.read { try String.fetchOne($0,sql:"SELECT state FROM notificationAttempts WHERE cycleID=?",arguments:[id.uuidString]) }
    }
}
