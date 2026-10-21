import XCTest
@testable import MergeProCore

/// An interactive repository refresh and the poller both commit the repository's inventory checkpoint;
/// neither may overwrite a newer one with the older continuation it started from.
@MainActor final class InventoryCheckpointRaceTests:XCTestCase {
    func testInteractiveRefreshKeepsACheckpointThePollerCommittedMeanwhile() async throws {
        // Holds the first GraphQL inventory read until released, so a poller commit can land mid-refresh.
        let transport=await RoutingTransport.repositoryInventory(holdingFirstGraphQL:true)
        let database=try DatabaseStore(path:":memory:")
        let directory=try makeTemporaryDirectory()
        let account=AccountScope(host:"github.com",accountID:"1"),key=RepositoryKey(account:account,repositoryID:"7")
        try database.saveAccount(.init(scope:account,login:"fixture",tokenReference:nil))
        try database.saveRepository(.init(key:key,name:"o/r",isPrivate:true,capabilities:[.readPullRequests]))
        let credentials=MemoryCredentials();credentials.save(.init(accessToken:"offline-inventory"),account:account)
        let session=GitHubAccountSession(storage:AccountSessionStore(database:database,cache:try CacheStore(directory:directory,database:database),credentials:credentials),transport:transport)
        let service=RepositoryPRInventoryService(session:session,budget:RateBudget(minimumSpacing:.zero),database:database,clientID:"fixture")
        let task=Task { try await service.refresh(key) }
        await transport.waitUntilHolding()
        // The poller commits this repository's inventory checkpoint while the tab's read is in flight.
        let statusKey=ProviderKey(host:account.host,accountID:account.accountID,repositoryID:key.repositoryID,objectID:"pull-request-inventory")
        let polled=PollFeatureSnapshot(key:statusKey,feature:"github-pr-inventory",payload:try JSONEncoder.stable.encode(PRInventoryStatus(complete:false,fetchedCount:1,fetchedAt:Date(),message:"poller")))
        try await database.database.write { db in
            try db.execute(sql:"INSERT INTO pollFeatureSnapshots VALUES (?,?,?,?,?,?)",arguments:[statusKey.host,statusKey.accountID,statusKey.repositoryID,statusKey.objectID,polled.feature,try JSONEncoder.stable.encode(polled)])
        }
        await transport.release()
        let status=try await task.value
        XCTAssertTrue(status.complete)
        let stored=try await service.cachedStatus(key)
        XCTAssertEqual(stored?.message,"poller","the newer checkpoint is not overwritten by an older continuation")
        XCTAssertEqual(try database.pullRequests(repository:key).count,101,"provider rows are still stored")
    }
}
