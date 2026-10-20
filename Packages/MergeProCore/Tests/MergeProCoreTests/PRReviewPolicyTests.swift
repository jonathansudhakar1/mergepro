import XCTest
@testable import MergeProCore

final class PRReviewPolicyTests:XCTestCase {
    let account=AccountScope(host:"github.com",accountID:"a")
    func row(_ n:Int,accountID:String="a",repo:String="r",size:Int?=100,age:TimeInterval=100,partial:Bool=false) -> PullRequest {
        var m=PRMetadata(number:n,webURL:URL(string:"https://github.com/o/r/pull/\(n)")!,repositoryName:"o/r")
        m.authorLogin="copilot";m.actorType="Bot";m.mergedAt=Date(timeIntervalSince1970:1_000_000-age);m.additions=size;m.deletions=size == nil ? nil : 0;m.partial=partial
        return .init(key:.init(host:"github.com",accountID:accountID,repositoryID:repo,objectID:String(n)),headRevision:.init("h"),title:"PR",state:.merged,isDraft:false,metadata:m)
    }
    func testManualRulesPersistAndReclassifyCachedAndFutureWrites() throws {
        let db=try DatabaseStore(path:":memory:");try db.saveAccount(.init(scope:account,login:"a",tokenReference:"test"))
        try db.saveRepository(.init(key:row(1).key.repository,name:"o/r",isPrivate:false,capabilities:.init()))
        try db.savePullRequests([row(1)])
        let store=PRClassificationStore(database:db)
        try store.save(["CoPilot":.human],account:account)
        XCTAssertEqual(try PRClassificationStore(database:db).rules(account:account),["copilot":.human])
        XCTAssertEqual(try db.snapshot(for:account).pullRequests.first?.metadata?.authorClassification,"human")
        try db.savePullRequests([row(1)]) // stale normalization must not beat current user preference.
        XCTAssertEqual(try db.snapshot(for:account).pullRequests.first?.metadata?.authorClassification,"human")
        XCTAssertEqual(try store.rules(account:.init(host:"github.com",accountID:"b")),[:])
        try store.save([:],account:account)
        XCTAssertEqual(try db.snapshot(for:account).pullRequests.first?.metadata?.authorClassification,"agent")
        XCTAssertThrowsError(try store.save(["invalid login":.human],account:account))
    }
    func testHistoricalMedianExcludesOtherScopesOldPartialUnknownAndCurrentPR() {
        let current=row(999)
        let samples=(1...5).map { row($0,size:$0*100) }
        let excluded=[row(6,accountID:"b",size:99999),row(7,repo:"other",size:99999),row(8,size:nil),row(9,size:99999,age:91*86400),row(10,size:99999,partial:true),current]
        let result=RepositorySizeBaseline.calculate(samples+excluded,for:current,now:Date(timeIntervalSince1970:1_000_000))
        XCTAssertEqual(result.sampleCount,5);XCTAssertEqual(result.usualSize,300)
        XCTAssertNil(RepositorySizeBaseline.calculate(Array(samples.prefix(4)),for:current,now:Date(timeIntervalSince1970:1_000_000)).usualSize)
    }
    func testHistoricalSampleIsBoundedAndSizeRuleUsesActualBaseline() {
        let current=row(999)
        let samples=(1...60).map { row($0,size:$0 <= 50 ? 100 : 10000,age:Double($0)) }
        let result=RepositorySizeBaseline.calculate(samples,for:current,now:Date(timeIntervalSince1970:1_000_000))
        XCTAssertEqual(result.sampleCount,50);XCTAssertEqual(result.usualSize,100)
        XCTAssertTrue(RiskRules.evaluate(files:[.init(path:"a",status:.added,patch:nil,additions:600)],viewed:[],usualSize:result.usualSize).contains { $0.kind == .unusuallyLarge })
    }
}

extension PRReviewPolicyTests {
    func testLateInventoryCommitReadsLatestOverrideAndClear() throws {
        let db=try DatabaseStore(path:":memory:");try db.saveAccount(.init(scope:account,login:"a",tokenReference:"test"))
        let pr=row(1);try db.saveRepository(.init(key:pr.key.repository,name:"o/r",isPrivate:false,capabilities:.init()))
        let cycle=UUID(),deadline=ContinuousClock.now.advanced(by:.seconds(30));let store=PollCycleStore(database:db)
        try store.begin(cycle,at:Date(),baseline:false)
        let context=PollFetchContext(cycleID:cycle,account:account,repositories:[pr.key.repository],featureID:"github-pr-inventory",cachedPullRequests:[],cachedSnapshots:[],repositoryMetadata:[:],deadline:deadline,operation:nil,client:nil,budget:RateBudget(),baselinedRepositories:[],suppressNotifications:true,cachedResponses:[:])
        let rules=PRClassificationStore(database:db)
        try rules.save(["copilot":.human],account:account)
        try store.apply(.init(pullRequests:[pr]),context:context,deadline:deadline,requireTracked:false)
        XCTAssertEqual(try db.snapshot(for:account).pullRequests.first?.metadata?.authorClassification,"human")
        let staleManual=try XCTUnwrap(db.snapshot(for:account).pullRequests.first)
        try rules.save([:],account:account)
        try store.apply(.init(pullRequests:[staleManual]),context:context,deadline:deadline,requireTracked:false)
        XCTAssertEqual(try db.snapshot(for:account).pullRequests.first?.metadata?.authorClassification,"agent")
    }
}
