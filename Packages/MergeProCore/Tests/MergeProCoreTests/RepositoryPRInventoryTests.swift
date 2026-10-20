import XCTest
@testable import MergeProCore

@MainActor final class RepositoryPRInventoryTests:XCTestCase {
    func fixture(_ transport:any GitHubTransport) throws -> (DatabaseStore,GitHubAccountSession,RepositoryPRInventoryService,RepositoryKey) {
        let database=try DatabaseStore(path:":memory:")
        let directory=try makeTemporaryDirectory()
        let cache=try CacheStore(directory:directory,database:database),credentials=MemoryCredentials()
        let account=AccountScope(host:"github.com",accountID:"1"),key=RepositoryKey(account:account,repositoryID:"7")
        try database.saveAccount(.init(scope:account,login:"fixture",tokenReference:nil))
        try database.saveRepository(.init(key:key,name:"o/r",isPrivate:true,capabilities:[.readPullRequests]))
        credentials.save(.init(accessToken:"offline-inventory"),account:account)
        let session=GitHubAccountSession(storage:AccountSessionStore(database:database,cache:cache,credentials:credentials),transport:transport)
        return (database,session,.init(session:session,budget:RateBudget(minimumSpacing:.zero),database:database,clientID:"fixture"),key)
    }
    func testRepositoryTabReadsUntrackedPRsWithoutCreatingANotificationCycle() async throws {
        let (database,_,service,key)=try fixture(await RoutingTransport.repositoryInventory())
        let status=try await service.refresh(key)
        XCTAssertTrue(status.complete)
        XCTAssertEqual(try database.snapshot(for:key.account).pullRequests.count,101)
        XCTAssertTrue(try database.snapshot(for:key.account).trackedRepositories.isEmpty)
        XCTAssertTrue(try PollCycleStore(database:database).inbox().isEmpty)
    }
    func testPreviousSessionResponseCannotPopulateUntrackedRepoTab() async throws {
        let transport=await RoutingTransport.repositoryInventory(holdingFirstGraphQL:true)
        let (database,session,service,key)=try fixture(transport)
        let task=Task { try await service.refresh(key) }
        await transport.waitUntilHolding()
        await session.invalidateOperations(for:key.account)
        await transport.release()
        do { _=try await task.value;XCTFail("stale session result must be rejected") } catch { }
        XCTAssertTrue(try database.snapshot(for:key.account).pullRequests.isEmpty)
    }
}

extension RepositoryPRInventoryTests {
    func testFreshUntrackedRepositoryServesCachedRowsWithoutNetworkUntilItsWindowEnds() async throws {
        let transport=await RoutingTransport.repositoryInventory()
        let (_,_,service,key)=try fixture(transport)
        let first=try await service.refreshIfStale(key)
        XCTAssertTrue(first.didFetch);XCTAssertTrue(first.status.complete)
        let afterFirst=await transport.identityReads+transport.graphQLReads,firstGraphQL=await transport.graphQLReads;XCTAssertGreaterThan(firstGraphQL,0)
        let fresh=try await service.refreshIfStale(key,now:Date().addingTimeInterval(110))
        XCTAssertFalse(fresh.didFetch);XCTAssertEqual(fresh.status.fetchedCount,first.status.fetchedCount)
        let rows=try await service.cachedRows(key);XCTAssertEqual(rows.count,101)
        XCTAssertTrue(rows.allSatisfy { $0.key.repository == key })
        let unchanged=await transport.identityReads+transport.graphQLReads;XCTAssertEqual(unchanged,afterFirst)
        let stale=try await service.refreshIfStale(key,now:Date().addingTimeInterval(130))
        XCTAssertTrue(stale.didFetch)
        let after=await transport.graphQLReads;XCTAssertGreaterThan(after,firstGraphQL)
    }
    func testTrackedRepositoryUsesThePollerFreshnessWindow() async throws {
        let transport=await RoutingTransport.repositoryInventory()
        let (database,_,service,key)=try fixture(transport)
        try database.setTracked(key,tracked:true)
        _ = try await service.refreshIfStale(key)
        let fresh=try await service.refreshIfStale(key,now:Date().addingTimeInterval(50));XCTAssertFalse(fresh.didFetch)
        let stale=try await service.refreshIfStale(key,now:Date().addingTimeInterval(70));XCTAssertTrue(stale.didFetch)
    }
    func testRepositoryIdentityIsVerifiedOncePerAccountSession() async throws {
        let transport=await RoutingTransport.repositoryInventory()
        let (database,session,service,key)=try fixture(transport)
        _ = try await service.refresh(key);_ = try await service.refresh(key)
        let other=RepositoryPRInventoryService(session:session,budget:RateBudget(minimumSpacing:.zero),database:database,clientID:"fixture")
        _ = try await other.refresh(key)
        let reused=await transport.identityReads;XCTAssertEqual(reused,1)
        await session.invalidateOperations(for:key.account)
        _ = try await service.refresh(key)
        let renewed=await transport.identityReads;XCTAssertEqual(renewed,2)
    }
}
