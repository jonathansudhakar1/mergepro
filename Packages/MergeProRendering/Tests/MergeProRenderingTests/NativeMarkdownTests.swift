import XCTest
@testable import MergeProRendering
final class NativeMarkdownTests:XCTestCase {
    func testGFMTableReferenceLinkAndNestedInlineSemantics() throws {
        let value=try NativeMarkdown.parse("| Name | State |\n| :--- | ---: |\n| **bold** | [link][ref] and ~~old~~ |\n\n[ref]: https://github.com/o/r\n\n- [x] done with *emphasis* and `code`\n  - nested")
        let table=try XCTUnwrap(value.blocks.first)
        XCTAssertEqual(table.kind,.table);XCTAssertEqual(table.rows.count,2)
        XCTAssertEqual(table.alignments,[.left,.right])
        XCTAssertTrue(table.rows[1][0].contains { $0.styles.contains(.strong) && $0.text == "bold" })
        XCTAssertTrue(table.rows[1][1].contains { $0.destination == URL(string:"https://github.com/o/r") })
        XCTAssertTrue(table.rows[1][1].contains { $0.styles.contains(.strike) })
        XCTAssertEqual(value.blocks[1].children.first?.checked,true)
        XCTAssertEqual(value.blocks[1].children.first?.children.last?.kind,.list)
    }
    func testHTMLUnsafeLinksAndReferenceImagesRemainInertValues() throws {
        let value=try NativeMarkdown.parse("<script>alert(1)</script>\n\n[unsafe](javascript:evil) ![alt][image]\n\n[image]: https://user-images.githubusercontent.com/public.png")
        XCTAssertEqual(value.blocks.first?.kind,.literal)
        let runs=value.blocks[1].inlines
        XCTAssertNil(runs.first(where:{ $0.text == "unsafe" })?.destination)
        XCTAssertEqual(runs.first(where: { $0.image })?.destination?.host,"user-images.githubusercontent.com")
    }
    func testBareURLPunctuationParenthesesAndCodeExclusion() throws {
        let value=try NativeMarkdown.parse("See https://example.com/a(b). and www.example.com, email@example.com and `https://code.example`.\n\n```\nhttps://fence.example\n```\n\n[label https://text.example](https://target.example)")
        let links=value.blocks[0].inlines.compactMap(\.destination)
        XCTAssertEqual(links.map(\.absoluteString),["https://example.com/a(b)","https://www.example.com"])
        XCTAssertNil(value.blocks[0].inlines.first(where:{ $0.text.contains("email@example.com") })?.destination)
        XCTAssertNil(value.blocks[0].inlines.first(where:{ $0.styles.contains(.code) })?.destination)
        XCTAssertEqual(value.blocks[1].kind,.code)
        XCTAssertTrue(value.blocks[2].inlines.allSatisfy { $0.destination?.host == "target.example" })
    }
    func testCleartextHTTPLinksHaveNoDestinationWhileHTTPSStillLinks() throws {
        let value=try NativeMarkdown.parse("Plain http://example.com/a and HTTP://example.com/b then https://example.com/c\n\n[cleartext](http://example.com/d) [secure](https://example.com/e) ![img](http://example.com/i.png)\n\n[![alt](https://example.com/s.png)](http://example.com/f) <http://example.com/g> [creds](https://user:pass@example.com/h)")
        XCTAssertEqual(value.blocks[0].inlines.compactMap(\.destination).map(\.absoluteString),["https://example.com/c"])
        XCTAssertNil(value.blocks[0].inlines.first(where:{ $0.text.contains("http://example.com/a") })?.destination)
        XCTAssertNil(value.blocks[1].inlines.first(where:{ $0.text == "cleartext" })?.destination)
        XCTAssertEqual(value.blocks[1].inlines.first(where:{ $0.text == "secure" })?.destination?.absoluteString,"https://example.com/e")
        XCTAssertNil(value.blocks[1].inlines.first(where:{ $0.image })?.destination)
        let image=try XCTUnwrap(value.blocks[2].inlines.first(where:{ $0.image }))
        XCTAssertEqual(image.destination?.path,"/s.png");XCTAssertNil(image.linkDestination)
        XCTAssertTrue(value.blocks[2].inlines.filter { !$0.image }.allSatisfy { $0.destination == nil })
    }
    func testLinkedImagePreservesImageSourceSeparatelyFromDestination() throws {
        let value=try NativeMarkdown.parse("[![alt](https://user-images.githubusercontent.com/a.png)](https://github.com/o/r)")
        let image=try XCTUnwrap(value.blocks.first?.inlines.first)
        XCTAssertTrue(image.image)
        XCTAssertEqual(image.destination?.path,"/a.png")
        XCTAssertEqual(image.linkDestination?.path,"/o/r")
    }
    func testBoundsAndCodeFencePreserveLiteralSource() throws {
        XCTAssertThrowsError(try NativeMarkdown.parse(String(repeating:"x",count:262145)))
        XCTAssertThrowsError(try NativeMarkdown.parse(String(repeating:"> ",count:30)+"deep"))
        XCTAssertThrowsError(try NativeMarkdown.parse(String(repeating:"*a* ",count:2500)))
        let value=try NativeMarkdown.parse("```swift\nlet html = \"<script>\"\n```\n\n> quote\n\n---")
        XCTAssertEqual(value.blocks[0].kind,.code);XCTAssertEqual(value.blocks[0].language,"swift")
        XCTAssertTrue(value.blocks[0].literal.contains("<script>"));XCTAssertEqual(value.blocks[1].kind,.quote);XCTAssertEqual(value.blocks[2].kind,.rule)
    }
}
