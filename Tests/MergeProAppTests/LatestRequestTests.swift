import XCTest
@testable import MergePro

@MainActor final class LatestRequestTests:XCTestCase {
    func testOnlyTheNewestRequestIsCurrent() {
        let requests=LatestRequest()
        let first=requests.begin()
        XCTAssertTrue(requests.isCurrent(first))
        XCTAssertEqual(requests.latest,first,"reading the latest token doesn't supersede it")
        XCTAssertTrue(requests.isCurrent(first))
        let second=requests.begin()
        XCTAssertFalse(requests.isCurrent(first))
        XCTAssertTrue(requests.isCurrent(second))
        requests.cancel()
        XCTAssertFalse(requests.isCurrent(second),"cancel supersedes outstanding requests without starting one")
        XCTAssertNotEqual(requests.begin(),second)
    }
    func testRunDropsTheResultOfSupersededWork() async {
        let requests=LatestRequest(),gate=TestGate()
        let slow=Task { await requests.run { await gate.wait();return "older" } }
        await gate.arrived()
        let fast=await requests.run { "newer" }
        await gate.open()
        let late=await slow.value
        XCTAssertEqual(fast,"newer")
        XCTAssertNil(late,"a result that lands after a newer request began is dropped")
    }
    func testRunPassesErrorsThrough() async {
        struct Failure:Error {}
        let requests=LatestRequest()
        do { _ = try await requests.run { () async throws -> Int in throw Failure() };XCTFail("expected the work's error") }
        catch { XCTAssertTrue(error is Failure) }
    }
}
