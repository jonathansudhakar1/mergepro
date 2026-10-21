import XCTest
@testable import MergeProCore

/// Navigation history ranks palette rows by lookup, not by scanning up to 1,000 visits per row.
final class PRNavigationIndexTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    func key(_ index:Int) -> ProviderKey { ProviderKey(host:"github.com",accountID:"1",repositoryID:"r",objectID:"pull-request:\(index)") }

    func testScoresSurviveDecodeInvalidationAndTrimming() throws {
        var state=PRViewState()
        for index in 0..<1200 { state.recordVisit(key(index),at:now.addingTimeInterval(Double(index))) }
        XCTAssertEqual(state.navigationHistory?.count,1000,"History stays bounded")
        XCTAssertEqual(state.navigationScore(key(0),at:now),0,"Trimmed visits no longer rank")
        state.recordVisit(key(1199),at:now.addingTimeInterval(2000))
        XCTAssertEqual(state.navigationHistory?.first { $0.key == key(1199) }?.opens,2)
        let expected=state.navigationScore(key(1199),at:now.addingTimeInterval(2000))
        XCTAssertGreaterThan(expected,state.navigationScore(key(1198),at:now.addingTimeInterval(2000)))
        let decoded=try JSONDecoder().decode(PRViewState.self,from:JSONEncoder.stable.encode(state))
        XCTAssertEqual(decoded,state)
        XCTAssertEqual(decoded.navigationScore(key(1199),at:now.addingTimeInterval(2000)),expected,"A decoded state is indexed")
        var other=decoded
        other.invalidate(key(1199).account)
        XCTAssertEqual(other.navigationScore(key(1199),at:now),0)
    }

    func testNavigationScoreIsALookup() {
        var state=PRViewState()
        for index in 0..<1000 { state.recordVisit(key(index),at:now.addingTimeInterval(Double(index))) }
        let history=state.navigationHistory ?? []
        let rows=(0..<5000).map { key($0 % 2000) }
        func linear(_ key:ProviderKey) -> Double {
            guard let visit=history.first(where:{ $0.key == key }) else { return 0 }
            return log2(Double(visit.opens)+1)/(1+max(0,now.timeIntervalSince(visit.lastOpenedAt)/86400))
        }
        let linearStart=ContinuousClock.now
        let baseline=rows.reduce(0.0) { $0+linear($1) }
        let linearTime=linearStart.duration(to:.now)
        let indexedStart=ContinuousClock.now
        let indexed=rows.reduce(0.0) { $0+state.navigationScore($1,at:now) }
        let indexedTime=indexedStart.duration(to:.now)
        XCTAssertEqual(indexed,baseline,accuracy:0.0001)
        print("TASK10 navigationScore 5000 rows × 1000 visits: indexed \(indexedTime), linear \(linearTime)")
        XCTAssertLessThan(indexedTime,linearTime/4,"Ranking must not scan history per row")
    }

    func testRecordVisitStaysFastAtTheCap() {
        var state=PRViewState()
        for index in 0..<1000 { state.recordVisit(key(index),at:now.addingTimeInterval(Double(index))) }
        let start=ContinuousClock.now
        for index in 0..<200 { state.recordVisit(key(index*3),at:now.addingTimeInterval(Double(5000+index))) }
        let elapsed=start.duration(to:.now)
        print("TASK10 recordVisit ×200 at 1000 visits: \(elapsed)")
        XCTAssertWithinPerformanceBudget(elapsed,.seconds(2),"Generous bound for debug builds")
    }
}
