import XCTest
@testable import MergeProCore

/// Cards, table rows, menus, the menu bar and notifications offer the same actions for the same rows and account,
/// and merge verification stays true as its evidence ages.
final class ActionSurfaceAgreementTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    func row(_ account:String="42",_ id:String="1",state:PullRequest.State = .open,author:Bool=false,_ change:(inout PRMetadata) -> Void = { _ in }) -> PullRequest {
        var m=PRMetadata(number:Int(id) ?? 1,webURL:URL(string:"https://github.com/o/r/pull/\(id)")!,repositoryName:"o/r")
        m.viewerIsAuthor=author;change(&m)
        return .init(key:ProviderKey(host:"github.com",accountID:account,repositoryID:"R1",objectID:"pull-request:PR"+id),headRevision:.init("h"+id),title:"PR \(id)",state:state,isDraft:false,metadata:m)
    }
    /// Complete, satisfied evidence read at `fetchedAt`, optionally queued (a blocker while fresh).
    func evidence(for pr:PullRequest,at fetchedAt:Date,queued:Bool=false) -> MergeEvidence {
        var e=MergeEvidence(key:pr.key,head:pr.headRevision.rawValue,base:"b",branch:"main",fetchedAt:fetchedAt)
        e.open=true;e.draft=false;e.conflictFree=true;e.actorAllowed=true;e.tokenCanWrite=true;e.rulesComplete=true;e.asyncSupported=true;e.methods=[.squash]
        e.queued=queued
        return e
    }

    // MARK: Account scoping

    func testMenuBarAndInboxMergeActOnlyAsTheRowsOwnAccount() {
        let mine=row("42")
        XCTAssertEqual(PRMenuBarRules.mergeRoute(row:mine,actionPR:mine),.mergeSheet)
        XCTAssertEqual(PRMenuBarRules.mergeRoute(row:mine,actionPR:nil),.openPullRequest,"the action account has not read this row")
        XCTAssertEqual(PRMenuBarRules.mergeRoute(row:mine,actionPR:row("77")),.openPullRequest,"another account's copy would act")
        XCTAssertTrue(PRMenuBarRules.actsAsRowAccount(row:mine,actionPR:mine))
        XCTAssertFalse(PRMenuBarRules.actsAsRowAccount(row:mine,actionPR:row("42","2")),"a different pull request")
    }

    func testNotificationApproveFollowsTheMenuBarRuleAtResponseTime() {
        let other=row("42")
        XCTAssertEqual(NotificationApproval.route(approve:true,row:nil,actionPR:nil),.activity,"not cached: its activity opens")
        XCTAssertEqual(NotificationApproval.route(approve:true,row:other,actionPR:other),.approve)
        XCTAssertEqual(NotificationApproval.route(approve:false,row:other,actionPR:other),.openPullRequest)
        XCTAssertEqual(NotificationApproval.route(approve:true,row:other,actionPR:nil),.openPullRequest,"the action account has no copy")
        XCTAssertEqual(NotificationApproval.route(approve:true,row:other,actionPR:row("77")),.openPullRequest,"another account's composer would act")
        let own=row("42",author:true)
        XCTAssertEqual(NotificationApproval.route(approve:true,row:own,actionPR:own),.openPullRequest,"GitHub refuses approving your own pull request")
        let closed=row("42",state:.closed)
        XCTAssertEqual(NotificationApproval.route(approve:true,row:closed,actionPR:closed),.openPullRequest)
    }

    func testNotificationCategoryOffersApproveOnlyWhenTheRuleAllows() throws {
        let pr=row("42")
        func event(_ category:String) -> ChangeEvent {
            ChangeEvent(key:"42:R1:1:"+category,object:pr.key,category:category,occurredAt:now,title:"T",
                        locator:EventLocator(subjectType:"PullRequest",subjectNumber:"1",webURL:URL(string:"https://github.com/o/r/pull/1")))
        }
        let item=try XCTUnwrap(NotificationAggregator.summary(cycleID:UUID(),events:[event("review requested")]).items.first)
        XCTAssertTrue(item.offersReview)
        XCTAssertTrue(item.offersApproval(row:pr,actionPR:pr))
        XCTAssertFalse(item.offersApproval(row:nil,actionPR:nil),"not cached: Open and Snooze only")
        XCTAssertFalse(item.offersApproval(row:pr,actionPR:row("77")),"another account would act")
        XCTAssertFalse(item.offersApproval(row:row("42",author:true),actionPR:row("42",author:true)),"own pull request")
        XCTAssertFalse(item.offersApproval(row:row("42","2"),actionPR:row("42","2")),"a different pull request's row")
        let merged=try XCTUnwrap(NotificationAggregator.summary(cycleID:UUID(),events:[event("merged")]).items.first)
        XCTAssertFalse(merged.offersApproval(row:pr,actionPR:pr),"merged in this cycle")
    }

    // MARK: Selection

    func testCommandsNeverActOnARowDeselectedInTheList() {
        let a=row("42","1").key,b=row("42","2").key,c=row("42","3").key
        let order=[a,b,c]
        // ⌘-clicking the only selected row leaves focus on it and the selection empty.
        let emptied=PRSelection(focused:a,selected:[])
        XCTAssertEqual(emptied.commandKeys(order:order,visibleFocus:a,selectionOnly:true),[],"the list acts on nothing")
        XCTAssertEqual(emptied.commandKeys(order:order,visibleFocus:a,selectionOnly:false),[a],"the board acts on the focused card")
        // ⌘-clicking one of two selected rows leaves focus on the deselected one.
        let one=PRSelection(focused:b,selected:[a])
        XCTAssertEqual(one.commandKeys(order:order,visibleFocus:b,selectionOnly:true),[a])
        XCTAssertEqual(one.commandKeys(order:order,visibleFocus:b,selectionOnly:false),[b],"board j/k focus without selecting")
        let several=PRSelection(focused:a,selected:[c,a])
        XCTAssertEqual(several.commandKeys(order:order,visibleFocus:a,selectionOnly:true),[a,c],"display order")
        XCTAssertEqual(several.commandKeys(order:order,visibleFocus:a,selectionOnly:false),[a,c])
        XCTAssertEqual(PRSelection(focused:nil,selected:[b]).commandKeys(order:order,visibleFocus:nil,selectionOnly:false),[b])
        XCTAssertEqual(PRSelection(focused:a,selected:[b]).commandKeys(order:[a],visibleFocus:a,selectionOnly:true),[],"a filtered-out selection is not acted on")
    }

    // MARK: Evidence age

    func testABlockerFromFreshEvidenceStopsCountingExactlyWhenItGoesStale() throws {
        let base=row("42")
        let read=now.addingTimeInterval(-30)
        let pr=row("42") { $0.mergeEvidence=self.evidence(for:base,at:read,queued:true) }
        let current=MergePolicy.evaluate(pr:pr,now:now)
        XCTAssertFalse(current.opensMergeSheet,"queued is a known blocker while fresh")
        let change=try XCTUnwrap(current.evidenceChange(after:now))
        XCTAssertEqual(change.timeIntervalSince(read),MergePolicy.maximumAge,accuracy:0.001)
        XCTAssertFalse(MergePolicy.evaluate(pr:pr,now:read.addingTimeInterval(MergePolicy.maximumAge)).opensMergeSheet,"still fresh at the limit")
        let later=MergePolicy.evaluate(pr:pr,now:change)
        XCTAssertTrue(later.opensMergeSheet,"stale evidence never blocks; the sheet reads GitHub again")
        XCTAssertNil(later.evidenceChange(after:change),"stale evidence changes no further")
        XCTAssertNil(MergePolicy.evaluate(pr:base,now:now).evidenceChange(after:now),"no evidence, nothing to refresh")
        XCTAssertNil(MergePolicy.unverified(base).evidenceChange(after:now))
    }

    func testEvidenceStampedAheadOfTheClockBecomesFreshThenStale() throws {
        let base=row("42")
        let read=now.addingTimeInterval(20)
        let pr=row("42") { $0.mergeEvidence=self.evidence(for:base,at:read,queued:true) }
        let early=MergePolicy.evaluate(pr:pr,now:now)
        XCTAssertTrue(early.opensMergeSheet,"not yet fresh")
        let fresh=try XCTUnwrap(early.evidenceChange(after:now))
        XCTAssertEqual(fresh,read.addingTimeInterval(-5))
        XCTAssertFalse(MergePolicy.evaluate(pr:pr,now:fresh).opensMergeSheet)
        let soonest=MergeEligibility.nextEvidenceChange([early,MergePolicy.evaluate(pr:base,now:now),MergePolicy.evaluate(pr:row("42") { $0.mergeEvidence=self.evidence(for:base,at:self.now) },now:now)],after:now)
        XCTAssertEqual(soonest,fresh,"the earliest change among cards")
    }

    func testAgeWordingIsRefreshedEachMinuteThenHourlyThenDaily() {
        let read=now
        XCTAssertEqual(PRStatusSummary.nextAgeChange(after:read,verifiedAt:read),read.addingTimeInterval(60),"\"just now\" ends after a minute")
        XCTAssertEqual(PRStatusSummary.nextAgeChange(after:read.addingTimeInterval(59),verifiedAt:read),read.addingTimeInterval(60))
        XCTAssertEqual(PRStatusSummary.nextAgeChange(after:read.addingTimeInterval(60),verifiedAt:read),read.addingTimeInterval(120))
        XCTAssertEqual(PRStatusSummary.nextAgeChange(after:read.addingTimeInterval(3_000),verifiedAt:read),read.addingTimeInterval(3_060))
        XCTAssertEqual(PRStatusSummary.nextAgeChange(after:read.addingTimeInterval(3_600),verifiedAt:read),read.addingTimeInterval(7_200),"hourly after an hour")
        XCTAssertEqual(PRStatusSummary.nextAgeChange(after:read.addingTimeInterval(90_000),verifiedAt:read),read.addingTimeInterval(172_800),"daily after a day")
        XCTAssertEqual(PRStatusSummary.nextAgeChange(after:read.addingTimeInterval(-20),verifiedAt:read),read.addingTimeInterval(60),"a read stamped ahead of the clock")
        // The wording really is the same until the next mark.
        let ready=MergePolicy.evaluate(pr:row("42") { $0.mergeEvidence=self.evidence(for:self.row("42"),at:read) },now:read)
        XCTAssertEqual(PRStatusSummary.merge(ready,now:read.addingTimeInterval(59.9)).text,"Verified ready · just now")
        XCTAssertNotEqual(PRStatusSummary.merge(ready,now:read.addingTimeInterval(60)).text,"Verified ready · just now")
    }

    func testMergeColumnUsesTheGivenEligibilityAndItsAge() {
        let base=row("42")
        let ready=MergePolicy.evaluate(pr:row("42") { $0.mergeEvidence=self.evidence(for:base,at:self.now);$0.mergeable="MERGEABLE" },now:now)
        XCTAssertEqual(PRStatusSummary.mergeColumn(ready,mergeable:"MERGEABLE",now:now),.init(tone:.passing,text:"Verified ready · just now"))
        let aged=PRStatusSummary.mergeColumn(ready,mergeable:"MERGEABLE",now:now.addingTimeInterval(180))
        XCTAssertEqual(aged.tone,.passing)
        XCTAssertNotEqual(aged.text,"Verified ready · just now","the same eligibility reads its age at render time")
        let unverified=MergePolicy.unverified(base)
        XCTAssertEqual(PRStatusSummary.mergeColumn(unverified,mergeable:"MERGEABLE",now:now),.init(tone:.passing,text:"No conflicts · Not verified"))
        XCTAssertEqual(PRStatusSummary.mergeColumn(unverified,mergeable:nil,now:now),.init(tone:.unknown,text:"Not verified"))
        let blocked=MergePolicy.evaluate(pr:row("42") { $0.mergeEvidence=self.evidence(for:base,at:self.now,queued:true) },now:now)
        XCTAssertEqual(PRStatusSummary.mergeColumn(blocked,mergeable:"MERGEABLE",now:now),.init(tone:.failing,text:"Already in merge queue."))
    }
}
