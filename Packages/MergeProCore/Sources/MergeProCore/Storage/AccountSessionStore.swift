import Foundation

/// OS credentials remain outside SQLite. Implementations must be synchronous and thread safe.
public protocol GitHubCredentialStore: Sendable {
    func credential(for account: AccountScope) throws -> GitHubCredential?
    func save(_ credential: GitHubCredential, account: AccountScope) throws
    func remove(account: AccountScope) throws
}
public struct AccountOperation: Sendable {
    public let account: AccountScope
    public let credential: GitHubCredential
    let generation: UUID
}

/// Credential-free availability for UI consumers; the session owner remains the authority.
public enum AccountAuthorizationState: Equatable, Sendable {
    case available
    case authorizationRequired(localPersistenceFailed: Bool)
    public func applying(to snapshot: LocalSnapshot) -> LocalSnapshot {
        guard case .authorizationRequired(let failed) = self else { return snapshot }
        var settings = snapshot.settings
        settings[.authorizationProblem] = "true"
        settings[.authorizationPersistenceFailed] = failed ? "true" : "false"
        return LocalSnapshot(account:snapshot.account,repositories:[],trackedRepositories:snapshot.trackedRepositories,
            pins:[],settings:settings,pullRequests:[],drafts:snapshot.drafts)
    }
}
public struct AccountAuthorizationChange: Sendable {
    public let account: AccountScope
    public let state: AccountAuthorizationState
}

/// Serializes each account's credential/cache/database mutations across actor suspension.
/// A captured generation is checked while holding the same lock as the mutation; task
/// cancellation is an optimization, not the authority for accepting network results.
public actor AccountSessionStore {
    private let database: DatabaseStore
    private let cache: CacheStore
    private let credentials: any GitHubCredentialStore
    private var generations: [AccountScope:UUID] = [:]
    private var blocked: [AccountScope:AccountAuthorizationState] = [:]
    private var observers: [UUID:AsyncStream<AccountAuthorizationChange>.Continuation] = [:]
    /// Credentials read once per account, so polls and UI do not reach the Keychain on every call. Every
    /// credential change in this process goes through this actor, which replaces or drops the entry.
    private var cachedCredentials: [AccountScope:GitHubCredential] = [:]
    private func storedCredential(for account: AccountScope) throws -> GitHubCredential? {
        if let cached = cachedCredentials[account] { return cached }
        let credential = try credentials.credential(for:account)
        cachedCredentials[account] = credential
        return credential
    }
    private func saveCredential(_ credential: GitHubCredential, account: AccountScope) throws {
        cachedCredentials[account] = nil
        try credentials.save(credential,account:account)
        cachedCredentials[account] = credential
    }
    private func removeCredential(account: AccountScope) throws {
        cachedCredentials[account] = nil
        try credentials.remove(account:account)
    }
    public func authorizationChanges() async throws -> AsyncStream<AccountAuthorizationChange> {
        for account in try database.accounts() { _ = try await authorizationState(for:account.scope) }
        let id = UUID()
        let (stream, continuation) = AsyncStream<AccountAuthorizationChange>.makeStream()
        observers[id] = continuation
        // Unbounded scoped queue: no account denial is lost when another account changes.
        for account in try database.accounts() {
            continuation.yield(.init(account:account.scope,state:blocked[account.scope] ?? .available))
        }
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish(_ state: AccountAuthorizationState, account: AccountScope) {
        for observer in observers.values { observer.yield(.init(account:account,state:state)) }
    }
    /// Also detects missing credentials after restart, before a cached UI snapshot is exposed.
    public func authorizationState(for account: AccountScope) async throws -> AccountAuthorizationState {
        await acquire(account); defer { release(account) }
        if let state = blocked[account] { return state }
        guard try database.account(account) != nil else { return .authorizationRequired(localPersistenceFailed:false) }
        if try database.setting(.authorizationProblem,account:account) == "true" {
            let state = AccountAuthorizationState.authorizationRequired(localPersistenceFailed:false)
            blocked[account] = state; publish(state,account:account); return state
        }
        if try storedCredential(for:account) == nil {
            let generation = generations[account] ?? UUID(); generations[account] = generation
            do { _ = try await markInvalidLocked(account:account,generation:generation,cause:.missingCredential) }
            catch { Log.storage.error("Could not record a missing credential: \(Log.kind(error), privacy: .public)") }
            return blocked[account] ?? .authorizationRequired(localPersistenceFailed:true)
        }
        return .available
    }
    /// One cheap authorization check, then the single whole-account read the board needs.
    public func snapshot(for account: AccountScope) async throws -> LocalSnapshot {
        let state = try await authorizationState(for:account)
        return (blocked[account] ?? state).applying(to:try database.snapshot(for:account))
    }
    private var locked: Set<AccountScope> = []
    private var waiters: [AccountScope:[CheckedContinuation<Void,Never>]] = [:]
    public init(database: DatabaseStore, cache: CacheStore, credentials: any GitHubCredentialStore) {
        self.database = database; self.cache = cache; self.credentials = credentials
    }
    public static func tokenReference(for account: AccountScope) -> String { account.host.lowercased() + ":" + account.accountID }
    private func acquire(_ account: AccountScope) async {
        if locked.insert(account).inserted { return }
        await withCheckedContinuation { waiters[account,default:[]].append($0) }
    }
    private func release(_ account: AccountScope) {
        if var queue = waiters[account], !queue.isEmpty {
            let next = queue.removeFirst(); waiters[account] = queue.isEmpty ? nil : queue
            next.resume()
        } else { locked.remove(account) }
    }
    private func isCurrent(_ operation: AccountOperation) throws -> Bool {
        try isCurrent(account:operation.account,generation:operation.generation)
    }
    private func isCurrent(account: AccountScope, generation: UUID) throws -> Bool {
        guard blocked[account] == nil, generations[account] == generation else { return false }
        return try database.account(account) != nil
    }
    /// Why an account's credential stopped being usable, which decides how much private content goes.
    private enum InvalidationCause {
        /// GitHub rejected the credential (a trusted 401, revocation or expiry): the full private-content purge.
        case providerRejected
        /// No Keychain item. Not provider-confirmed (data-protection fallback, migration edge cases): only payload
        /// files and feature caches go (`invalidatePrivatePayloads`); rows wait for reconnecting or a confirmed rejection.
        case missingCredential
    }
    // The caller holds the account mutation lock, including through this cache await.
    private func markInvalidLocked(account: AccountScope, generation: UUID, cause: InvalidationCause) async throws -> Bool {
        guard try isCurrent(account:account,generation:generation) else { return false }
        // A known current-credential failure is authoritative even if cancellation/cleanup follows.
        blocked[account] = .authorizationRequired(localPersistenceFailed:false)
        generations[account] = UUID()
        publish(blocked[account]!,account:account)
        var failure: (any Error)?
        // Each cleanup is attempted independently. Credential removal makes a failed SQLite
        // flag fail closed after restart; all credential changes hold this same account lock.
        do { try removeCredential(account:account) } catch { failure = error }
        do { try database.setSetting("true",for:.authorizationProblem,account:account) } catch { failure = failure ?? error }
        // A revoked or expired credential purges private provider content from disk and memory; a missing one
        // invalidates payloads only. Unsent drafts and the write ledger stay: nothing is resent, and reconcile
        // resumes after reconnecting.
        PRDetailMemoryCache.shared.purge(account:account)
        do {
            switch cause {
            case .providerRejected: try await cache.purgePrivateContent(for:account)
            case .missingCredential: try await cache.invalidatePrivatePayloads(for:account)
            }
        } catch { failure = failure ?? error }
        // Again after the await: a detail read already in flight may have stored an entry meanwhile.
        PRDetailMemoryCache.shared.purge(account:account)
        if let failure {
            blocked[account] = .authorizationRequired(localPersistenceFailed:true)
            publish(blocked[account]!,account:account)
            throw failure
        }
        return true
    }
    public func invalidateOperations(for account: AccountScope) async {
        await acquire(account); defer { release(account) }
        generations[account] = UUID()
    }
    public func operation(for account: AccountScope, now: Date) async throws -> AccountOperation {
        await acquire(account); defer { release(account) }
        try Task.checkCancellation()
        if case .authorizationRequired(let failed) = blocked[account] {
            throw AccountAcquisitionFailure.missingCredential(localPersistenceFailed:failed)
        }
        guard try database.account(account) != nil else { throw GitHubFailure.invalidAuthentication }
        let settings = try database.settings(account:account)
        if settings[.authorizationProblem] == "true" { throw GitHubFailure.invalidAuthentication }
        if let epoch = settings[.discoveryRetryAt].flatMap(Double.init), Date(timeIntervalSince1970:epoch) > now {
            throw GitHubFailure.rateLimited(until:Date(timeIntervalSince1970:epoch))
        }
        let generation = generations[account] ?? UUID(); generations[account] = generation
        guard let credential = try storedCredential(for:account) else {
            do {
                guard try await markInvalidLocked(account:account,generation:generation,cause:.missingCredential) else { throw CancellationError() }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw AccountAcquisitionFailure.missingCredential(localPersistenceFailed:true)
            }
            throw AccountAcquisitionFailure.missingCredential(localPersistenceFailed:false)
        }
        return AccountOperation(account:account,credential:credential,generation:generation)
    }
    /// Account lifecycle and the synchronous feature commit share one mutation lock.
    public func withCurrentOperation(_ operation: AccountOperation, body: @Sendable (DatabaseStore) throws -> Void) async throws -> Bool {
        await acquire(operation.account); defer { release(operation.account) }
        guard try isCurrent(operation), !Task.isCancelled,
              try database.setting(.authorizationProblem,account:operation.account) != "true" else { return false }
        try body(database)
        return true
    }
    /// Write admission rechecks the persisted active action identity after acquiring the
    /// existing account mutation lock. Network dispatch remains outside that lock.
    public func withCurrentWriteOperation(_ operation:AccountOperation,body:@Sendable (DatabaseStore) throws -> Void) async throws -> Bool {
        try await withCurrentOperation(operation) { db in
            guard try db.applicationSetting(.activeActionAccount) == Self.tokenReference(for:operation.account) else { throw PRWriteFailure.accountChanged }
            try body(db)
        }
    }
    public func observationFence(_ key:ProviderKey,operation:AccountOperation) async throws -> Int {
        await acquire(operation.account);defer { release(operation.account) }
        guard key.account == operation.account,try isCurrent(operation) else { throw CancellationError() }
        return try database.observationFence(for:key)
    }
    /// Immutable rendering payloads share the credential owner's account lock through cache awaits.
    @discardableResult
    public func detailPayload(_ data: Data?, key: PayloadKey, pr: ProviderKey, headSHA: String, operation: AccountOperation) async throws -> Data? {
        await acquire(operation.account); defer { release(operation.account) }
        guard key.object.account == operation.account, pr.account == operation.account,
              try isCurrent(operation), !Task.isCancelled,
              try database.pullRequestExists(pr,headSHA:headSHA) else { throw CancellationError() }
        if let data { try await cache.put(data,for:key); return data }
        return try await cache.data(for:key)
    }
    public func saveAuthorized(_ result: AuthorizedGitHubAccount) async throws {
        await acquire(result.scope); defer { release(result.scope) }
        try Task.checkCancellation()
        generations[result.scope] = UUID()
        blocked[result.scope] = .authorizationRequired(localPersistenceFailed:false)
        publish(blocked[result.scope]!,account:result.scope)
        do {
            try await cache.invalidatePrivatePayloads(for:result.scope)
            try Task.checkCancellation()
            try saveCredential(result.credential,account:result.scope)
            try database.saveAccount(Account(scope:result.scope,login:result.login,tokenReference:Self.tokenReference(for:result.scope)))
            try database.setSetting("false",for:.authorizationProblem,account:result.scope)
            blocked[result.scope] = nil
            publish(.available,account:result.scope)
        } catch {
            // A partial reauthorization must not reopen availability, including after restart.
            do { try removeCredential(account:result.scope) }
            catch { Log.keychain.error("Could not remove a partially reauthorized credential: \(Log.kind(error), privacy: .public)") }
            do { try database.setSetting("true",for:.authorizationProblem,account:result.scope) }
            catch { Log.storage.error("Could not record a failed reauthorization: \(Log.kind(error), privacy: .public)") }
            blocked[result.scope] = .authorizationRequired(localPersistenceFailed:true)
            publish(blocked[result.scope]!,account:result.scope)
            throw error
        }
    }
    public func saveRefreshed(_ credential: GitHubCredential, operation: AccountOperation) async throws -> Bool {
        await acquire(operation.account); defer { release(operation.account) }
        guard try isCurrent(operation), !Task.isCancelled,
              try storedCredential(for:operation.account)?.accessToken == operation.credential.accessToken else { return false }
        try await cache.invalidatePrivatePayloads(for:operation.account)
        try Task.checkCancellation()
        try saveCredential(credential,account:operation.account)
        return true
    }
    public func markInvalid(_ operation: AccountOperation) async throws -> Bool {
        await acquire(operation.account); defer { release(operation.account) }
        // Read tickets remain valid across rotation for successful commits. A token-specific
        // authentication failure may invalidate only the credential that actually failed.
        guard try storedCredential(for:operation.account)?.accessToken == operation.credential.accessToken else { return false }
        return try await markInvalidLocked(account:operation.account,generation:operation.generation,cause:.providerRejected)
    }
    public func saveDiscovery(_ result: GitHubDiscoveryResult, operation: AccountOperation) async throws -> Bool {
        await acquire(operation.account); defer { release(operation.account) }
        guard try isCurrent(operation), !Task.isCancelled else { return false }
        // A complete listing that omits a known repository purges its cached content (lost access).
        if try await !cache.commitRepositoryDiscovery(result,account:operation.account).isEmpty {
            PRDetailMemoryCache.shared.purge(account:operation.account)
        }
        return true
    }
    public func remove(_ account: AccountScope) async throws {
        await acquire(account); defer { release(account) }
        generations[account] = UUID()
        cachedCredentials[account] = nil
        defer { PRDetailMemoryCache.shared.purge(account:account) }
        try await cache.removeAccount(account) { [credentials] _ in try credentials.remove(account:account) }
    }
}

// Internal acquisition result: cleanup already ran under the store lock, before a token ticket existed.
enum AccountAcquisitionFailure: Error, Sendable {
    case missingCredential(localPersistenceFailed: Bool)
}
