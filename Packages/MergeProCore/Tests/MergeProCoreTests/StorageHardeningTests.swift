import Foundation
import XCTest
import GRDB
@testable import MergeProCore

private final class CountingCredentials: GitHubCredentialStore, @unchecked Sendable {
    let base = MemoryCredentials()
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func credential(for account: AccountScope) -> GitHubCredential? { lock.withLock { count += 1 }; return base.credential(for:account) }
    func save(_ credential: GitHubCredential, account: AccountScope) { base.save(credential,account:account) }
    func remove(account: AccountScope) { base.remove(account:account) }
}
private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    func set(_ value: Int) { lock.withLock { stored = value } }
    var value: Int? { lock.withLock { stored } }
}
private final class TracedStatements: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

/// Account purge, revocation purge, lost access, retention, frozen schema and storage performance.
final class StorageHardeningTests: XCTestCase {
    private let account = AccountScope(host:"github.com",accountID:"42")
    private let other = AccountScope(host:"github.com",accountID:"55")
    private let revision = PRWriteRevision(head:"h",origin:"o",target:"t")
    private func repository(_ scope: AccountScope, _ id: String) -> Repository {
        Repository(key:RepositoryKey(account:scope,repositoryID:id),name:"org/r\(id)",isPrivate:true,capabilities:[.readPullRequests])
    }
    private func key(_ scope: AccountScope, repo: String, object: String = "pull-request:1") -> ProviderKey {
        ProviderKey(host:scope.host,accountID:scope.accountID,repositoryID:repo,objectID:object)
    }
    private func pullRequest(_ scope: AccountScope, repo: String) -> PullRequest {
        PullRequest(key:key(scope,repo:repo),headRevision:RevisionID("sha"),title:"Private fixture title",state:.open,isDraft:false)
    }
    private func seed(_ store: DatabaseStore, _ scope: AccountScope, repos: [String], tracked: Set<String>? = nil) throws {
        try store.saveAccount(Account(scope:scope,login:"login-\(scope.accountID)",tokenReference:AccountSessionStore.tokenReference(for:scope)))
        for id in repos {
            try store.saveRepository(repository(scope,id))
            if tracked?.contains(id) ?? true { try store.setTracked(RepositoryKey(account:scope,repositoryID:id),tracked:true) }
            try store.savePullRequests([pullRequest(scope,repo:id)])
        }
    }
    private func event(_ scope: AccountScope, repo: String, key: String, occurredAt: Date = Date(), object: String = "pull-request:1") -> ChangeEvent {
        ChangeEvent(key:key,object:self.key(scope,repo:repo,object:object),category:"fixture",occurredAt:occurredAt,title:"Private event title")
    }
    @discardableResult private func record(_ store: DatabaseStore, _ events: [ChangeEvent], at date: Date = Date(), failure: Bool = false) throws -> UUID {
        let cycles = PollCycleStore(database:store), id = UUID()
        try cycles.begin(id,at:date,baseline:false)
        try cycles.record(events,cycleID:id)
        if failure { try cycles.failure(id,workID:"work",message:"fixture failure") }
        try cycles.interrupt(id,at:date)
        return id
    }
    /// Inbox rows read directly, independent of the inbox query API.
    private func eventKeys(_ store: DatabaseStore) throws -> Set<String> {
        Set(try store.database.read { try String.fetchAll($0,sql:"SELECT eventKey FROM changeEvents") })
    }
    private func count(_ store: DatabaseStore, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try store.database.read { try Int.fetchOne($0,sql:sql,arguments:arguments) ?? 0 }
    }
    private func count(_ store: DatabaseStore, table: String, _ scope: AccountScope) throws -> Int {
        try count(store,"SELECT COUNT(*) FROM \(table) WHERE host=? AND accountID=?",[scope.host,scope.accountID])
    }
    /// The synchronous overload, so async tests can write fixture rows without Sendable captures.
    private func write(_ store: DatabaseStore, _ body: (Database) throws -> Void) throws { try store.database.write(body) }
    private func backdate(_ store: DatabaseStore, operation id: UUID, to date: Date) throws {
        try store.database.write { db in
            let json = try XCTUnwrap(try Data.fetchOne(db,sql:"SELECT json FROM reviewOperations WHERE id=?",arguments:[id.uuidString]))
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with:json) as? [String:Any])
            object["createdAt"] = date.timeIntervalSinceReferenceDate
            try db.execute(sql:"UPDATE reviewOperations SET json=? WHERE id=?",arguments:[try JSONSerialization.data(withJSONObject:object),id.uuidString])
        }
    }

    // MARK: Account removal (write ledger)

    func testRemovingAccountPurgesItsWriteLedgerFencesAndReadingProgressInOneStep() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        try seed(store,account,repos:["1"]); try seed(store,other,repos:["1"])
        let cache = try CacheStore(directory:directory.appendingPathComponent("cache"),database:store,reconcileInBackground:false)
        let ledger = DraftReviewStore(database:store)
        for (index,scope) in [account,other].enumerated() {
            let pr = pullRequest(scope,repo:"1")
            try ledger.prepare(PRWriteOperation(command:PRWriteCommand(key:pr.key,repository:"org/r1",number:1,revision:revision,intent:.conversation("sent private body"))))
            try store.confirmWrite(pr)
            let thread = event(scope,repo:"1",key:"thread-\(index)",object:"notification-thread:\(index + 7)")
            try record(store,[thread])
            try store.prepareNotificationThread(NotificationThreadOperation(command:try NotificationThreadCommand(event:thread,intent:.read)))
            try PRDetailStore(database:store).save(PRDetailState(headSHA:"sha"),key:pr.key)
        }
        try await cache.removeAccount(account) { _ in }
        XCTAssertTrue(try ledger.operations(pullRequest(account,repo:"1").key).isEmpty,"sent bodies of a removed account must not stay on disk")
        XCTAssertEqual(try ledger.operations(pullRequest(other,repo:"1").key).count,1)
        XCTAssertEqual(try count(store,"SELECT COUNT(*) FROM reviewOperations"),1)
        XCTAssertTrue(try store.notificationThreadOperations(account:account).isEmpty)
        XCTAssertEqual(try store.notificationThreadOperations(account:other).count,1)
        XCTAssertTrue(try store.observationFences(account:account).isEmpty)
        XCTAssertEqual(try store.observationFences(account:other).count,1)
        XCTAssertEqual(try count(store,"SELECT COUNT(*) FROM applicationSettings WHERE name LIKE 'pr-detail-viewed:%'"),1)
    }

    // MARK: Notification summaries

    private func summaryBlob(_ store: DatabaseStore, _ sql: String, _ id: UUID) throws -> Data? {
        try store.database.read { try Data.fetchOne($0,sql:sql,arguments:[id.uuidString]) }
    }

    /// Closed cycles and notification attempts store per-subject items (PR titles, web URLs, repository names).
    /// Both purges remove the purged account's items and event keys and keep other accounts' items.
    func testPurgesScrubTheAccountFromStoredNotificationSummaries() async throws {
        for removal in [true, false] {
            let directory = try makeTemporaryDirectory()
            let store = try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
            try seed(store,account,repos:["1"]); try seed(store,other,repos:["1"])
            let cache = try CacheStore(directory:directory.appendingPathComponent("cache"),database:store,reconcileInBackground:false)
            let credentials = MemoryCredentials()
            for scope in [account,other] { credentials.save(GitHubCredential(accessToken:"fixture-\(scope.accountID)",scopes:["repo"]),account:scope) }
            func titled(_ scope: AccountScope, _ title: String) -> ChangeEvent {
                ChangeEvent(key:"event-\(scope.accountID)",object:key(scope,repo:"1"),category:"checks",occurredAt:Date(),title:title,
                            locator:EventLocator(subjectType:"PullRequest",subjectNumber:"1",webURL:URL(string:"https://github.com/secret-org-\(scope.accountID)/repo/pull/1")))
            }
            let cycles = PollCycleStore(database:store), id = UUID()
            try cycles.begin(id,at:Date(),baseline:false)
            try cycles.record([titled(account,"Purged private title"),titled(other,"Kept title")],cycleID:id)
            let summary = try cycles.close(id,at:Date(),policy:NotificationPolicy(enabled:true))
            XCTAssertEqual(summary.items.count,2)
            let reserved = try await cycles.reserve(summary)
            XCTAssertTrue(reserved)
            if removal { try await cache.removeAccount(account) { _ in } }
            else {
                let session = AccountSessionStore(database:store,cache:cache,credentials:credentials)
                let ticket = try await session.operation(for:account,now:Date())
                let invalidated = try await session.markInvalid(ticket)
                XCTAssertTrue(invalidated)
            }
            let stored = (try summaryBlob(store,"SELECT summary FROM pollCycles WHERE id=?",id),
                          try summaryBlob(store,"SELECT summary FROM notificationAttempts WHERE cycleID=?",id))
            for (name,data) in [("cycle",stored.0),("attempt",stored.1)] {
                let json = try XCTUnwrap(data,name)
                let text = String(decoding:json,as:UTF8.self)
                XCTAssertFalse(text.contains("Purged private title"),"\(name), removal \(removal)")
                XCTAssertFalse(text.contains("secret-org-42"),"\(name), removal \(removal)")
                XCTAssertFalse(text.contains("event-42"),"\(name), removal \(removal)")
                let decoded = try JSONDecoder().decode(PollSummary.self,from:json)
                XCTAssertEqual(decoded.items.map(\.subjectTitle),["Kept title"],"\(name): other accounts keep their items")
                XCTAssertEqual(decoded.eventKeys,["event-55"])
            }
            XCTAssertEqual(try cycles.attemptState(id),"reserved","the attempt record itself stays (a cycle is never notified twice)")
        }
    }

    // MARK: WAL scrubbing

    /// `secure_delete` zeroes freed pages in the database file but not the old frames the WAL still holds:
    /// after a purge or account removal the WAL is checkpointed and truncated, so no frame keeps the content.
    func testPurgesAndAccountRemovalLeaveNoPurgedContentInTheWAL() async throws {
        for removal in [true, false] {
            let directory = try makeTemporaryDirectory()
            let path = directory.appendingPathComponent("db.sqlite").path
            let store = try DatabaseStore(path:path)
            XCTAssertEqual(try count(store,"PRAGMA journal_size_limit"), DatabaseStore.journalSizeLimit)
            try seed(store,account,repos:["1"])
            let marker = "WAL-MARKER-\(UUID().uuidString)"
            try store.savePullRequests([PullRequest(key:key(account,repo:"1",object:"pull-request:9"),headRevision:RevisionID("sha"),title:marker,state:.open,isDraft:false)])
            func contains(_ file: String) throws -> Bool {
                guard FileManager.default.fileExists(atPath:file) else { return false }
                return try Data(contentsOf:URL(fileURLWithPath:file)).range(of:Data(marker.utf8)) != nil
            }
            XCTAssertTrue(try contains(path + "-wal") || contains(path), "fixture: the title reached disk")
            let cache = try CacheStore(directory:directory.appendingPathComponent("cache"),database:store,reconcileInBackground:false)
            if removal { try await cache.removeAccount(account) { _ in } } else { try await cache.purgePrivateContent(for:account) }
            XCTAssertFalse(try contains(path + "-wal"), "removal \(removal): the WAL keeps no purged frame")
            XCTAssertFalse(try contains(path), "removal \(removal): the database file keeps no purged row")
        }
    }

    // MARK: Ledger retention

    func testTerminalLedgerRetentionNeverPrunesUnresolvedOperations() throws {
        let store = try DatabaseStore(path:try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path)
        try seed(store,account,repos:["1"])
        let ledger = DraftReviewStore(database:store), now = Date()
        let old = now.addingTimeInterval(-40*86400), recent = now.addingTimeInterval(-5*86400)
        var expected: [UUID:Bool] = [:]
        let cases: [(PRWriteOperation.State,Date,Bool)] = [(.prepared,old,true),(.sending,old,true),(.uncertain,old,true),
            (.confirmed,old,false),(.rejected,old,false),(.postedOutdated,old,false),(.confirmed,recent,true)]
        for (index,(state,created,kept)) in cases.enumerated() {
            var operation = PRWriteOperation(command:PRWriteCommand(key:key(account,repo:"1",object:"pull-request:\(index)"),repository:"org/r1",number:index,revision:revision,intent:.conversation("body \(index)")))
            try ledger.prepare(operation)
            let steps: [PRWriteOperation.State:[PRWriteOperation.State]] = [.prepared:[],.sending:[.sending],.uncertain:[.sending,.uncertain],
                .confirmed:[.sending,.confirmed],.rejected:[.rejected],.postedOutdated:[.sending,.postedOutdated]]
            for step in steps[state]! {
                operation.state = step; try ledger.update(operation)
            }
            try backdate(store,operation:operation.id,to:created)
            expected[operation.id] = kept
        }
        var threads: [UUID:Bool] = [:]
        let threadCases: [(NotificationThreadOperation.State,Date,Bool)] = [(.uncertain,old,true),(.sending,old,true),(.confirmed,old,false),(.rejected,old,false),(.confirmed,recent,true)]
        let events = threadCases.indices.map { event(account,repo:"1",key:"thread-event-\($0)",object:"notification-thread:\($0 + 1)") }
        try record(store,events)
        for (index,(state,closed,kept)) in threadCases.enumerated() {
            var operation = NotificationThreadOperation(command:try NotificationThreadCommand(event:events[index],intent:.read))
            try store.prepareNotificationThread(operation)
            if state == .rejected { operation.state = .rejected; try store.updateNotificationThread(operation,expected:.prepared) }
            else {
                operation.state = .sending; try store.updateNotificationThread(operation,expected:.prepared)
                if state != .sending { operation.state = state; try store.updateNotificationThread(operation,expected:.sending) }
            }
            try store.database.write { try $0.execute(sql:"UPDATE notificationThreadOperations SET closedAt=? WHERE id=? AND closedAt IS NOT NULL",arguments:[closed.timeIntervalSince1970,operation.id.uuidString]) }
            threads[operation.id] = kept
        }
        XCTAssertEqual(try eventKeys(store).count,events.count)
        try store.runStorageMaintenance(now:now)
        for (id,kept) in expected { XCTAssertEqual(try ledger.operation(id) != nil,kept) }
        let remaining = Set(try store.notificationThreadOperations().map(\.id))
        for (id,kept) in threads { XCTAssertEqual(remaining.contains(id),kept) }
    }

    func testPruningAdoptsAProviderReceiptBeforeDeletingItsOperation() throws {
        let store = try DatabaseStore(path:try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path)
        try seed(store,account,repos:["1"])
        let ledger = DraftReviewStore(database:store), pr = key(account,repo:"1")
        try ledger.save(ReviewDraft(key:pr,revision:revision))
        var operation = PRWriteOperation(command:PRWriteCommand(key:pr,repository:"org/r1",number:1,revision:revision,intent:.createPending("summary")))
        try ledger.prepare(operation)
        operation.state = .sending; try ledger.update(operation)
        // A legacy receipt committed without adoption: only the ledger row knows the pending review exists.
        try store.database.write { db in
            let json = try XCTUnwrap(try Data.fetchOne(db,sql:"SELECT json FROM reviewOperations WHERE id=?",arguments:[operation.id.uuidString]))
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with:json) as? [String:Any])
            object["state"] = "confirmed"; object["providerIDs"] = ["PRR_fixture"]
            object["createdAt"] = Date().addingTimeInterval(-60*86400).timeIntervalSinceReferenceDate
            try db.execute(sql:"UPDATE reviewOperations SET json=? WHERE id=?",arguments:[try JSONSerialization.data(withJSONObject:object),operation.id.uuidString])
        }
        try store.runStorageMaintenance(now:Date())
        XCTAssertNil(try ledger.operation(operation.id))
        XCTAssertEqual(try ledger.load(pr)?.pendingReviewID,"PRR_fixture","a pruned receipt must never make a sent review look unsent")
    }

    // MARK: Revoked credential

    func testInvalidCredentialPurgesPrivateContentButKeepsUnresolvedLedgerDraftsAndSelection() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        try seed(store,account,repos:["1","2"],tracked:["1"]); try seed(store,other,repos:["1"])
        try store.setRepositoryScope(.selectedRepositories,owner:"org",account:account)
        let cache = try CacheStore(directory:directory.appendingPathComponent("cache"),database:store,reconcileInBackground:false)
        let credentials = MemoryCredentials()
        for scope in [account,other] { credentials.save(GitHubCredential(accessToken:"fixture-\(scope.accountID)",scopes:["repo"]),account:scope) }
        let session = AccountSessionStore(database:store,cache:cache,credentials:credentials)
        try record(store,[event(account,repo:"1",key:"private-a"),event(other,repo:"1",key:"private-o")])
        try write(store) { db in
            for scope in [account,other] {
                try db.execute(sql:"INSERT INTO pollResponses(host,accountID,url,etag,lastModified,body,nextURL,feature) VALUES (?,?,?,?,?,?,?,?)",
                               arguments:[scope.host,scope.accountID,"https://api.github.com/repos/org/r1/notifications?all=true","\"fixture-etag\"",nil,Data("private feed body".utf8),nil,PollCycleStore.notificationFeedFeature])
                try db.execute(sql:"INSERT INTO pollBaselines VALUES (?,?,?,?)",arguments:[scope.host,scope.accountID,"1",PollCycleStore.notificationFeedFeature])
            }
        }
        let payload = PayloadKey(object:key(account,repo:"1"),revision:RevisionID("sha"),kind:.diff)
        try await cache.put(Data("private diff".utf8),for:payload)
        let otherPayload = PayloadKey(object:key(other,repo:"1"),revision:RevisionID("sha"),kind:.diff)
        try await cache.put(Data("other diff".utf8),for:otherPayload)
        let ledger = DraftReviewStore(database:store)
        let pending = PRWriteOperation(command:PRWriteCommand(key:key(account,repo:"1"),repository:"org/r1",number:1,revision:revision,intent:.conversation("unsent")))
        try ledger.prepare(pending)
        try store.saveDraft(Draft(key:key(account,repo:"1"),revision:RevisionID("sha"),body:"unsent draft"))
        PRDetailMemoryCache.shared.update(.init(pr:key(account,repo:"1"),head:"sha"),epoch:"fixture") { _ in }
        XCTAssertEqual(PRDetailMemoryCache.shared.count(account:account),1)

        let ticket = try await session.operation(for:account,now:Date())
        let invalidated = try await session.markInvalid(ticket)
        XCTAssertTrue(invalidated)

        for table in ["changeEvents","pollResponses","pollBaselines","pullRequests","repositories","cacheEntries"] {
            XCTAssertEqual(try count(store,table:table,account),0,table)
        }
        for table in ["changeEvents","pollResponses","pollBaselines","pullRequests","repositories","cacheEntries"] {
            XCTAssertEqual(try count(store,table:table,other),1,"another account keeps \(table)")
        }
        let removed = try await cache.data(for:payload); XCTAssertNil(removed)
        let retained = try await cache.data(for:otherPayload); XCTAssertEqual(retained,Data("other diff".utf8))
        XCTAssertEqual(PRDetailMemoryCache.shared.count(account:account),0)
        XCTAssertEqual(try ledger.operation(pending.id)?.state,.prepared,"unresolved writes are kept so they are never resent")
        XCTAssertEqual(try store.snapshot(for:account).drafts.count,1)
        XCTAssertEqual(try store.setting("authorizationProblem",account:account),"true")

        // Reconnecting restores the explicit selection when discovery finds the repositories again.
        let result = GitHubDiscoveryResult(repositories:[repository(account,"1"),repository(account,"2")],organizations:[],teams:[],issues:[],isComplete:true,retryAt:nil)
        try store.commitRepositoryDiscovery(result,account:account)
        XCTAssertEqual(try store.trackedRepositories(account:account),[RepositoryKey(account:account,repositoryID:"1")])
        XCTAssertTrue(try PollCycleStore(database:store).baselines(account:account,feature:PollCycleStore.notificationFeedFeature).isEmpty,"the first poll re-baselines instead of notifying")
    }

    // MARK: Lost repository access

    private func discoveryFixture() async throws -> (DatabaseStore,CacheStore,AccountSessionStore,PayloadKey,PayloadKey) {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        try seed(store,account,repos:["1","2"])
        let cache = try CacheStore(directory:directory.appendingPathComponent("cache"),database:store,reconcileInBackground:false)
        let credentials = MemoryCredentials(); credentials.save(GitHubCredential(accessToken:"fixture",scopes:["repo"]),account:account)
        try record(store,[event(account,repo:"1",key:"kept-event"),event(account,repo:"2",key:"lost-event")])
        try write(store) { db in
            for repo in ["1","2"] {
                let snapshot = PollFeatureSnapshot(key:key(account,repo:repo),feature:"fixture-feature",payload:Data("private".utf8))
                try db.execute(sql:"INSERT INTO pollFeatureSnapshots VALUES (?,?,?,?,?,?)",arguments:[account.host,account.accountID,repo,"pull-request:1","fixture-feature",try JSONEncoder.stable.encode(snapshot)])
                try db.execute(sql:"INSERT INTO actions_catalog VALUES (?,?,?,?)",arguments:[account.host,account.accountID,repo,Data("{}".utf8)])
                try db.execute(sql:"INSERT INTO repo_browser_cache VALUES (?,?,?,?,?)",arguments:[account.host,account.accountID,"branches|"+repo,Data("[]".utf8),0])
                try db.execute(sql:"INSERT INTO repo_browser_cache VALUES (?,?,?,?,?)",arguments:[account.host,account.accountID,"tree|\(repo)|sha|tree",Data("[]".utf8),0])
                try db.execute(sql:"INSERT INTO pollResponses(host,accountID,url,etag,lastModified,body,nextURL,feature) VALUES (?,?,?,?,?,?,?,?)",
                               arguments:[account.host,account.accountID,"https://api.github.com/repos/org/r\(repo)/notifications?all=true","\"etag\"",nil,Data("private".utf8),nil,PollCycleStore.notificationFeedFeature])
            }
        }
        let kept = PayloadKey(object:key(account,repo:"1"),revision:RevisionID("sha"),kind:.diff)
        let lost = PayloadKey(object:key(account,repo:"2"),revision:RevisionID("sha"),kind:.diff)
        try await cache.put(Data("kept".utf8),for:kept); try await cache.put(Data("lost".utf8),for:lost)
        return (store,cache,AccountSessionStore(database:store,cache:cache,credentials:credentials),kept,lost)
    }
    private func repositoryContent(_ store: DatabaseStore, _ repo: String) throws -> [Int] {
        let arguments: StatementArguments = [account.host,account.accountID,repo]
        return try ["pullRequests","changeEvents","pollFeatureSnapshots","actions_catalog"].map { try count(store,"SELECT COUNT(*) FROM \($0) WHERE host=? AND accountID=? AND repositoryID=?",arguments) }
            + [try count(store,"SELECT COUNT(*) FROM repo_browser_cache WHERE account_host=? AND account_id=? AND (cache_key=? OR cache_key LIKE ?)",[account.host,account.accountID,"branches|"+repo,"tree|\(repo)|%"]),
               try count(store,"SELECT COUNT(*) FROM pollResponses WHERE host=? AND accountID=? AND url LIKE ?",[account.host,account.accountID,"%/repos/org/r\(repo)/%"])]
    }

    func testCompleteDiscoveryPurgesOnlyTheRepositoryThatLostAccess() async throws {
        let (store,cache,storage,kept,lost) = try await discoveryFixture()
        let session = GitHubAccountSession(storage:storage,transport:ScriptedTransport([json("[\(repo(1))]"),json("[]"),json("[]")]),clock:FixtureClock())
        guard case .updated(let result) = await session.discover(account,clientID:"id"), result.isComplete else { return XCTFail("complete discovery expected") }
        XCTAssertEqual(try repositoryContent(store,"2"),[0,0,0,0,0,0])
        XCTAssertEqual(try repositoryContent(store,"1"),[1,1,1,1,2,1])
        let lostData = try await cache.data(for:lost); XCTAssertNil(lostData)
        let keptData = try await cache.data(for:kept); XCTAssertEqual(keptData,Data("kept".utf8))
        XCTAssertNotNil(try store.repository(RepositoryKey(account:account,repositoryID:"2")),"saved scope is never removed by a listing")
    }

    func testPartialFailedOrThrottledDiscoveryNeverPurgesMissingRepositories() async throws {
        let listings: [[GitHubResponse]] = [
            [json("{}",status:500),json("[]"),json("[]")],
            [json("{}",status:502)],
            [json("[\(repo(1))]",headers:["X-GitHub-SSO":"partial-results; organizations=9"]),json("[]"),json("[]")],
            [json("[\(repo(1))]",headers:["Link":"<https://api.github.com/user/repos?page=2>; rel=\"next\""]),json("{}",status:503),json("[]"),json("[]")],
            [json("{}",status:429,headers:["Retry-After":"60"])],
            [json("[\(repo(1))]"),json("{}",status:403,headers:["X-GitHub-SSO":"required; url=https://github.com/orgs/a/sso"]),json("[]")],
        ]
        for (index,responses) in listings.enumerated() {
            let (store,cache,storage,_,lost) = try await discoveryFixture()
            let session = GitHubAccountSession(storage:storage,transport:ScriptedTransport(responses),clock:FixtureClock())
            _ = await session.discover(account,clientID:"id")
            XCTAssertEqual(try repositoryContent(store,"2"),[1,1,1,1,2,1],"listing \(index)")
            let data = try await cache.data(for:lost); XCTAssertEqual(data,Data("lost".utf8),"listing \(index)")
        }
    }

    // MARK: Maintenance

    func testMigrationIndexesInboxLookups() throws {
        let store = try DatabaseStore(path:try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path)
        let indexes = Set(try store.database.read { try String.fetchAll($0,sql:"SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='changeEvents'") })
        XCTAssertTrue(indexes.isSuperset(of:["changeEvents_unacknowledged","changeEvents_unsurfaced","changeEvents_acknowledged_age","changeEvents_cycle"]))
        func plan(_ sql: String) throws -> String {
            try store.database.read { try Row.fetchAll($0,sql:"EXPLAIN QUERY PLAN "+sql).map { $0["detail"] as String }.joined(separator:"\n") }
        }
        XCTAssertTrue(try plan("SELECT json FROM changeEvents WHERE acknowledged=0 AND surfaced=0 ORDER BY eventKey").contains("changeEvents_unsurfaced"))
        XCTAssertTrue(try plan("SELECT json FROM changeEvents WHERE acknowledged=0 ORDER BY eventKey LIMIT 50").contains("changeEvents_unacknowledged"))
    }

    func testMaintenancePrunesOldAcknowledgedEventsAndPollHistoryWithoutResurrection() throws {
        let store = try DatabaseStore(path:try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path)
        try seed(store,account,repos:["1"])
        let cycles = PollCycleStore(database:store), now = Date()
        let old = now.addingTimeInterval(-40*86400), recent = now.addingTimeInterval(-86400)
        let oldAcknowledged = event(account,repo:"1",key:"old-acknowledged",occurredAt:old)
        let oldUnread = event(account,repo:"1",key:"old-unread",occurredAt:old.addingTimeInterval(-60))
        let recentAcknowledged = event(account,repo:"1",key:"recent-acknowledged",occurredAt:recent)
        let reconciling = event(account,repo:"1",key:"old-reconciling",occurredAt:old,object:"notification-thread:9")
        let retainedCycle = try record(store,[oldAcknowledged,oldUnread,recentAcknowledged,reconciling],at:old)
        let emptyCycle = try record(store,[],at:old,failure:true)
        let recentCycle = try record(store,[],at:recent,failure:true)
        try store.database.write { db in
            for cycle in [emptyCycle,recentCycle] { try db.execute(sql:"INSERT INTO notificationAttempts VALUES (?,?,'delivered')",arguments:[cycle.uuidString,Data("{}".utf8)]) }
        }
        try cycles.acknowledge([oldAcknowledged.key,recentAcknowledged.key,reconciling.key])
        var thread = NotificationThreadOperation(command:try NotificationThreadCommand(event:reconciling,intent:.done))
        try store.prepareNotificationThread(thread)
        thread.state = .sending; try store.updateNotificationThread(thread,expected:.prepared)

        try store.runStorageMaintenance(now:now)
        XCTAssertEqual(try eventKeys(store),[oldUnread.key,recentAcknowledged.key,reconciling.key])
        let remainingCycles = Set(try store.database.read { try String.fetchAll($0,sql:"SELECT id FROM pollCycles") })
        XCTAssertEqual(remainingCycles,[retainedCycle.uuidString,recentCycle.uuidString])
        XCTAssertEqual(try cycles.failures(recentCycle),["fixture failure"])
        XCTAssertTrue(try cycles.failures(emptyCycle).isEmpty)
        XCTAssertNil(try cycles.attemptState(emptyCycle)); XCTAssertEqual(try cycles.attemptState(recentCycle),"delivered")

        // A feed page that still lists the pruned thread must not bring it back as unread.
        let fresh = event(account,repo:"1",key:"fresh",occurredAt:now)
        try record(store,[oldAcknowledged,fresh])
        let inbox = try eventKeys(store)
        XCTAssertFalse(inbox.contains(oldAcknowledged.key))
        XCTAssertTrue(inbox.contains(fresh.key))
    }

    func testMaintenanceRunsAtMostOncePerDay() throws {
        let store = try DatabaseStore(path:try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path)
        let now = Date()
        XCTAssertTrue(try store.runStorageMaintenanceIfDue(now:now))
        XCTAssertFalse(try store.runStorageMaintenanceIfDue(now:now.addingTimeInterval(3600)))
        XCTAssertTrue(try store.runStorageMaintenanceIfDue(now:now.addingTimeInterval(25*3600)))
    }

    // MARK: Frozen migration v7

    private let featureTables: Set<String> = ["actions_view_state","actions_catalog","actions_presets","actions_operations","repo_browser_state","repo_browser_cache","repo_browser_operations"]
    private func tables(_ path: String) throws -> Set<String> {
        let queue = try DatabaseQueue(path:path)
        defer { try? queue.close() }
        return Set(try queue.read { try String.fetchAll($0,sql:"SELECT name FROM sqlite_master WHERE type='table'") })
    }

    func testFreshAndUpgradedDatabasesGetFeatureTablesFromFrozenMigration() throws {
        let directory = try makeTemporaryDirectory()
        let fresh = directory.appendingPathComponent("fresh.sqlite").path
        _ = try DatabaseStore(path:fresh)
        XCTAssertTrue(try tables(fresh).isSuperset(of:featureTables))

        let upgraded = directory.appendingPathComponent("upgraded.sqlite").path
        do {
            let queue = try DatabaseQueue(path:upgraded)
            try Migrations.migrator().migrate(queue,upTo:"v6-notification-thread-operations")
            try queue.close()
        }
        XCTAssertTrue(try tables(upgraded).isDisjoint(with:featureTables))
        _ = try DatabaseStore(path:upgraded)
        XCTAssertTrue(try tables(upgraded).isSuperset(of:featureTables))

        // Before v7 was registered, the stores created these tables themselves; their rows survive.
        let early = directory.appendingPathComponent("early.sqlite").path
        do {
            let queue = try DatabaseQueue(path:early)
            try Migrations.migrator().migrate(queue,upTo:"v6-notification-thread-operations")
            try queue.write { db in
                try db.execute(sql:"CREATE TABLE actions_catalog(host TEXT NOT NULL,accountID TEXT NOT NULL,repositoryID TEXT NOT NULL,json BLOB NOT NULL,PRIMARY KEY(host,accountID,repositoryID))")
                try db.execute(sql:"INSERT INTO actions_catalog VALUES ('github.com','42','1',x'7b7d')")
            }
            try queue.close()
        }
        let store = try DatabaseStore(path:early)
        XCTAssertTrue(try tables(early).isSuperset(of:featureTables))
        XCTAssertEqual(try count(store,"SELECT COUNT(*) FROM actions_catalog"),1)
    }

    func testFeatureStoreInitializersRunNoSchemaStatements() throws {
        let store = try DatabaseStore(path:try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path)
        let traced = TracedStatements()
        try store.database.writeWithoutTransaction { $0.trace { traced.append($0.description) } }
        defer { try? store.database.writeWithoutTransaction { $0.trace(options:[],nil) } }
        for _ in 0..<3 { _ = try ActionsStore(database:store); _ = try RepositoryBrowserPersistence(database:store) }
        XCTAssertFalse(traced.all.contains { $0.localizedCaseInsensitiveContains("CREATE TABLE") },traced.all.joined(separator:"\n"))
    }

    // MARK: Performance

    func testFileDatabaseUsesWALWithSecureDeleteAndPrivatePermissions() throws {
        let path = try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path
        let store = try DatabaseStore(path:path)
        XCTAssertEqual(try store.database.read { try String.fetchOne($0,sql:"PRAGMA journal_mode") },"wal")
        XCTAssertEqual(try store.database.read { try Int.fetchOne($0,sql:"PRAGMA secure_delete") },1)
        XCTAssertEqual(try store.database.write { try Int.fetchOne($0,sql:"PRAGMA secure_delete") },1)
        try store.setApplicationSetting("value",for:"fixture")
        for suffix in ["","-wal","-shm"] where FileManager.default.fileExists(atPath:path+suffix) {
            let permissions = try FileManager.default.attributesOfItem(atPath:path+suffix)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue,0o600,suffix)
        }
    }

    func testReadsRunBesideAWriteAndNeverObserveItHalfApplied() throws {
        let store = try DatabaseStore(path:try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path)
        let inserted = DispatchSemaphore(value:0), checked = DispatchSemaphore(value:0), observed = LockedCount()
        DispatchQueue.global().async {
            inserted.wait()
            observed.set((try? store.database.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM applicationSettings WHERE name LIKE 'half-%'") }) ?? -1)
            checked.signal()
        }
        try store.database.write { db in
            try db.execute(sql:"INSERT INTO applicationSettings VALUES ('half-1','a')")
            inserted.signal()
            XCTAssertEqual(checked.wait(timeout:.now()+10),.success,"a read must not wait behind the writer")
            try db.execute(sql:"INSERT INTO applicationSettings VALUES ('half-2','b')")
        }
        XCTAssertEqual(observed.value,0)
        XCTAssertEqual(try count(store,"SELECT COUNT(*) FROM applicationSettings WHERE name LIKE 'half-%'"),2)
    }

    func testIdenticalUpsertsDoNotRewriteRows() throws {
        let store = try DatabaseStore(path:try makeTemporaryDirectory().appendingPathComponent("db.sqlite").path)
        try seed(store,account,repos:["1"])
        try store.setSetting("v",for:"name",account:account)
        try store.setApplicationSetting("v",for:"name")
        let discovery = GitHubDiscoveryResult(repositories:[repository(account,"1")],organizations:[],teams:[],issues:[],isComplete:true,retryAt:nil)
        try store.commitRepositoryDiscovery(discovery,account:account)
        try store.database.write { db in
            try db.execute(sql:"CREATE TEMP TABLE rewrites(name TEXT)")
            for table in ["accounts","repositories","pullRequests","settings","applicationSettings"] {
                try db.execute(sql:"CREATE TEMP TRIGGER rewrite_\(table) AFTER UPDATE ON main.\(table) BEGIN INSERT INTO rewrites VALUES ('\(table)'); END")
            }
        }
        func rewrites() throws -> [String] { try store.database.write { try String.fetchAll($0,sql:"SELECT name FROM rewrites ORDER BY rowid") } }
        try store.saveAccount(Account(scope:account,login:"login-\(account.accountID)",tokenReference:AccountSessionStore.tokenReference(for:account)))
        try store.saveRepository(repository(account,"1"))
        try store.savePullRequests([pullRequest(account,repo:"1")])
        try store.setSetting("v",for:"name",account:account)
        try store.setApplicationSetting("v",for:"name")
        try store.commitRepositoryDiscovery(discovery,account:account)
        XCTAssertEqual(try rewrites(),[])
        try store.setSetting("changed",for:"name",account:account)
        XCTAssertEqual(try rewrites(),["settings"])
    }

    func testPayloadCacheScansOnlyAfterAnUncleanShutdownAndValidatesReadsLazily() async throws {
        let directory = try makeTemporaryDirectory(), cacheDirectory = directory.appendingPathComponent("cache")
        let store = try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        try seed(store,account,repos:["1"])
        let payload = PayloadKey(object:key(account,repo:"1"),revision:RevisionID("sha"),kind:.diff)
        var cache = try CacheStore(directory:cacheDirectory,database:store,reconcileInBackground:false)
        try await cache.put(Data("payload".utf8),for:payload)
        let accountDirectory = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at:cacheDirectory,includingPropertiesForKeys:nil).first { $0.hasDirectoryPath })
        let orphan = accountDirectory.appendingPathComponent(String(repeating:"0",count:64)+".payload")
        try Data("orphan".utf8).write(to:orphan)

        cache = try CacheStore(directory:cacheDirectory,database:store,reconcileInBackground:false)
        let clean = try await cache.data(for:payload)
        XCTAssertEqual(clean,Data("payload".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath:orphan.path),"a clean reopen does not walk the cache folder")

        try FileManager.default.removeItem(at:cacheDirectory.appendingPathComponent(CacheStore.cleanMarkerName))
        cache = try CacheStore(directory:cacheDirectory,database:store,reconcileInBackground:false)
        let recovered = try await cache.data(for:payload)
        XCTAssertEqual(recovered,Data("payload".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:orphan.path),"an unclean shutdown is recovered by a full scan")

        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at:accountDirectory,includingPropertiesForKeys:nil).first { $0.pathExtension == "payload" })
        try Data("truncated".utf8).write(to:file)
        let invalid = try await cache.data(for:payload)
        XCTAssertNil(invalid,"a payload that no longer matches its manifest is a miss")
        XCTAssertFalse(try store.hasPayload(id:CacheStore.payloadID(payload)))
    }

    func testPayloadCacheFolderIsExcludedFromBackup() throws {
        let directory = try makeTemporaryDirectory(), cacheDirectory = directory.appendingPathComponent("cache")
        let store = try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        _ = try CacheStore(directory:cacheDirectory,database:store,reconcileInBackground:false)
        XCTAssertEqual(try cacheDirectory.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup,true)
    }

    func testCredentialReadsAreCachedAndInvalidatedWithTheCredential() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        try seed(store,account,repos:[])
        let cache = try CacheStore(directory:directory.appendingPathComponent("cache"),database:store,reconcileInBackground:false)
        let credentials = CountingCredentials()
        credentials.save(GitHubCredential(accessToken:"first",scopes:["repo"]),account:account)
        let session = AccountSessionStore(database:store,cache:cache,credentials:credentials)
        var ticket = try await session.operation(for:account,now:Date())
        for _ in 0..<5 { ticket = try await session.operation(for:account,now:Date()) }
        _ = try await session.authorizationState(for:account)
        XCTAssertEqual(credentials.reads,1,"polls and UI must not read the Keychain on every call")
        let refreshed = GitHubCredential(accessToken:"second",scopes:["repo"])
        let saved = try await session.saveRefreshed(refreshed,operation:ticket)
        XCTAssertTrue(saved)
        let current = try await session.operation(for:account,now:Date())
        XCTAssertEqual(current.credential,refreshed)
        let invalidated = try await session.markInvalid(current)
        XCTAssertTrue(invalidated)
        XCTAssertNil(credentials.base.credential(for:account))
        try await session.saveAuthorized(AuthorizedGitHubAccount(scope:account,login:"login-42",credential:GitHubCredential(accessToken:"third",scopes:["repo"])))
        let reconnected = try await session.operation(for:account,now:Date())
        XCTAssertEqual(reconnected.credential.accessToken,"third")
        try await session.remove(account)
        XCTAssertNil(credentials.base.credential(for:account))
    }
}
