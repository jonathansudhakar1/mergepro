import XCTest
@testable import MergeProCore

/// One action set for cards, table rows, menus and keyboard commands.
final class PRRowActionTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    func row(_ id:String,state:PullRequest.State = .open,draft:Bool=false,_ change:(inout PRMetadata) -> Void = { _ in }) -> PullRequest {
        var m=PRMetadata(number:Int(id) ?? 1,webURL:URL(string:"https://github.com/o/r/pull/\(id)")!,repositoryName:"o/r");change(&m)
        return .init(key:ProviderKey(host:"github.com",accountID:"42",repositoryID:"R1",objectID:"pull-request:PR"+id),headRevision:.init("h"+id),title:"PR \(id)",state:state,isDraft:draft,metadata:m)
    }
    func actions(_ rows:[PullRequest]) -> PRRowActionState { PRRowActionState(rows:rows) { MergePolicy.evaluate(pr:$0,now:self.now) } }

    func testSingleRowUsesNormalFlowsAndOffersEveryAction() {
        let state=actions([row("1")])
        XCTAssertTrue(state.canOpen);XCTAssertTrue(state.canApprove);XCTAssertFalse(state.approveIsBatch)
        XCTAssertTrue(state.canRequestChanges);XCTAssertTrue(state.canComment)
        XCTAssertTrue(state.canMerge,"Unknown evidence opens the merge sheet");XCTAssertFalse(state.mergeIsBatch)
        XCTAssertTrue(state.canEditLabels);XCTAssertTrue(state.canClose);XCTAssertEqual(state.draft,.convertToDraft)
        XCTAssertTrue(state.canCopyLink);XCTAssertEqual(state.autoMerge,.enableAutoMerge);XCTAssertTrue(state.canUpdateBranch)
        XCTAssertFalse(state.canRemoveFromQueue,"Only offered when GitHub last reported the PR queued")
        XCTAssertEqual(state.mergeTitle,"Merge…")
    }

    func testMultiSelectionDisablesSingleRowComposers() {
        let state=actions([row("1"),row("2")])
        XCTAssertEqual(state.count,2)
        XCTAssertTrue(state.canApprove);XCTAssertTrue(state.approveIsBatch)
        XCTAssertFalse(state.canRequestChanges,"Request changes acts on one PR only")
        XCTAssertFalse(state.canComment,"Comment acts on one PR only")
        XCTAssertFalse(state.canEditLabels);XCTAssertFalse(state.canClose);XCTAssertNil(state.draft);XCTAssertNil(state.autoMerge)
        XCTAssertTrue(state.canMerge);XCTAssertTrue(state.mergeIsBatch)
        XCTAssertEqual(state.mergeTitle,"Merge 2 selected…")
        XCTAssertTrue(state.canCopyLink)
    }

    func testKnownBlockersAndClosedRows() {
        let draft=actions([row("1",draft:true)])
        XCTAssertFalse(draft.canMerge);XCTAssertEqual(draft.draft,.markReady);XCTAssertNil(draft.autoMerge,"GitHub refuses auto-merge on drafts")
        let merged=actions([row("1",state:.merged)])
        XCTAssertFalse(merged.canApprove);XCTAssertFalse(merged.canRequestChanges);XCTAssertTrue(merged.canComment)
        XCTAssertFalse(merged.canMerge);XCTAssertFalse(merged.canClose);XCTAssertNil(merged.draft);XCTAssertFalse(merged.canUpdateBranch)
        let mixed=actions([row("1",state:.merged),row("2",state:.closed)])
        XCTAssertFalse(mixed.canMerge,"Nothing left after skipping known blockers")
        XCTAssertFalse(mixed.canApprove,"Batch approval needs an open row")
        let partly=actions([row("1",draft:true),row("2")])
        XCTAssertTrue(partly.canMerge,"Blocked rows are skipped, not the whole batch")
    }

    func testAutoMergeQueueAndFailingChecks() {
        let enabled=actions([row("1") { $0.autoMergeKnown=true;$0.autoMerge=true }])
        XCTAssertEqual(enabled.autoMerge,.disableAutoMerge)
        var queued=MergeEvidence(key:row("1").key,head:"h1",base:"b",branch:"main",fetchedAt:.distantPast);queued.queued=true;queued.open=true;queued.draft=false
        XCTAssertTrue(actions([row("1") { $0.mergeEvidence=queued }]).canRemoveFromQueue)
        XCTAssertTrue(actions([row("1") { $0.checks="FAILURE" }]).checksFailing)
        XCTAssertTrue(actions([row("1") { $0.failingRequiredCheck=true }]).checksFailing)
        XCTAssertFalse(actions([row("1") { $0.checks="PENDING" }]).checksFailing)
    }

    func testStatusSummaryIsReadableWithExplicitUnknowns() {
        XCTAssertEqual(PRStatusSummary.checks("SUCCESS"),.init(tone:.passing,text:"Checks passing"))
        XCTAssertEqual(PRStatusSummary.checks("FAILURE"),.init(tone:.failing,text:"Checks failing"))
        XCTAssertEqual(PRStatusSummary.checks("ERROR").tone,.failing)
        XCTAssertEqual(PRStatusSummary.checks("PENDING"),.init(tone:.pending,text:"Checks running"))
        XCTAssertEqual(PRStatusSummary.checks(nil),.init(tone:.unknown,text:"Checks unknown"))
        XCTAssertEqual(PRStatusSummary.review("CHANGES_REQUESTED"),.init(tone:.failing,text:"Changes requested"))
        XCTAssertEqual(PRStatusSummary.review("APPROVED"),.init(tone:.passing,text:"Approved"))
        XCTAssertEqual(PRStatusSummary.review("REVIEW_REQUIRED"),.init(tone:.pending,text:"Review required"))
        XCTAssertEqual(PRStatusSummary.review(nil),.init(tone:.unknown,text:"Review unknown"))
        XCTAssertEqual(PRStatusSummary.mergeable("CONFLICTING"),.init(tone:.failing,text:"Conflicts"))
        XCTAssertEqual(PRStatusSummary.mergeable("MERGEABLE"),.init(tone:.passing,text:"No conflicts"))
        XCTAssertEqual(PRStatusSummary.mergeable("UNKNOWN"),.init(tone:.unknown,text:"Conflicts unknown"))
        for raw in ["SUCCESS","FAILURE","CHANGES_REQUESTED","REVIEW_REQUIRED"] {
            XCTAssertFalse(PRStatusSummary.checks(raw).text.contains("_"));XCTAssertFalse(PRStatusSummary.review(raw).text.contains("_"))
        }
    }

    func testMergeVerificationTextSaysWhenAndUnknown() {
        var e=MergeEvidence(key:row("1").key,head:"h1",base:"b",branch:"main",fetchedAt:now.addingTimeInterval(-180))
        e.open=true;e.draft=false;e.conflictFree=true;e.actorAllowed=true;e.tokenCanWrite=true;e.rulesComplete=true;e.asyncSupported=true;e.methods=[.squash]
        let stale=MergePolicy.evaluate(pr:row("1") { $0.mergeEvidence=e },now:now)
        let verified=PRStatusSummary.merge(stale,now:now)
        XCTAssertEqual(verified.tone,.passing)
        XCTAssertTrue(verified.text.hasPrefix("Verified ready · "),verified.text)
        XCTAssertNotEqual(verified.text,"Verified ready · just now")
        XCTAssertEqual(PRStatusSummary.merge(MergePolicy.evaluate(pr:row("1"),now:now),now:now),.init(tone:.unknown,text:"Not verified"))
        XCTAssertEqual(PRStatusSummary.merge(MergePolicy.evaluate(pr:row("1",draft:true),now:now),now:now),.init(tone:.failing,text:"Pull request is draft."))
        e.fetchedAt=now
        XCTAssertEqual(PRStatusSummary.merge(MergePolicy.evaluate(pr:row("1") { $0.mergeEvidence=e },now:now),now:now).text,"Verified ready · just now")
    }

    func testListKeyboardMovesTableSelectionAndBoardMovesFocusOnly() {
        let keys=(1...4).map { row(String($0)).key }
        var list=PRSelection()
        XCTAssertEqual(list.move(1,in:keys,selecting:true),keys[0],"First j lands on the first row")
        XCTAssertEqual(list.selected,[keys[0]])
        list.move(1,in:keys,selecting:true);list.move(1,in:keys,selecting:true)
        XCTAssertEqual(list.focused,keys[2]);XCTAssertEqual(list.selected,[keys[2]],"The highlighted row is the selection A/M/Return act on")
        list.move(9,in:keys,selecting:true)
        XCTAssertEqual(list.focused,keys[3],"Clamped at the end")
        list.move(-1,in:keys,selecting:true)
        XCTAssertEqual(list.selected,[keys[2]])
        var board=PRSelection(focused:keys[0],selected:[keys[0],keys[1]])
        board.move(1,in:keys,selecting:false)
        XCTAssertEqual(board.focused,keys[1]);XCTAssertEqual(board.selected,[keys[0],keys[1]],"Board focus moves without changing a multi-selection")
        var empty=PRSelection()
        XCTAssertNil(empty.move(1,in:[],selecting:true))
    }
}
