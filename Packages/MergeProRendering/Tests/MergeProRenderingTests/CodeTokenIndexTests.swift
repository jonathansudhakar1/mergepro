import XCTest
@testable import MergeProRendering

final class CodeTokenIndexTests:XCTestCase {
    func testViewportFindsEnclosingTokensAndKeepsOriginalLayeringOrder() {
        let enclosing=CodeToken(range:NSRange(location:0,length:100),scopes:["string"])
        let overlay=CodeToken(range:NSRange(location:55,length:2),scopes:["keyword"])
        let earlier=CodeToken(range:NSRange(location:50,length:1),scopes:["constant"])
        let outside=CodeToken(range:NSRange(location:150,length:10),scopes:["comment"])
        let index=CodeTokenIndex([overlay,outside,enclosing,earlier],length:200)
        XCTAssertEqual(index.intersecting(NSRange(location:50,length:10)),[overlay,enclosing,earlier])
        XCTAssertEqual(index.intersecting(NSRange(location:110,length:5)),[])
    }
    func testInvalidAndOverflowingRangesAreIgnored() {
        let good=CodeToken(range:NSRange(location:0,length:2),scopes:["keyword"])
        let index=CodeTokenIndex([.init(range:NSRange(location:Int.max,length:10),scopes:["string"]),.init(range:NSRange(location:-1,length:2),scopes:["string"]),good],length:2)
        XCTAssertEqual(index.intersecting(NSRange(location:0,length:2)),[good])
        XCTAssertEqual(index.intersecting(NSRange(location:Int.max,length:10)),[])
    }
}
