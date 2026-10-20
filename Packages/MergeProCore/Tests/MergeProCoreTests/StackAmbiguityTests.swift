import XCTest
@testable import MergeProCore

/// The common "deploy" pattern (many main → deploy PRs) makes every PR into main an ambiguous inferred
/// layer. Ambiguous inferred stacks must not collapse the board: each PR stays its own card, while the
/// stack and its warning stay available for card annotations and the detail sidebar.
final class StackAmbiguityTests: XCTestCase {
    func pr(_ n:Int,_ head:String,_ base:String,_ state:PullRequest.State = .open,repo:String = "R") -> PullRequest {
        var m=PRMetadata(number:n,webURL:URL(string:"https://github.com/o/\(repo)/pull/\(n)")!,repositoryName:"o/\(repo)")
        m.headBranch=head;m.baseBranch=base;m.headRepositoryID=repo
        m.updatedAt=Date(timeIntervalSince1970:1_800_000_000-Double(n));m.createdAt=m.updatedAt
        return .init(key:.init(host:"github.com",accountID:"42",repositoryID:repo,objectID:"pull-request:P\(n)"),headRevision:.init("sha\(n)"),title:"PR \(n)",state:state,isDraft:false,metadata:m)
    }
    /// Two releases from main into deploy plus three independent features into main.
    func deployRows() -> [PullRequest] {
        [pr(1,"main","deploy",.merged),pr(2,"main","deploy"),pr(3,"feature/a","main"),pr(4,"feature/b","main"),pr(5,"feature/c","main")]
    }
    func testDeployPatternIsOneAmbiguousInferredStack() throws {
        let rows=deployRows()
        let stacks=StackGraph.inferred(rows)
        XCTAssertEqual(stacks.count,1)
        let stack=try XCTUnwrap(stacks.first)
        XCTAssertEqual(stack.layers.count,rows.count)
        XCTAssertTrue(stack.warnings.contains(PRStack.ambiguousChainWarning))
        XCTAssertTrue(stack.isAmbiguousChain)
    }
    func testAmbiguousInferredStackKeepsEveryPRAsItsOwnCard() {
        let rows=deployRows()
        let projection=PRStackProjection(rows:rows)
        XCTAssertEqual(StackGraph.visibleCards(rows,projection:projection).map(\.key),rows.map(\.key))
        XCTAssertEqual(StackGraph.visibleCards(rows,stacks:projection.stacks).map(\.key),rows.map(\.key))
        // Expansion state is irrelevant for a stack that never collapses.
        XCTAssertEqual(StackGraph.visibleCards(rows,projection:projection,expanded:Set(projection.stacks.map(\.id))).map(\.key),rows.map(\.key))
    }
    func testAmbiguousWarningRemainsAvailableForEveryCard() throws {
        let rows=deployRows()
        let projection=PRStackProjection(rows:rows)
        for row in rows {
            let stack=try XCTUnwrap(projection.stack(for:row.key),"#\(row.metadata!.number)")
            XCTAssertTrue(stack.warnings.contains(PRStack.ambiguousChainWarning))
        }
    }
    func testBoardLayoutShowsAmbiguousLayersAsSeparateCards() {
        let rows=deployRows()
        var pipeline=PRBoardPipeline()
        pipeline.update(rows:rows)
        var view=PRViewConfiguration();view.timeScope = .allTime;view.mergedDays=36500
        let layout=pipeline.layout(view:view,now:Date(timeIntervalSince1970:1_800_000_000))
        XCTAssertEqual(Set(layout.cards.rows.map(\.key)),Set(layout.projection.rows.map(\.key)))
        XCTAssertEqual(layout.cards.rows.count,layout.projection.rows.count)
        XCTAssertEqual(Set(layout.navigationKeys),Set(layout.projection.rows.map(\.key)))
    }
    func testUnambiguousChainStillCollapsesNextToAnAmbiguousComponent() throws {
        // Same repository: the deploy component is ambiguous, the a → b → c chain is not.
        let a=pr(10,"a","trunk"),b=pr(11,"b","a"),c=pr(12,"c","b")
        let rows=deployRows()+[a,b,c]
        let projection=PRStackProjection(rows:rows)
        let chain=try XCTUnwrap(projection.stack(for:b.key))
        XCTAssertFalse(chain.isAmbiguousChain)
        XCTAssertTrue(chain.warnings.isEmpty)
        let cards=StackGraph.visibleCards(rows,projection:projection).map(\.key)
        XCTAssertEqual(cards,deployRows().map(\.key)+[a.key])
        XCTAssertEqual(StackGraph.visibleCards(rows,projection:projection,expanded:[chain.id]).map(\.key),rows.map(\.key))
    }
    func testNativeStacksWithWarningsStillCollapse() {
        let a=pr(1,"a","main"),b=pr(2,"b","main")
        let stack=StackGraph.native(id:"S",number:1,size:3,entries:[.init(position:1,pr:a),.init(position:2,pr:b)],complete:false,linear:nil)
        XCTAssertFalse(stack.warnings.isEmpty)
        XCTAssertFalse(stack.isAmbiguousChain)
        XCTAssertEqual(StackGraph.visibleCards([a,b],stacks:[stack]).map(\.key),[a.key])
    }
    func testScaledDeployPatternKeepsEveryVisiblePRAsACard() {
        var rows:[PullRequest]=[],n=0
        for i in 0..<40 { n += 1;rows.append(pr(n,"main","deploy",i == 39 ? .open : .merged)) }
        for i in 0..<200 { n += 1;rows.append(pr(n,"feature/\(i)","main",i % 3 == 0 ? .merged : .open)) }
        let projection=PRStackProjection(rows:rows)
        XCTAssertEqual(projection.stacks.count,1)
        XCTAssertEqual(StackGraph.visibleCards(rows,projection:projection).count,rows.count)
    }
}
