import Foundation
import GRDB

struct RepositoryBrowserPersistence:Sendable {
    let database:DatabaseStore
    /// The schema is created by migration v7; constructing this is free and never writes.
    init(database:DatabaseStore) throws { self.database=database }
    func cached<T:Decodable>(_ key:String,account:AccountScope,as type:T.Type) throws -> T? {
        try database.database.read { db in
            guard let data=try Data.fetchOne(db,sql:"SELECT json FROM repo_browser_cache WHERE account_host=? AND account_id=? AND cache_key=?",arguments:[account.host,account.accountID,key]) else { return nil }
            return try JSONDecoder().decode(T.self,from:data)
        }
    }
    func cache<T:Encodable>(_ value:T,key:String,account:AccountScope) throws {
        let data=try JSONEncoder().encode(value)
        guard data.count<=12_000_000 else { return }
        try database.database.write { db in
            try db.execute(sql:"INSERT INTO repo_browser_cache VALUES(?,?,?,?,?) ON CONFLICT(account_host,account_id,cache_key) DO UPDATE SET json=excluded.json,touched=excluded.touched",arguments:[account.host,account.accountID,key,data,Date().timeIntervalSince1970])
            // A bounded regenerable feature cache; durable navigation and mutation intent are retained.
            while try Int.fetchOne(db,sql:"SELECT COALESCE(SUM(length(json)),0) FROM repo_browser_cache") ?? 0 > 128_000_000 {
                try db.execute(sql:"DELETE FROM repo_browser_cache WHERE rowid=(SELECT rowid FROM repo_browser_cache ORDER BY touched LIMIT 1)")
            }
        }
    }
    func state(_ account:AccountScope) throws -> RepoTreePersistence {
        try database.database.read { db in
            guard let data=try Data.fetchOne(db,sql:"SELECT json FROM repo_browser_state WHERE account_host=? AND account_id=? AND name='catalog'",arguments:[account.host,account.accountID]) else { return .init() };return try JSONDecoder().decode(RepoTreePersistence.self,from:data)
        }
    }
    func saveState(_ state:RepoTreePersistence,account:AccountScope) throws {
        try database.database.write { db in
            try db.execute(sql:"INSERT INTO repo_browser_state VALUES(?,?,?,?) ON CONFLICT(account_host,account_id,name) DO UPDATE SET json=excluded.json",arguments:[account.host,account.accountID,"catalog",try JSONEncoder().encode(state)])
        }
    }
    func operationState(_ identity:String,account:AccountScope) throws -> String? {
        try database.database.read { try String.fetchOne($0,sql:"SELECT state FROM repo_browser_operations WHERE account_host=? AND account_id=? AND identity=?",arguments:[account.host,account.accountID,identity]) }
    }
    func record(_ identity:String,account:AccountScope,state:String,data:Data) throws {
        try database.database.write { db in
            try db.execute(sql:"INSERT INTO repo_browser_operations SELECT ?,?,?,?,? WHERE EXISTS(SELECT 1 FROM accounts WHERE host=? AND accountID=?) ON CONFLICT(account_host,account_id,identity) DO UPDATE SET state=excluded.state,json=excluded.json",arguments:[account.host,account.accountID,identity,state,data,account.host,account.accountID])
        }
    }
}

extension RepositoryBrowserPersistence {
    func codeState(_ repository:RepositoryKey) throws -> RepoCodePersistence {
        try database.database.read { db in
            guard let data=try Data.fetchOne(db,sql:"SELECT json FROM repo_browser_state WHERE account_host=? AND account_id=? AND name=?",arguments:[repository.account.host,repository.account.accountID,"code|"+repository.repositoryID]) else { return .init() };return try JSONDecoder().decode(RepoCodePersistence.self,from:data)
        }
    }
    func saveCodeState(_ state:RepoCodePersistence,repository:RepositoryKey) throws {
        try database.database.write { db in try db.execute(sql:"INSERT INTO repo_browser_state VALUES(?,?,?,?) ON CONFLICT(account_host,account_id,name) DO UPDATE SET json=excluded.json",arguments:[repository.account.host,repository.account.accountID,"code|"+repository.repositoryID,try JSONEncoder().encode(state)]) }
    }
}
