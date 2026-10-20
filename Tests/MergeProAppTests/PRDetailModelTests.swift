import MergeProCore
import XCTest
@testable import MergePro

/// The PR window's state transitions with scripted services: stale results, load errors, the explicit Update and
/// Next/Previous navigation. No view, storage or network is involved.
@MainActor final class PRDetailModelTests:XCTestCase {
    private func model(_ pr:PullRequest,_ services:FakeDetailServices,link:PRDetailWorkspaceLink = .init()) -> PRDetailModel {
        let model=PRDetailModel(pr:pr,storage:SetupStorage(),services:services,link:link)
        model.tab = .files
        return model
    }

    // MARK: Stale results

    func testDetailForAnOlderHeadIsDroppedOnceTheWindowMovesToANewHead() async {
        let services=FakeDetailServices(),gate=TestGate()
        await services.script(head:"aaa111",snapshot:DetailFixtures.snapshot(head:"aaa111",files:["Sources/Old.swift"]),gate:gate)
        await services.script(head:"bbb222",snapshot:DetailFixtures.snapshot(head:"bbb222",files:["Sources/New.swift"]))
        let model=model(DetailFixtures.pr(head:"aaa111"),services)
        let older=Task { await model.load() }
        await gate.arrived()
        model.show(DetailFixtures.pr(head:"bbb222"))
        let newer=await model.load()
        await gate.open()
        let late=await older.value
        XCTAssertTrue(newer)
        XCTAssertFalse(late,"the older head's result arrives after the newer load began")
        XCTAssertEqual(model.detail?.headSHA,"bbb222")
        XCTAssertEqual(model.description?.headSHA,"bbb222")
        XCTAssertEqual(model.selectedFile,"Sources/New.swift","the stale inventory never chose the file")
        XCTAssertFalse(model.loading,"the stale load doesn't own the spinner")
        XCTAssertNil(model.loadError)
    }
    func testStaleFailureDoesNotReplaceTheNewerLoadsResult() async {
        let services=FakeDetailServices(),gate=TestGate()
        await services.script(head:"aaa111",failure:PRDetailFailure.unavailable,gate:gate)
        await services.script(head:"bbb222",snapshot:DetailFixtures.snapshot(head:"bbb222",files:["a.swift"]))
        let model=model(DetailFixtures.pr(head:"aaa111"),services)
        let older=Task { await model.load() }
        await gate.arrived()
        model.show(DetailFixtures.pr(head:"bbb222"))
        await model.load()
        await gate.open();_ = await older.value
        XCTAssertNil(model.loadError,"a failure for a superseded head is not this window's failure")
        XCTAssertEqual(model.detail?.headSHA,"bbb222")
    }
    func testComparisonInFlightIsDroppedByAnExplicitRefresh() async {
        let services=FakeDetailServices(),gate=TestGate()
        let compared=DiffDocument(baseSHA:"c1",headSHA:"c2",files:[DetailFixtures.file("z.swift")],expectedFiles:1)
        await services.scriptComparison(base:"c1",document:compared,gate:gate)
        let model=model(DetailFixtures.pr(head:"aaa111"),services)
        model.tab = .commits;model.compareBase="c1";model.compareHead="c2"
        model.startComparison(snapshots:false)
        let request=try! XCTUnwrap(model.compareRequest)
        let running=Task { await model.compare(request:request) }
        await gate.arrived()
        model.refreshDetail()
        await gate.open();await running.value
        XCTAssertNil(model.comparison,"Refresh chose the canonical diff; the late comparison must not replace it")
        XCTAssertEqual(model.tab,.commits)
        XCTAssertNil(model.compareRequest)
        // A current comparison applies and opens Files on its first file.
        model.startComparison(snapshots:false)
        await model.compare(request:try! XCTUnwrap(model.compareRequest))
        XCTAssertEqual(model.comparison?.headSHA,"c2")
        XCTAssertEqual(model.tab,.files)
        XCTAssertEqual(model.selectedFile,"z.swift")
        model.returnToCanonical()
        XCTAssertNil(model.comparison)
    }

    // MARK: Load errors

    func testLoadErrorIsClearedWhenTheNextLoadStarts() async {
        let services=FakeDetailServices(),gate=TestGate()
        await services.script(head:"aaa111",failure:PRDetailFailure.unavailable)
        let model=model(DetailFixtures.pr(head:"aaa111"),services)
        let failed=await model.load()
        XCTAssertFalse(failed)
        XCTAssertEqual(model.loadError,"Detail unavailable. Reconnect or open this pull request on GitHub.")
        XCTAssertFalse(model.loading)
        await services.script(head:"aaa111",snapshot:DetailFixtures.snapshot(head:"aaa111",files:["a.swift"]),gate:gate)
        model.refreshDetail()
        let retry=Task { await model.load() }
        await gate.arrived()
        XCTAssertNil(model.loadError,"the old failure is gone as soon as the retry starts")
        XCTAssertTrue(model.loading)
        await gate.open()
        let loaded=await retry.value
        XCTAssertTrue(loaded)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.detail?.headSHA,"aaa111")
    }
    func testMovedHeadKeepsTheDiffWhenTheWorkspaceAlreadyListsTheNewerHead() async {
        let services=FakeDetailServices()
        await services.script(head:"aaa111",snapshot:DetailFixtures.snapshot(head:"aaa111",files:["a.swift"]))
        var listed=RevisionID("aaa111")
        let model=model(DetailFixtures.pr(head:"aaa111"),services,link:.init(listedHead:{ _ in listed }))
        await model.load()
        // GitHub moved on; the workspace already knows, so the Update banner explains instead of an error.
        listed=RevisionID("bbb222")
        await services.script(head:"aaa111",failure:PRDetailFailure.revisionChanged)
        model.refreshDetail();await model.load()
        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.detail?.headSHA,"aaa111","what's on screen stays until the explicit Update")
        // Unknown to the workspace: the window says so and drops the stale diff.
        listed=RevisionID("aaa111")
        model.refreshDetail();await model.load()
        XCTAssertEqual(model.loadError,"The pull request changed on GitHub. Refresh the workspace before reviewing.")
        XCTAssertNil(model.detail)
    }
    func testUnavailableWorkspaceRowSuppressesLoadErrors() async {
        let services=FakeDetailServices()
        await services.script(head:"aaa111",failure:PRDetailFailure.unavailable)
        let model=model(DetailFixtures.pr(head:"aaa111"),services,link:.init(available:{ _ in false }))
        await model.load()
        XCTAssertNil(model.loadError,"a window whose account went away shows its unavailable state, not a load error")
    }

    // MARK: New commits — Update

    func testNewHeadAppliesOnlyThroughTheExplicitUpdate() {
        var state=PRDetailRouteState()
        let opened=DetailFixtures.pr(head:"aaa111"),relabeled=DetailFixtures.pr(head:"aaa111",title:"Improve caching (v2)"),pushed=DetailFixtures.pr(head:"bbb222",title:"Improve caching (v2)")
        state.adopt(opened)
        XCTAssertEqual(state.display(opened),opened)
        XCTAssertNil(state.pendingHead(opened))
        // Same head: metadata changes show at once.
        state.adopt(relabeled)
        XCTAssertEqual(state.display(relabeled).title,"Improve caching (v2)")
        XCTAssertNil(state.pendingHead(relabeled))
        // A push is held back, however many times the workspace polls it.
        state.adopt(pushed);state.adopt(pushed)
        XCTAssertEqual(state.display(pushed).headRevision.rawValue,"aaa111")
        XCTAssertEqual(state.pendingHead(pushed),"bbb222")
        state.applyUpdate(pushed)
        XCTAssertEqual(state.display(pushed),pushed)
        XCTAssertNil(state.pendingHead(pushed))
    }
    func testAppliedUpdateRereadsTheNewHeadAndKeepsTabFileAndSearch() async {
        let services=FakeDetailServices()
        await services.script(head:"aaa111",snapshot:DetailFixtures.snapshot(head:"aaa111",files:["a.swift","b.swift"]))
        await services.script(head:"bbb222",snapshot:DetailFixtures.snapshot(head:"bbb222",files:["a.swift","b.swift","c.swift"]))
        let model=model(DetailFixtures.pr(head:"aaa111"),services)
        await model.load()
        model.selectedFile="b.swift";model.search="cache";model.split=true
        let account=model.account,threads=model.threads,refresh=model.refresh
        // Same-head row changes (labels, state) don't reread anything.
        model.show(DetailFixtures.pr(head:"aaa111",title:"Renamed"))
        XCTAssertEqual(model.pr.title,"Renamed")
        XCTAssertTrue(model.account === account)
        XCTAssertEqual(model.refresh,refresh)
        // The explicit Update: account-bound reads and the detail start over at the new head.
        model.show(DetailFixtures.pr(head:"bbb222"))
        XCTAssertFalse(model.account === account)
        XCTAssertFalse(model.threads === threads)
        XCTAssertNotEqual(model.refresh,refresh)
        XCTAssertEqual(model.account.readPR.headRevision.rawValue,"bbb222")
        await model.load()
        XCTAssertEqual(model.detail?.headSHA,"bbb222")
        XCTAssertEqual(model.detail?.files.count,3)
        XCTAssertEqual(model.tab,.files)
        XCTAssertEqual(model.selectedFile,"b.swift")
        XCTAssertEqual(model.search,"cache")
        XCTAssertTrue(model.split)
        let reads=await services.detailReads
        XCTAssertEqual(reads,["aaa111","bbb222"])
    }

    // MARK: Next / Previous

    func testNextAndPreviousFollowTheWorkspaceOrder() {
        let keys=["pr-1","pr-2","pr-3"].map { DetailFixtures.key($0) }
        let middle=PRDetailRouteState.steps(keys,at:keys[1])
        XCTAssertEqual(middle.previous,keys[0]);XCTAssertEqual(middle.next,keys[2]);XCTAssertEqual(middle.position,"2 of 3")
        let first=PRDetailRouteState.steps(keys,at:keys[0])
        XCTAssertNil(first.previous);XCTAssertEqual(first.next,keys[1]);XCTAssertEqual(first.position,"1 of 3")
        let last=PRDetailRouteState.steps(keys,at:keys[2])
        XCTAssertEqual(last.previous,keys[1]);XCTAssertNil(last.next)
        let elsewhere=PRDetailRouteState.steps(keys,at:DetailFixtures.key("pr-9"))
        XCTAssertNil(elsewhere.previous);XCTAssertNil(elsewhere.next);XCTAssertNil(elsewhere.position,"a PR outside the order has no steps")
    }
    func testNavigatingInPlaceShowsTheTargetAndResetsItsRow() {
        let scene=DetailFixtures.key("pr-1"),next=DetailFixtures.key("pr-2")
        var state=PRDetailRouteState()
        state.adopt(DetailFixtures.pr(head:"aaa111",object:"pr-1"))
        XCTAssertFalse(state.go(scene,from:scene),"already on screen")
        XCTAssertTrue(state.go(next,from:scene))
        XCTAssertEqual(state.shownKey(scene),next)
        XCTAssertNil(state.shown,"the next pull request shows its own latest row")
        let target=DetailFixtures.pr(head:"ccc333",object:"pr-2")
        state.adopt(target)
        XCTAssertEqual(state.display(target),target)
        XCTAssertNil(state.pendingHead(target))
        // Restoration or the scene's own navigation callback takes over.
        state.sceneKeyChanged()
        XCTAssertEqual(state.shownKey(next),next)
        XCTAssertNil(state.shown)
    }
    func testNextUnviewedWrapsAndSkipsTheSelection() async {
        let services=FakeDetailServices()
        await services.script(head:"aaa111",snapshot:DetailFixtures.snapshot(head:"aaa111",files:["b/2.swift","a/1.swift","b/3.swift"]))
        let model=model(DetailFixtures.pr(head:"aaa111"),services)
        await model.load()
        XCTAssertEqual(model.selectedFile,"a/1.swift","Files opens on the first file in list order")
        XCTAssertTrue(model.selectNextUnviewed());XCTAssertEqual(model.selectedFile,"b/2.swift")
        XCTAssertTrue(model.selectNextUnviewed());XCTAssertEqual(model.selectedFile,"b/3.swift")
        XCTAssertTrue(model.selectNextUnviewed());XCTAssertEqual(model.selectedFile,"a/1.swift","wraps around")
        model.tab = .overview
        XCTAssertFalse(model.selectNextUnviewed(),"N only acts in Files")
    }
}
