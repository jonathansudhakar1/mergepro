import Foundation
import XCTest
@testable import MergeProCore

/// Counts credential reads (each one is a Keychain read in the app).
private final class CountingCredentials: GitHubCredentialStore, @unchecked Sendable {
    private let base = MemoryCredentials()
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func credential(for account: AccountScope) -> GitHubCredential? { lock.withLock { count += 1 }; return base.credential(for:account) }
    func save(_ credential: GitHubCredential, account: AccountScope) { base.save(credential,account:account) }
    func remove(account: AccountScope) { base.remove(account:account) }
}

/// Decoding and reading costs of the post-cycle refresh: activity history, PR rows and feature caches.
final class PollStoreDecodeTests: XCTestCase {
    let account = AccountScope(host:"github.com",accountID:"1")
    func store() throws -> (DatabaseStore,PollCycleStore) {
        let database = try DatabaseStore(path:":memory:")
        try database.saveAccount(Account(scope:account,login:"viewer",tokenReference:nil))
        try database.saveRepository(Repository(key:RepositoryKey(account:account,repositoryID:"1"),name:"o/r",isPrivate:false,capabilities:[]))
        return (database,PollCycleStore(database:database))
    }

    func testCycleCloseAndRepeatedInboxReadsDecodeOnlyNewOrPendingEvents() throws {
        let (_,store) = try store()
        // 500 delivered events of earlier cycles, then one cycle with 3 new ones.
        let old = UUID()
        try store.begin(old,at:Date(),baseline:true); try store.record((0..<500).map { pollEvent($0) },cycleID:old)
        _ = try store.close(old,at:Date(),policy:NotificationPolicy(enabled:true))
        XCTAssertEqual(store.eventDecodes,0,"A baseline close decodes nothing")
        let id = UUID()
        try store.begin(id,at:Date(),baseline:false); try store.record((500..<503).map { pollEvent($0) },cycleID:id)
        let summary = try store.close(id,at:Date(),policy:NotificationPolicy(enabled:true))
        XCTAssertEqual(summary.eventKeys.count,3)
        XCTAssertEqual(store.eventDecodes,3,"Close decodes only unsurfaced, unacknowledged events (was: all 503)")
        XCTAssertEqual(try store.inbox().count,503)
        XCTAssertEqual(store.eventDecodes,503)
        XCTAssertEqual(try store.inbox().count,503)
        XCTAssertEqual(store.eventDecodes,503,"A repeated inbox read decodes nothing new (was: 503 again)")
        try store.acknowledge([pollEvent(501).key])
        XCTAssertEqual(try store.inbox(eventKeys:[pollEvent(501).key]).first?.acknowledged,true,"Flags are always read fresh")
        XCTAssertEqual(store.eventDecodes,503)
        let page = try store.inbox(limit:2)
        XCTAssertEqual(page.map(\.id),[pollEvent(502).key,pollEvent(501).key],"Pages are newest recorded first")
        let next = try store.inbox(limit:2,offset:2)
        XCTAssertEqual(next.count,2); XCTAssertEqual(next.first?.id,pollEvent(500).key,"Then the rest of that cycle, before older cycles")
        XCTAssertEqual(try store.pendingInbox().map(\.id),[pollEvent(500).key,pollEvent(502).key].sorted())
    }

    func testPullRequestRowsDecodeOnlyRowsWhoseStoredBytesChanged() throws {
        let (database,store) = try store()
        let repo = RepositoryKey(account:account,repositoryID:"1")
        func pr(_ number: Int, state: PullRequest.State = .open, title: String = "Fixture", updated: TimeInterval = 0) -> PullRequest {
            var metadata = PRMetadata(number:number,webURL:URL(string:"https://github.com/o/r/pull/\(number)")!,repositoryName:"o/r")
            metadata.updatedAt = Date(timeIntervalSinceNow:updated)
            return PullRequest(key:ProviderKey(host:"github.com",accountID:"1",repositoryID:"1",objectID:"pull-request:\(number)"),headRevision:RevisionID("sha"),title:title,state:state,isDraft:false,metadata:metadata)
        }
        try database.savePullRequests((1...300).map { pr($0,state:$0 <= 20 ? .open : .merged,updated:$0 <= 40 ? -60 : -86_400 * 90) })
        let first = try store.pullRequestRows(repositories:[repo])
        XCTAssertEqual(first.keys.count,300); XCTAssertEqual(first.decoded.count,300)
        let again = try store.pullRequestRows(repositories:[repo],known:first.fingerprints)
        XCTAssertEqual(again.keys,first.keys); XCTAssertTrue(again.decoded.isEmpty,"Unchanged rows are not decoded again")
        try database.savePullRequests([pr(7,title:"Changed")])
        let changed = try store.pullRequestRows(repositories:[repo],known:again.fingerprints)
        XCTAssertEqual(changed.decoded.keys.map(\.objectID),["pull-request:7"]); XCTAssertEqual(changed.decoded.values.first?.title,"Changed")
        // A launch's first pass: open PRs plus recently updated history only.
        let recent = try store.pullRequestRows(repositories:[repo],openOrUpdatedSince:Date(timeIntervalSinceNow:-86_400 * 30))
        XCTAssertEqual(recent.keys.count,40)
    }

    func testPaletteRebuildsOnlyAfterItsSourcesChange() async throws {
        let (database,_) = try store()
        try database.setApplicationSetting(AccountSessionStore.tokenReference(for:account),for:"activeActionAccount")
        let directory = try makeTemporaryDirectory()
        let credentials = MemoryCredentials(); credentials.save(GitHubCredential(accessToken:"fixture"),account:account)
        let session = GitHubAccountSession(storage:AccountSessionStore(database:database,cache:try CacheStore(directory:directory,database:database),credentials:credentials),transport:ScriptedTransport([]))
        let service = RepositoryBrowserService(session:session,budget:RateBudget(minimumSpacing:.zero),database:database,clientID:"fixture",activeAccount:{ nil })
        let ticket = try await session.authenticatedOperation(for:account,clientID:"fixture")
        try await service.cache([RepositoryBranch(name:"main",sha:"a",protected:false)],key:"branches|1",ticket:ticket)
        let first = try await service.paletteEntries()
        XCTAssertEqual(first.map(\.kind),["repository","branch"])
        for _ in 0..<3 { let same = try await service.paletteEntries(); XCTAssertEqual(same,first) }
        let decodes = await service.paletteDecodes
        XCTAssertEqual(decodes,1,"Unchanged caches are not decoded again (was: once per call)")
        // Unrelated cache writes (tree pages, blobs) do not invalidate the palette; a branch refresh does.
        try await service.cache(Data("blob".utf8),key:"blob|1|sha|sha",ticket:ticket)
        _ = try await service.paletteEntries()
        let unrelated = await service.paletteDecodes
        XCTAssertEqual(unrelated,1)
        try await service.cache([RepositoryBranch(name:"main",sha:"a",protected:false),RepositoryBranch(name:"next",sha:"b",protected:false)],key:"branches|1",ticket:ticket)
        let updated = try await service.paletteEntries()
        XCTAssertEqual(updated.filter { $0.kind == "branch" }.count,2)
        let rebuilt = await service.paletteDecodes
        XCTAssertEqual(rebuilt,2)
    }

    func testCachedCatalogsReadCredentialsOncePerAccountAndOnlyEachRepositorysRuns() async throws {
        let (database,_) = try store()
        let keys = (1...10).map { RepositoryKey(account:account,repositoryID:String($0)) }
        for key in keys { try database.saveRepository(Repository(key:key,name:"o/r\(key.repositoryID)",isPrivate:false,capabilities:[])) }
        let directory = try makeTemporaryDirectory()
        let credentials = CountingCredentials(); credentials.save(GitHubCredential(accessToken:"fixture"),account:account)
        let session = GitHubAccountSession(storage:AccountSessionStore(database:database,cache:try CacheStore(directory:directory,database:database),credentials:credentials),transport:ScriptedTransport([]))
        // One polled run per repository.
        let store = PollCycleStore(database:database), id = UUID()
        try store.begin(id,at:Date(),baseline:true)
        let runs = try keys.map { key in
            let run = WorkflowRun(repository:try XCTUnwrap(database.repository(key)),runID:Int64(key.repositoryID)!,workflowID:3,attempt:1,name:"CI",branch:"main",headSHA:"sha",event:"push",actor:"dev",status:"completed",conclusion:"success",createdAt:Date(),updatedAt:Date())
            return PollFeatureSnapshot(key:run.key,feature:"github-actions",payload:try JSONEncoder.stable.encode(run))
        }
        let context = PollFetchContext(cycleID:id,account:account,repositories:Set(keys),featureID:"github-actions",cachedPullRequests:[],cachedSnapshots:[],repositoryMetadata:[:],
            deadline:.now.advanced(by:.seconds(10)),operation:nil,client:nil,budget:RateBudget(),baselinedRepositories:[],suppressNotifications:true,cachedResponses:[:])
        try store.apply(PollFetchResult(snapshots:runs),context:context,deadline:context.deadline,requireTracked:false)
        let service = ActionsService(session:session,budget:RateBudget(minimumSpacing:.zero),database:database,clientID:"fixture",activeAccount:{ nil })
        let before = credentials.reads
        _ = try await service.cachedCatalog(repository:keys[0])
        let single = credentials.reads - before
        let start = credentials.reads
        let catalogs = await service.cachedCatalogs(repositories:keys)
        let batched = credentials.reads - start
        XCTAssertEqual(Set(catalogs.keys),Set(keys))
        XCTAssertTrue(catalogs.allSatisfy { $0.value.runs.map(\.repository.key) == [$0.key] },"Each catalog holds only its repository's runs")
        XCTAssertLessThanOrEqual(batched,single,"Ten repositories cost one repository's credential reads (was: ten times as many)")
    }
}
