import GRDB

struct CacheEntry: Sendable {
    let id: String
    let account: AccountScope
    let byteCount: Int64
    let accessOrder: Int64
}

extension DatabaseStore {
    func cacheEntries() throws -> [CacheEntry] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM cacheEntries ORDER BY accessOrder, id").map {
                CacheEntry(id: $0["id"], account: AccountScope(host: $0["host"], accountID: $0["accountID"]),
                           byteCount: $0["byteCount"], accessOrder: $0["accessOrder"])
            }
        }
    }

    /// Single-row manifest lookup by primary key.
    func hasPayload(id: String) throws -> Bool {
        try database.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM cacheEntries WHERE id = ?)", arguments: [id]) ?? false }
    }

    /// The manifest size of one payload, for lazy validation of its file on read.
    func payloadByteCount(id: String) throws -> Int64? {
        try database.read { try Int64.fetchOne($0, sql: "SELECT byteCount FROM cacheEntries WHERE id = ?", arguments: [id]) }
    }

    func payloadUsage() throws -> Int64 {
        try database.read { try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(byteCount), 0) FROM cacheEntries") ?? 0 }
    }

    /// One statement instead of a whole-manifest scan plus a write per entry.
    func forgetPayloads(account: AccountScope) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM cacheEntries WHERE host = ? AND accountID = ?", arguments: [account.host, account.accountID])
        }
    }

    /// The repository lets a lost repository's payloads be purged without touching the rest of the account.
    func recordPayload(id: String, account: AccountScope, repositoryID: String?, byteCount: Int64) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO cacheEntries (id, host, accountID, byteCount, accessOrder, repositoryID)
                VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX(accessOrder), 0) + 1 FROM cacheEntries), ?)
                ON CONFLICT(id) DO UPDATE SET byteCount = excluded.byteCount, accessOrder = excluded.accessOrder, repositoryID = excluded.repositoryID
                """, arguments: [id, account.host, account.accountID, byteCount, repositoryID])
        }
    }

    func touchPayload(id: String) throws {
        try database.write { db in
            try db.execute(sql: """
                UPDATE cacheEntries SET accessOrder = (SELECT COALESCE(MAX(accessOrder), 0) + 1 FROM cacheEntries)
                WHERE id = ?
                """, arguments: [id])
        }
    }

    func forgetPayload(id: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM cacheEntries WHERE id = ?", arguments: [id])
        }
    }
}
