import MergeProCore
import XCTest
@testable import MergePro

/// What VoiceOver hears after a merge sheet action: every outcome, not only "merged".
final class MergeAnnouncementTests:XCTestCase {
    func testOutcomesAreAnnouncedWithThePullRequest() {
        XCTAssertEqual(MergeOptionsSheet.outcomeAnnouncement(.queued,state:.confirmed,message:nil,action:.queue,number:12),"Pull request #12: Added to the merge queue")
        XCTAssertEqual(MergeOptionsSheet.outcomeAnnouncement(.autoMergeEnabled,state:.confirmed,message:nil,action:.enableAutoMerge,number:12),"Pull request #12: Auto-merge enabled")
        XCTAssertEqual(MergeOptionsSheet.outcomeAnnouncement(.autoMergeDisabled,state:.confirmed,message:nil,action:.disableAutoMerge,number:12),"Pull request #12: Auto-merge disabled")
        XCTAssertEqual(MergeOptionsSheet.outcomeAnnouncement(.queueRemoved,state:.confirmed,message:nil,action:.removeQueue,number:12),"Pull request #12: Removed from the merge queue")
        XCTAssertEqual(MergeOptionsSheet.outcomeAnnouncement(.merged(commitSHA:"0123456789abcdef"),state:.confirmed,message:nil,action:.direct,number:12),"Pull request #12: Merged as 0123456")
        XCTAssertEqual(MergeOptionsSheet.outcomeAnnouncement(.failed(reason:"Required checks are failing."),state:.rejected,message:nil,action:.direct,number:12),"Pull request #12: Not merged: Required checks are failing.")
    }
    func testUnknownOutcomesNameTheActionAndStayExplicit() {
        XCTAssertEqual(MergeOptionsSheet.outcomeAnnouncement(nil,state:.uncertain,message:nil,action:.enableAutoMerge,number:7),"Pull request #7: Enable auto-merge — Outcome unknown")
        XCTAssertEqual(MergeOptionsSheet.outcomeAnnouncement(nil,state:.sending,message:"Waiting for GitHub",action:.queue,number:7),"Pull request #7: Add to merge queue — Still sending. Waiting for GitHub")
        XCTAssertEqual(MergeOptionsSheet.outcomeAnnouncement(.pending(operationID:"op"),state:.sending,message:nil,action:.direct,number:nil),"Merge requested; GitHub is still processing it")
    }
    func testFailuresBeforeAnyOutcomeAreAnnounced() {
        XCTAssertEqual(MergeOptionsSheet.failureAnnouncement(MergeOptionsSheet.actionName(.queue)+" failed",number:12,reason:"The network connection was lost."),"Pull request #12: Add to merge queue failed. The network connection was lost.")
        XCTAssertEqual(MergeOptionsSheet.failureAnnouncement("Reading the provider result failed",number:nil,reason:"Unavailable."),"Reading the provider result failed. Unavailable.")
    }
}
