import XCTest
@testable import MergeProCore

final class MergePolicyTests:XCTestCase {
    let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"R1",objectID:"pull-request:PR1")
    func testEligibilityTableRetainsOptionalFailureAndNoReviewRequired() {
        var base=MergeEvidence(key:key,head:"h",base:"b",branch:"main",fetchedAt:Date())
        base.open=true;base.draft=false;base.conflictFree=true;base.actorAllowed=true;base.tokenCanWrite=true
        base.rulesComplete=true;base.requirements=[.init(name:"checks",state:.satisfied)];base.methods=[.squash];base.asyncSupported=true
        let cases:[(String,(inout MergeEvidence)->Void,Bool)]=[
            ("no review required",{ _ in },true),("optional failing check",{ $0.optionalFailures=["lint"] },true),
            ("draft",{ $0.draft=true },false),("conflict",{ $0.conflictFree=false },false),
            ("missing review",{ $0.requirements=[.init(name:"reviews",state:.pending)] },false),
            ("missing check",{ $0.requirements=[.init(name:"required CI",state:.pending)] },false),
            ("unknown actor",{ $0.actorAllowed=nil },false),("denied actor",{ $0.actorAllowed=false },false),
            ("stale",{ $0.fetchedAt = .distantPast },false),("unknown rule",{ $0.rulesComplete=false },false),
            ("operation running",{ $0.operationInProgress=true },false),
            ("future auto merge",{ $0.autoMergeEnabled=true;$0.requirements=[.init(name:"CI",state:.pending)] },false)]
        for (name,change,wanted) in cases { var evidence=base;change(&evidence);XCTAssertEqual(MergePolicy.evaluate(evidence).eligible,wanted,name) }
        base.queueRequired=true;base.queueMethod = .squash;base.behind=true
        XCTAssertEqual(MergePolicy.evaluate(base).action,.queue,"Behind does not universally block queue admission")
    }
    func testRequiredCheckAppIdentityAndTestMergePrecedence() {
        let requirement=MergeCheckRequirement(context:"CI",appID:12)
        let checks=[MergeCheck(context:"CI",appID:12,sha:"head",state:"SUCCESS",kind:.check),MergeCheck(context:"CI",appID:12,sha:"test",state:"FAILURE",kind:.check)]
        XCTAssertEqual(MergePolicy.checkState(requirement,checks:checks,head:"head",testMerge:"test"),.pending)
        XCTAssertEqual(MergePolicy.checkState(requirement,checks:[.init(context:"CI",appID:13,sha:"head",state:"SUCCESS",kind:.check)],head:"head",testMerge:nil),.pending)
        for state in ["SUCCESS","NEUTRAL","SKIPPED"] { XCTAssertEqual(MergePolicy.checkState(requirement,checks:[.init(context:"CI",appID:12,sha:"head",state:state,kind:.check)],head:"head",testMerge:nil),.satisfied) }
    }
}

extension MergePolicyTests {
    func testReadinessTransitionUsesFreshAuthoritativeEvidenceAndInitialSilence() {
        func row(_ eligible:Bool,_ at:Date) -> PullRequest {
            var evidence=MergeEvidence(key:key,head:"h",base:"b",branch:"main",fetchedAt:at)
            evidence.open=true;evidence.draft=false;evidence.actorAllowed=true;evidence.tokenCanWrite=true;evidence.conflictFree=true;evidence.rulesComplete=true;evidence.asyncSupported=true;evidence.methods=[.squash];evidence.requirements=[.init(name:"reviews",state:eligible ? .satisfied : .pending)]
            var m=PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r");m.mergeEvidence=evidence
            return .init(key:key,headRevision:.init("h"),title:"PR",state:.open,isDraft:false,metadata:m)
        }
        let ready=row(true,Date()),blocked=row(false,Date().addingTimeInterval(-120))
        XCTAssertFalse(MergePolicy.becameReady(previous:nil,current:ready))
        XCTAssertTrue(MergePolicy.becameReady(previous:blocked,current:ready))
        XCTAssertFalse(MergePolicy.becameReady(previous:row(true,.distantPast),current:ready),"Expiry alone is not a false-to-true transition")
        XCTAssertFalse(MergePolicy.becameReady(previous:blocked,current:row(true,.distantPast)))
    }
}
extension MergePolicyTests {
    func testDraftAndCloseRequireCommandSpecificPermission() throws {
        let revision=PRWriteRevision(head:"h",origin:"o",target:"b")
        let truth=PRWriteTruth(key:key,revision:revision,viewerIsAuthor:false,canReview:true,canComment:true,canUpdate:true,canReopen:true,canLabel:true,isOpen:true)
        for intent:PRWriteIntent in [.metadata(.draft(true)),.metadata(.closed(true))] {
            let command=PRWriteCommand(key:key,repository:"o/r",number:1,revision:revision,intent:intent)
            XCTAssertThrowsError(try command.validate(truth:truth),"Generic viewerCanUpdate is not the command-specific admission evidence")
        }
    }
}
extension MergePolicyTests {
    private func evidence(_ change:(inout MergeEvidence)->Void) -> MergeEvidence {
        var e=MergeEvidence(key:key,head:"h",base:"b",branch:"main",fetchedAt:Date());e.methods=[.merge,.squash,.rebase];e.methodReasons=[:];change(&e);return e
    }
    func testMethodOptionsExplainRepositoryRulesetLinearAndQueueTrimming() {
        let trimmed=evidence { $0.methods=[.squash];$0.methodReasons=["merge":"Linear history required","rebase":"Not allowed by ruleset 'Main'"] }
        for action in [MergeAction.direct,.enableAutoMerge] {
            let options=MergePolicy.methodOptions(trimmed,action:action)
            XCTAssertEqual(options.map(\.method),[.merge,.squash,.rebase],"GitHub's order")
            XCTAssertEqual(options.map(\.enabled),[false,true,false])
            XCTAssertEqual(options.map(\.reason),["Linear history required",nil,"Not allowed by ruleset 'Main'"])
        }
        let settings=evidence { $0.methods=[.merge];$0.methodReasons=["squash":"Disabled in repository settings","rebase":"Disabled in repository settings"] }
        XCTAssertEqual(MergePolicy.methodOptions(settings,action:.direct).map(\.reason),[nil,"Disabled in repository settings","Disabled in repository settings"])
        var legacy=settings;legacy.methodReasons=nil
        XCTAssertEqual(MergePolicy.methodOptions(legacy,action:.direct).map(\.reason),[nil,"Not verified as allowed for this pull request.","Not verified as allowed for this pull request."])
        let queue=evidence { $0.queueRequired=true;$0.queueMethod = .squash;$0.methodReasons=["rebase":"Disabled in repository settings"];$0.methods=[.merge,.squash] }
        for action in [MergeAction.queue,.direct] {
            let options=MergePolicy.methodOptions(queue,action:action)
            XCTAssertEqual(options.map(\.enabled),[false,true,false],"Only the queue's method remains")
            XCTAssertEqual(options.map(\.reason),["Merge queue uses squash",nil,"Merge queue uses squash"])
            XCTAssertEqual(MergePolicy.evaluate(queue).methods,options.filter(\.enabled).map(\.method),"Same answer as the shared policy")
        }
        XCTAssertEqual(MergePolicy.methodOptions(queue,action:.enableAutoMerge).map(\.enabled),[true,true,false],"Auto-merge validates against the configured methods")
        let unknownQueue=evidence { $0.queueRequired=true }
        XCTAssertEqual(MergePolicy.methodOptions(unknownQueue,action:.queue).map(\.reason),Array(repeating:"Merge queue method is unknown.",count:3))
        for action in [MergeAction.disableAutoMerge,.removeQueue,.updateBranch] {
            XCTAssertTrue(MergePolicy.methodOptions(trimmed,action:action).allSatisfy { !$0.enabled && $0.reason == "Not used by this action." })
        }
        XCTAssertTrue(MergePolicy.methodOptions(nil,action:.direct).allSatisfy { !$0.enabled && $0.reason != nil })
        XCTAssertEqual(MergeMethodOption(method:.squash,enabled:true,reason:nil).label,"Squash and merge")
    }
    func testMethodReasonsAreExplanationNotAdmissionAndDecodeWhenMissing() throws {
        let a=evidence { $0.methodReasons=["rebase":"Not allowed by ruleset 'Old name'"] },b=evidence { $0.methodReasons=["rebase":"Not allowed by ruleset 'New name'"] }
        XCTAssertTrue(a.sameAdmission(as:b),"A renamed ruleset does not change the admission facts")
        XCTAssertFalse(a.sameAdmission(as:evidence { $0.methods=[.squash] }),"Methods remain admission facts")
        var payload=try JSONSerialization.jsonObject(with:JSONEncoder().encode(a)) as! [String:Any]
        payload.removeValue(forKey:"methodReasons")
        XCTAssertNil(try JSONDecoder().decode(MergeEvidence.self,from:JSONSerialization.data(withJSONObject:payload)).methodReasons)
    }
}
