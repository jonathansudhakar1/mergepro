import MergeProCore
import XCTest
@testable import MergePro

/// A PR window acts only on the head it shows. While a newer head waits for the explicit Update, review and merge
/// actions wait too, and the merge sheet and review composer refuse a newer action-account head before sending.
@MainActor final class PRDisplayedHeadTests:XCTestCase {
    func testRefusalNamesBothHeadsAndPointsToUpdate() throws {
        XCTAssertNil(PRDisplayedHead.refusal(shown:nil,actual:"bbb2222222",acting:"merging"),"outside a PR window nothing is pinned")
        XCTAssertNil(PRDisplayedHead.refusal(shown:"aaa1111111",actual:"aaa1111111",acting:"merging"))
        XCTAssertNil(PRDisplayedHead.refusal(shown:"AAA1111111",actual:"aaa1111111",acting:"merging"),"SHAs compare case-insensitively")
        let refusal=try XCTUnwrap(PRDisplayedHead.refusal(shown:"aaa1111111",actual:"bbb2222222",acting:"merging"))
        XCTAssertTrue(refusal.contains("aaa11111"),refusal)
        XCTAssertTrue(refusal.contains("bbb22222"),refusal)
        XCTAssertTrue(refusal.contains("Update"),refusal)
        XCTAssertTrue(refusal.contains("before merging"),refusal)
        XCTAssertTrue(refusal.hasSuffix("Nothing was sent."),refusal)
    }
    func testOnlyActionsThatLandTheHeadAreGuarded() {
        // The Merge button (no requested action) merges or queues, per policy.
        XCTAssertTrue(PRDisplayedHead.guards(nil))
        XCTAssertTrue(PRDisplayedHead.guards(.direct))
        XCTAssertTrue(PRDisplayedHead.guards(.queue))
        XCTAssertTrue(PRDisplayedHead.guards(.enableAutoMerge))
        // Stopping an auto-merge or leaving the queue never lands the newer head; it may be exactly what a push calls for.
        XCTAssertFalse(PRDisplayedHead.guards(.disableAutoMerge))
        XCTAssertFalse(PRDisplayedHead.guards(.removeQueue))
        XCTAssertFalse(PRDisplayedHead.guards(.updateBranch))
    }
    func testReviewAndMergeActionsWaitForTheExplicitUpdate() {
        let model=PRDetailModel(pr:DetailFixtures.pr(head:"aaa111"),storage:TestDependencies.storage(),services:FakeDetailServices())
        XCTAssertFalse(model.actionsWaitForUpdate)
        model.pendingHead="bbb222"
        XCTAssertTrue(model.actionsWaitForUpdate)
        model.compose(.requestChanges);XCTAssertFalse(model.composing,"Request changes waits for Update")
        model.compose(.comment,selection:nil);XCTAssertFalse(model.composing,"Comment and Full review… wait for Update")
        model.openMerge(nil);XCTAssertFalse(model.merging,"Merge waits for Update")
        model.openMerge(.enableAutoMerge);XCTAssertFalse(model.merging,"auto-merge would land the newer head")
        XCTAssertFalse(model.canOpenMerge(nil));XCTAssertFalse(model.canOpenMerge(.queue))
        model.openMerge(.disableAutoMerge)
        XCTAssertTrue(model.merging);XCTAssertEqual(model.mergeAction,.disableAutoMerge)
        model.merging=false
        // The explicit Update: the window shows the new head, and actions act on it.
        model.show(DetailFixtures.pr(head:"bbb222"))
        XCTAssertFalse(model.actionsWaitForUpdate,"the pending head is the one on screen now")
        model.compose(.comment);XCTAssertTrue(model.composing)
        model.composing=false;model.pendingHead=nil
        model.openMerge(nil);XCTAssertTrue(model.merging);XCTAssertNil(model.mergeAction)
    }
}
