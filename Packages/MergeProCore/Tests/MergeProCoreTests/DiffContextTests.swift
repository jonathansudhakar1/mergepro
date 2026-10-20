import XCTest
@testable import MergeProCore
final class DiffContextTests:XCTestCase {
    func fixture() -> (DiffDocument,DiffFile,String,String) {
        let before=(1...12).map { "line\($0)" }.joined(separator:"\n")
        let after=before.replacingOccurrences(of:"line5\n",with:"changed5\n").replacingOccurrences(of:"line10\n",with:"changed10\n")
        let file=DiffFile(path:"new.swift",previousPath:"old.swift",status:.renamed,patch:"@@ -5 +5 @@\n-line5\n+changed5\n@@ -10 +10 @@\n-line10\n+changed10",additions:2,deletions:2)
        return (.init(baseSHA:"base",headSHA:"head",files:[file],expectedFiles:1),file,before,after)
    }
    func testIncrementalContextPreservesCoordinatesAndCollapse() throws {
        let (doc,file,before,after)=fixture()
        let context=try DiffContext(document:doc,file:file,before:.init(sha:"base",text:before),after:.init(sha:"head",text:after))
        XCTAssertEqual(context.gaps.map(\.count),[4,4,2])
        let initial=context.lines(expansion:[:]);XCTAssertEqual(initial.filter { $0.kind != .context }.count,4)
        let expanded=context.lines(expansion:[0:.init(fromStart:0,fromEnd:2),1:.init(fromStart:2,fromEnd:3)])
        XCTAssertTrue(expanded.contains { $0.oldLine == 3 && $0.newLine == 3 })
        XCTAssertEqual(expanded.filter { $0.newLine == 8 }.count,1,"overlapping expansion must not duplicate lines")
        let anchor=try context.anchor(side:.left,start:3,end:5,displayed:expanded)
        XCTAssertEqual(anchor,.init(commitSHA:"base",path:"old.swift",side:"LEFT",startLine:3,endLine:5))
        XCTAssertThrowsError(try context.anchor(side:.left,start:1,end:5,displayed:initial))
        XCTAssertEqual(context.lines(expansion:[:]),initial)
    }
    func testMissingTruncatedWrongRevisionAndMismatchedGapCannotFabricateContext() throws {
        let (doc,file,before,after)=fixture()
        XCTAssertThrowsError(try DiffContext(document:doc,file:file,before:.init(sha:"stale",text:before),after:.init(sha:"head",text:after)))
        XCTAssertThrowsError(try DiffContext(document:doc,file:file,before:.init(sha:"base",text:before),after:.init(sha:"head",text:after.replacingOccurrences(of:"line1\n",with:"different\n"))))
        let truncated=DiffFile(path:"a",status:.modified,patch:"@@ -1,2 +1,2 @@\n-x\n+y")
        XCTAssertThrowsError(try DiffContext(document:.init(baseSHA:"b",headSHA:"h",files:[truncated],expectedFiles:1),file:truncated,before:.init(sha:"b",text:"x\nz"),after:.init(sha:"h",text:"y\nz")))
        let missing=DiffFile(path:"a",status:.modified,patch:nil)
        XCTAssertThrowsError(try DiffContext(document:.init(baseSHA:"b",headSHA:"h",files:[missing],expectedFiles:1),file:missing,before:.init(sha:"b",text:"x"),after:.init(sha:"h",text:"x")))
    }
    func testInsertionAndDeletionZeroCountBoundaries() throws {
        let file=DiffFile(path:"a",status:.modified,patch:"@@ -1,0 +2,1 @@\n+insert")
        let doc=DiffDocument(baseSHA:"b",headSHA:"h",files:[file],expectedFiles:1)
        let context=try DiffContext(document:doc,file:file,before:.init(sha:"b",text:"one\ntwo"),after:.init(sha:"h",text:"one\ninsert\ntwo"))
        let all=context.lines(expansion:[0:.init(fromStart:20,fromEnd:0),1:.init(fromStart:20,fromEnd:0)])
        XCTAssertEqual(all.filter { $0.kind == .context }.map(\.oldLine),[1,2])
        XCTAssertEqual(all.filter { $0.kind == .context }.map(\.newLine),[1,3])
        let removed=DiffFile(path:"gone",status:.removed,patch:"@@ -1,2 +0,0 @@\n-one\n-two")
        let deletion=try DiffContext(document:.init(baseSHA:"b",headSHA:"h",files:[removed],expectedFiles:1),file:removed,before:.init(sha:"b",text:"one\ntwo"),after:nil)
        XCTAssertEqual(try deletion.anchor(side:.left,start:1,end:2,displayed:deletion.lines(expansion:[:])).commitSHA,"b")
        XCTAssertThrowsError(try deletion.anchor(side:.right,start:1,end:1,displayed:deletion.lines(expansion:[:])))
    }
}

extension DiffContextTests {
    func testGutterMappingsPreserveRenamedLeftAndRightCommentCoordinates() throws {
        let (doc,file,before,after)=fixture()
        let context=try DiffContext(document:doc,file:file,before:.init(sha:"base",text:before),after:.init(sha:"head",text:after))
        let lines=context.lines(expansion:[0:.init(fromEnd:2)])
        let comment=PRDetailEvent(id:"comment",title:"Review",body:"body",url:nil,providerComment:.init(reviewedHeadSHA:"head",path:"new.swift",side:"LEFT",startLine:5,endLine:5))
        let annotation=PRDetailEvent(id:"annotation",title:"Check",body:"warning",url:nil,anchor:.init(commitSHA:"head",path:"new.swift",side:"RIGHT",startLine:5,endLine:5))
        let presentation=DiffPresentation(lines:lines,side:nil,hideWhitespace:false)
        let markers=presentation.markers(document:doc,file:file,events:[comment,annotation],context:context,displayed:lines)
        let rendering=try XCTUnwrap(comment.renderingAnchor(in:doc))
        let provider=try XCTUnwrap(doc.providerCommentLocation(for:rendering))
        XCTAssertEqual(provider.path,"new.swift");XCTAssertEqual(provider.reviewedHeadSHA,"head")
        XCTAssertEqual(comment.providerComment?.path,"new.swift","rendering must not rewrite provider coordinates")
        let expanded=try context.anchor(side:.left,start:3,end:3,displayed:lines)
        XCTAssertNil(doc.providerCommentLocation(for:expanded),"expanded rendering context is not proof of provider comment eligibility")
        XCTAssertEqual(markers.first(where:{ $0.kind == .comment })?.anchor,.init(commitSHA:"base",path:"old.swift",side:"LEFT",startLine:5,endLine:5))
        XCTAssertEqual(markers.first(where:{ $0.kind == .annotation })?.anchor,.init(commitSHA:"head",path:"new.swift",side:"RIGHT",startLine:5,endLine:5))
        XCTAssertTrue(presentation.markers(document:.init(baseSHA:"base",headSHA:"new-head",files:[file],expectedFiles:1),file:file,events:[comment],context:context,displayed:lines).isEmpty)
        XCTAssertEqual(markers.filter { $0.kind == .removed }.count,2)
        XCTAssertEqual(markers.filter { $0.kind == .added }.count,2)
        XCTAssertTrue(markers.allSatisfy { $0.range.location >= 0 && NSMaxRange($0.range) <= presentation.text.utf16.count })
    }
}

extension DiffContextTests {
    func testMarkersRejectFileOutsideCanonicalDocumentWithoutContext() {
        let file=DiffFile(path:"other",status:.modified,patch:"@@ -1 +1 @@\n-old\n+new")
        XCTAssertTrue(DiffPresentation(file:file,side:nil,hideWhitespace:false).markers(document:.init(baseSHA:"b",headSHA:"h",files:[],expectedFiles:0),file:file,events:[],context:nil,displayed:file.lines).isEmpty)
    }
}
