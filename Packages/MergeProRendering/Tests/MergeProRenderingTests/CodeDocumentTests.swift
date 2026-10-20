import XCTest
@testable import MergeProRendering

final class CodeDocumentTests:XCTestCase {
    func testLineNavigationUsesUTF16AndPreservesCRLFIndentationAndTrailingLine() {
        let source="\t🐈\r\n  café\n"
        let document=CodeDocument(source)
        XCTAssertEqual(document.source,source)
        XCTAssertEqual(document.lineRanges,[NSRange(location:0,length:3),NSRange(location:5,length:6),NSRange(location:12,length:0)])
        XCTAssertEqual(document.range(forLine:2),NSRange(location:5,length:6))
        XCTAssertNil(document.range(forLine:0));XCTAssertNil(document.range(forLine:4))
        XCTAssertEqual(document.lineNumber(at:6),2)
        XCTAssertEqual(document.lineNumber(at:12),3)
        XCTAssertEqual(document.lineNumberMarks.map(\.label),["1","2","3"])
    }
    func testFindHasLiteralCaseInsensitiveUTF16MatchesAndWrapsBothDirections() {
        let document=CodeDocument("🐈 cat CAT catapult [cat]")
        let result=document.find("cat")
        XCTAssertEqual(result.ranges,[NSRange(location:3,length:3),NSRange(location:7,length:3),NSRange(location:11,length:3),NSRange(location:21,length:3)])
        XCTAssertEqual(result.nextIndex(after:3,backwards:false),0)
        XCTAssertEqual(result.nextIndex(after:0,backwards:true),3)
        XCTAssertEqual(result.nextIndex(after:nil,backwards:true),3)
        XCTAssertEqual(document.find("[cat]").ranges,[NSRange(location:20,length:5)])
        XCTAssertTrue(document.find("").ranges.isEmpty)
        XCTAssertNil(document.find("missing").nextIndex(after:nil,backwards:false))
    }
    func testFindCapsWorkAndReportsAdditionalMatches() {
        let result=CodeDocument("a a a a").find("a",limit:2)
        XCTAssertEqual(result.ranges,[NSRange(location:0,length:1),NSRange(location:2,length:1)])
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(CodeDocument("a a").find("a",limit:2).truncated)
    }
    func testLateHighlightCannotAttachToAnotherSourceOrLanguage() async {
        let first=CodeDocumentIdentity(source:"let first = 1",path:"a.swift")
        let tokens=await CodeTokenizer.shared.tokenize(first.source,path:first.path)
        let snapshot=CodeHighlightSnapshot(identity:first,result:tokens)
        XCTAssertFalse(snapshot.tokens(for:first).isEmpty)
        XCTAssertTrue(snapshot.tokens(for:.init(source:"let later = 2",path:"a.swift")).isEmpty)
        XCTAssertTrue(snapshot.tokens(for:.init(source:first.source,path:"a.txt")).isEmpty)
        XCTAssertTrue(snapshot.tokens(for:.init(source:first.source,path:first.path,languageOverride:"json")).isEmpty)
    }
    func testLargeDocumentNavigationAndFindStayBoundedWithoutChangingSource() {
        let source=String(repeating:"\tlet cat = \"🐈\"\n",count:10000)
        let document=CodeDocument(source)
        XCTAssertEqual(document.lineRanges.count,10001)
        XCTAssertEqual(document.range(forLine:10000),NSRange(location:159984,length:15))
        XCTAssertEqual(document.find("🐈",limit:20).ranges.count,20)
        XCTAssertEqual(document.source,source)
    }
}
