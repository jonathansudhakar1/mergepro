import GRDB

public enum Migrations {
    /// A JSON path from a stored `json` column; malformed JSON yields NULL instead of failing the statement.
    /// Part of migration v8's schema: never change this text once v8 has shipped.
    static func extract(_ path: String) -> String { "CASE WHEN json_valid(CAST(json AS TEXT)) THEN json_extract(CAST(json AS TEXT),'\(path)') END" }
    /// The write ledger's state, exactly as indexed by `reviewOperations_state`. Queries must use this same
    /// expression text for SQLite to use the index.
    static let reviewOperationState = extract("$.state")
    /// Forward-only schema versions. GRDB rolls back a failed migration transaction.
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-core") { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    host TEXT NOT NULL, accountID TEXT NOT NULL,
                    login TEXT NOT NULL, tokenReference TEXT,
                    PRIMARY KEY (host, accountID)
                );
                CREATE TABLE repositories (
                    host TEXT NOT NULL, accountID TEXT NOT NULL, repositoryID TEXT NOT NULL,
                    json BLOB NOT NULL, PRIMARY KEY (host, accountID, repositoryID),
                    FOREIGN KEY (host, accountID) REFERENCES accounts ON DELETE CASCADE
                );
                CREATE TABLE trackedRepositories (
                    host TEXT NOT NULL, accountID TEXT NOT NULL, repositoryID TEXT NOT NULL,
                    PRIMARY KEY (host, accountID, repositoryID),
                    FOREIGN KEY (host, accountID, repositoryID) REFERENCES repositories ON DELETE CASCADE
                );
                CREATE TABLE pullRequests (
                    host TEXT NOT NULL, accountID TEXT NOT NULL, repositoryID TEXT NOT NULL,
                    objectID TEXT NOT NULL, json BLOB NOT NULL,
                    PRIMARY KEY (host, accountID, repositoryID, objectID),
                    FOREIGN KEY (host, accountID, repositoryID) REFERENCES repositories ON DELETE CASCADE
                );
                CREATE TABLE pins (
                    host TEXT NOT NULL, accountID TEXT NOT NULL, repositoryID TEXT NOT NULL,
                    objectID TEXT NOT NULL, PRIMARY KEY (host, accountID, repositoryID, objectID),
                    FOREIGN KEY (host, accountID) REFERENCES accounts ON DELETE CASCADE
                );
                CREATE TABLE settings (
                    host TEXT NOT NULL, accountID TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL,
                    PRIMARY KEY (host, accountID, name),
                    FOREIGN KEY (host, accountID) REFERENCES accounts ON DELETE CASCADE
                );
                -- No cascading account FK: inaccessible drafts remain private locally.
                CREATE TABLE drafts (
                    id TEXT PRIMARY KEY NOT NULL, host TEXT NOT NULL, accountID TEXT NOT NULL,
                    json BLOB NOT NULL
                );
                CREATE INDEX drafts_account ON drafts(host, accountID);
                CREATE TABLE cacheEntries (
                    id TEXT PRIMARY KEY NOT NULL, host TEXT NOT NULL, accountID TEXT NOT NULL,
                    byteCount INTEGER NOT NULL CHECK (byteCount >= 0), accessOrder INTEGER NOT NULL,
                    FOREIGN KEY (host, accountID) REFERENCES accounts ON DELETE CASCADE
                );
                CREATE INDEX cache_lru ON cacheEntries(accessOrder, id);
                """)
        }
        migrator.registerMigration("v2-application-settings") { db in
            try db.execute(sql: "CREATE TABLE applicationSettings (name TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
        }
        migrator.registerMigration("v3-poll-cycles-inbox-attempts") { db in
            try db.execute(sql: """
                CREATE TABLE pollCycles (
                    id TEXT PRIMARY KEY NOT NULL, startedAt REAL NOT NULL, closedAt REAL,
                    baseline INTEGER NOT NULL, status TEXT NOT NULL, summary BLOB
                );
                CREATE UNIQUE INDEX one_open_cycle ON pollCycles(status) WHERE status = 'open';
                CREATE TABLE changeEvents (
                    eventKey TEXT PRIMARY KEY NOT NULL, cycleID TEXT NOT NULL,
                    host TEXT NOT NULL, accountID TEXT NOT NULL, repositoryID TEXT NOT NULL,
                    json BLOB NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0,
                    surfaced INTEGER NOT NULL DEFAULT 0,
                    FOREIGN KEY (cycleID) REFERENCES pollCycles(id)
                );
                CREATE INDEX inbox_account ON changeEvents(host, accountID, repositoryID);
                CREATE TABLE notificationAttempts (
                    cycleID TEXT PRIMARY KEY NOT NULL, summary BLOB NOT NULL, state TEXT NOT NULL,
                    FOREIGN KEY (cycleID) REFERENCES pollCycles(id)
                );
                CREATE TABLE pollFailures (
                    cycleID TEXT NOT NULL, workID TEXT NOT NULL, message TEXT NOT NULL,
                    PRIMARY KEY (cycleID, workID), FOREIGN KEY (cycleID) REFERENCES pollCycles(id)
                );
                CREATE TABLE pollFeatureSnapshots (
                    host TEXT NOT NULL, accountID TEXT NOT NULL, repositoryID TEXT NOT NULL,
                    objectID TEXT NOT NULL, feature TEXT NOT NULL, json BLOB NOT NULL,
                    PRIMARY KEY (host, accountID, repositoryID, objectID, feature),
                    FOREIGN KEY (host, accountID, repositoryID) REFERENCES repositories ON DELETE CASCADE
                );
                CREATE TABLE pollBaselines (
                    host TEXT NOT NULL, accountID TEXT NOT NULL, repositoryID TEXT NOT NULL, feature TEXT NOT NULL,
                    PRIMARY KEY (host, accountID, repositoryID, feature),
                    FOREIGN KEY (host, accountID, repositoryID) REFERENCES repositories ON DELETE CASCADE
                );
                CREATE TABLE pollResponses (
                    host TEXT NOT NULL, accountID TEXT NOT NULL, url TEXT NOT NULL,
                    etag TEXT, lastModified TEXT, body BLOB NOT NULL, nextURL TEXT, PRIMARY KEY (host, accountID, url),
                    FOREIGN KEY (host, accountID) REFERENCES accounts ON DELETE CASCADE
                );
                """)
        }
        migrator.registerMigration("v4-pr-workspace") { db in
            try db.execute(sql:"CREATE TABLE prWorkspace (id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL)")
        }
        migrator.registerMigration("v5-review-drafts-operations-observations") { db in
            try db.execute(sql:"""
                CREATE TABLE reviewDrafts(identity TEXT PRIMARY KEY NOT NULL, host TEXT NOT NULL, accountID TEXT NOT NULL, json BLOB NOT NULL);
                CREATE INDEX reviewDrafts_account ON reviewDrafts(host,accountID);
                CREATE TABLE reviewOperations(id TEXT PRIMARY KEY NOT NULL, identity TEXT NOT NULL, json BLOB NOT NULL);
                CREATE INDEX reviewOperations_identity ON reviewOperations(identity);
                CREATE TABLE prObservationFences(host TEXT NOT NULL,accountID TEXT NOT NULL,repositoryID TEXT NOT NULL,objectID TEXT NOT NULL,epoch INTEGER NOT NULL,PRIMARY KEY(host,accountID,repositoryID,objectID));
                """)
        }
        migrator.registerMigration("v6-notification-thread-operations") { db in
            try db.execute(sql:"""
                CREATE TABLE notificationThreadOperations(id TEXT PRIMARY KEY NOT NULL,host TEXT NOT NULL,accountID TEXT NOT NULL,threadID TEXT NOT NULL,state TEXT NOT NULL,json BLOB NOT NULL);
                CREATE UNIQUE INDEX unresolved_notification_thread ON notificationThreadOperations(host,accountID,threadID) WHERE state IN ('prepared','sending','uncertain');
                """)
        }
        migrator.registerMigration("v7-actions-repository-browser") { db in
            // Frozen copy of the schema the Actions and repository-browser stores once created on every
            // construction. `IF NOT EXISTS` stays: databases from before v7 already have these tables.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS actions_view_state(host TEXT NOT NULL,accountID TEXT NOT NULL,json BLOB NOT NULL,PRIMARY KEY(host,accountID));
                CREATE TABLE IF NOT EXISTS actions_catalog(host TEXT NOT NULL,accountID TEXT NOT NULL,repositoryID TEXT NOT NULL,json BLOB NOT NULL,PRIMARY KEY(host,accountID,repositoryID));
                CREATE TABLE IF NOT EXISTS actions_presets(id TEXT PRIMARY KEY,host TEXT NOT NULL,accountID TEXT NOT NULL,repositoryID TEXT NOT NULL,json BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS actions_operations(id TEXT PRIMARY KEY,host TEXT NOT NULL,accountID TEXT NOT NULL,repositoryID TEXT NOT NULL,state TEXT NOT NULL,json BLOB NOT NULL,lockKey TEXT UNIQUE);
                CREATE TABLE IF NOT EXISTS repo_browser_state(account_host TEXT NOT NULL, account_id TEXT NOT NULL, name TEXT NOT NULL, json BLOB NOT NULL, PRIMARY KEY(account_host,account_id,name));
                CREATE TABLE IF NOT EXISTS repo_browser_cache(account_host TEXT NOT NULL, account_id TEXT NOT NULL, cache_key TEXT NOT NULL, json BLOB NOT NULL, touched REAL NOT NULL, PRIMARY KEY(account_host,account_id,cache_key));
                CREATE TABLE IF NOT EXISTS repo_browser_operations(account_host TEXT NOT NULL, account_id TEXT NOT NULL, identity TEXT NOT NULL, state TEXT NOT NULL, json BLOB NOT NULL, PRIMARY KEY(account_host,account_id,identity));
                """)
        }
        migrator.registerMigration("v8-storage-lookup-indexes") { db in
            // Generated from the stored JSON, so every writer (including UPDATE json=?) keeps them in
            // sync. Creating the indexes backfills existing rows; malformed JSON yields NULL, never a failure.
            try db.execute(sql: """
                ALTER TABLE pullRequests ADD COLUMN state TEXT GENERATED ALWAYS AS (\(extract("$.state"))) VIRTUAL;
                ALTER TABLE pullRequests ADD COLUMN headSHA TEXT GENERATED ALWAYS AS (\(extract("$.headRevision.rawValue"))) VIRTUAL;
                -- Seconds since the 2001 reference date, as JSONEncoder stores Date.
                ALTER TABLE pullRequests ADD COLUMN updatedAt REAL GENERATED ALWAYS AS (\(extract("$.metadata.updatedAt"))) VIRTUAL;
                CREATE INDEX pullRequests_repository_state ON pullRequests(host,accountID,repositoryID,state);
                CREATE INDEX pullRequests_account_state_updated ON pullRequests(host,accountID,state,updatedAt);
                -- Guarded like the columns above (one corrupt ledger row must not fail the migration), and
                -- matched exactly by `DatabaseStore.activeReservations`, so ledger scans use it.
                CREATE INDEX reviewOperations_state ON reviewOperations(\(reviewOperationState));
                ALTER TABLE pollResponses ADD COLUMN feature TEXT;
                UPDATE pollResponses SET feature='github-notification-signals' WHERE url LIKE '%/notifications?%' OR url LIKE '%/notifications';
                """)
        }
        migrator.registerMigration("v9-legacy-pr-key-cleanup") { db in
            // Created/linked PRs were once stored under the raw node ID beside the inventory's canonical row.
            try LegacyPRKeyCleanup.run(db)
        }
        migrator.registerMigration("v10-canonical-ledger-reservations") { db in
            try LegacyPRKeyCleanup.repairLedgerReservations(db)
        }
        migrator.registerMigration("v11-storage-maintenance") { db in
            // Inbox lookups use partial indexes: the predicate text must contain `acknowledged=0` (and
            // `surfaced=0`) literally, not bound parameters. `occurredAt` is seconds since the 2001
            // reference date, as JSONEncoder stores Date.
            try db.execute(sql: """
                ALTER TABLE changeEvents ADD COLUMN occurredAt REAL GENERATED ALWAYS AS (\(extract("$.occurredAt"))) VIRTUAL;
                CREATE INDEX changeEvents_unacknowledged ON changeEvents(eventKey) WHERE acknowledged=0;
                CREATE INDEX changeEvents_unsurfaced ON changeEvents(eventKey) WHERE acknowledged=0 AND surfaced=0;
                CREATE INDEX changeEvents_acknowledged_age ON changeEvents(occurredAt) WHERE acknowledged=1;
                CREATE INDEX changeEvents_cycle ON changeEvents(cycleID);
                -- Acknowledged events older than this were pruned. A provider page that still lists one must
                -- not bring it back as unread (feed event keys are deterministic), so such inserts are ignored.
                CREATE TABLE changeEventRetention(
                    host TEXT NOT NULL, accountID TEXT NOT NULL, repositoryID TEXT NOT NULL, prunedThrough REAL NOT NULL,
                    PRIMARY KEY(host, accountID, repositoryID)
                );
                CREATE TRIGGER changeEvents_skip_pruned BEFORE INSERT ON changeEvents
                WHEN NEW.acknowledged = 0 AND json_valid(CAST(NEW.json AS TEXT)) AND EXISTS (SELECT 1 FROM changeEventRetention r
                    WHERE r.host = NEW.host AND r.accountID = NEW.accountID AND r.repositoryID = NEW.repositoryID
                    AND json_extract(CAST(NEW.json AS TEXT),'$.occurredAt') <= r.prunedThrough)
                BEGIN SELECT RAISE(IGNORE); END;
                -- When a notification command reached a terminal state (Unix seconds); retention starts there.
                ALTER TABLE notificationThreadOperations ADD COLUMN closedAt REAL;
                UPDATE notificationThreadOperations SET closedAt = CAST(strftime('%s','now') AS REAL) WHERE state IN ('confirmed','rejected');
                -- Lets a lost repository's payload files be found without decoding every PR detail index.
                ALTER TABLE cacheEntries ADD COLUMN repositoryID TEXT;
                CREATE INDEX cacheEntries_repository ON cacheEntries(host, accountID, repositoryID);
                CREATE TABLE storageMaintenance(id INTEGER PRIMARY KEY CHECK(id = 1), lastRun REAL NOT NULL);
                """)
        }
        migrator.registerMigration("v12-renamed-settings") { db in
            // Development-era names of the Local settings (`SettingsKey.localFolders`, `.localRecoveryHints`).
            try renameApplicationSettings([("phase4LocalFolders", "localFolders"), ("phase4LocalRecoveryHints", "localRecoveryHints")], in: db)
        }
        return migrator
    }
    /// Moves each old app-wide setting's value to its new name, unless the new name already has one, and removes the
    /// old name. Migrations pass literal names, so a later change to a `SettingsKey` never changes what they did.
    static func renameApplicationSettings(_ renames: [(old: String, new: String)], in db: Database) throws {
        for (old, new) in renames {
            guard let value = try String.fetchOne(db, sql: "SELECT value FROM applicationSettings WHERE name = ?", arguments: [old]) else { continue }
            try db.execute(sql: "INSERT OR IGNORE INTO applicationSettings VALUES (?, ?)", arguments: [new, value])
            try db.execute(sql: "DELETE FROM applicationSettings WHERE name = ?", arguments: [old])
        }
    }
}
