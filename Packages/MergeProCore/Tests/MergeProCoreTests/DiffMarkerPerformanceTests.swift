import XCTest
@testable import MergeProCore

final class DiffMarkerPerformanceTests:XCTestCase {
    func testIndexedWorkerProducesReusableMarkersWithLinearScaling() async throws {
        func run(_ count:Int) async throws -> (Double,Int) {
            let old=(1...count).map { "old\($0)" }.joined(separator:"\n")
            let new=(1...count).map { "new\($0)" }.joined(separator:"\n")
            let patch="@@ -1,\(count) +1,\(count) @@\n"+old.split(separator:"\n").map { "-"+$0 }.joined(separator:"\n")+"\n"+new.split(separator:"\n").map { "+"+$0 }.joined(separator:"\n")
            let file=DiffFile(path:"new",previousPath:"old",status:.renamed,patch:patch)
            let doc=DiffDocument(baseSHA:"b",headSHA:"h",files:[file],expectedFiles:1)
            let context=try DiffContext(document:doc,file:file,before:.init(sha:"b",text:old),after:.init(sha:"h",text:new))
            let clock=ContinuousClock(),start=clock.now
            let result=try await DiffPresentationWorker.shared.prepare(document:doc,file:file,context:context,expansion:[:],events:[],hideWhitespace:false,fullSource:new,fullSide:.right)
            let elapsed=start.duration(to:clock.now).components
            XCTAssertEqual(result.markers["unified"]?.count,count*4)
            XCTAssertEqual(result.markers["full"]?.last?.anchor.endLine,count)
            XCTAssertEqual(try context.anchor(side:.left,start:count,end:count,visible:result.visible).path,"old")
            return (Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18,result.markers["full"]?.count ?? 0)
        }
        _ = try await run(100)
        let small=try await run(2500),large=try await run(10000)
        print("Marker pipeline component: 2500=\(small.0)s 10000=\(large.0)s; includes 3 presentations + full-source markers; no UI/open claim")
        XCTAssertEqual(large.1,small.1*4)
        XCTAssertLessThan(large.0,max(0.1,small.0)*8,"4x rows must avoid quadratic 16x growth; generous scheduling floor")
    }
}
