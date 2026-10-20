import Foundation
import GRDB

/// Transactional SQLite storage. Create one store per application database. A file database is a
/// WAL pool: writes are serialized, reads run beside them on the last committed snapshot, so a read
/// never observes a half-applied write. Calls are synchronous; invoke them off the main actor for large batches.
public final class DatabaseStore: Sendable {
    let database: any DatabaseWriter
    /// Bytes a WAL keeps after a checkpoint resets it (SQLite truncates it to this size).
    static let journalSizeLimit = 4 * 1024 * 1024

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // Deleted normalized private payloads should not linger in SQLite free pages (every connection).
            try db.execute(sql: "PRAGMA secure_delete = ON")
            // A reset WAL is truncated back to this size, so old frames do not pile up in a large file.
            try db.execute(sql: "PRAGMA journal_size_limit = \(Self.journalSizeLimit)")
        }
        if path == ":memory:" {
            database = try DatabaseQueue(path: path, configuration: configuration)
        } else {
            // SQLite gives the -wal and -shm files the database file's mode, so create it private first.
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            database = try DatabasePool(path: path, configuration: configuration)
            for file in [path, path + "-wal", path + "-shm"] where FileManager.default.fileExists(atPath: file) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
            }
        }
        try Migrations.migrator().migrate(database)
    }

    /// Sorted keys: JSONEncoder's key order otherwise varies between encodes of an equal value, so an
    /// unchanged row would never compare equal and every upsert would rewrite it.
    static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public func saveAccount(_ account: Account) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO accounts (host, accountID, login, tokenReference) VALUES (?, ?, ?, ?)
                ON CONFLICT(host, accountID) DO UPDATE SET login = excluded.login, tokenReference = excluded.tokenReference
                WHERE login IS NOT excluded.login OR tokenReference IS NOT excluded.tokenReference
                """, arguments: [account.scope.host, account.scope.accountID, account.login, account.tokenReference])
        }
    }

    public func accounts() throws -> [Account] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM accounts ORDER BY host, accountID").map {
                Account(scope: AccountScope(host: $0["host"], accountID: $0["accountID"]),
                        login: $0["login"], tokenReference: $0["tokenReference"])
            }
        }
    }

    public func saveRepository(_ repository: Repository) throws {
        let json = try Self.canonicalJSON(repository)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO repositories (host, accountID, repositoryID, json) VALUES (?, ?, ?, ?)
                ON CONFLICT(host, accountID, repositoryID) DO UPDATE SET json = excluded.json WHERE json IS NOT excluded.json
                """, arguments: [repository.key.account.host, repository.key.account.accountID, repository.key.repositoryID, json])
        }
    }

    /// Commits a normalized response atomically; an invalid membership rolls back the batch.
    public func savePullRequests(_ pullRequests: [PullRequest]) throws {
        try database.write { db in
            for pr in pullRequests {
                let pr=try PRClassificationStore.applyingRules(to:pr,in:db)
                try db.execute(sql: """
                    INSERT INTO pullRequests (host, accountID, repositoryID, objectID, json) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(host, accountID, repositoryID, objectID) DO UPDATE SET json = excluded.json WHERE json IS NOT excluded.json
                    """, arguments: [pr.key.host, pr.key.accountID, pr.key.repositoryID, pr.key.objectID, try Self.canonicalJSON(pr)])
            }
        }
    }

    public func setTracked(_ key: RepositoryKey, tracked: Bool) throws {
        try database.write { db in
            if tracked {
                try db.execute(sql: "INSERT OR IGNORE INTO trackedRepositories VALUES (?, ?, ?)",
                               arguments: [key.account.host, key.account.accountID, key.repositoryID])
            } else {
                try db.execute(sql: "DELETE FROM trackedRepositories WHERE host = ? AND accountID = ? AND repositoryID = ?",
                               arguments: [key.account.host, key.account.accountID, key.repositoryID])
            }
            try Self.recordExplicitRepositorySelection(key,in:db)
        }
    }

    public func setPinned(_ key: ProviderKey, pinned: Bool) throws {
        try database.write { db in
            if pinned {
                try db.execute(sql: "INSERT OR IGNORE INTO pins VALUES (?, ?, ?, ?)",
                               arguments: [key.host, key.accountID, key.repositoryID, key.objectID])
            } else {
                try db.execute(sql: "DELETE FROM pins WHERE host = ? AND accountID = ? AND repositoryID = ? AND objectID = ?",
                               arguments: [key.host, key.accountID, key.repositoryID, key.objectID])
            }
        }
    }

    /// A raw name, for tests; production code writes `AccountSettingKey`s.
    func setSetting(_ value: String, for name: String, account: AccountScope) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO settings VALUES (?, ?, ?, ?)
                ON CONFLICT(host, accountID, name) DO UPDATE SET value = excluded.value WHERE value IS NOT excluded.value
                """, arguments: [account.host, account.accountID, name, value])
        }
    }

    /// Upserts private, unsent text, including drafts whose account is inaccessible.
    public func saveDraft(_ draft: Draft) throws {
        try database.write { db in
            if let existing = try Data.fetchOne(db, sql: "SELECT json FROM drafts WHERE id = ?", arguments: [draft.id.uuidString]),
               try JSONDecoder().decode(Draft.self, from: existing).key != draft.key {
                throw StorageError.draftIdentityConflict
            }
            try db.execute(sql: """
                INSERT INTO drafts VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET json = excluded.json
                """, arguments: [draft.id.uuidString, draft.key.host, draft.key.accountID, try JSONEncoder().encode(draft)])
        }
    }

    /// Whole-account state, including every cached PR. For one setting, row or repository,
    /// use the targeted lookups in DatabaseLookups.swift instead.
    public func snapshot(for account: AccountScope) throws -> LocalSnapshot {
        try database.read { try Self.fetchSnapshot($0, account: account) }.decoded()
    }

    /// Initial local state followed by committed changes, with no UI-framework dependency.
    public func snapshots(for account: AccountScope) -> AsyncValueObservation<LocalSnapshot> {
        ValueObservation.tracking { db in
            try Self.fetchSnapshot(db, account: account)
        }.map { try $0.decoded() }.removeDuplicates().values(in: database, bufferingPolicy: .bufferingNewest(1))
    }

    /// One consistent read of raw rows. Decoding runs after the database is released, so
    /// other readers and the poller's writes do not wait behind JSON decoding.
    private static func fetchSnapshot(_ db: Database, account: AccountScope) throws -> RawSnapshot {
        let arguments: StatementArguments = [account.host, account.accountID]
        let predicate = " WHERE host = ? AND accountID = ?"
        let accountRow = try Row.fetchOne(db, sql: "SELECT login, tokenReference FROM accounts" + predicate, arguments: arguments)
        func raw(_ table: String, order: String) throws -> [Data] {
            try Data.fetchAll(db, sql: "SELECT json FROM " + table + predicate + " ORDER BY " + order, arguments: arguments)
        }
        return RawSnapshot(
            account: accountRow.map { Account(scope: account, login: $0["login"], tokenReference: $0["tokenReference"]) },
            repositories: try raw("repositories", order: "repositoryID"),
            trackedRepositories: try trackedRepositories(account: account, in: db),
            pins: try pins(account: account, in: db),
            settings: try settings(account: account, in: db),
            pullRequests: RawPullRequests(active: try activeReservations(db), rows: try raw("pullRequests", order: "repositoryID, objectID")),
            drafts: try raw("drafts", order: "id"))
    }
    private struct RawSnapshot: Sendable {
        let account: Account?
        let repositories: [Data]
        let trackedRepositories: Set<RepositoryKey>
        let pins: Set<ProviderKey>
        let settings: [String: String]
        let pullRequests: RawPullRequests
        let drafts: [Data]
        func decoded() throws -> LocalSnapshot {
            let decoder = JSONDecoder()
            return LocalSnapshot(account: account, repositories: try repositories.map { try decoder.decode(Repository.self, from: $0) },
                                 trackedRepositories: trackedRepositories, pins: pins, settings: settings,
                                 pullRequests: try pullRequests.decoded(), drafts: try drafts.map { try decoder.decode(Draft.self, from: $0) })
        }
    }

    func account(_ scope: AccountScope) throws -> Account? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT login, tokenReference FROM accounts WHERE host = ? AND accountID = ?",
                             arguments: [scope.host, scope.accountID])
                .map { Account(scope: scope, login: $0["login"], tokenReference: $0["tokenReference"]) }
        }
    }

    /// `secure_delete` zeroes freed pages, but the WAL still holds the frames written before a delete. After
    /// a purge, checkpoint everything into the database file and truncate the WAL to zero bytes. Best effort:
    /// a reader still on an older snapshot makes it busy; the next purge or daily maintenance retries.
    func scrubWriteAheadLog() {
        do { try database.writeWithoutTransaction { try $0.checkpoint(.truncate) } }
        catch { Log.storage.info("WAL checkpoint after a purge did not complete; retried later: \(Log.kind(error), privacy: .public)") }
    }

    // CacheStore owns cleanup ordering; this must not be exposed independently of file/credential removal.
    /// Removal was confirmed by the user ("Remove its Keychain credentials and private cached data"), so the
    /// account's write ledger goes with it, unresolved rows included: they hold sent review, comment, merge and
    /// edit text. Unsent drafts stay (no account FK). One transaction: nothing private outlives a partial removal.
    func deleteAccountRecords(_ scope: AccountScope) throws {
        try database.write { db in
            let arguments: StatementArguments = [scope.host, scope.accountID]
            try Self.purgeFeaturePayloads(scope,in:db)
            try db.execute(sql:"DELETE FROM actions_operations WHERE host=? AND accountID=?",arguments:arguments)
            try db.execute(sql:"DELETE FROM repo_browser_operations WHERE account_host=? AND account_id=?",arguments:arguments)
            // Inbox events carry the removed account's private titles/locators and have no account FK; so do
            // the per-subject items stored with closed cycles and notification attempts.
            try Self.scrubNotificationSummaries(scope,in:db)
            try db.execute(sql:"DELETE FROM changeEvents WHERE host=? AND accountID=?",arguments:arguments)
            try db.execute(sql:"DELETE FROM changeEventRetention WHERE host=? AND accountID=?",arguments:arguments)
            try db.execute(sql:"DELETE FROM notificationThreadOperations WHERE host=? AND accountID=?",arguments:arguments)
            try db.execute(sql:"DELETE FROM prObservationFences WHERE host=? AND accountID=?",arguments:arguments)
            // The review ledger has no account column: its identity is base64 sorted-keys JSON of the PR key.
            for row in try Row.fetchAll(db,sql:"SELECT id,identity,json FROM reviewOperations") where Self.ledgerAccount(identity:row["identity"],json:row["json"]) == scope {
                try db.execute(sql:"DELETE FROM reviewOperations WHERE id=?",arguments:[row["id"] as String])
            }
            // Revision-bound reading progress names private paths and is app-wide; remove it with the account.
            let progress = SettingsKey.detailProgressPrefix
            for name in try String.fetchAll(db,sql:"SELECT name FROM applicationSettings WHERE substr(name,1,?)=?",arguments:[progress.count,progress])
            where Self.providerKey(identity:String(name.dropFirst(progress.count)))?.account == scope {
                try db.execute(sql:"DELETE FROM applicationSettings WHERE name=?",arguments:[name])
            }
            try db.execute(sql: "DELETE FROM accounts WHERE host = ? AND accountID = ?", arguments: arguments)
        }
        scrubWriteAheadLog()
    }
    static func providerKey(identity: String) -> ProviderKey? {
        Data(base64Encoded:identity).flatMap { try? JSONDecoder().decode(ProviderKey.self,from:$0) }
    }
    /// A ledger row's account from its identity, else from the stored command. Unattributable rows return nil and stay.
    static func ledgerAccount(identity: String, json: Data) -> AccountScope? {
        providerKey(identity:identity)?.account ?? (try? JSONDecoder().decode(PRWriteOperation.self,from:json))?.command.key.account
    }

    /// A confirmed-invalid (revoked or expired) credential: purge the account's private provider content
    /// (inbox events, feed bodies and validators, PR and repository rows, poll checkpoints and baselines,
    /// detail indexes and the payload manifest). The account, settings, pins, drafts, reading progress and
    /// the entire write ledger stay: an unresolved write is never resent and reconciles after reconnecting.
    /// Tracked selections are kept as opaque repository IDs and restored by the next discovery; cleared
    /// baselines make the first poll after reconnecting re-baseline instead of notifying.
    func purgePrivateContent(_ scope: AccountScope) throws {
        try database.write { db in
            let arguments: StatementArguments = [scope.host, scope.accountID]
            try Self.purgeFeaturePayloads(scope,in:db)
            let tracked = try String.fetchAll(db,sql:"SELECT repositoryID FROM trackedRepositories WHERE host=? AND accountID=?",arguments:arguments)
            try Self.retainTracking(Set(tracked),account:scope,in:db)
            try Self.scrubNotificationSummaries(scope,in:db)
            for table in ["changeEvents","pollResponses","pollBaselines","pollFeatureSnapshots","pullRequests","repositories","cacheEntries"] {
                try db.execute(sql:"DELETE FROM \(table) WHERE host=? AND accountID=?",arguments:arguments)
            }
        }
        scrubWriteAheadLog()
    }
    /// Removes the account's subjects and event keys from every stored cycle summary and notification attempt
    /// (other accounts' items stay). Run before the account's inbox rows are deleted: they attribute the keys
    /// of collapsed summaries. An undecodable summary cannot be attributed and is cleared, failing closed; an
    /// attempt row itself stays, so its cycle is never notified twice.
    static func scrubNotificationSummaries(_ scope:AccountScope,in db:Database) throws {
        let keys = Set(try String.fetchAll(db,sql:"SELECT eventKey FROM changeEvents WHERE host=? AND accountID=?",arguments:[scope.host,scope.accountID]))
        let decoder = JSONDecoder()
        // Cycles without events (most of them) carry nothing private and are skipped without decoding.
        let named = "summary IS NOT NULL AND (NOT json_valid(CAST(summary AS TEXT)) OR json_array_length(CAST(summary AS TEXT),'$.eventKeys') > 0)"
        for (table,column) in [("pollCycles","id"),("notificationAttempts","cycleID")] {
            for row in try Row.fetchAll(db,sql:"SELECT \(column) AS id, summary FROM \(table) WHERE \(named)") {
                let id: String = row["id"]
                let replacement: Data?
                if let summary = try? decoder.decode(PollSummary.self,from:row["summary"] as Data) {
                    guard let scrubbed = summary.removing(account:scope,eventKeys:keys) else { continue }
                    replacement = try JSONEncoder().encode(scrubbed)
                } else if table == "notificationAttempts" {
                    replacement = try JSONEncoder().encode(PollSummary(cycleID:UUID(uuidString:id) ?? UUID(),eventKeys:[],title:"",body:""))
                } else { replacement = nil }
                try db.execute(sql:"UPDATE \(table) SET summary=? WHERE \(column)=?",arguments:[replacement,id])
            }
        }
    }
    func purgeFeaturePayloads(_ scope:AccountScope) throws {
        try database.write { try Self.purgeFeaturePayloads(scope,in:$0) }
        scrubWriteAheadLog()
    }
    private static func purgeFeaturePayloads(_ scope:AccountScope,in db:Database) throws {
        for table in ["actions_catalog","actions_presets","actions_view_state"] {
            try db.execute(sql:"DELETE FROM \(table) WHERE host=? AND accountID=?",arguments:[scope.host,scope.accountID])
        }
        for table in ["repo_browser_cache","repo_browser_state"] {
            try db.execute(sql:"DELETE FROM \(table) WHERE account_host=? AND account_id=?",arguments:[scope.host,scope.accountID])
        }
        try db.execute(sql:"DELETE FROM pollFeatureSnapshots WHERE host=? AND accountID=? AND feature='github-actions'",arguments:[scope.host,scope.accountID])
        // PR detail index rows name the purged content by hash. Keep only the merge-base memo (commit SHAs,
        // no private content): nothing then mistakes a purged payload for a cached one, and a reopen still
        // skips the merge-base read. An unreadable row is removed.
        let feature=PRDetailService.cacheFeature,decoder=JSONDecoder()
        for row in try Row.fetchAll(db,sql:"SELECT repositoryID,objectID,json FROM pollFeatureSnapshots WHERE host=? AND accountID=? AND feature=?",arguments:[scope.host,scope.accountID,feature]) {
            let target:StatementArguments=[scope.host,scope.accountID,row["repositoryID"] as String,row["objectID"] as String,feature]
            guard let json=row["json"] as Data?,let snapshot=try? decoder.decode(PollFeatureSnapshot.self,from:json),
                  let index=try? decoder.decode(PRDetailCacheIndex.self,from:snapshot.payload),!index.mergeBases.isEmpty else {
                try db.execute(sql:"DELETE FROM pollFeatureSnapshots WHERE host=? AND accountID=? AND repositoryID=? AND objectID=? AND feature=?",arguments:target)
                continue
            }
            let stripped=PollFeatureSnapshot(key:snapshot.key,feature:feature,payload:try JSONEncoder().encode(PRDetailCacheIndex(head:index.head,mergeBases:index.mergeBases)))
            try db.execute(sql:"UPDATE pollFeatureSnapshots SET json=? WHERE host=? AND accountID=? AND repositoryID=? AND objectID=? AND feature=?",arguments:[try JSONEncoder().encode(stripped)]+target)
        }
        // Cached response bodies are private. Only the notification feed's account-partitioned
        // validators survive revocation; unknown-feature rows fail closed and are purged.
        try db.execute(sql:"DELETE FROM pollResponses WHERE host=? AND accountID=? AND feature IS NOT ?",arguments:[scope.host,scope.accountID,PollCycleStore.notificationFeedFeature])
    }
}
