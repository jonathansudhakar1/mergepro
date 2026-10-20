import Foundation
import GRDB

extension DatabaseStore {
    private static func scopeRepositories(_ account:AccountScope,in db:Database) throws -> [Repository] {
        try Data.fetchAll(db,sql:"SELECT json FROM repositories WHERE host=? AND accountID=?",arguments:[account.host,account.accountID])
            .map { try JSONDecoder().decode(Repository.self,from:$0) }
    }
    private static func saveScope(_ configuration:RepositoryScopeConfiguration,account:AccountScope,in db:Database) throws {
        try writeScopeSetting(String(decoding:canonicalJSON(configuration),as:UTF8.self),key:.repositoryOwnerScopes,account:account,in:db)
    }
    private static func writeScopeSetting(_ value:String,key:AccountSettingKey,account:AccountScope,in db:Database) throws {
        try db.execute(sql:"INSERT INTO settings VALUES (?,?,?,?) ON CONFLICT(host,accountID,name) DO UPDATE SET value=excluded.value WHERE value IS NOT excluded.value",arguments:[account.host,account.accountID,key.rawValue,value])
    }
    private static func trackScopeKey(_ key:RepositoryKey,enabled:Bool,in db:Database) throws {
        if enabled {
            try db.execute(sql:"INSERT OR IGNORE INTO trackedRepositories VALUES (?,?,?)",arguments:[key.account.host,key.account.accountID,key.repositoryID])
        } else {
            try db.execute(sql:"DELETE FROM trackedRepositories WHERE host=? AND accountID=? AND repositoryID=?",arguments:[key.account.host,key.account.accountID,key.repositoryID])
        }
    }
    /// Keep the low-level single-key tracking API consistent once owner policies have been introduced.
    /// Legacy callers retain their existing settings shape until migration at discovery or a bulk edit.
    static func recordExplicitRepositorySelection(_ key:RepositoryKey,in db:Database) throws {
        let settings = try Self.settings(account:key.account,in:db)
        guard settings[.repositoryOwnerScopes] != nil,
              let data = try Data.fetchOne(db,sql:"SELECT json FROM repositories WHERE host=? AND accountID=? AND repositoryID=?",arguments:[key.account.host,key.account.accountID,key.repositoryID]) else { return }
        let repository = try JSONDecoder().decode(Repository.self,from:data)
        var configuration = try RepositoryScopeConfiguration(settings:settings,repositories:[])
        configuration.set(.selectedRepositories,for:RepositoryScopeConfiguration.owner(of:repository))
        try Self.saveScope(configuration,account:key.account,in:db)
    }
    /// One commit for discovery metadata, retained repositories, owner policy and newly included keys.
    /// Missing rows never remove saved scope: even a successful discovery may omit SSO resources.
    /// Only a complete listing proves lost access: then a previously known repository it omits loses its
    /// cached PRs, events, checkpoints, feature caches and payload manifest entries (returned, so the
    /// cache can delete the files). Partial listings, errors and rate limits never purge.
    @discardableResult func commitRepositoryDiscovery(_ result:GitHubDiscoveryResult,account:AccountScope) throws -> RepositoryAccessPurge {
        let purge = try commitDiscovery(result,account:account)
        if !purge.repositories.isEmpty { scrubWriteAheadLog() }
        return purge
    }
    private func commitDiscovery(_ result:GitHubDiscoveryResult,account:AccountScope) throws -> RepositoryAccessPurge {
        try database.write { db in
            let settings = try Self.settings(account:account,in:db)
            let known = Set(try String.fetchAll(db,sql:"SELECT repositoryID FROM repositories WHERE host=? AND accountID=?",arguments:[account.host,account.accountID]))
            var configuration = try RepositoryScopeConfiguration(settings:settings,repositories:Self.scopeRepositories(account,in:db))
            var retained = Self.retainedTracking(settings[.retainedTrackedRepositories])
            for repository in result.repositories {
                guard repository.key.account == account else { throw RepositoryScopeFailure.invalidRepositories }
                let owner = RepositoryScopeConfiguration.owner(of:repository)
                if configuration.owners[RepositoryScopeConfiguration.canonicalOwner(owner)] == nil { configuration.set(.allAccessible,for:owner) }
                try db.execute(sql:"INSERT INTO repositories VALUES (?,?,?,?) ON CONFLICT(host,accountID,repositoryID) DO UPDATE SET json=excluded.json WHERE json IS NOT excluded.json",arguments:[account.host,account.accountID,repository.key.repositoryID,try Self.canonicalJSON(repository)])
                // A selection kept through a credential purge is restored once its repository is listed again.
                let restored = retained.remove(repository.key.repositoryID) != nil
                if configuration.mode(for:owner) == .allAccessible || restored { try Self.trackScopeKey(repository.key,enabled:true,in:db) }
            }
            if result.isComplete { retained = [] }
            if retained != Self.retainedTracking(settings[.retainedTrackedRepositories]) { try Self.writeRetainedTracking(retained,account:account,in:db) }
            for organization in result.organizations where configuration.owners[RepositoryScopeConfiguration.canonicalOwner(organization.login)] == nil {
                configuration.set(.allAccessible,for:organization.login)
            }
            try Self.saveScope(configuration,account:account,in:db)
            try Self.writeScopeSetting(result.isComplete ? "true" : "false",key:.discoveryComplete,account:account,in:db)
            try Self.writeScopeSetting(result.issues.joined(separator:"\n"),key:.discoveryIssues,account:account,in:db)
            try Self.writeScopeSetting(result.retryAt.map { String($0.timeIntervalSince1970) } ?? "",key:.discoveryRetryAt,account:account,in:db)
            var organizations = result.organizations,teams = result.teams
            if !result.isComplete {
                if let value = settings[.organizations] {
                    let saved = try JSONDecoder().decode([GitHubOrganization].self,from:Data(value.utf8))
                    organizations += saved.filter { previous in !organizations.contains { $0.id == previous.id } }
                }
                if let value = settings[.teams] {
                    let saved = try JSONDecoder().decode([GitHubTeam].self,from:Data(value.utf8))
                    teams += saved.filter { previous in !teams.contains { $0.id == previous.id } }
                }
            }
            try Self.writeScopeSetting(String(decoding:Self.canonicalJSON(organizations),as:UTF8.self),key:.organizations,account:account,in:db)
            try Self.writeScopeSetting(String(decoding:Self.canonicalJSON(teams),as:UTF8.self),key:.teams,account:account,in:db)
            var purge = RepositoryAccessPurge()
            guard result.isComplete else { return purge }
            for id in known.subtracting(result.repositories.map(\.key.repositoryID)).sorted() {
                let key = RepositoryKey(account:account,repositoryID:id)
                purge.repositories.insert(key)
                purge.payloadIDs += try Self.purgeRepositoryContent(key,in:db)
            }
            return purge
        }
    }
    /// Cached provider content of one repository for one account. The repository row, tracking, pins,
    /// drafts, reading progress and the write ledger stay. Returns the removed payload manifest IDs;
    /// legacy entries without a repository are included, since they cannot be attributed.
    private static func purgeRepositoryContent(_ key:RepositoryKey,in db:Database) throws -> [String] {
        let arguments:StatementArguments = [key.account.host,key.account.accountID,key.repositoryID]
        let name = try Data.fetchOne(db,sql:"SELECT json FROM repositories WHERE host=? AND accountID=? AND repositoryID=?",arguments:arguments).flatMap { try? JSONDecoder().decode(Repository.self,from:$0) }?.name
        for table in ["pullRequests","changeEvents","pollFeatureSnapshots","pollBaselines","actions_catalog"] {
            try db.execute(sql:"DELETE FROM \(table) WHERE host=? AND accountID=? AND repositoryID=?",arguments:arguments)
        }
        // Repository browser keys are "<kind>|<repositoryID>[|...]"; code state is "code|<repositoryID>".
        for cacheKey in try String.fetchAll(db,sql:"SELECT cache_key FROM repo_browser_cache WHERE account_host=? AND account_id=?",arguments:[key.account.host,key.account.accountID])
        where cacheKey.split(separator:"|",omittingEmptySubsequences:false).dropFirst().first.map(String.init) == key.repositoryID {
            try db.execute(sql:"DELETE FROM repo_browser_cache WHERE account_host=? AND account_id=? AND cache_key=?",arguments:[key.account.host,key.account.accountID,cacheKey])
        }
        try db.execute(sql:"DELETE FROM repo_browser_state WHERE account_host=? AND account_id=? AND name=?",arguments:[key.account.host,key.account.accountID,"code|"+key.repositoryID])
        // Cached REST pages are keyed by URL, which names the repository rather than its ID.
        if let name, !name.isEmpty {
            let path = "/repos/"+name.lowercased()
            try db.execute(sql:"DELETE FROM pollResponses WHERE host=? AND accountID=? AND (instr(lower(url),?) > 0 OR substr(lower(url),-length(?)) = ?)",
                           arguments:[key.account.host,key.account.accountID,path+"/",path,path])
        }
        let ids = try String.fetchAll(db,sql:"SELECT id FROM cacheEntries WHERE host=? AND accountID=? AND (repositoryID=? OR repositoryID IS NULL)",arguments:arguments)
        try db.execute(sql:"DELETE FROM cacheEntries WHERE host=? AND accountID=? AND (repositoryID=? OR repositoryID IS NULL)",arguments:arguments)
        return ids
    }
    private static func retainedTracking(_ value:String?) -> Set<String> {
        value.flatMap { try? JSONDecoder().decode(Set<String>.self,from:Data($0.utf8)) } ?? []
    }
    private static func writeRetainedTracking(_ ids:Set<String>,account:AccountScope,in db:Database) throws {
        if ids.isEmpty { try db.execute(sql:"DELETE FROM settings WHERE host=? AND accountID=? AND name=?",arguments:[account.host,account.accountID,AccountSettingKey.retainedTrackedRepositories.rawValue]);return }
        try writeScopeSetting(String(decoding:JSONEncoder().encode(ids.sorted()),as:UTF8.self),key:.retainedTrackedRepositories,account:account,in:db)
    }
    /// Keeps tracked repository IDs (opaque, no names) across a purge of the repository rows.
    static func retainTracking(_ ids:Set<String>,account:AccountScope,in db:Database) throws {
        guard !ids.isEmpty else { return }
        let existing = retainedTracking(try setting(.retainedTrackedRepositories,account:account,in:db))
        try writeRetainedTracking(existing.union(ids),account:account,in:db)
    }
    /// Changing to specific repositories retains the current subset; changing to all includes every saved row.
    /// An optional active identity is checked inside the same transaction as the tracking changes.
    public func setRepositoryScope(_ mode:RepositoryScopeMode,owner:String,account:AccountScope,expectedActiveAccount:AccountScope? = nil) throws {
        try database.write { db in
            try Self.checkScopeAccount(account,expectedActiveAccount:expectedActiveAccount,in:db)
            let repositories = try Self.scopeRepositories(account,in:db)
            var configuration = try RepositoryScopeConfiguration(settings:Self.settings(account:account,in:db),repositories:repositories)
            configuration.set(mode,for:owner)
            if mode == .allAccessible {
                for repository in repositories where RepositoryScopeConfiguration.canonicalOwner(RepositoryScopeConfiguration.owner(of:repository)) == RepositoryScopeConfiguration.canonicalOwner(owner) {
                    try Self.trackScopeKey(repository.key,enabled:true,in:db)
                }
            }
            try Self.saveScope(configuration,account:account,in:db)
        }
    }
    /// Applies one page or one checkbox without replacing selections on other pages or inaccessible saved rows.
    public func setRepositorySelection(_ keys:Set<RepositoryKey>,enabled:Bool,owner:String,account:AccountScope,expectedActiveAccount:AccountScope? = nil) throws {
        try database.write { db in
            try Self.checkScopeAccount(account,expectedActiveAccount:expectedActiveAccount,in:db)
            let repositories = try Self.scopeRepositories(account,in:db)
            let eligible = Set(repositories.filter { RepositoryScopeConfiguration.canonicalOwner(RepositoryScopeConfiguration.owner(of:$0)) == RepositoryScopeConfiguration.canonicalOwner(owner) }.map(\.key))
            guard keys.isSubset(of:eligible) else { throw RepositoryScopeFailure.invalidRepositories }
            var configuration = try RepositoryScopeConfiguration(settings:Self.settings(account:account,in:db),repositories:repositories)
            configuration.set(.selectedRepositories,for:owner)
            for key in keys { try Self.trackScopeKey(key,enabled:enabled,in:db) }
            try Self.saveScope(configuration,account:account,in:db)
        }
    }
    private static func checkScopeAccount(_ account:AccountScope,expectedActiveAccount:AccountScope?,in db:Database) throws {
        guard try Row.fetchOne(db,sql:"SELECT 1 FROM accounts WHERE host=? AND accountID=?",arguments:[account.host,account.accountID]) != nil else { throw StorageError.accountMissing(account) }
        if let expectedActiveAccount {
            guard expectedActiveAccount == account,
                  try applicationSetting(.activeActionAccount,in:db) == AccountSessionStore.tokenReference(for:expectedActiveAccount) else { throw RepositoryScopeFailure.accountChanged }
        }
    }
}
/// Repositories a complete discovery no longer lists, and the payload manifest IDs removed with them.
struct RepositoryAccessPurge:Sendable {
    var repositories:Set<RepositoryKey> = []
    var payloadIDs:[String] = []
}
