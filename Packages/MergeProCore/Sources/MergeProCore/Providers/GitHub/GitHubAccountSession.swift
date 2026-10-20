import Foundation

public enum AccountDiscoveryOutcome: Sendable {
    case updated(GitHubDiscoveryResult), authorizationRequired(localPersistenceFailed: Bool), retryable, throttled(until: Date), stale
}
/// Owns account network work. All result side effects go through the generation-checked store.
public actor GitHubAccountSession {
    private let storage: AccountSessionStore
    private let transport: any GitHubTransport
    private let clock: any DeviceFlowClock
    private struct Worker { let id: UUID; let task: Task<AccountDiscoveryOutcome,Never> }
    private struct CredentialWorker { let id: UUID; let task: Task<AccountOperation,Error> }
    private var credentialWorkers: [AccountScope:CredentialWorker] = [:]
    private var workers: [AccountScope:Worker] = [:]
    public init(storage: AccountSessionStore, transport: any GitHubTransport, clock: any DeviceFlowClock = SystemDeviceFlowClock()) {
        self.storage = storage; self.transport = transport; self.clock = clock
    }
    public func invalidateOperations(for account: AccountScope) async {
        workers.removeValue(forKey:account)?.task.cancel()
        credentialWorkers.removeValue(forKey:account)?.task.cancel()
        await storage.invalidateOperations(for:account)
    }
    public func saveAuthorized(_ result: AuthorizedGitHubAccount) async throws {
        workers.removeValue(forKey:result.scope)?.task.cancel()
        credentialWorkers.removeValue(forKey:result.scope)?.task.cancel()
        try await storage.saveAuthorized(result)
    }
    public func remove(_ account: AccountScope) async throws {
        workers.removeValue(forKey:account)?.task.cancel()
        credentialWorkers.removeValue(forKey:account)?.task.cancel()
        try await storage.remove(account)
    }
    /// Refresh is single-flight and belongs to the credential session, not a feature cycle.
    /// Cancelling a feature waiter never discards a valid rotated credential.
    public func authenticatedOperation(for account: AccountScope, clientID: String) async throws -> AccountOperation {
        if let worker = credentialWorkers[account] { return try await worker.task.value }
        let id = UUID()
        let task = Task { try await self.resolveCredential(account,clientID:clientID) }
        credentialWorkers[account] = CredentialWorker(id:id,task:task)
        do {
            let value = try await task.value
            if credentialWorkers[account]?.id == id { credentialWorkers[account] = nil }
            return value
        } catch {
            if credentialWorkers[account]?.id == id { credentialWorkers[account] = nil }
            throw error
        }
    }
    private func resolveCredential(_ account: AccountScope, clientID: String) async throws -> AccountOperation {
        let ticket = try await storage.operation(for:account,now:await clock.date())
        do {
            if let expiry = ticket.credential.expiresAt, expiry <= (await clock.date()).addingTimeInterval(60) {
                let credential = try await DeviceFlowClient(clientID:clientID,transport:transport,clock:clock).refresh(ticket.credential)
                try Task.checkCancellation()
                guard try await storage.saveRefreshed(credential,operation:ticket) else { throw CancellationError() }
                return AccountOperation(account:account,credential:credential,generation:ticket.generation)
            }
            return ticket
        } catch {
            if error as? GitHubFailure == .invalidAuthentication {
                do { guard try await storage.markInvalid(ticket) else { throw CancellationError() } }
                catch {
                    if error is CancellationError { throw error }
                    throw AccountAcquisitionFailure.missingCredential(localPersistenceFailed:true)
                }
            }
            throw error
        }
    }
    public func featureClient(account: AccountScope, budget: RateBudget) -> GitHubHTTPClient {
        GitHubHTTPClient(transport:BudgetedGitHubTransport(base:transport,budget:budget,account:account),clock:clock)
    }
    public func interactiveReadClient(account:AccountScope,budget:RateBudget) -> GitHubHTTPClient {
        GitHubHTTPClient(transport:BudgetedGitHubTransport(base:transport,budget:budget,account:account,interactiveRead:true),clock:clock)
    }
    public func featureWriteClient(account:AccountScope,budget:RateBudget,beforeSend:@escaping @Sendable () async throws -> Void) -> GitHubHTTPClient {
        GitHubHTTPClient(transport:BudgetedGitHubTransport(base:transport,budget:budget,account:account,beforeSend:beforeSend),clock:clock)
    }
    /// The outer write transport holds the account request slot. Revalidation reads consume
    /// the same shared budget interactively without recursively acquiring that slot.
    func preflightWriteClient(account:AccountScope,budget:RateBudget,current:@escaping @Sendable () async throws -> Void,beforeSend:@escaping @Sendable (GitHubHTTPClient) async throws -> Void) -> GitHubHTTPClient {
        let reader=GitHubHTTPClient(transport:BudgetedGitHubTransport(base:transport,budget:budget,account:account,ownsRequestSlot:false,beforeSend:current),clock:clock)
        return featureWriteClient(account:account,budget:budget,beforeSend:{ try await beforeSend(reader) })
    }
    public func withCurrentOperation(_ operation: AccountOperation, body: @Sendable (DatabaseStore) throws -> Void) async throws -> Bool {
        try await storage.withCurrentOperation(operation,body:body)
    }
    @discardableResult
    public func detailPayload(_ data: Data?, key: PayloadKey, pr: ProviderKey, headSHA: String, operation: AccountOperation) async throws -> Data? {
        try await storage.detailPayload(data,key:key,pr:pr,headSHA:headSHA,operation:operation)
    }
    public func withCurrentWriteOperation(_ operation:AccountOperation,body:@Sendable (DatabaseStore) throws -> Void) async throws -> Bool {
        try await storage.withCurrentWriteOperation(operation,body:body)
    }
    public func observationFence(_ key:ProviderKey,operation:AccountOperation) async throws -> Int {
        try await storage.observationFence(key,operation:operation)
    }
    public func authorizationState(for account: AccountScope) async throws -> AccountAuthorizationState {
        try await storage.authorizationState(for:account)
    }
    public func snapshot(for account: AccountScope) async throws -> LocalSnapshot {
        try await storage.snapshot(for:account)
    }
    public func authorizationChanges() async throws -> AsyncStream<AccountAuthorizationChange> {
        try await storage.authorizationChanges()
    }
    public func featureFailed(_ error: any Error, operation: AccountOperation) async {
        guard error as? GitHubFailure == .invalidAuthentication else { return }
        do { _ = try await storage.markInvalid(operation) }
        catch { Log.storage.error("Could not record a rejected credential: \(Log.kind(error), privacy: .public)") }
    }
    public func discover(_ account: AccountScope, clientID: String) async -> AccountDiscoveryOutcome {
        if let worker = workers[account] { return await worker.task.value }
        let id = UUID()
        let task = Task { await self.run(account,clientID:clientID) }
        workers[account] = Worker(id:id,task:task)
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if workers[account]?.id == id { workers[account] = nil }
        return result
    }
    private func run(_ account: AccountScope, clientID: String) async -> AccountDiscoveryOutcome {
        var operation: AccountOperation?
        do {
            let ticket = try await authenticatedOperation(for:account,clientID:clientID); operation = ticket
            let credential = ticket.credential
            let result = try await RepositoryDiscovery(client:GitHubHTTPClient(transport:transport,clock:clock)).discover(account:account,credential:credential)
            try Task.checkCancellation()
            guard try await storage.saveDiscovery(result,operation:ticket) else { return .stale }
            return .updated(result)
        } catch {
            // Trusted401 must reach the credential owner even when discovery was canceled.
            // The owner still rejects old token/generation failures after rotation/reconnect.
            if error as? GitHubFailure == .invalidAuthentication {
                if let operation {
                    do { guard try await storage.markInvalid(operation) else { return .stale } }
                    catch { return .authorizationRequired(localPersistenceFailed:true) }
                }
                return .authorizationRequired(localPersistenceFailed:false)
            }
            if error is CancellationError || Task.isCancelled { return .stale }
            if case .missingCredential(let localPersistenceFailed) = error as? AccountAcquisitionFailure {
                return .authorizationRequired(localPersistenceFailed:localPersistenceFailed)
            }
            if case .rateLimited(let until) = error as? GitHubFailure {
                let fallback = (await clock.date()).addingTimeInterval(60)
                return .throttled(until:until ?? fallback)
            }
            return .retryable
        }
    }
}
