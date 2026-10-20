import MergeProCore
import XCTest
@testable import MergePro

/// Review threads sit inside the diff below their last line, in the unified pane and both split panes.
final class InlineThreadPlacementTests:XCTestCase {
    /// Rows: 0 " one" (old 1/new 1), 1 "-two" (old 2), 2 "+TWO" (new 2), 3 " three" (old 3/new 3), 4 "+four" (new 4).
    private let file=DiffFile(path:"Sources/Cache.swift",status:.modified,patch:"@@ -1,3 +1,4 @@\n one\n-two\n+TWO\n three\n+four\n")
    private func panes(hideWhitespace:Bool = false) -> (unified:DiffPresentation,left:DiffPresentation,right:DiffPresentation) {
        (DiffPresentation(file:file,side:nil,hideWhitespace:hideWhitespace),DiffPresentation(file:file,side:.left,hideWhitespace:hideWhitespace),DiffPresentation(file:file,side:.right,hideWhitespace:hideWhitespace))
    }
    private func line(_ id:String,_ side:DiffSide,_ start:Int,_ end:Int) -> InlineThreadPlacement.Line { .init(id:id,side:side,start:start,end:end) }

    func testPanesShareOneRowPerDiffLine() {
        let panes=panes()
        XCTAssertEqual(panes.unified.rows.count,5)
        XCTAssertEqual(panes.left.rows.count,panes.unified.rows.count)
        XCTAssertEqual(panes.right.rows.count,panes.unified.rows.count)
        XCTAssertEqual(panes.left.rows.map(\.line),[1,2,nil,3,nil])
        XCTAssertEqual(panes.right.rows.map(\.line),[1,nil,2,3,4])
    }
    func testThreadsSitBelowTheirLastLineOnTheirSide() {
        let panes=panes()
        let lines=[line("added",.right,4,4),line("removed",.left,2,2),line("range",.right,1,2),line("old-context",.left,3,3),line("elsewhere",.right,90,92)]
        let rows=InlineThreadPlacement.rows(lines,left:panes.left,right:panes.right)
        XCTAssertEqual(rows[4]?.map(\.id),["added"])
        XCTAssertEqual(rows[1]?.map(\.id),["removed"])
        XCTAssertEqual(rows[2]?.map(\.id),["range"],"a multi-line thread sits below its last line")
        XCTAssertEqual(rows[3]?.map(\.id),["old-context"],"an old-side comment on an unchanged line still has a row in the unified pane")
        XCTAssertFalse(rows.values.flatMap { $0 }.contains { $0.id == "elsewhere" },"lines outside the displayed diff stay in the overview")
        // The unified row is the same diff line the thread's side numbers.
        XCTAssertEqual(panes.unified.rows[1].line,2);XCTAssertEqual(panes.unified.rows[1].side,.left)
        XCTAssertEqual(panes.unified.rows[4].line,4);XCTAssertEqual(panes.unified.rows[4].side,.right)
    }
    func testThreadsOnOneRowKeepTheirOrder() {
        let panes=panes()
        let rows=InlineThreadPlacement.rows([line("first",.right,3,3),line("second",.left,3,3),line("third",.right,2,3)],left:panes.left,right:panes.right)
        XCTAssertEqual(rows[3]?.map(\.id),["first","second","third"])
        XCTAssertEqual(rows.count,1)
    }
    func testGutterClicksFindTheThreadsCoveringTheirRow() {
        let panes=panes()
        let lines=[line("range",.right,1,3),line("removed",.left,2,2),line("added",.right,4,4)]
        XCTAssertEqual(InlineThreadPlacement.lines(lines,coveringRow:2,left:panes.left,right:panes.right).map(\.id),["range"])
        XCTAssertEqual(InlineThreadPlacement.lines(lines,coveringRow:1,left:panes.left,right:panes.right).map(\.id),["removed"])
        XCTAssertEqual(InlineThreadPlacement.lines(lines,coveringRow:3,left:panes.left,right:panes.right).map(\.id),["range"])
        XCTAssertEqual(InlineThreadPlacement.lines(lines,coveringRow:4,left:panes.left,right:panes.right).map(\.id),["added"])
        XCTAssertTrue(InlineThreadPlacement.lines(lines,coveringRow:99,left:panes.left,right:panes.right).isEmpty)
        // A gutter mark's range starts in its row's content.
        for (index,row) in panes.unified.rows.enumerated() {
            XCTAssertEqual(InlineThreadPlacement.row(at:row.contentRange.location,in:panes.unified),index)
            if row.contentRange.length > 1 { XCTAssertEqual(InlineThreadPlacement.row(at:row.contentRange.location+1,in:panes.unified),index) }
        }
    }
    func testThreadsPlaceOnlyAtTheHeadTheirLinesBelongTo() throws {
        let json=#"{"path":"Sources/Cache.swift","current":{"reviewedHeadSHA":"bbb222","startLine":2,"endLine":4,"side":"RIGHT"},"original":{"reviewedHeadSHA":"aaa111","endLine":3,"side":"RIGHT"}}"#
        let coordinates=try JSONDecoder().decode(PRCommentCoordinates.self,from:Data(json.utf8))
        // The thread read follows the action account's row, which can already be at a push the window hasn't applied.
        XCTAssertNil(PRThreadModel.line(outdated:false,coordinates:coordinates,head:"aaa111"),"a newer head's line numbers would land on the wrong rows of the shown diff")
        let line=try XCTUnwrap(PRThreadModel.line(outdated:false,coordinates:coordinates,head:"bbb222"))
        XCTAssertEqual(line.side,.right);XCTAssertEqual(line.start,2);XCTAssertEqual(line.end,4)
        XCTAssertNil(PRThreadModel.line(outdated:true,coordinates:coordinates,head:"bbb222"),"outdated threads stay in the overview")
        XCTAssertNil(PRThreadModel.line(outdated:false,coordinates:nil,head:"bbb222"))
    }
    func testRowKeysFollowLineNumbersSoAHostSurvivesNewThreadsAndMovedRows() throws {
        let panes=panes()
        XCTAssertEqual(InlineThreadPlacement.key(row:3,left:panes.left,right:panes.right),"line:R3","an unchanged line is keyed by its new number")
        XCTAssertEqual(InlineThreadPlacement.key(row:1,left:panes.left,right:panes.right),"line:L2","a removed line by its old number")
        XCTAssertEqual(InlineThreadPlacement.key(row:4,left:panes.left,right:panes.right),"line:R4")
        // Another thread on the same line keeps its row and key, so a reply being typed in that row's host survives.
        let one=InlineThreadPlacement.rows([line("first",.right,3,3)],left:panes.left,right:panes.right)
        let two=InlineThreadPlacement.rows([line("first",.right,3,3),line("second",.left,3,3)],left:panes.left,right:panes.right)
        XCTAssertEqual(Array(one.keys),Array(two.keys))
        // Hidden whitespace moves rows, not line numbers.
        let whitespace=DiffFile(path:"a.swift",status:.modified,patch:"@@ -1,3 +1,3 @@\n keep\n-  spaced\n+spaced\n-old\n+new\n")
        let keys=try [false,true].map { hidden in
            let left=DiffPresentation(file:whitespace,side:.left,hideWhitespace:hidden),right=DiffPresentation(file:whitespace,side:.right,hideWhitespace:hidden)
            let row=try XCTUnwrap(InlineThreadPlacement.rows([line("new",.right,3,3)],left:left,right:right).keys.first)
            return (row,InlineThreadPlacement.key(row:row,left:left,right:right))
        }
        XCTAssertNotEqual(keys[0].0,keys[1].0,"hiding whitespace moved the row")
        XCTAssertEqual(keys[0].1,"line:R3");XCTAssertEqual(keys[1].1,"line:R3")
    }
    func testHiddenWhitespaceRowsLeaveEveryPaneAligned() {
        let whitespace=DiffFile(path:"a.swift",status:.modified,patch:"@@ -1,3 +1,3 @@\n keep\n-  spaced\n+spaced\n-old\n+new\n")
        let unified=DiffPresentation(file:whitespace,side:nil,hideWhitespace:true),left=DiffPresentation(file:whitespace,side:.left,hideWhitespace:true),right=DiffPresentation(file:whitespace,side:.right,hideWhitespace:true)
        XCTAssertEqual(unified.rows.count,left.rows.count)
        XCTAssertEqual(unified.rows.count,right.rows.count)
        let rows=InlineThreadPlacement.rows([line("new",.right,3,3)],left:left,right:right)
        let row=try? XCTUnwrap(rows.first?.key)
        XCTAssertEqual(row.map { unified.rows[$0].line },3)
        XCTAssertEqual(row.map { unified.rows[$0].side },.right)
    }
}
