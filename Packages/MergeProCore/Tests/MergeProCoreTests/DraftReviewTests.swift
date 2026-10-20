import XCTest
@testable import MergeProCore

final class DraftReviewTests:XCTestCase {
    let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"repo",objectID:"PR1")
    func testCrashRestoresExactDraftAndOnePendingPerAccount() throws {
        let dir=try makeTemporaryDirectory()
        let path=dir.appendingPathComponent("draft.sqlite").path
        let draft=ReviewDraft(key:key,revision:.init(head:"h",origin:"o",target:"t"),summary:"Unsaved 🐈\n@reviewer",comments:[])
        try DraftReviewStore(database:DatabaseStore(path:path)).save(draft)
        let restored=try DraftReviewStore(database:DatabaseStore(path:path)).load(key)
        XCTAssertEqual(restored,draft)
        var second=draft;second.summary="new summary";second.editVersion += 1
        let store=try DraftReviewStore(database:DatabaseStore(path:path));try store.save(second)
        XCTAssertEqual(try store.load(key)?.summary,"new summary")
        XCTAssertEqual(try store.all(account:key.account).count,1)
    }
    func testMalformedLedgerRowForAnotherPRDoesNotBlockReviewAdmission() throws {
        let database=try DatabaseStore(path:":memory:"),store=DraftReviewStore(database:database)
        // A corrupt ledger row belonging to another PR must not make every admission query fail.
        try database.database.write { try $0.execute(sql:"INSERT INTO reviewOperations(id,identity,json) VALUES(?,?,?)",arguments:[UUID().uuidString,"other",Data("{not json".utf8)]) }
        XCTAssertEqual(try store.operations(key),[])
        XCTAssertNoThrow(try store.beginReview(key,revision:.init(head:"h",origin:"o",target:"t")))
    }
    func testOriginalRenamedLeftMultilineAndDeletionAnchorsRemainDurable() throws {
        let file=DiffFile(path:"new.swift",previousPath:"old.swift",status:.renamed,patch:"@@ -1,2 +1,2 @@\n-old\n-deleted\n+new\n+replacement")
        let doc=DiffDocument(baseSHA:"o",headSHA:"h",files:[file],expectedFiles:1)
        let anchor=try doc.anchor(file:file,side:.left,start:1,end:2)
        let comment=try ReviewDraftComment(body:"keep original",anchor:anchor,document:doc,revision:.init(head:doc.headSHA,origin:doc.baseSHA,target:doc.baseSHA))
        XCTAssertEqual(comment.contentAnchor?.path,"old.swift");XCTAssertEqual(comment.providerPath,"new.swift")
        XCTAssertEqual(comment.location?.reviewedHeadSHA,"h")
        let store=DraftReviewStore(database:try DatabaseStore(path:":memory:"))
        let draft=ReviewDraft(key:key,revision:.init(head:"h",origin:"o",target:"t"),summary:"",comments:[comment]);try store.save(draft)
        XCTAssertEqual(try store.load(key),draft)
        let deletion=DiffFile(path:"deleted",status:.removed,patch:"@@ -1,1 +0,0 @@\n-gone")
        let deletedDoc=DiffDocument(baseSHA:"o",headSHA:"h",files:[deletion],expectedFiles:1)
        let deleted=try ReviewDraftComment(body:"deleted",anchor:deletedDoc.anchor(file:deletion,side:.left,start:1,end:1),document:deletedDoc,revision:.init(head:deletedDoc.headSHA,origin:deletedDoc.baseSHA,target:deletedDoc.baseSHA))
        XCTAssertEqual(deleted.location?.reviewedHeadSHA,"h");XCTAssertEqual(deleted.contentAnchor?.commitSHA,"o")
    }
    func testHistoricalComparisonCannotBecomeDraftProviderLocation() throws {
        let file=DiffFile(path:"a",status:.modified,patch:"@@ -1 +1 @@\n-old\n+new")
        let doc=DiffDocument(baseSHA:"o",headSHA:"h",files:[file],expectedFiles:1,comparison:.snapshot)
        XCTAssertThrowsError(try ReviewDraftComment(body:"x",anchor:doc.anchor(file:file,side:.right,start:1,end:1),document:doc,revision:.init(head:doc.headSHA,origin:doc.baseSHA,target:doc.baseSHA)))
    }
}

extension DraftReviewTests {
    func testReceiptRecoveryCannotAdoptPriorReviewIntoExplicitNextReviewAtSameRevision() throws {
        let store=DraftReviewStore(database:try DatabaseStore(path:":memory:")),revision=PRWriteRevision(head:"h",origin:"o",target:"t")
        try store.save(.init(key:key,revision:revision,summary:"first"))
        var operation=PRWriteOperation(command:.init(key:key,repository:"o/r",number:1,revision:revision,intent:.createPending("first")))
        try store.prepare(operation);operation.state = .sending;try store.update(operation)
        operation=try XCTUnwrap(store.operation(operation.id));operation.state = .confirmed;operation.providerIDs=["old-review"]
        try store.commitReceipt(operation,expectedState:.sending,normalized:nil)
        _ = try store.beginReview(key,revision:revision)
        XCTAssertNil(try store.load(key)?.pendingReviewID,"Recovery belongs to the captured local review generation, even when head/base remain unchanged")
    }
    func testEqualBaseEditorsCannotOverwriteSummaryReplyOrAppendedComment() throws {
        let store=DraftReviewStore(database:try DatabaseStore(path:":memory:"))
        try store.save(.init(key:key,revision:.init(head:"h",origin:"o",target:"t")))
        var summary=try XCTUnwrap(store.load(key)),reply=summary,comment=summary
        summary.summary="new summary";summary.editVersion += 1;try store.save(summary)
        reply.texts["reply:T"]="local reply";reply.editVersion += 1
        XCTAssertThrowsError(try store.save(reply))
        let file=DiffFile(path:"a",status:.modified,patch:"@@ -1 +1 @@\n-old\n+new"),doc=DiffDocument(baseSHA:"o",headSHA:"h",files:[file],expectedFiles:1)
        comment.comments.append(try ReviewDraftComment(fileBody:"local appended comment",path:"a",document:doc,revision:.init(head:"h",origin:"o",target:"t")));comment.editVersion += 1
        XCTAssertThrowsError(try store.save(comment))
        XCTAssertEqual(try store.load(key)?.summary,"new summary")
        XCTAssertEqual(reply.texts["reply:T"],"local reply","Conflict must retain editor's local snapshot")
        XCTAssertEqual(comment.comments.first?.body,"local appended comment")
    }
    func testReleasedOperationCannotBeResurrectedByStalePreparedOrSendingSnapshot() throws {
        let store=DraftReviewStore(database:try DatabaseStore(path:":memory:"))
        var old=PRWriteOperation(command:.init(key:key,repository:"o/r",number:1,revision:.init(head:"h",origin:"o",target:"t"),intent:.conversation("old")))
        try store.prepare(old);try store.rejectUnsent(old.id)
        let replacement=PRWriteOperation(command:old.command);try store.prepare(replacement)
        XCTAssertThrowsError(try store.update(old))
        old.state = .sending;XCTAssertThrowsError(try store.update(old))
        XCTAssertEqual(try store.operation(old.id)?.state,.rejected)
        XCTAssertEqual(try store.operation(replacement.id)?.state,.prepared)
    }
    func testOnlyNeverSentOperationsCanBeExplicitlyReleasedWithoutLosingDraftText() throws {
        let store=DraftReviewStore(database:try DatabaseStore(path:":memory:"))
        let draft=ReviewDraft(key:key,revision:.init(head:"h",origin:"o",target:"t"),summary:"retained text");try store.save(draft)
        let command=PRWriteCommand(key:key,repository:"o/r",number:1,revision:draft.revision,intent:.conversation(draft.summary))
        let prepared=PRWriteOperation(command:command);try store.prepare(prepared)
        try store.rejectUnsent(prepared.id)
        XCTAssertEqual(try store.operation(prepared.id)?.state,.rejected)
        var sent=PRWriteOperation(command:command);try store.prepare(sent);sent.state = .sending;try store.update(sent)
        XCTAssertThrowsError(try store.rejectUnsent(sent.id))
        XCTAssertEqual(try store.load(key),draft)
    }
}

extension DraftReviewTests {
    func testBeginningNextReviewArchivesOriginalDraftAndCannotHideUncertainCommand() throws {
        let store=DraftReviewStore(database:try DatabaseStore(path:":memory:"))
        let original=ReviewDraft(key:key,revision:.init(head:"h",origin:"o",target:"t"),summary:"previous text",pendingReviewID:"submitted-review")
        try store.save(original)
        let next=try store.beginReview(key,revision:.init(head:"new",origin:"new-origin",target:"new-target"))
        XCTAssertNil(next.pendingReviewID);XCTAssertEqual(next.previousDrafts.first?.summary,"previous text");XCTAssertEqual(next.previousDrafts.first?.revision,original.revision)
        var op=PRWriteOperation(command:.init(key:key,repository:"o/r",number:1,revision:next.revision,intent:.conversation("uncertain")));try store.prepare(op);op.state = .sending;try store.update(op)
        XCTAssertThrowsError(try store.beginReview(key,revision:next.revision))
        XCTAssertEqual(try store.load(key),next)
    }
}

extension DraftReviewTests {
    func testRepeatedSelectionsHaveDistinctDraftIDsAndExplicitRelocationRetainsOriginalPatch() throws {
        let file=DiffFile(path:"a",status:.modified,patch:"@@ -1 +1 @@\n-old\n+new"),doc=DiffDocument(baseSHA:"origin",headSHA:"head",files:[file],expectedFiles:1)
        let selection=try ReviewDraftComment(body:"",anchor:doc.anchor(file:file,side:.right,start:1,end:1),document:doc,revision:.init(head:doc.headSHA,origin:doc.baseSHA,target:doc.baseSHA))
        let first=selection.withBody("first"),second=selection.withBody("second")
        XCTAssertNotEqual(first.id,second.id)
        let next=DiffDocument(baseSHA:"next-origin",headSHA:"next-head",files:[file],expectedFiles:1)
        let current=try ReviewDraftComment(body:"",anchor:next.anchor(file:file,side:.right,start:1,end:1),document:next,revision:.init(head:next.headSHA,origin:next.baseSHA,target:next.baseSHA))
        let relocated=first.relocated(to:current)
        XCTAssertEqual(relocated.body,"first");XCTAssertEqual(relocated.originalAnchors,[try XCTUnwrap(first.contentAnchor)])
        XCTAssertEqual(relocated.originalPatches,[try XCTUnwrap(first.originalPatch)]);XCTAssertEqual(relocated.location?.reviewedHeadSHA,"next-head")
    }
}
