import XCTest
@testable import MergeProCore

@MainActor final class PRDetailRevisionFixTests:XCTestCase {
    func testMovingSymbolicComparisonResolvesBeforeContentAndNextComparison() async throws {
        let a=String(repeating:"a",count:40),b=String(repeating:"b",count:40),c=String(repeating:"c",count:40)
        let transport=ScriptedTransport([json("{\"sha\":\"\(a)\"}"),json("{\"sha\":\"\(b)\"}"),json("{\"merge_base_commit\":{\"sha\":\"\(a)\"},\"files\":[]}"),json(#"{"type":"file","encoding":"base64","content":"b2xk"}"#),json("{\"sha\":\"\(a)\"}"),json("{\"sha\":\"\(c)\"}"),json("{\"merge_base_commit\":{\"sha\":\"\(a)\"},\"files\":[]}")])
        let fetcher=GitHubPRDetailFetcher(client:.init(transport:transport))
        let first=try await fetcher.compare(repository:"o/r",base:"release",head:"main",token:"fixture")
        XCTAssertEqual(first.headSHA,b)
        _ = try await fetcher.blob(repository:"o/r",path:"a",sha:first.headSHA,token:"fixture")
        let second=try await fetcher.compare(repository:"o/r",base:"release",head:"main",token:"fixture")
        XCTAssertEqual(second.headSHA,c)
        let requests=await transport.captured()
        XCTAssertEqual(requests[2].url?.path,"/repos/o/r/compare/\(a)...\(b)")
        XCTAssertEqual(URLComponents(url:requests[3].url!,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,b)
    }
    func testSymbolicBlobIsRejectedBeforeTransport() async throws {
        let transport=ScriptedTransport([])
        do { _ = try await GitHubPRDetailFetcher(client:.init(transport:transport)).blob(repository:"o/r",path:"a",sha:"main",token:"fixture");XCTFail() }
        catch { XCTAssertEqual(error as? PRDetailFailure,.invalidPath) }
        let requests=await transport.captured();XCTAssertTrue(requests.isEmpty)
    }
    func testHistoricalComparisonCannotMarkCurrentProgress() {
        let current=DiffDocument(baseSHA:"b",headSHA:"h",files:[],expectedFiles:0)
        var state=PRDetailState(headSHA:"h")
        XCTAssertFalse(state.markViewed("a",viewed:true,displayed:.init(baseSHA:"old",headSHA:"older",files:[],expectedFiles:0),canonical:current))
        XCTAssertFalse(state.markViewed("a",viewed:true,displayed:.init(baseSHA:"other",headSHA:"h",files:[],expectedFiles:0),canonical:current))
        XCTAssertTrue(state.viewed.isEmpty)
        XCTAssertTrue(state.markViewed("a",viewed:true,displayed:current,canonical:current));XCTAssertEqual(state.viewed,["a"])
    }
    func testReplacementBlockPairsCorrespondingLinesAndHidesWhitespace() {
        let file=DiffFile(path:"a",status:.modified,patch:"@@ -1,2 +1,2 @@\n-a b\n-c d\n+a  b\n+c  d")
        XCTAssertTrue(DiffPresentation(file:file,side:nil,hideWhitespace:true).rows.isEmpty)
        let mixed=DiffFile(path:"a",status:.modified,patch:"@@ -1,2 +1,2 @@\n-a b\n-let 🐈 = 1\n+a  b\n+let 🐈 = 2")
        let rows=DiffPresentation(file:mixed,side:nil,hideWhitespace:true)
        XCTAssertEqual(rows.rows.map(\.line),[2,2])
        XCTAssertEqual(rows.rows.compactMap(\.wordRange).map { (rows.text as NSString).substring(with:$0) },["1","2"])
    }
    func testOutdatedCommentRetainsNullableCurrentAndOriginalCoordinates() async throws {
        let transport=ScriptedTransport([json("[]"),json(#"[{"id":7,"path":"renamed.swift","line":null,"start_line":null,"side":"LEFT","start_side":"LEFT","commit_id":"current","original_commit_id":"reviewed","original_line":9,"original_start_line":7,"body":"Outdated"}]"#)])
        let section=try await GitHubPRDetailFetcher(client:.init(transport:transport)).section(repository:"o/r",number:1,sha:"current",tab:.conversation,token:"fixture")
        let event=try XCTUnwrap(section.events.first),coordinates=try XCTUnwrap(event.commentCoordinates)
        XCTAssertNil(coordinates.current.endLine);XCTAssertNil(coordinates.current.startLine)
        XCTAssertEqual(coordinates.original.reviewedHeadSHA,"reviewed");XCTAssertEqual(coordinates.original.startLine,7);XCTAssertEqual(coordinates.original.endLine,9)
        XCTAssertEqual(coordinates.current.startSide,"LEFT");XCTAssertEqual(coordinates.path,"renamed.swift")
        XCTAssertNil(event.providerComment)
        XCTAssertNil(event.renderingAnchor(in:.init(baseSHA:"base",headSHA:"current",files:[.init(path:"renamed.swift",status:.modified,patch:"@@ -7,3 +7,3 @@\n a\n b\n c")],expectedFiles:1)))
    }
}

extension PRDetailRevisionFixTests {
    func testSnapshotInventoryUsesBothFrozenDirectionsAndCannotSupplyProviderWriteAnchors() async throws {
        let old=String(repeating:"a",count:40),new=String(repeating:"b",count:40),base=String(repeating:"c",count:40)
        let transport=ScriptedTransport([json("{\"merge_base_commit\":{\"sha\":\"\(base)\"},\"files\":[]}"),json("{\"merge_base_commit\":{\"sha\":\"\(base)\"},\"files\":[{\"filename\":\"old-only\",\"status\":\"added\",\"additions\":1,\"deletions\":0}]}")])
        let doc=try await GitHubPRDetailFetcher(client:.init(transport:transport)).snapshotInterdiff(repository:"o/r",old:old,new:new,token:"fixture")
        XCTAssertEqual(doc.comparison,.snapshot);XCTAssertEqual(doc.baseSHA,old);XCTAssertEqual(doc.files.first?.status,.removed)
        let requests=await transport.captured();XCTAssertEqual(requests.map { $0.url!.path },["/repos/o/r/compare/\(old)...\(new)","/repos/o/r/compare/\(new)...\(old)"])
        let file=try await SnapshotDiffWorker.shared.diff(file:doc.files[0],before:"old-only",after:nil)
        let ready=doc.replacing(file),anchor=try ready.anchor(file:file,side:.left,start:1,end:1)
        XCTAssertNil(ready.providerCommentLocation(for:anchor))
        XCTAssertNil(PRDetailEvent(id:"c",title:"",body:"",url:nil,providerComment:.init(reviewedHeadSHA:new,path:file.path,side:"LEFT",startLine:1,endLine:1)).renderingAnchor(in:ready))
    }
}
