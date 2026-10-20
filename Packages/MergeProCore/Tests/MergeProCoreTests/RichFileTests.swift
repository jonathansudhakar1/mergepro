import XCTest
@testable import MergeProCore
final class RichFileTests:XCTestCase {
    func testCSVQuotedFieldsAndNewlinesStayData() throws {
        let result=try RichFileDocument.csv("name,value\r\n\"a,b\",\"line1\nline2\"\r\n")
        XCTAssertEqual(result,[["name","value"],["a,b","line1\nline2"]])
    }
    func testNotebookOmitsExecutableHTMLAndWidgetsButKeepsSource() throws {
        let data=Data(#"{"cells":[{"cell_type":"code","source":["print(1)"],"outputs":[{"data":{"text/html":["<script>evil()</script>"],"text/plain":["1"]}}]}]}"#.utf8)
        let cells=try RichFileDocument.notebook(data)
        XCTAssertEqual(cells[0].source,"print(1)")
        XCTAssertEqual(cells[0].outputs,["1"])
        XCTAssertFalse(String(describing:cells).contains("evil"))
    }
    func testRichRoutingDoesNotDecodeSVGOrLFSAsRaster() {
        XCTAssertEqual(RichFileDocument.kind(path:"evil.svg",data:Data("<script>".utf8)),.svgSource)
        XCTAssertEqual(RichFileDocument.kind(path:"image.png",data:Data("version https://git-lfs.github.com/spec/v1\n".utf8)),.lfs)
    }
    func testLocalEditorPathsRejectTraversalSymlinkEscapeAndInvalidLines() throws {
        let root=try makeTemporaryDirectory()
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("escape"),withDestinationURL:URL(fileURLWithPath:"/tmp"))
        XCTAssertThrowsError(try EditorLocation(root:root,path:"../x",line:1))
        XCTAssertThrowsError(try EditorLocation(root:root,path:"escape/x",line:1))
        XCTAssertThrowsError(try EditorLocation(root:root,path:"safe.swift",line:0))
        let value=try EditorLocation(root:root,path:"a b#c.swift",line:12)
        XCTAssertEqual(value.url.path,root.appendingPathComponent("a b#c.swift").path)
        XCTAssertTrue(value.editorURL(.vscode)!.absoluteString.contains("%23"))
    }
}
