import XCTest
@testable import MergeProCore
final class StackGraphTests:XCTestCase {
    func testStackExpansionIsIsolatedAcrossAccountsForTheSameGitHubPullRequests() throws {
        let a=pr("1","a","main"),b=pr("2","b","a")
        func otherAccount(_ row:PullRequest) -> PullRequest {
            .init(key:.init(host:row.key.host,accountID:"43",repositoryID:row.key.repositoryID,objectID:row.key.objectID),headRevision:row.headRevision,title:row.title,state:row.state,isDraft:row.isDraft,metadata:row.metadata)
        }
        let otherA=otherAccount(a),otherB=otherAccount(b),rows=[a,b,otherA,otherB]
        let projection=PRStackProjection(rows:rows)
        let stack=try XCTUnwrap(projection.stack(for:a.key))
        let expandedID=[a.key.host,a.key.accountID,a.key.repositoryID,stack.id].map { Data($0.utf8).base64EncodedString() }.joined(separator:"|")
        XCTAssertEqual(Set(StackGraph.visibleCards(rows,projection:projection,expanded:[expandedID]).map(\.key)),Set([a.key,b.key,otherA.key]))
    }
    func pr(_ id:String,_ head:String,_ base:String,_ state:PullRequest.State = .open) -> PullRequest {
        var m=PRMetadata(number:Int(id)!,webURL:URL(string:"https://github.com/o/r/pull/"+id)!,repositoryName:"o/r");m.headBranch=head;m.baseBranch=base;m.headRepositoryID="R"
        return .init(key:.init(host:"github.com",accountID:"42",repositoryID:"R",objectID:"pull-request:P"+id),headRevision:.init("sha"+id),title:id,state:state,isDraft:false,metadata:m)
    }
    func testInferredBottomUpClosedAmbiguousAndCycle() throws {
        let a=pr("1","a","main"),b=pr("2","b","a"),c=pr("3","c","b")
        let chain=try XCTUnwrap(StackGraph.inferred([c,a,b]).first)
        XCTAssertEqual(chain.layers.map(\.key),[a.key,b.key,c.key]);XCTAssertTrue(chain.warnings.isEmpty)
        XCTAssertEqual(try chain.affected(upTo:b.key).map(\.key),[a.key,b.key])
        XCTAssertFalse(StackGraph.inferred([a,pr("2","b","a",.closed),c])[0].warnings.isEmpty)
        XCTAssertFalse(StackGraph.inferred([a,b,pr("3","b","a")])[0].warnings.isEmpty)
        XCTAssertFalse(StackGraph.inferred([pr("1","a","b"),b])[0].warnings.isEmpty)
    }
    func testNativeMembershipPositionsAndAffectedOpenDownstack() throws {
        let a=pr("1","a","main",.merged),b=pr("2","b","main"),c=pr("3","c","main")
        let stack=StackGraph.native(id:"S1",number:8,size:3,entries:[.init(position:3,pr:c),.init(position:1,pr:a),.init(position:2,pr:b)],complete:true,linear:true)
        XCTAssertEqual(stack.kind,.native);XCTAssertEqual(try stack.affected(upTo:c.key).map(\.key),[b.key,c.key])
        XCTAssertEqual(stack.representative?.key,b.key)
        XCTAssertFalse(StackGraph.native(id:"S1",number:8,size:3,entries:[.init(position:1,pr:a),.init(position:1,pr:b)],complete:false,linear:nil).warnings.isEmpty)
    }
}

private actor BatchCalls { var keys:[ProviderKey]=[];func add(_ key:ProviderKey) { keys.append(key) } }
extension StackGraphTests {
    func testSerialBatchRetainsCompletedAndStopsAtPendingOrFailure() async throws {
        let prs=[pr("1","a","main"),pr("2","b","a"),pr("3","c","b")]
        let commands=try prs.map { pr -> MergeCommand in
            var evidence=MergeEvidence(key:pr.key,head:pr.headRevision.rawValue,base:"base",branch:"main",fetchedAt:Date());evidence.open=true;evidence.draft=false
            let inspection=MergeInspection(pr:pr,evidence:evidence)
            return try .init(selected:inspection,affected:[inspection],method:.squash,action:.direct)
        }
        let calls=BatchCalls()
        let progress=await StackMergeCoordinator.merge(commands,perform:{ command in
            await calls.add(command.pr)
            var result=PRWriteOperation(command:command.writeCommand)
            if command.target.number == 1 { result.state = .confirmed;result.mergeOutcome = .merged(commitSHA:"merged") }
            else { result.state = .uncertain;result.mergeOutcome = .pending(operationID:UUID().uuidString) }
            return result
        },progress:{ _ in })
        let keys=await calls.keys;XCTAssertEqual(keys,Array(prs.prefix(2)).map(\.key));XCTAssertEqual(progress.completed,[prs[0].key]);XCTAssertEqual(progress.remaining,Array(prs.suffix(2)).map(\.key));XCTAssertNotNil(progress.stopped)
    }
    func testNativeDequeueListsHigherAffectedLayersAndNoMergedLowerLayers() throws {
        let a=pr("1","a","main"),b=pr("2","b","main"),c=pr("3","c","main")
        let stack=StackGraph.native(id:"S",number:1,size:3,entries:[a,b,c].enumerated().map { .init(position:$0.offset+1,pr:$0.element) },complete:true,linear:true)
        XCTAssertEqual(try stack.affected(upTo:b.key,action:.removeQueue).map(\.key),[b.key,c.key])
        XCTAssertEqual(try stack.affected(upTo:b.key).map(\.key),[a.key,b.key])
    }
}

extension StackGraphTests {
    func testReversedSelectionOrdersDependenciesAndStopsBeforeMergingIntoLandedFeatureBranch() async throws {
        let a=pr("1","a","main"),b=pr("2","b","a")
        func command(_ row:PullRequest,base:String,branch:String) throws -> MergeCommand {
            let evidence=MergeEvidence(key:row.key,head:row.headRevision.rawValue,base:base,branch:branch,fetchedAt:Date())
            let read=MergeInspection(pr:row,evidence:evidence)
            return try .init(selected:read,affected:[read],method:.squash,action:.direct)
        }
        let lower=try command(a,base:"main-sha",branch:"main")
        var upper=try command(b,base:a.headRevision.rawValue,branch:"a")
        upper.inferredDependency = .init(parent:a.key,parentHead:a.headRevision.rawValue,parentBranch:"a",parentWasMerged:false,providerURL:b.metadata!.webURL)
        let calls=BatchCalls()
        let result=await StackMergeCoordinator.merge([upper,lower],perform:{ value in
            await calls.add(value.pr)
            var operation=PRWriteOperation(command:value.writeCommand)
            operation.state = .confirmed;operation.mergeOutcome = .merged(commitSHA:"landed")
            return operation
        },progress:{ _ in })
        let actual=await calls.keys
        XCTAssertEqual(actual,[a.key],"The selected upper still targets feature branch a after a lands; it must not be sent")
        XCTAssertEqual(result.completed,[a.key]);XCTAssertEqual(result.remaining,[b.key]);XCTAssertNotNil(result.stopped)
    }
}

extension StackGraphTests {
    func testGenericSelectionCapturesVerifiedDependenciesAndRejectsRetargetedIdentity() throws {
        let a=pr("1","a","main"),b=pr("2","b","a")
        func command(_ row:PullRequest,_ branch:String,_ base:String) throws -> MergeCommand {
            let evidence=MergeEvidence(key:row.key,head:row.headRevision.rawValue,base:base,branch:branch,fetchedAt:Date())
            let read=MergeInspection(pr:row,evidence:evidence)
            return try .init(selected:read,affected:[read],method:.squash,action:.direct)
        }
        let lower=try command(a,"main","base"),upper=try command(b,"a",a.headRevision.rawValue)
        let stack=try XCTUnwrap(StackGraph.inferred([b,a]).first)
        let captured=try StackMergeCoordinator.captureDependencies([upper,lower],stacks:[stack])
        XCTAssertEqual(captured.map(\.pr),[a.key,b.key])
        XCTAssertEqual(captured.last?.inferredDependency?.parent,a.key)
        XCTAssertEqual(captured.last?.inferredDependency?.parentHead,a.headRevision.rawValue)
        XCTAssertThrowsError(try StackMergeCoordinator.captureDependencies([try command(b,"main","new-base"),lower],stacks:[stack]))
        XCTAssertThrowsError(try StackMergeCoordinator.captureDependencies([try command(b,"a","old-parent-head"),lower],stacks:[stack]))
    }
}

extension StackGraphTests {
    func testCollapsedCardsNeverSubstituteAFilteredLayerAndAssignOneAuthorLane() throws {
        func authored(_ row:PullRequest,_ login:String) -> PullRequest {
            var metadata=row.metadata!;metadata.authorLogin=login
            return .init(key:row.key,headRevision:row.headRevision,title:row.title,state:row.state,isDraft:row.isDraft,metadata:metadata)
        }
        let lower=authored(pr("1","a","main"),"alice"),upper=authored(pr("2","b","a"),"bob")
        let stack=try XCTUnwrap(StackGraph.inferred([lower,upper]).first)
        // The lower layer is excluded by the caller's filter: it must not reappear.
        XCTAssertEqual(StackGraph.visibleCards([upper],stacks:[stack]).map(\.key),[upper.key])
        let cards=StackGraph.visibleCards([upper,lower],stacks:[stack])
        var view=PRViewConfiguration();view.timeScope = .allTime;view.grouping = .author
        let lanes=BoardProjection(rows:cards,view:view).lanes
        XCTAssertEqual(cards.map(\.key),[lower.key])
        XCTAssertEqual(lanes.keys.sorted(),["alice"])
        XCTAssertEqual(lanes.values.flatMap { $0 }.count,1)
        XCTAssertEqual(StackGraph.visibleCards([upper],stacks:[stack],expanded:[stack.id]).map(\.key),[upper.key])
    }
}
