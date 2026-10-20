import Foundation
import XCTest
@testable import MergeProCore

// MARK: - Temporary directories and databases

extension XCTestCase {
    /// A fresh, empty directory under the system temporary directory, removed when the test finishes.
    func makeTemporaryDirectory(prefix: String = "MergeProTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    /// A file-backed `DatabaseStore` named `name` in its own temporary directory (removed at teardown).
    func makeTemporaryDatabase(named name: String = "db.sqlite") throws -> (database: DatabaseStore, directory: URL) {
        let directory = try makeTemporaryDirectory()
        return (try DatabaseStore(path: directory.appendingPathComponent(name).path), directory)
    }
}

// MARK: - Accounts and repositories

extension Repository {
    /// A private fixture repository with no recorded capabilities.
    static func fixture(_ key: RepositoryKey, name: String = "o/r", isPrivate: Bool = true, capabilities: ProviderCapabilities = []) -> Repository {
        Repository(key: key, name: name, isPrivate: isPrivate, capabilities: capabilities)
    }
}
extension GitHubCredential {
    /// The placeholder token every offline fixture signs in with.
    static let fixture = GitHubCredential(accessToken: "fixture", scopes: ["repo"])
}

// MARK: - Signed-in session

/// A file-backed database, payload cache and signed-in GitHub session for one account, in a temporary
/// directory removed at teardown: the wiring every write coordinator and service test repeats.
struct SessionFixture {
    let directory: URL
    let database: DatabaseStore
    let cache: CacheStore
    let credentials: MemoryCredentials
    let storage: AccountSessionStore
    let session: GitHubAccountSession
    let account: AccountScope
    /// The app's active-action-account resolver: this account while it is the stored active account.
    var activeAccount: @Sendable () async throws -> AccountScope? {
        let (database, account) = (database, account)
        return { try database.applicationSetting("activeActionAccount") == AccountSessionStore.tokenReference(for: account) ? account : nil }
    }
}

extension XCTestCase {
    /// Saves `account` (as `login`) and `repositories`, stores `credential` for it and, when `active`, makes it the
    /// active action account, then opens a session over `transport`.
    func makeSessionFixture(account: AccountScope, login: String = "actor", tokenReference: String? = nil, repositories: [Repository] = [],
                            transport: any GitHubTransport, credential: GitHubCredential = .fixture, active: Bool = true) throws -> SessionFixture {
        let directory = try makeTemporaryDirectory()
        let database = try DatabaseStore(path: directory.appendingPathComponent("db").path)
        try database.saveAccount(Account(scope: account, login: login, tokenReference: tokenReference))
        for repository in repositories { try database.saveRepository(repository) }
        if active { try database.setApplicationSetting(AccountSessionStore.tokenReference(for: account), for: "activeActionAccount") }
        let credentials = MemoryCredentials(); credentials.save(credential, account: account)
        let cache = try CacheStore(directory: directory.appendingPathComponent("cache"), database: database)
        let storage = AccountSessionStore(database: database, cache: cache, credentials: credentials)
        return SessionFixture(directory: directory, database: database, cache: cache, credentials: credentials, storage: storage,
                              session: GitHubAccountSession(storage: storage, transport: transport), account: account)
    }
}
