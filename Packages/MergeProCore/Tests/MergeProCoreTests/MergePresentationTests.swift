import XCTest
@testable import MergeProCore

final class MergePresentationTests: XCTestCase {
    private func key(_ account:String) -> ProviderKey { .init(host:"github.com",accountID:account,repositoryID:"1",objectID:"pull-request:P") }
    func testAccountReplacementRetiresEditorWhileSameAccountRefreshPreservesIt() {
        let a=key("A"),b=key("B")
        var state=MergeOptionsPresentationState()
        let loaded=state.begin(account:b.account);state.select(b,request:loaded)
        XCTAssertTrue(state.present(b,request:loaded,available:true))
        state.title="Private B title";state.message="Private B message"
        let same=state.begin(account:b.account);state.select(b,request:same)
        XCTAssertTrue(state.present(b,request:same,available:true));XCTAssertEqual(state.title,"Private B title")
        let replace=state.begin(account:a.account)
        XCTAssertEqual(state.title,"");XCTAssertEqual(state.message,"")
        XCTAssertFalse(state.canDisplay(b,available:true))
        state.select(a,request:replace)
        // B is now revoked while A's replacement load is suspended. Old B completion
        // must remain unable to publish even when availability later returns.
        XCTAssertFalse(state.accepts(b,request:same,available:false))
        XCTAssertFalse(state.accepts(b,request:same,available:true))
        XCTAssertTrue(state.present(a,request:replace,available:true))
        XCTAssertEqual(state.title,"");XCTAssertEqual(state.message,"")
        state.title="A";state.invalidate();XCTAssertEqual(state.title,"")
        XCTAssertFalse(state.accepts(a,request:replace,available:true))
    }
    func testHeldAggregateCannotPublishAfterAnyNewerComparisonChoice() {
        for choice in [PRComparisonPresentationState.Choice.comparison,.refresh,.canonical] {
            var state=PRComparisonPresentationState()
            let held=state.choose(.aggregate)
            let latest=state.choose(choice)
            XCTAssertFalse(state.accepts(held,available:true),"Old success/error must not overwrite the newer choice")
            XCTAssertTrue(state.accepts(latest,available:true))
            XCTAssertFalse(state.accepts(latest,available:false))
        }
    }
}
extension MergePresentationTests {
    func testCommitTextDefaultsAreHeadBoundAndRetiredWithTheEditor() {
        let b=key("B"),a=key("A")
        var evidence=MergeEvidence(key:b,head:"h1",base:"base",branch:"main",fetchedAt:Date())
        let defaults=MergeMessageDefaults(head:"h1",titles:[.squash:"PR (#1)",.merge:"Merge pull request #1 from o/f"],bodies:[.squash:"Body",.merge:"PR"],coAuthorTrailers:["Co-authored-by: Sam <sam@example.com>"])
        var state=MergeOptionsPresentationState()
        let request=state.begin(account:b.account);state.select(b,request:request)
        XCTAssertTrue(state.present(b,request:request,available:true))
        XCTAssertTrue(state.applyDefaults(defaults,method:.squash,evidence:evidence))
        XCTAssertEqual(state.title,"PR (#1)");XCTAssertEqual(state.message,"Body")
        XCTAssertNil(state.overrides(action:.direct).title,"Unedited prefill is never sent")
        state.message="Edited"
        XCTAssertTrue(state.applyDefaults(defaults,method:.merge,evidence:evidence))
        XCTAssertEqual(state.title,"Merge pull request #1 from o/f");XCTAssertEqual(state.message,"Edited")
        XCTAssertEqual(state.overrides(action:.direct).message,"Edited");XCTAssertNil(state.overrides(action:.queue).message)
        evidence=MergeEvidence(key:b,head:"h2",base:"base",branch:"main",fetchedAt:Date())
        XCTAssertTrue(state.applyDefaults(defaults,method:.squash,evidence:evidence))
        XCTAssertNil(state.text.defaults,"Prefill for an older head is discarded");XCTAssertEqual(state.title,"");XCTAssertEqual(state.message,"Edited")
        XCTAssertFalse(state.applyDefaults(defaults,method:.squash,evidence:MergeEvidence(key:a,head:"h1",base:"base",branch:"main",fetchedAt:Date())),"Another PR's prefill cannot enter this editor")
        _ = state.begin(account:a.account)
        XCTAssertNil(state.text.defaults);XCTAssertEqual(state.message,"");XCTAssertFalse(state.text.messageEdited)
    }
}
