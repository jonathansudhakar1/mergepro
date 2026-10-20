import Foundation
import XCTest
import GRDB
@testable import MergeProCore

/// Realistic account volume: 5k PRs per account, mostly merged/closed history that is never pruned.
final class StorageVolumeTests: XCTestCase {
    static let perAccount=5_000, repos=50
    let accounts=[AccountScope(host:"github.com",accountID:"1"),AccountScope(host:"github.com",accountID:"2")]
    func key(_ account:AccountScope,repo:Int,number:Int) -> ProviderKey { ProviderKey(host:account.host,accountID:account.accountID,repositoryID:"repo-\(repo)",objectID:"pull-request:\(repo)-\(number)") }
    func pullRequest(_ account:AccountScope,index:Int) -> PullRequest {
        let repo=index % Self.repos,number=index / Self.repos,key=key(account,repo:repo,number:number)
        let state:PullRequest.State=index % 5 == 0 ? .open : index % 5 == 1 ? .closed : .merged
        var m=PRMetadata(number:number,webURL:URL(string:"https://github.com/org/repo-\(repo)/pull/\(number)")!,repositoryName:"org/repo-\(repo)")
        m.descriptionPreview=String(repeating:"Describe the change and its rollout plan. ",count:5)
        m.authorID="author-\(index % 37)";m.authorLogin="author-\(index % 37)";m.viewerID=account.accountID
        m.headBranch="feature/\(index)";m.baseBranch="main";m.baseRevision=String(repeating:"b",count:40)
        m.createdAt=Date(timeIntervalSince1970:1_700_000_000+Double(index));m.updatedAt=Date(timeIntervalSince1970:1_700_100_000+Double(index))
        m.mergedAt=state == .merged ? m.updatedAt : nil;m.reviewDecision="APPROVED";m.labels=["area/\(repo)","size/m"];m.labelColors=["area/\(repo)":"ff00aa","size/m":"00ff00"]
        m.requests=[PRReviewRequest(id:"team-\(repo)",name:"org/team",kind:.team,isForViewer:index % 7 == 0,viewerStatus:.needsReview)]
        m.assignees=["author-\(index % 37)"];m.reviewers=["reviewer-\(index % 11)"];m.checks="success";m.additions=index % 400;m.deletions=index % 90;m.files=index % 30;m.comments=index % 12
        m.reviewEvidenceComplete=true
        if state == .open {
            var e=MergeEvidence(key:key,head:String(repeating:"a",count:40),base:String(repeating:"b",count:40),branch:"main",fetchedAt:Date(timeIntervalSince1970:1_700_200_000))
            e.open=true;e.draft=false;e.conflictFree=true;e.actorAllowed=true;e.tokenCanWrite=true;e.rulesComplete=true;e.methods=[.squash,.merge];m.mergeEvidence=e
        }
        return PullRequest(key:key,headRevision:RevisionID("head-\(index)"),title:"Change number \(index) touching repo \(repo)",state:state,isDraft:false,metadata:m)
    }
    struct Fixture { let directory:URL;let database:DatabaseStore;let cache:CacheStore;let session:AccountSessionStore;let target:PullRequest }
    func seededFixture() async throws -> Fixture {
        let directory=try makeTemporaryDirectory()
        let database=try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        let credentials=MemoryCredentials()
        for account in accounts {
            try database.saveAccount(Account(scope:account,login:"login-\(account.accountID)",tokenReference:AccountSessionStore.tokenReference(for:account)))
            credentials.save(GitHubCredential(accessToken:"token-\(account.accountID)",scopes:["repo"]),account:account)
            for repo in 0..<Self.repos {
                try database.saveRepository(Repository(key:RepositoryKey(account:account,repositoryID:"repo-\(repo)"),name:"org/repo-\(repo)",isPrivate:true,capabilities:[.readPullRequests]))
                if repo % 2 == 0 { try database.setTracked(RepositoryKey(account:account,repositoryID:"repo-\(repo)"),tracked:true) }
            }
            try database.savePullRequests((0..<Self.perAccount).map { pullRequest(account,index:$0) })
            try database.setSetting("1",for:"discoveryRetryAt",account:account)
            try database.setSetting("false",for:"authorizationProblem",account:account)
        }
        // A long-lived ledger: completed operations are retained evidence and are never active.
        try await database.database.write { db in
            for index in 0..<2_000 {
                try db.execute(sql:"INSERT INTO reviewOperations VALUES (?,?,?)",arguments:[UUID().uuidString,"identity-\(index % 50)",Data("{\"state\":\"confirmed\",\"padding\":\"\(String(repeating:"x",count:400))\"}".utf8)])
            }
        }
        let cache=try CacheStore(directory:directory.appendingPathComponent("cache"),database:database)
        let session=AccountSessionStore(database:database,cache:cache,credentials:credentials)
        return Fixture(directory:directory,database:database,cache:cache,session:session,target:pullRequest(accounts[0],index:2_500))
    }
    /// Median wall time in milliseconds; the first call warms SQLite's page cache.
    func median(_ runs:Int=9,_ body:() async throws -> Void) async rethrows -> Double {
        try await body()
        var samples:[Double]=[]
        for _ in 0..<runs { let start=ContinuousClock.now;try await body();let elapsed=ContinuousClock.now-start;samples.append(Double(elapsed.components.attoseconds)/1e15+Double(elapsed.components.seconds)*1000) }
        return samples.sorted()[runs/2]
    }
    func report(_ name:String,_ ms:Double) { print("[StorageVolume] \(name): \(String(format:"%.3f",ms)) ms") }

    /// Relative checks against the whole-account reads these lookups replace, measured on the same data; the
    /// absolute caps need MERGEPRO_PERF_TESTS=1.
    func testTargetedLookupsStayFastAndBeatWholeAccountReadsAtVolume() async throws {
        let f=try await seededFixture(),account=accounts[0],target=f.target,polls=PollCycleStore(database:f.database)
        let ticket=try await f.session.operation(for:account,now:Date())
        let payload=PayloadKey(object:target.key,revision:target.headRevision,kind:.blob)
        try await f.session.detailPayload(Data("blob".utf8),key:payload,pr:target.key,headSHA:target.headRevision.rawValue,operation:ticket)
        let timings:[(String,Double)]=[
            ("AccountSessionStore.operation()",try await median { _=try await f.session.operation(for:account,now:Date()) }),
            ("AccountSessionStore.detailPayload() lookup",try await median { _=try await f.session.detailPayload(nil,key:payload,pr:target.key,headSHA:target.headRevision.rawValue,operation:ticket) }),
            ("AccountSessionStore.authorizationState()",try await median { _=try await f.session.authorizationState(for:account) }),
            ("DatabaseStore.setting(_:account:)",try await median { _=try f.database.setting("authorizationProblem",account:account) }),
            ("DatabaseStore.pullRequest(for:)",try await median { _=try f.database.pullRequest(for:target.key) }),
            ("DatabaseStore.pullRequestExists(_:headSHA:)",try await median { _=try f.database.pullRequestExists(target.key,headSHA:target.headRevision.rawValue) }),
            ("DatabaseStore.reviewOperation(id:)",try await median { _=try f.database.reviewOperation(id:UUID()) }),
            ("DatabaseStore.trackedRepositories(account:)",try await median { _=try f.database.trackedRepositories(account:account) }),
            ("DatabaseStore.repositories(account:)",try await median { _=try f.database.repositories(account:account) }),
        ]
        let snapshot=try await median(5) { _=try f.database.snapshot(for:account) }
        report("DatabaseStore.snapshot(for:) (whole account)",snapshot)
        for (name,ms) in timings {
            report(name,ms);XCTAssertWithinPerformanceBudget(milliseconds:ms,25,name)
            XCTAssertLessThan(ms*10,snapshot,"\(name) is at least 10x faster than a whole-account snapshot")
        }
        XCTAssertEqual(try f.database.pullRequest(for:target.key),try f.database.snapshot(for:account).pullRequests.first { $0.key == target.key })
        // Scoped reads are proportional to the scope, not the account's history.
        let repo=target.key.repository
        let scoped=try await median(5) { _=try polls.pullRequests(repositories:[repo]) },whole=try await median(5) { _=try polls.pullRequests(account:account) }
        report("PollCycleStore.pullRequests(repositories:) one repo",scoped)
        report("PollCycleStore.pullRequests(account:)",whole)
        XCTAssertLessThan(scoped*4,whole,"One repository of fifty reads far less than the account")
        report("DatabaseStore.pullRequests(repository:states:[.merged])",try await median(5) { _=try f.database.pullRequests(repository:repo,states:[.merged]) })
        report("DatabaseStore.pullRequests(account:states:[.open])",try await median(5) { _=try f.database.pullRequests(account:account,states:[.open]) })
        report("DatabaseStore.pullRequests(account:states:[.merged],limit:50)",try await median(5) { _=try f.database.pullRequests(account:account,states:[.merged],limit:50) })
        XCTAssertEqual(try polls.pullRequests(repositories:[repo]).count,Self.perAccount/Self.repos)
        XCTAssertEqual(try f.database.pullRequests(account:account,states:[.open]).count,Self.perAccount/5)
    }

    /// Existing installs migrate once; creating the lookup indexes derives values from stored JSON.
    func testV8MigrationCostAtVolume() async throws {
        let directory=try makeTemporaryDirectory()
        let path=directory.appendingPathComponent("db.sqlite").path
        let queue=try DatabaseQueue(path:path)
        try Migrations.migrator().migrate(queue,upTo:"v7-actions-repository-browser")
        let encoder=JSONEncoder(),accounts=accounts
        let repositories=try accounts.flatMap { account in try (0..<Self.repos).map { [account.host,account.accountID,"repo-\($0)"].databaseValue(json:try encoder.encode(Repository(key:RepositoryKey(account:account,repositoryID:"repo-\($0)"),name:"org/repo-\($0)",isPrivate:true,capabilities:[]))) } }
        let rows=try accounts.flatMap { account in try (0..<Self.perAccount).map { let pr=pullRequest(account,index:$0);return [pr.key.host,pr.key.accountID,pr.key.repositoryID,pr.key.objectID].databaseValue(json:try encoder.encode(pr)) } }
        try await queue.write { db in
            for account in accounts { try db.execute(sql:"INSERT INTO accounts VALUES (?,?,'login',NULL)",arguments:[account.host,account.accountID]) }
            for row in repositories { try db.execute(sql:"INSERT INTO repositories VALUES (?,?,?,?)",arguments:StatementArguments(row)) }
            for row in rows { try db.execute(sql:"INSERT INTO pullRequests VALUES (?,?,?,?,?)",arguments:StatementArguments(row)) }
        }
        try queue.close()
        let start=ContinuousClock.now
        let store=try DatabaseStore(path:path)
        let elapsed=ContinuousClock.now-start
        report("v7 -> v8 migration (2 x \(Self.perAccount) PRs)",Double(elapsed.components.attoseconds)/1e15+Double(elapsed.components.seconds)*1000)
        XCTAssertEqual(try store.pullRequests(account:accounts[1],states:[.open]).count,Self.perAccount/5)
        XCTAssertEqual(try store.pullRequest(for:pullRequest(accounts[0],index:7).key),pullRequest(accounts[0],index:7))
    }

    func testWholeAccountReadTimingsReport() async throws {
        let f=try await seededFixture(),account=accounts[0],target=f.target
        report("fetchSnapshot (whole account)",try await median(5) { _=try f.database.snapshot(for:account) })
        // Time the shared database is held for a whole-account read; decoding now happens after release.
        report("whole-account PR rows, database hold only",try await median(5) { _=try f.database.database.read { try Data.fetchAll($0,sql:"SELECT json FROM pullRequests WHERE host=? AND accountID=? ORDER BY repositoryID, objectID",arguments:[account.host,account.accountID]) } })
        report("setting via snapshot",try await median(5) { _=try f.database.snapshot(for:account).settings["authorizationProblem"] })
        report("AccountSessionStore.operation()",try await median(5) { _=try await f.session.operation(for:account,now:Date()) })
        let ticket=try await f.session.operation(for:account,now:Date())
        let payload=PayloadKey(object:target.key,revision:target.headRevision,kind:.blob)
        try await f.session.detailPayload(Data("blob".utf8),key:payload,pr:target.key,headSHA:target.headRevision.rawValue,operation:ticket)
        report("AccountSessionStore.detailPayload() lookup",try await median(5) { _=try await f.session.detailPayload(nil,key:payload,pr:target.key,headSHA:target.headRevision.rawValue,operation:ticket) })
        report("single PR via snapshot",try await median(5) { _=try f.database.snapshot(for:account).pullRequests.first { $0.key == target.key } })
        report("PollCycleStore.pullRequests(account:)",try await median(5) { _=try PollCycleStore(database:f.database).pullRequests(account:account) })
        report("PollCycleStore.repositoryMetadata(account:)",try await median(5) { _=try PollCycleStore(database:f.database).repositoryMetadata(account:account) })
        report("AccountSessionStore.snapshot(for:)",try await median(5) { _=try await f.session.snapshot(for:account) })
    }
}
private extension Array where Element == String {
    func databaseValue(json:Data) -> [DatabaseValue] { map(\.databaseValue)+[json.databaseValue] }
}
