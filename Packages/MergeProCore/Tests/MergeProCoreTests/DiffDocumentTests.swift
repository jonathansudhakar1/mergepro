import XCTest
@testable import MergeProCore

final class DiffDocumentTests: XCTestCase {
    func testRenameMultilineAnchorRetainsOriginalSidePathAndRevision() throws {
        let file = DiffFile(path:"new.swift", previousPath:"old.swift", status:.renamed, patch:"@@ -3,2 +3,2 @@\n-one\n-two\n+three\n+four")
        let doc = DiffDocument(baseSHA:"base", headSHA:"head", files:[file], expectedFiles:1)
        let lines = file.lines
        XCTAssertEqual(lines.map(\.oldLine), [3,4,nil,nil])
        XCTAssertEqual(lines.map(\.newLine), [nil,nil,3,4])
        XCTAssertEqual(try doc.anchor(file:file,side:.left,start:3,end:4), ReviewAnchor(commitSHA:"base",path:"old.swift",side:"LEFT",startLine:3,endLine:4))
        XCTAssertEqual(try doc.anchor(file:file,side:.right,start:3,end:4).commitSHA,"head")
        XCTAssertThrowsError(try doc.anchor(file:file,side:.right,start:2,end:4))
    }
    func testDeletedFileCannotAnchorRightAndTruncatedPatchIsExplicit() throws {
        let deleted = DiffFile(path:"gone",status:.removed,patch:"@@ -1,2 +0,0 @@\n-a\n-b")
        let short = DiffFile(path:"partial",status:.modified,patch:"@@ -1,2 +1,2 @@\n same")
        let missing = DiffFile(path:"binary",status:.modified,patch:nil)
        let doc = DiffDocument(baseSHA:"b",headSHA:"h",files:[deleted,short,missing],expectedFiles:4000)
        XCTAssertEqual(short.patchState,.truncated)
        XCTAssertEqual(missing.patchState,.unavailable)
        XCTAssertEqual(doc.missingFileCount,3997)
        XCTAssertThrowsError(try doc.anchor(file:deleted,side:.right,start:1,end:1))
        XCTAssertEqual(try doc.anchor(file:deleted,side:.left,start:1,end:2).endLine,2)
        XCTAssertEqual(doc.search("same").matches.count,1)
        XCTAssertFalse(doc.search("absent").complete)
    }
    func testViewedMarksInvalidateOnForcePushAndInterdiffNeverSubstitutesBase() {
        var state = PRDetailState(headSHA:"old")
        state.markViewed("a",viewed:true)
        state.lastReviewedSHA = "old"
        state.acceptRevision("new")
        XCTAssertFalse(state.viewed.contains("a"))
        XCTAssertEqual(state.lastReviewedSHA,"old")
        XCTAssertEqual(InterdiffAvailability.resolve(original:"old",head:"new",retrievable:false),.unavailable(original:"old"))
    }
    func testWordChangesRespectUnicodeAndWhitespace() {
        let edits = DiffWords.changedRange(old:"let 🐈 = 1",new:"let 🐈 = 2")
        XCTAssertEqual(edits.new,NSRange(location:9,length:1))
        XCTAssertTrue(DiffWords.onlyWhitespace(old:"a b",new:"a  b"))
    }
    func testWordChangesSnapToWordsAndSkipUnrelatedLines() {
        // seconds(1) → seconds(2) highlights the number only; base → base2 highlights the whole identifier.
        XCTAssertEqual(DiffWords.changedRange(old:"    var base = .seconds(1)",new:"    var base = .seconds(2)").new,NSRange(location:24,length:1))
        XCTAssertEqual(DiffWords.changedRange(old:"let base = 1",new:"let base2 = 1").new,NSRange(location:4,length:5))
        // Paired lines that are really different get no word highlight.
        XCTAssertEqual(DiffWords.changedRange(old:"        return .seconds(1)",new:"        // Honor Retry-After on secondary rate limits.").new.length,0)
    }
}

extension DiffDocumentTests {
    func testPresentationMapsSelectionToRealLinesInsteadOfDisplayNumbers() throws {
        let file=DiffFile(path:"a",status:.modified,patch:"@@ -8,2 +8,2 @@\n same\n-old 🐈\n+new 🐈")
        let presentation=DiffPresentation(file:file,side:.right,hideWhitespace:false)
        XCTAssertEqual(presentation.rows.map(\.line),[8,nil,9])
        let selected=presentation.rows[2].contentRange
        XCTAssertEqual(presentation.lineRange(for:selected)?.lowerBound,9)
        XCTAssertEqual((presentation.text as NSString).substring(with:selected),"new 🐈")
    }
}

extension DiffDocumentTests {
    func testProviderStatisticsExposeOmittedWholeHunks() {
        let file=DiffFile(path:"a",status:.modified,patch:"@@ -1 +1 @@\n-old\n+new",additions:5,deletions:5)
        XCTAssertEqual(file.patchState,.truncated)
    }
}
