import Foundation
import XCTest
import GRDB
@testable import MergeProCore

final class MemoryCredentials: GitHubCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AccountScope:GitHubCredential] = [:]
    func credential(for account: AccountScope) -> GitHubCredential? { lock.withLock { values[account] } }
    func save(_ credential: GitHubCredential, account: AccountScope) { lock.withLock { values[account] = credential } }
    func remove(account: AccountScope) { _ = lock.withLock { values.removeValue(forKey:account) } }
}
private struct RemovalFailureCredentials: GitHubCredentialStore {
    let base: MemoryCredentials
    func credential(for account: AccountScope) -> GitHubCredential? { base.credential(for:account) }
    func save(_ credential: GitHubCredential, account: AccountScope) { base.save(credential,account:account) }
    func remove(account: AccountScope) throws { throw CocoaError(.fileWriteNoPermission) }
}

@MainActor
final class AccountSessionTests: XCTestCase {
    let account = AccountScope(host:"github.com",accountID:"42")
    let newCredential = GitHubCredential(accessToken:"new-fixture",scopes:["repo"])
    func fixture(expiring: Bool = false, failInvalidStatePersistence: Bool = false) async throws -> (DatabaseStore, CacheStore, MemoryCredentials, AccountSessionStore, PayloadKey) {
        let directory = try makeTemporaryDirectory()
        let database = try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        let cache = try CacheStore(directory:directory.appendingPathComponent("cache"),database:database)
        let credentials = MemoryCredentials()
        credentials.save(GitHubCredential(accessToken:"old-fixture",refreshToken:expiring ? "old-refresh" : nil,expiresAt:expiring ? Date(timeIntervalSince1970:1) : nil,scopes:["repo"]),account:account)
        try database.saveAccount(Account(scope:account,login:"login",tokenReference:AccountSessionStore.tokenReference(for:account)))
        let key = ProviderKey(host:account.host,accountID:account.accountID,repositoryID:"1",objectID:"1")
        let payload = PayloadKey(object:key,revision:RevisionID("sha"),kind:.diff)
        try await cache.put(Data("private-fixture".utf8),for:payload)
        if failInvalidStatePersistence {
            let queue = try DatabaseQueue(path:directory.appendingPathComponent("db.sqlite").path)
            try await queue.write { db in
                try db.execute(sql:"CREATE TRIGGER fixture_failed_invalid_state BEFORE INSERT ON settings WHEN NEW.name = 'authorizationProblem' BEGIN SELECT RAISE(ABORT, 'fixture persistence failure'); END")
            }
        }
        return (database,cache,credentials,AccountSessionStore(database:database,cache:cache,credentials:credentials),payload)
    }
    func testMissingCredentialPurgesOnlyAccountPayloadsPersistsInvalidStateAndPreservesDrafts() async throws {
        let (database,cache,credentials,storage,payload) = try await fixture()
        let other = AccountScope(host:"github.com",accountID:"55")
        credentials.save(newCredential,account:other)
        try database.saveAccount(Account(scope:other,login:"other",tokenReference:AccountSessionStore.tokenReference(for:other)))
        let otherPayload = PayloadKey(object:ProviderKey(host:other.host,accountID:other.accountID,repositoryID:"1",objectID:"1"),revision:RevisionID("sha"),kind:.diff)
        try await cache.put(Data("other-private-fixture".utf8),for:otherPayload)
        let draft = Draft(id:UUID(),key:payload.object,revision:payload.revision,body:"unsent fixture")
        try database.saveDraft(draft)
        credentials.remove(account:account)
        let transport = ScriptedTransport([])
        let session = GitHubAccountSession(storage:storage,transport:transport,clock:FixtureClock())
        let outcome = await session.discover(account,clientID:"id")
        guard case .authorizationRequired(localPersistenceFailed:false) = outcome else { return XCTFail("missing credential should require reconnect after durable cleanup") }
        XCTAssertEqual(try database.snapshot(for:account).settings["authorizationProblem"],"true")
        XCTAssertEqual(try database.snapshot(for:account).drafts,[draft])
        let removed = try await cache.data(for:payload); XCTAssertNil(removed)
        let retained = try await cache.data(for:otherPayload); XCTAssertEqual(retained,Data("other-private-fixture".utf8))
        XCTAssertEqual(credentials.credential(for:other),newCredential)
        XCTAssertNotEqual(try database.snapshot(for:other).settings["authorizationProblem"],"true")
        let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
    }
    /// A missing Keychain item is not a provider-confirmed revocation (data-protection fallback, a migration
    /// edge case): payload files and feature caches go, but cached PR rows, repositories and the inbox stay
    /// until GitHub itself rejects the credential.
    func testMissingCredentialInvalidatesPayloadsWithoutTheFullPrivateContentPurge() async throws {
        let (database,cache,credentials,storage,payload) = try await fixture()
        let repository = RepositoryKey(account:account,repositoryID:"1")
        try database.saveRepository(Repository(key:repository,name:"o/r",isPrivate:true,capabilities:[]))
        try database.savePullRequests([PullRequest(key:payload.object,headRevision:RevisionID("sha"),title:"Fixture",state:.open,isDraft:false)])
        let cycles = PollCycleStore(database:database), cycle = UUID()
        try cycles.begin(cycle,at:Date(),baseline:false)
        try cycles.record([ChangeEvent(key:"kept",object:payload.object,category:"fixture",occurredAt:Date())],cycleID:cycle)
        try cycles.interrupt(cycle)
        credentials.remove(account:account)
        let state = try await storage.authorizationState(for:account)
        XCTAssertEqual(state,.authorizationRequired(localPersistenceFailed:false))
        XCTAssertEqual(try database.snapshot(for:account).settings["authorizationProblem"],"true")
        let removed = try await cache.data(for:payload); XCTAssertNil(removed,"payload files are invalidated")
        XCTAssertEqual(try database.snapshot(for:account).pullRequests.count,1,"cached rows wait for a provider-confirmed revocation")
        XCTAssertNotNil(try database.repository(repository))
        XCTAssertEqual(try cycles.inbox().map(\.id),["kept"])
    }
    func testMissingCredentialPersistenceFailureIsTruthfullyReportedWithoutNetworkRequest() async throws {
        let (database,_,credentials,storage,_) = try await fixture(failInvalidStatePersistence:true)
        credentials.remove(account:account)
        let transport = ScriptedTransport([])
        let session = GitHubAccountSession(storage:storage,transport:transport,clock:FixtureClock())
        let outcome = await session.discover(account,clientID:"id")
        guard case .authorizationRequired(localPersistenceFailed:true) = outcome else { return XCTFail("failed missing-credential cleanup must surface a local persistence failure") }
        XCTAssertNotEqual(try database.snapshot(for:account).settings["authorizationProblem"],"true")
        let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
    }
    func testCurrentCredentialInvalidationBlocksAcquisitionAndOldCommitWhenSQLiteFlagFails() async throws {
        let (database,_,_,storage,_) = try await fixture(failInvalidStatePersistence:true)
        let ticket = try await storage.operation(for:account,now:Date())
        do { _ = try await storage.markInvalid(ticket); XCTFail("SQLite trigger must abort persistence") } catch {}
        XCTAssertNotEqual(try database.snapshot(for:account).settings["authorizationProblem"],"true")
        do { _ = try await storage.operation(for:account,now:Date()); XCTFail("Known revoked credential must not be reacquired") } catch {}
        let committed = try await storage.withCurrentOperation(ticket) { _ in
            XCTFail("An old ticket must never enter the commit body after known revocation")
        }
        XCTAssertFalse(committed)
    }
    func testBeginningReconnectCancelsOldDiscoveryBeforeAuthorizationCompletes() async throws {
        let (database,cache,credentials,storage,payload) = try await fixture()
        let original = credentials.credential(for:account)
        let transport = ScriptedTransport.suspended(); let session = GitHubAccountSession(storage:storage,transport:transport,clock:FixtureClock())
        let task = Task { await session.discover(account,clientID:"id") }
        await transport.waitUntilHolding()
        await session.invalidateOperations(for:account)
        await transport.release(json("{}",status:401))
        let outcome = await task.value
        guard case .stale = outcome else { return XCTFail("pending reconnect must invalidate old operation") }
        XCTAssertEqual(credentials.credential(for:account),original)
        XCTAssertNotEqual(try database.snapshot(for:account).settings["authorizationProblem"],"true")
        let data = try await cache.data(for:payload); XCTAssertEqual(data,Data("private-fixture".utf8))
    }
    func testReconnectRejectsLateOldToken401WithoutInvalidatingNewCredential() async throws {
        let (database,cache,credentials,storage,payload) = try await fixture()
        let transport = ScriptedTransport.suspended(); let session = GitHubAccountSession(storage:storage,transport:transport,clock:FixtureClock())
        let task = Task { await session.discover(account,clientID:"id") }
        await transport.waitUntilHolding()
        try await session.saveAuthorized(AuthorizedGitHubAccount(scope:account,login:"renamed",credential:newCredential))
        try await cache.put(Data("new-private-fixture".utf8),for:payload)
        let newDiscovery = await session.discover(account,clientID:"id")
        guard case .updated = newDiscovery else { return XCTFail("new credential discovery must not be suppressed by old in-flight work") }
        await transport.release(json("{}",status:401)); _ = await task.value
        XCTAssertEqual(credentials.credential(for:account),newCredential)
        XCTAssertEqual(try database.snapshot(for:account).settings["authorizationProblem"],"false")
        let data = try await cache.data(for:payload); XCTAssertEqual(data,Data("new-private-fixture".utf8))
    }
    func testReconnectRejectsLateRefreshFromOldCredential() async throws {
        let (_,_,credentials,storage,_) = try await fixture(expiring:true)
        let transport = ScriptedTransport.suspended(); let session = GitHubAccountSession(storage:storage,transport:transport,clock:FixtureClock())
        let task = Task { await session.discover(account,clientID:"id") }
        await transport.waitUntilHolding()
        try await session.saveAuthorized(AuthorizedGitHubAccount(scope:account,login:"login",credential:newCredential))
        await transport.release(token); _ = await task.value
        XCTAssertEqual(credentials.credential(for:account),newCredential)
        let requests = await transport.requests; XCTAssertEqual(requests.count,1)
    }
    func testRemovalRejectsLateRefreshAndDoesNotRestoreKeychainCredential() async throws {
        let (database,_,credentials,storage,_) = try await fixture(expiring:true)
        let transport = ScriptedTransport.suspended(); let session = GitHubAccountSession(storage:storage,transport:transport,clock:FixtureClock())
        let task = Task { await session.discover(account,clientID:"id") }
        await transport.waitUntilHolding()
        try await session.remove(account)
        await transport.release(token); _ = await task.value
        XCTAssertNil(credentials.credential(for:account)); XCTAssertEqual(try database.accounts(),[])
        let requests = await transport.requests; XCTAssertEqual(requests.count,1)
    }
    func testTransientRefreshFailurePreservesCredentialPrivateCacheAndRetryability() async throws {
        for response in [json("{}",status:500),json("not-json")] {
            let (database,cache,credentials,storage,payload) = try await fixture(expiring:true)
            let original = credentials.credential(for:account)
            let session = GitHubAccountSession(storage:storage,transport:ScriptedTransport([response]),clock:FixtureClock())
            let outcome = await session.discover(account,clientID:"id")
            guard case .retryable = outcome else { XCTFail("transient response must stay retryable"); continue }
            XCTAssertEqual(credentials.credential(for:account),original)
            XCTAssertNotEqual(try database.snapshot(for:account).settings["authorizationProblem"],"true")
            let data = try await cache.data(for:payload); XCTAssertEqual(data,Data("private-fixture".utf8))
        }
    }
    func testExplicitInvalidRefreshDisablesOnlyThatAccountAndPurgesPrivateCache() async throws {
        let (database,cache,_,storage,payload) = try await fixture(expiring:true)
        let session = GitHubAccountSession(storage:storage,transport:ScriptedTransport([json(#"{"error":"bad_refresh_token"}"#)]),clock:FixtureClock())
        let outcome = await session.discover(account,clientID:"id")
        guard case .authorizationRequired(localPersistenceFailed:false) = outcome else { return XCTFail("invalid refresh must require reconnect") }
        XCTAssertEqual(try database.snapshot(for:account).settings["authorizationProblem"],"true")
        let data = try await cache.data(for:payload); XCTAssertNil(data)
    }
    func testThrottleBlocksRepeatedDiscoveryAndRestoredSessionUntilDeadline() async throws {
        let (database,cache,credentials,storage,_) = try await fixture()
        let transport = ScriptedTransport([json("{}",status:429,headers:["Retry-After":"60"]),json("[]"),json("[]"),json("[]"),json("[]"),json("[]"),json("[]")])
        let clock = FixtureClock()
        let session = GitHubAccountSession(storage:storage,transport:transport,clock:clock)
        _ = await session.discover(account,clientID:"id")
        let retry = await session.discover(account,clientID:"id")
        guard case .throttled(until:Date(timeIntervalSince1970:60)) = retry else { return XCTFail("account retry must retain structured throttle deadline") }
        var requests = await transport.captured(); XCTAssertEqual(requests.count,1)
        let restored = GitHubAccountSession(storage:AccountSessionStore(database:database,cache:cache,credentials:credentials),transport:transport,clock:clock)
        let afterRestart = await restored.discover(account,clientID:"id")
        guard case .throttled = afterRestart else { return XCTFail("deadline must survive lifecycle recreation") }
        requests = await transport.captured(); XCTAssertEqual(requests.count,1)
        try await clock.sleep(seconds:61)
        let afterDeadline = await restored.discover(account,clientID:"id")
        guard case .updated(let result) = afterDeadline else { return XCTFail("retry becomes available after deadline") }
        XCTAssertTrue(result.isComplete)
        requests = await transport.captured(); XCTAssertEqual(requests.count,4)
    }
    func testStorageAtomicallyRejectsStaleMutationsEvenWithoutTaskCancellation() async throws {
        let (database,cache,credentials,storage,payload) = try await fixture()
        let operation = try await storage.operation(for:account,now:Date(timeIntervalSince1970:0))
        try await storage.saveAuthorized(AuthorizedGitHubAccount(scope:account,login:"new",credential:newCredential))
        try await cache.put(Data("new-private-fixture".utf8),for:payload)
        let refreshSaved = try await storage.saveRefreshed(GitHubCredential(accessToken:"stale"),operation:operation)
        let invalidSaved = try await storage.markInvalid(operation)
        XCTAssertFalse(refreshSaved); XCTAssertFalse(invalidSaved)
        XCTAssertEqual(credentials.credential(for:account),newCredential)
        XCTAssertEqual(try database.snapshot(for:account).settings["authorizationProblem"],"false")
        let data = try await cache.data(for:payload); XCTAssertEqual(data,Data("new-private-fixture".utf8))
        try await storage.remove(account)
        let restoredAfterRemoval = try await storage.saveRefreshed(GitHubCredential(accessToken:"stale"),operation:operation)
        XCTAssertFalse(restoredAfterRemoval); XCTAssertNil(credentials.credential(for:account))
    }
    func testConcurrentFeatureConsumersShareOneRefreshAndPreserveTicketGeneration() async throws {
        let (_,_,credentials,storage,_) = try await fixture(expiring:true)
        let transport = ScriptedTransport.suspended()
        let session = GitHubAccountSession(storage:storage,transport:transport,clock:FixtureClock())
        let first = Task { try await session.authenticatedOperation(for:account,clientID:"id") }
        await transport.waitUntilHolding()
        let second = Task { try await session.authenticatedOperation(for:account,clientID:"id") }
        for _ in 0..<20 { await Task.yield() }
        first.cancel() // The feature cycle expired, but credential rotation still must persist.
        await transport.release(token)
        let a = try await first.value; let b = try await second.value
        XCTAssertEqual(a.credential,b.credential)
        XCTAssertEqual(credentials.credential(for:account),b.credential)
        let requests = await transport.requests; XCTAssertEqual(requests.count,1)
        let aCurrent = try await storage.withCurrentOperation(a) { _ in }
        let bCurrent = try await storage.withCurrentOperation(b) { _ in }
        XCTAssertTrue(aCurrent); XCTAssertTrue(bCurrent)
        // A third consumer gets the saved rotation, without invalidating the first two tickets.
        _ = try await session.authenticatedOperation(for:account,clientID:"id")
        let stillCurrent = try await storage.withCurrentOperation(a) { _ in }; XCTAssertTrue(stillCurrent)
    }

    func testLateOldToken401CannotInvalidateValidRotationOrConcurrentReadCommit() async throws {
        let (database,cache,credentials,storage,payload) = try await fixture()
        let ticketA = try await storage.operation(for:account,now:Date(timeIntervalSince1970:0))
        let rotated = GitHubCredential(accessToken:"rotated-B-fixture",refreshToken:"rotated-refresh-fixture")
        let saved = try await storage.saveRefreshed(rotated,operation:ticketA); XCTAssertTrue(saved)
        let ticketB = try await storage.operation(for:account,now:Date(timeIntervalSince1970:0))
        try await cache.put(Data("current-B-private-fixture".utf8),for:payload)
        let session = GitHubAccountSession(storage:storage,transport:ScriptedTransport([]))
        await session.featureFailed(GitHubFailure.invalidAuthentication,operation:ticketA)
        XCTAssertEqual(credentials.credential(for:account),rotated)
        XCTAssertNotEqual(try database.snapshot(for:account).settings["authorizationProblem"],"true")
        let retained = try await cache.data(for:payload); XCTAssertEqual(retained,Data("current-B-private-fixture".utf8))
        let account = self.account
        let oldReadCanCommit = try await storage.withCurrentOperation(ticketA) { db in
            try db.setSetting("committed",for:"valid-old-read",account:account)
        }
        let newReadCanCommit = try await storage.withCurrentOperation(ticketB) { db in
            try db.setSetting("committed",for:"valid-new-read",account:account)
        }
        XCTAssertTrue(oldReadCanCommit); XCTAssertTrue(newReadCanCommit)
        XCTAssertEqual(try database.snapshot(for:account).settings["valid-old-read"],"committed")
        // A failure from the actual current token still disables authentication.
        await session.featureFailed(GitHubFailure.invalidAuthentication,operation:ticketB)
        XCTAssertEqual(try database.snapshot(for:account).settings["authorizationProblem"],"true")
        let removed = try await cache.data(for:payload); XCTAssertNil(removed)
    }

    func testFeature401PersistenceFailureIsIsolatedRestartSafeAndOnlyVerifiedReconnectReleases() async throws {
        let (database,cache,credentials,storage,payload) = try await fixture(failInvalidStatePersistence:true)
        let other = AccountScope(host:"github.com",accountID:"55")
        try database.saveAccount(Account(scope:other,login:"other",tokenReference:"fixture"))
        credentials.save(newCredential,account:other)
        let session = GitHubAccountSession(storage:storage,transport:ScriptedTransport([]))
        let ticket = try await session.authenticatedOperation(for:account,clientID:"fixture")
        let otherTicket = try await session.authenticatedOperation(for:other,clientID:"fixture")
        await session.featureFailed(GitHubFailure.invalidAuthentication,operation:ticket)
        let availability = try await session.authorizationState(for:account)
        XCTAssertEqual(availability,.authorizationRequired(localPersistenceFailed:true))
        XCTAssertNil(credentials.credential(for:account))
        XCTAssertEqual(credentials.credential(for:other),newCredential)
        let retained = try await session.withCurrentOperation(otherTicket) { _ in }; XCTAssertTrue(retained)
        let payloadData = try await cache.data(for:payload); XCTAssertNil(payloadData)
        let restored = AccountSessionStore(database:database,cache:cache,credentials:credentials)
        let restoredState = try await restored.authorizationState(for:account)
        XCTAssertEqual(restoredState,.authorizationRequired(localPersistenceFailed:true))
        do { try await session.saveAuthorized(.init(scope:account,login:"verified",credential:newCredential)); XCTFail("Trigger must reject reconnect persistence") } catch {}
        XCTAssertNil(credentials.credential(for:account))
        let stillBlocked = try await session.authorizationState(for:account)
        XCTAssertEqual(stillBlocked,.authorizationRequired(localPersistenceFailed:true))
        try await database.database.write { db in try db.execute(sql:"DROP TRIGGER fixture_failed_invalid_state") }
        try await session.saveAuthorized(.init(scope:account,login:"verified",credential:newCredential))
        let released = try await session.authorizationState(for:account); XCTAssertEqual(released,.available)
        let fresh = try await session.authenticatedOperation(for:account,clientID:"fixture")
        let freshCommit = try await session.withCurrentOperation(fresh) { _ in }; XCTAssertTrue(freshCommit)
        let oldCommit = try await session.withCurrentOperation(ticket) { _ in XCTFail("Old generation must remain invalid") }; XCTAssertFalse(oldCommit)
    }

    func testLosslessOwnerStreamPreservesRapidDenialsForBothAccountsAndInitialDeniedState() async throws {
        let (database,_,credentials,storage,_) = try await fixture(failInvalidStatePersistence:true)
        let other = AccountScope(host:"github.com",accountID:"55")
        try database.saveAccount(Account(scope:other,login:"other",tokenReference:"fixture"))
        credentials.save(newCredential,account:other)
        let first = try await storage.operation(for:account,now:Date())
        let second = try await storage.operation(for:other,now:Date())
        var events = try await storage.authorizationChanges().makeAsyncIterator()
        _ = await events.next(); _ = await events.next()
        do { _ = try await storage.markInvalid(first); XCTFail("SQLite abort expected") } catch {}
        do { _ = try await storage.markInvalid(second); XCTFail("SQLite abort expected") } catch {}
        var changes: [AccountAuthorizationChange] = []
        for _ in 0..<4 { changes.append(await events.next()!) }
        XCTAssertEqual(changes.filter { $0.account == account }.count,2)
        XCTAssertEqual(changes.filter { $0.account == other }.count,2)
        XCTAssertTrue(changes.allSatisfy { $0.state != .available })
        var restored = try await storage.authorizationChanges().makeAsyncIterator()
        let a = await restored.next(); let b = await restored.next()
        XCTAssertEqual(Set([a!.account,b!.account]),[account,other])
        XCTAssertEqual(a?.state,.authorizationRequired(localPersistenceFailed:true))
        XCTAssertEqual(b?.state,.authorizationRequired(localPersistenceFailed:true))
    }
    func testCredentialDeletionAndSQLiteFailureStillBlockLiveOwnerAndExposeCleanupFailure() async throws {
        let (database,cache,credentials,_,payload) = try await fixture(failInvalidStatePersistence:true)
        let store = AccountSessionStore(database:database,cache:cache,credentials:RemovalFailureCredentials(base:credentials))
        let ticket = try await store.operation(for:account,now:Date())
        do { _ = try await store.markInvalid(ticket); XCTFail("Cleanup error must not be hidden") } catch {}
        XCTAssertNotNil(credentials.credential(for:account))
        XCTAssertNotEqual(try database.snapshot(for:account).settings["authorizationProblem"],"true")
        let state = try await store.authorizationState(for:account)
        XCTAssertEqual(state,.authorizationRequired(localPersistenceFailed:true))
        do { _ = try await store.operation(for:account,now:Date()); XCTFail("Live owner must remain blocked") } catch {}
        let committed = try await store.withCurrentOperation(ticket) { _ in XCTFail("Old commit must be rejected") }; XCTAssertFalse(committed)
        let data = try await cache.data(for:payload); XCTAssertNil(data,"Payload cleanup is attempted despite two earlier failures")
    }

    func testLateCanceledHTTP401FromOldTokenPreservesRotatedCredentialAndReadCommits() async throws {
        let (database,_,credentials,storage,_) = try await fixture()
        let transport = ScriptedTransport.suspended()
        let session = GitHubAccountSession(storage:storage,transport:transport)
        let ticket = try await session.authenticatedOperation(for:account,clientID:"fixture")
        let client = await session.featureClient(account:account,budget:RateBudget(minimumSpacing:.zero))
        let task = Task { try await client.get(URL(string:"https://api.github.com/user")!,token:ticket.credential.accessToken) }
        await transport.waitUntilHolding()
        let saved = try await storage.saveRefreshed(newCredential,operation:ticket); XCTAssertTrue(saved)
        task.cancel()
        await transport.release(GitHubResponse(status:401,responseURL:URL(string:"https://api.github.com/user")))
        do { _ = try await task.value; XCTFail("Observed trusted 401 must surface") }
        catch {
            XCTAssertEqual(error as? GitHubFailure,.invalidAuthentication)
            await session.featureFailed(error,operation:ticket)
        }
        XCTAssertEqual(credentials.credential(for:account),newCredential)
        XCTAssertNotEqual(try database.snapshot(for:account).settings["authorizationProblem"],"true")
        let state = try await session.authorizationState(for:account); XCTAssertEqual(state,.available)
        let committed = try await session.withCurrentOperation(ticket) { _ in }; XCTAssertTrue(committed)
    }
    func testRefresh401PersistenceFailureReportsAuthorizationRequiredRatherThanRetryable() async throws {
        let (_,_,_,storage,_) = try await fixture(expiring:true,failInvalidStatePersistence:true)
        let session = GitHubAccountSession(storage:storage,transport:ScriptedTransport([json("{}",status:401)]),clock:FixtureClock())
        let result = await session.discover(account,clientID:"fixture")
        guard case .authorizationRequired(localPersistenceFailed:true) = result else { return XCTFail("Known refresh revocation must retain truthful cleanup-failure outcome") }
    }

    func testFailedCacheCleanupMustFinishBeforeReauthorizationClearsOwner() async throws {
        let (database,_,credentials,store,_) = try await fixture()
        try await database.database.write { db in
            try db.execute(sql:"CREATE TRIGGER fixture_failed_cache_cleanup BEFORE DELETE ON cacheEntries BEGIN SELECT RAISE(ABORT, 'fixture cache cleanup failure'); END")
        }
        let ticket = try await store.operation(for:account,now:Date())
        do { _ = try await store.markInvalid(ticket); XCTFail("Cache cleanup abort expected") } catch {}
        XCTAssertNil(credentials.credential(for:account))
        do { try await store.saveAuthorized(.init(scope:account,login:"verified",credential:newCredential)); XCTFail("Reconnect must retry and finish previous failed cache cleanup") } catch {}
        let denied = try await store.authorizationState(for:account)
        XCTAssertEqual(denied,.authorizationRequired(localPersistenceFailed:true))
        try await database.database.write { db in try db.execute(sql:"DROP TRIGGER fixture_failed_cache_cleanup") }
        try await store.saveAuthorized(.init(scope:account,login:"verified",credential:newCredential))
        let available = try await store.authorizationState(for:account); XCTAssertEqual(available,.available)
    }

    func testCanceledDiscoveryTrusted401StillRevokesCurrentCredentialDespiteFailedStatusPersistence() async throws {
        let (_,_,credentials,storage,_) = try await fixture(failInvalidStatePersistence:true)
        let transport = ScriptedTransport.suspended()
        let session = GitHubAccountSession(storage:storage,transport:transport)
        let task = Task { await session.discover(account,clientID:"fixture") }
        await transport.waitUntilHolding()
        task.cancel()
        await transport.release(GitHubResponse(status:401,responseURL:await transport.requests.first!.url))
        let outcome = await task.value
        guard case .authorizationRequired(localPersistenceFailed:true) = outcome else { return XCTFail("Known trusted401 must reach owner before discovery cancellation is treated as stale") }
        let state = try await session.authorizationState(for:account)
        XCTAssertEqual(state,.authorizationRequired(localPersistenceFailed:true))
        XCTAssertNil(credentials.credential(for:account))
    }

}
