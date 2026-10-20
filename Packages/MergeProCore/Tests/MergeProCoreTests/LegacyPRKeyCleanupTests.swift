import Foundation
import GRDB
import XCTest
@testable import MergeProCore

/// PRs created or linked from the app were once saved under the raw GitHub node ID, while the inventory
/// stores `pull-request:<node ID>`. The one-time cleanup removes a raw row only when the canonical row exists
/// for the same account and repository, and carries pins and reading progress over to the canonical key.
final class LegacyPRKeyCleanupTests: XCTestCase {
    func testUpgradePreservesReservationWhenCanonicalLedgerHistoryAlreadyExists() throws {
        let store=try store(),raw=key(account,"PR_upgrade"),canonical=key(account,"pull-request:PR_upgrade")
        try store.savePullRequests([pr(raw,number:1),pr(canonical,number:1)])
        let ledger=DraftReviewStore(database:store),revision=PRWriteRevision(head:"sha",origin:"base",target:"base")
        func operation(_ key:ProviderKey) -> PRWriteOperation {
            PRWriteOperation(command:PRWriteCommand(key:key,repository:"o/r",number:1,revision:revision,intent:.review(.approve,"review")))
        }
        var pending=operation(raw);try ledger.prepare(pending)
        pending.state = .sending;try ledger.update(pending)
        pending.state = .uncertain;try ledger.update(pending)
        let completed=operation(canonical);try ledger.prepare(completed);try ledger.rejectUnsent(completed.id)
        // Reproduce a database on which v9 already ran: it removed the raw row but retained
        // both ledger histories. A forward upgrade must repair this existing installation.
        try cleanup(store)
        XCTAssertNil(try store.pullRequest(for:raw))
        try store.database.write { try $0.execute(sql:"DELETE FROM grdb_migrations WHERE identifier='v10-canonical-ledger-reservations'") }
        let upgraded=try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        let repaired=DraftReviewStore(database:upgraded)
        XCTAssertEqual(try repaired.operation(pending.id)?.command.key,canonical)
        XCTAssertEqual(try repaired.operation(pending.id)?.state,.uncertain)
        XCTAssertEqual(try repaired.operation(completed.id)?.state,.rejected)
        XCTAssertTrue(try repaired.operations(canonical).contains { $0.id == pending.id })
        XCTAssertThrowsError(try repaired.prepare(operation(canonical))) { XCTAssertEqual($0 as? PRWriteFailure,.operationInProgress) }
    }
    func testUpgradeKeepsLegacyNilGenerationReceiptWithOriginalDraft() throws {
        try assertReceiptOwnership(legacyGenerations:true)
    }
    func testUpgradeKeepsDistinctGenerationReceiptWithOriginalDraft() throws {
        try assertReceiptOwnership(legacyGenerations:false)
    }
    private func assertReceiptOwnership(legacyGenerations:Bool) throws {
        let store=try store(),raw=key(account,"PR_receipt"),canonical=key(account,"pull-request:PR_receipt")
        try store.savePullRequests([pr(raw,number:1),pr(canonical,number:1)])
        let ledger=DraftReviewStore(database:store),revision=PRWriteRevision(head:"sha",origin:"base",target:"base")
        var original=ReviewDraft(key:raw,revision:revision,summary:"original")
        var unrelated=ReviewDraft(key:canonical,revision:revision,summary:"unrelated")
        if legacyGenerations { original.reviewGeneration=nil;unrelated.reviewGeneration=nil }
        try ledger.save(original);try ledger.save(unrelated)
        var pending=PRWriteOperation(command:PRWriteCommand(key:raw,repository:"o/r",number:1,revision:revision,intent:.createPending("original")))
        try ledger.prepare(pending);pending=try XCTUnwrap(ledger.operation(pending.id))
        pending.state = .sending;try ledger.update(pending)
        pending.state = .uncertain;try ledger.update(pending)
        let completed=PRWriteOperation(command:PRWriteCommand(key:canonical,repository:"o/r",number:1,revision:revision,intent:.review(.approve,"old")))
        try ledger.prepare(completed);try ledger.rejectUnsent(completed.id)
        try cleanup(store)
        try store.database.write { try $0.execute(sql:"DELETE FROM grdb_migrations WHERE identifier='v10-canonical-ledger-reservations'") }
        let upgraded=try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        let repaired=DraftReviewStore(database:upgraded)
        var receipt=try XCTUnwrap(repaired.operation(pending.id))
        receipt.state = .confirmed;receipt.providerIDs=["provider-review"]
        try repaired.commitReceipt(receipt,expectedState:.uncertain,normalized:nil)
        XCTAssertEqual(try repaired.load(raw)?.pendingReviewID,"provider-review")
        XCTAssertEqual(try repaired.load(canonical),unrelated)
        XCTAssertTrue(try repaired.operations(canonical).contains { $0.id == pending.id },"terminal history remains visible")
        // A crash between saving the ledger and adopting its receipt must recover the same owner.
        try upgraded.database.write { db in
            let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            let identity=try encoder.encode(raw).base64EncodedString()
            try db.execute(sql:"UPDATE reviewDrafts SET json=? WHERE identity=?",arguments:[try JSONEncoder().encode(original),identity])
        }
        try repaired.recoverReceipts(canonical)
        XCTAssertEqual(try repaired.load(raw)?.pendingReviewID,"provider-review")
        XCTAssertEqual(try repaired.load(canonical),unrelated)
    }
    let account=AccountScope(host:"github.com",accountID:"42")
    let other=AccountScope(host:"github.com",accountID:"43")
    var directory:URL!
    override func setUpWithError() throws { directory=try makeTemporaryDirectory(prefix:"LegacyPRKeyCleanupTests") }
    func key(_ account:AccountScope,repo:String = "R",_ objectID:String) -> ProviderKey { ProviderKey(host:account.host,accountID:account.accountID,repositoryID:repo,objectID:objectID) }
    func pr(_ key:ProviderKey,number:Int,head:String = "sha") -> PullRequest {
        var m=PRMetadata(number:number,webURL:URL(string:"https://github.com/o/r/pull/\(number)")!,repositoryName:"o/r")
        m.headBranch="feature/\(number)";m.baseBranch="main"
        return PullRequest(key:key,headRevision:RevisionID(head),title:"PR \(number)",state:.open,isDraft:false,metadata:m)
    }
    func store() throws -> DatabaseStore {
        let store=try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        for scope in [account,other] {
            try store.saveAccount(Account(scope:scope,login:"user-\(scope.accountID)"))
            for repo in ["R","S"] { try store.saveRepository(Repository(key:RepositoryKey(account:scope,repositoryID:repo),name:"o/\(repo)",isPrivate:true,capabilities:ProviderCapabilities())) }
        }
        return store
    }
    func objectIDs(_ store:DatabaseStore,_ scope:AccountScope,repo:String = "R") throws -> [String] {
        try store.pullRequests(repository:RepositoryKey(account:scope,repositoryID:repo)).map(\.key.objectID)
    }
    @discardableResult func cleanup(_ store:DatabaseStore) throws -> Int { try store.database.write { try LegacyPRKeyCleanup.run($0) } }

    func testRemovesRawRowOnlyWhenCanonicalRowExistsInSameAccountAndRepository() throws {
        let store=try store()
        try store.savePullRequests([
            pr(key(account,"PR_dup"),number:1),pr(key(account,"pull-request:PR_dup"),number:1),
            // Raw row whose canonical row lives in another repository or account: kept.
            pr(key(account,"PR_otherRepo"),number:2),pr(key(account,repo:"S","pull-request:PR_otherRepo"),number:2),
            pr(key(account,"PR_otherAccount"),number:3),pr(key(other,"pull-request:PR_otherAccount"),number:3),
            // Raw row without any canonical row: kept.
            pr(key(account,"PR_alone"),number:4),
        ])
        XCTAssertEqual(try cleanup(store),1)
        XCTAssertEqual(try objectIDs(store,account),["PR_alone","PR_otherAccount","PR_otherRepo","pull-request:PR_dup"])
        XCTAssertEqual(try objectIDs(store,account,repo:"S"),["pull-request:PR_otherRepo"])
        XCTAssertEqual(try objectIDs(store,other),["pull-request:PR_otherAccount"])
        XCTAssertEqual(try cleanup(store),0,"idempotent")
    }
    func testCanonicalRowIsUntouched() throws {
        let store=try store()
        let canonical=pr(key(account,"pull-request:PR_x"),number:7,head:"canonical-head")
        try store.savePullRequests([pr(key(account,"PR_x"),number:7,head:"stale-head"),canonical])
        try cleanup(store)
        XCTAssertEqual(try store.pullRequest(for:canonical.key)?.headRevision,canonical.headRevision)
        XCTAssertNil(try store.pullRequest(for:key(account,"PR_x")))
    }
    func testPinsMoveToTheCanonicalKey() throws {
        let store=try store()
        try store.savePullRequests([pr(key(account,"PR_a"),number:1),pr(key(account,"pull-request:PR_a"),number:1),
            pr(key(account,"PR_b"),number:2),pr(key(account,"pull-request:PR_b"),number:2)])
        let repositoryPin=key(account,"repository")
        try store.setPinned(key(account,"PR_a"),pinned:true)
        // Both raw and canonical pinned: one canonical pin remains.
        try store.setPinned(key(account,"PR_b"),pinned:true)
        try store.setPinned(key(account,"pull-request:PR_b"),pinned:true)
        try store.setPinned(repositoryPin,pinned:true)
        try cleanup(store)
        XCTAssertEqual(try store.pins(account:account),[key(account,"pull-request:PR_a"),key(account,"pull-request:PR_b"),repositoryPin])
    }
    func testReadingProgressMovesToTheCanonicalKey() throws {
        let store=try store()
        let raw=key(account,"PR_a"),canonical=key(account,"pull-request:PR_a")
        let rawOnly=key(account,"PR_b"),canonicalB=key(account,"pull-request:PR_b")
        try store.savePullRequests([pr(raw,number:1),pr(canonical,number:1),pr(rawOnly,number:2),pr(canonicalB,number:2),pr(key(account,"PR_alone"),number:3)])
        let progress=PRDetailStore(database:store)
        var state=PRDetailState(headSHA:"sha");state.markViewed("Sources/A.swift",viewed:true)
        try progress.save(state,key:raw)
        // Existing canonical progress wins over the raw copy.
        var rawB=PRDetailState(headSHA:"sha");rawB.markViewed("old.swift",viewed:true)
        var keptB=PRDetailState(headSHA:"sha");keptB.markViewed("new.swift",viewed:true)
        try progress.save(rawB,key:rawOnly);try progress.save(keptB,key:canonicalB)
        // Progress for a raw key without a canonical row is left alone.
        var alone=PRDetailState(headSHA:"sha");alone.markViewed("alone.swift",viewed:true)
        try progress.save(alone,key:key(account,"PR_alone"))
        try cleanup(store)
        XCTAssertEqual(try progress.load(canonical,headSHA:"sha").viewed,["Sources/A.swift"])
        XCTAssertEqual(try progress.load(raw,headSHA:"sha").viewed,[])
        XCTAssertEqual(try progress.load(canonicalB,headSHA:"sha").viewed,["new.swift"])
        XCTAssertEqual(try progress.load(rawOnly,headSHA:"sha").viewed,[])
        XCTAssertEqual(try progress.load(key(account,"PR_alone"),headSHA:"sha").viewed,["alone.swift"])
    }
    func testReviewDraftsInlineDraftsAndLedgerMoveToTheCanonicalKeyUnlessItHasItsOwn() throws {
        let store=try store()
        let rawA=key(account,"PR_a"),canonA=key(account,"pull-request:PR_a")
        let rawB=key(account,"PR_b"),canonB=key(account,"pull-request:PR_b")
        let rawC=key(account,"PR_c")
        try store.savePullRequests([pr(rawA,number:1),pr(canonA,number:1),pr(rawB,number:2),pr(canonB,number:2),pr(rawC,number:3)])
        let reviews=DraftReviewStore(database:store),revision=PRWriteRevision(head:"sha",origin:"base",target:"base")
        // A: only the raw key has local state, including an in-flight write. B: the canonical key has its own.
        let draftA=ReviewDraft(key:rawA,revision:revision,summary:"raw A")
        try reviews.save(draftA,expectedVersion:nil)
        try reviews.save(ReviewDraft(key:rawB,revision:revision,summary:"raw B"))
        try reviews.save(ReviewDraft(key:canonB,revision:revision,summary:"canonical B"))
        try reviews.save(ReviewDraft(key:rawC,revision:revision,summary:"raw C"))
        let inlineA=Draft(key:rawA,revision:RevisionID("sha"),body:"inline A"),inlineRawB=Draft(key:rawB,revision:RevisionID("sha"),body:"inline raw B")
        let inlineB=Draft(key:canonB,revision:RevisionID("sha"),body:"inline canonical B"),inlineC=Draft(key:rawC,revision:RevisionID("sha"),body:"inline C")
        for draft in [inlineA,inlineRawB,inlineB,inlineC] { try store.saveDraft(draft) }
        func operation(_ key:ProviderKey,_ body:String) throws -> PRWriteOperation {
            let value=PRWriteOperation(command:PRWriteCommand(key:key,repository:"o/r",number:1,revision:revision,intent:.review(.approve,body)))
            try reviews.prepare(value);var sending=value;sending.state = .sending;try reviews.update(sending);return sending
        }
        let opA=try operation(rawA,"A"),opRawB=try operation(rawB,"raw B"),opB=try operation(canonB,"canonical B"),opC=try operation(rawC,"C")
        try cleanup(store)
        let movedA=try XCTUnwrap(reviews.load(canonA))
        XCTAssertEqual(movedA.summary,"raw A");XCTAssertEqual(movedA.reviewGeneration,draftA.reviewGeneration);XCTAssertEqual(movedA.revision,revision)
        XCTAssertNil(try reviews.load(rawA))
        XCTAssertEqual(try reviews.load(canonB)?.summary,"canonical B");XCTAssertEqual(try reviews.load(rawB)?.summary,"raw B","the raw copy is retained, not merged")
        XCTAssertEqual(try reviews.load(rawC)?.summary,"raw C","no canonical row: untouched")
        let inline=try store.snapshot(for:account).drafts
        XCTAssertEqual(Set(inline.map(\.id)),Set([inlineA,inlineRawB,inlineB,inlineC].map(\.id)))
        XCTAssertEqual(inline.first { $0.id == inlineA.id }?.key,canonA);XCTAssertEqual(inline.first { $0.id == inlineA.id }?.body,"inline A")
        XCTAssertEqual(inline.first { $0.id == inlineRawB.id }?.key,rawB);XCTAssertEqual(inline.first { $0.id == inlineB.id }?.key,canonB)
        XCTAssertEqual(inline.first { $0.id == inlineC.id }?.key,rawC)
        // The in-flight write now reserves the canonical PR, so a second write cannot start beside it.
        XCTAssertEqual(try reviews.operations(canonA).map(\.id),[opA.id]);XCTAssertTrue(try reviews.operations(rawA).isEmpty)
        let movedOp=try XCTUnwrap(reviews.operation(opA.id))
        XCTAssertEqual(movedOp.command.key,canonA);XCTAssertEqual(movedOp.createdAt,opA.createdAt,"other fields round-trip exactly")
        XCTAssertEqual(movedOp.state,.sending);XCTAssertEqual(movedOp.command.intent,opA.command.intent)
        XCTAssertEqual(try reviews.operations(canonB).map(\.id),[opB.id]);XCTAssertEqual(try reviews.operations(rawB).map(\.id),[opRawB.id])
        XCTAssertEqual(try reviews.operations(rawC).map(\.id),[opC.id])
        let active=try store.database.read { try DatabaseStore.activeReservations($0) }
        XCTAssertEqual(active,[canonA,rawB,canonB,rawC])
        let before=try store.database.read { try Row.fetchAll($0,sql:"SELECT identity,json FROM reviewOperations ORDER BY id").map { "\($0["identity"] as String)|\(String(decoding:$0["json"] as Data,as:UTF8.self))" } }
        try cleanup(store)
        XCTAssertEqual(try store.database.read { try Row.fetchAll($0,sql:"SELECT identity,json FROM reviewOperations ORDER BY id").map { "\($0["identity"] as String)|\(String(decoding:$0["json"] as Data,as:UTF8.self))" } },before,"idempotent")
    }
    func testCorruptLocalStateIsLeftInPlace() throws {
        let store=try store()
        try store.savePullRequests([pr(key(account,"PR_a"),number:1),pr(key(account,"pull-request:PR_a"),number:1)])
        let identity=try { () throws -> String in let e=JSONEncoder();e.outputFormatting = [.sortedKeys];return try e.encode(key(account,"PR_a")).base64EncodedString() }()
        try store.database.write { db in
            try db.execute(sql:"INSERT INTO reviewDrafts VALUES (?,?,?,?)",arguments:[identity,account.host,account.accountID,Data("{broken".utf8)])
            try db.execute(sql:"INSERT INTO reviewOperations VALUES (?,?,?)",arguments:["op",identity,Data("{broken".utf8)])
            try db.execute(sql:"INSERT INTO drafts VALUES (?,?,?,?)",arguments:[UUID().uuidString,account.host,account.accountID,Data("{broken".utf8)])
        }
        XCTAssertNoThrow(try cleanup(store))
        XCTAssertEqual(try store.database.read { try String.fetchAll($0,sql:"SELECT identity FROM reviewDrafts UNION ALL SELECT identity FROM reviewOperations") },[identity,identity])
    }
    func testMigrationCleansAnExistingDatabaseOnce() throws {
        let path=directory.appendingPathComponent("legacy.sqlite").path
        let queue=try DatabaseQueue(path:path)
        try Migrations.migrator().migrate(queue,upTo:"v8-storage-lookup-indexes")
        let encoder=JSONEncoder()
        try queue.write { db in
            try db.execute(sql:"INSERT INTO accounts (host,accountID,login,tokenReference) VALUES (?,?,?,NULL)",arguments:[account.host,account.accountID,"me"])
            try db.execute(sql:"INSERT INTO repositories VALUES (?,?,?,?)",arguments:[account.host,account.accountID,"R",try encoder.encode(Repository(key:RepositoryKey(account:account,repositoryID:"R"),name:"o/r",isPrivate:true,capabilities:ProviderCapabilities()))])
            for item in [pr(key(account,"PR_dup"),number:1),pr(key(account,"pull-request:PR_dup"),number:1),pr(key(account,"PR_alone"),number:2)] {
                try db.execute(sql:"INSERT INTO pullRequests (host,accountID,repositoryID,objectID,json) VALUES (?,?,?,?,?)",arguments:[item.key.host,item.key.accountID,item.key.repositoryID,item.key.objectID,try encoder.encode(item)])
            }
        }
        try queue.close()
        let store=try DatabaseStore(path:path)
        XCTAssertEqual(try objectIDs(store,account),["PR_alone","pull-request:PR_dup"])
        // A raw row written after the migration is not touched again by reopening.
        try store.savePullRequests([pr(key(account,"PR_dup"),number:1)])
        let reopened=try DatabaseStore(path:path)
        XCTAssertEqual(try objectIDs(reopened,account),["PR_alone","PR_dup","pull-request:PR_dup"])
    }
}
