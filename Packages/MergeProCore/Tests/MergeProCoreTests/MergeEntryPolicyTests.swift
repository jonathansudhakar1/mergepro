import XCTest
@testable import MergeProCore

/// Merge entry points open the sheet unless a known blocker exists; the sheet verifies before submitting.
final class MergeEntryPolicyTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    func key(_ id:String="1") -> ProviderKey { ProviderKey(host:"github.com",accountID:"42",repositoryID:"R1",objectID:"pull-request:PR"+id) }
    func evidence(_ id:String="1",at:Date,_ change:(inout MergeEvidence) -> Void = { _ in }) -> MergeEvidence {
        var e=MergeEvidence(key:key(id),head:"h"+id,base:"b",branch:"main",fetchedAt:at)
        e.open=true;e.draft=false;e.conflictFree=true;e.actorAllowed=true;e.tokenCanWrite=true;e.rulesComplete=true;e.asyncSupported=true;e.methods=[.squash]
        change(&e);return e
    }
    func row(_ id:String="1",state:PullRequest.State = .open,draft:Bool=false,evidence:MergeEvidence?=nil,_ change:(inout PRMetadata) -> Void = { _ in }) -> PullRequest {
        var m=PRMetadata(number:Int(id) ?? 1,webURL:URL(string:"https://github.com/o/r/pull/\(id)")!,repositoryName:"o/r")
        m.mergeEvidence=evidence;change(&m)
        return .init(key:key(id),headRevision:.init("h"+id),title:"PR \(id)",state:state,isDraft:draft,metadata:m)
    }

    func testStaleOrMissingEvidenceStillOpensMergeSheet() {
        let missing=MergePolicy.evaluate(pr:row(),now:now)
        XCTAssertFalse(missing.eligible)
        XCTAssertTrue(missing.opensMergeSheet,"Unknown evidence is verified in the sheet, not refused at the entry point")
        XCTAssertNil(missing.verifiedAt)
        XCTAssertFalse(missing.verifiedReady)

        let readAt=now.addingTimeInterval(-600)
        let stale=MergePolicy.evaluate(pr:row(evidence:evidence(at:readAt)),now:now)
        XCTAssertFalse(stale.eligible,"Evidence older than maximumAge is not submit evidence")
        XCTAssertTrue(stale.opensMergeSheet)
        XCTAssertEqual(stale.verifiedAt,readAt)
        XCTAssertTrue(stale.verifiedReady,"The last read found it ready")
        XCTAssertTrue(stale.blockers.isEmpty)

        let fresh=MergePolicy.evaluate(pr:row(evidence:evidence(at:now)),now:now)
        XCTAssertTrue(fresh.eligible);XCTAssertTrue(fresh.opensMergeSheet);XCTAssertTrue(fresh.verifiedReady)
    }

    func testPendingRequirementsAndUnknownFactsDoNotBlockOpeningSheet() {
        let pending=MergePolicy.evaluate(pr:row(evidence:evidence(at:now) { $0.requirements=[.init(name:"reviews",state:.pending)] }),now:now)
        XCTAssertFalse(pending.eligible)
        XCTAssertTrue(pending.opensMergeSheet,"The sheet offers auto-merge for pending requirements")
        XCTAssertFalse(pending.verifiedReady)
        let unknown=MergePolicy.evaluate(pr:row(evidence:evidence(at:now) { $0.actorAllowed=nil;$0.conflictFree=nil;$0.rulesComplete=false }),now:now)
        XCTAssertFalse(unknown.eligible)
        XCTAssertTrue(unknown.opensMergeSheet,"Unknown is not a known blocker")
    }

    func testKnownBlockersPreventOpeningSheet() {
        let cases:[(String,PullRequest,String)]=[
            ("closed",row(state:.closed),"Pull request is not open."),
            ("merged",row(state:.merged),"Pull request is not open."),
            ("draft",row(draft:true),"Pull request is draft."),
            ("inventory conflicts",row { $0.mergeable="CONFLICTING" },"Merge conflicts."),
            ("fresh evidence conflicts",row(evidence:evidence(at:now) { $0.conflictFree=false }),"Merge conflicts."),
            ("not permitted",row(evidence:evidence(at:now) { $0.actorAllowed=false }),"The active account is not permitted."),
            ("operation pending",row(evidence:evidence(at:now) { $0.operationInProgress=true }),"An action is pending reconciliation."),
        ]
        for (name,pr,blocker) in cases {
            let result=MergePolicy.evaluate(pr:pr,now:now)
            XCTAssertFalse(result.opensMergeSheet,name)
            XCTAssertTrue(result.blockers.contains(blocker),"\(name): \(result.blockers)")
            XCTAssertEqual(Set(result.blockers).count,result.blockers.count,"\(name): blockers are listed once")
        }
        let stalePermission=MergePolicy.evaluate(pr:row(evidence:evidence(at:now.addingTimeInterval(-3600)) { $0.actorAllowed=false }),now:now)
        XCTAssertTrue(stalePermission.opensMergeSheet,"Stale evidence is unknown now; the sheet reads again")
        XCTAssertFalse(stalePermission.verifiedReady)
    }

    func testEvidenceForAnotherHeadIsNotVerification() {
        var e=evidence(at:now);e=MergeEvidence(key:e.key,head:"old",base:e.base,branch:e.branch,fetchedAt:now)
        let result=MergePolicy.evaluate(pr:row(evidence:e),now:now)
        XCTAssertNil(result.verifiedAt)
        XCTAssertTrue(result.opensMergeSheet)
    }

    func testBatchPlanSkipsKnownBlockersWithReasonsAndKeepsTheRest() {
        let ready=row("1",evidence:evidence("1",at:now.addingTimeInterval(-900)))
        let unknown=row("2")
        let draft=row("3",draft:true)
        let closed=row("4",state:.closed)
        let plan=MergePolicy.batchPlan([ready,unknown,draft,closed]) { MergePolicy.evaluate(pr:$0,now:self.now) }
        XCTAssertEqual(plan.ready.map(\.key),[ready.key,unknown.key])
        XCTAssertEqual(plan.skipped.map(\.pr.key),[draft.key,closed.key])
        XCTAssertEqual(plan.skipped.map(\.reason),["Pull request is draft.","Pull request is not open."])
    }

    /// The "Ready to merge" rule uses inventory facts that don't expire with 60-second merge evidence.
    func testInventoryReadinessUsesNonExpiringSignals() {
        func ready(_ change:(inout PRMetadata) -> Void = { _ in }) -> PullRequest {
            row { $0.reviewDecision="APPROVED";$0.checks="SUCCESS";$0.mergeable="MERGEABLE";change(&$0) }
        }
        XCTAssertEqual(MergePolicy.inventoryReadiness(ready()),.ready)
        XCTAssertEqual(MergePolicy.inventoryReadiness(ready { $0.mergeEvidence=self.evidence(at:.distantPast) }),.ready,"Expired evidence does not matter")
        XCTAssertEqual(MergePolicy.inventoryReadiness(row(draft:true) { $0.reviewDecision="APPROVED";$0.checks="SUCCESS";$0.mergeable="MERGEABLE" }),.notReady)
        XCTAssertEqual(MergePolicy.inventoryReadiness(row(state:.merged) { $0.reviewDecision="APPROVED";$0.checks="SUCCESS";$0.mergeable="MERGEABLE" }),.notReady)
        XCTAssertEqual(MergePolicy.inventoryReadiness(ready { $0.reviewDecision="CHANGES_REQUESTED" }),.notReady)
        XCTAssertEqual(MergePolicy.inventoryReadiness(ready { $0.reviewDecision="REVIEW_REQUIRED" }),.notReady)
        XCTAssertEqual(MergePolicy.inventoryReadiness(ready { $0.checks="FAILURE" }),.notReady)
        XCTAssertEqual(MergePolicy.inventoryReadiness(ready { $0.checks="PENDING" }),.notReady)
        XCTAssertEqual(MergePolicy.inventoryReadiness(ready { $0.failingRequiredCheck=true }),.notReady)
        XCTAssertEqual(MergePolicy.inventoryReadiness(ready { $0.mergeable="CONFLICTING" }),.notReady)
        XCTAssertEqual(MergePolicy.inventoryReadiness(ready { $0.checks=nil }),.unknown,"No check rollup is unknown, not passing")
        XCTAssertEqual(MergePolicy.inventoryReadiness(ready { $0.mergeable="UNKNOWN" }),.unknown)
        XCTAssertEqual(MergePolicy.inventoryReadiness(ready { $0.reviewDecision=nil }),.unknown)
        XCTAssertEqual(MergePolicy.inventoryReadiness(ready { $0.reviewDecision=nil;$0.reviewEvidenceComplete=true;$0.requiredReviewCount=0;$0.approvalCount=1;$0.outstandingChanges=false }),.ready,"Complete no-required-review approval counts as approved")
    }

    func testBuiltInReadyToMergeViewKeepsReadyRowsWithExpiredEvidence() throws {
        let view=try XCTUnwrap(PRViewState().views.first { $0.name == "Ready to merge" })
        let readyRow=row("1",evidence:evidence("1",at:now.addingTimeInterval(-7200))) { $0.reviewDecision="APPROVED";$0.checks="SUCCESS";$0.mergeable="MERGEABLE";$0.updatedAt=self.now }
        let failing=row("2") { $0.reviewDecision="APPROVED";$0.checks="FAILURE";$0.mergeable="MERGEABLE";$0.updatedAt=self.now }
        let rows=BoardProjection(rows:[readyRow,failing],view:view.configuration,now:now).rows
        XCTAssertEqual(rows.map(\.key),[readyRow.key])
        XCTAssertTrue(try FilterExpression.parse("ready:false").matches(failing,now:now))
        XCTAssertTrue(try FilterExpression.parse("ready:unknown").matches(row("3"),now:now))
        XCTAssertEqual(try FilterExpression.parse("ready:true").serialized,"ready:\"true\"")
    }

    func testLegacyReadyToMergeViewMigratesToInventoryRule() throws {
        var state=PRViewState()
        let index=try XCTUnwrap(state.views.firstIndex { $0.name == "Ready to merge" })
        state.views[index].configuration.filter=try FilterExpression.parse("eligible:true")
        state.currentViewID=state.views[index].id;state.current=state.views[index].configuration
        var custom=PRSavedView(name:"Mine");custom.configuration.filter=try FilterExpression.parse("eligible:true")
        state.views.append(custom)
        XCTAssertTrue(state.migrateLegacyBuiltins())
        XCTAssertEqual(state.views[index].configuration.filter,try FilterExpression.parse("ready:true"))
        XCTAssertEqual(state.current.filter,try FilterExpression.parse("ready:true"))
        XCTAssertEqual(state.views.last?.configuration.filter,try FilterExpression.parse("eligible:true"),"A user's own view is not rewritten")
        XCTAssertFalse(state.migrateLegacyBuiltins())
    }
}
