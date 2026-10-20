import XCTest
@testable import MergeProCore

final class SnapshotInterdiffTests:XCTestCase {
    func testDivergentOldHeadOnlyChangeAppearsAsExactRemoval() async throws {
        let forward=DiffDocument(baseSHA:"common",headSHA:"new",files:[],expectedFiles:0)
        let reverse=DiffDocument(baseSHA:"common",headSHA:"old",files:[.init(path:"a",status:.modified,patch:"@@ -1 +1,2 @@\n same\n+old-only")],expectedFiles:1)
        let doc=try SnapshotInterdiff.candidates(forward:forward,reverse:reverse,requestedOld:"reviewed",requestedNew:"head")
        XCTAssertEqual(doc.baseSHA,"old");XCTAssertEqual(doc.headSHA,"new");XCTAssertEqual(doc.files.count,1)
        let file=try await SnapshotDiffWorker.shared.diff(file:doc.files[0],before:"same\nold-only\n",after:"same\n")
        XCTAssertEqual(file.lines.filter { $0.kind == .removed }.map(\.text),["old-only"])
        XCTAssertEqual(file.lines.filter { $0.kind == .added }.count,0)
        XCTAssertEqual(try doc.replacing(file).anchor(file:file,side:.left,start:2,end:2).commitSHA,"old")
    }
    func testRenameAndOldOnlyAddedFileRetainDeletionIdentity() async throws {
        let forward=DiffDocument(baseSHA:"common",headSHA:"new",files:[.init(path:"new-name",previousPath:"origin",status:.renamed,patch:nil)],expectedFiles:1)
        let reverse=DiffDocument(baseSHA:"common",headSHA:"old",files:[.init(path:"old-name",previousPath:"origin",status:.renamed,patch:nil),.init(path:"old-only",status:.added,patch:nil)],expectedFiles:2)
        let doc=try SnapshotInterdiff.candidates(forward:forward,reverse:reverse,requestedOld:"old",requestedNew:"new")
        let rename=try XCTUnwrap(doc.files.first { $0.path == "new-name" });XCTAssertEqual(rename.previousPath,"old-name")
        let deleted=try XCTUnwrap(doc.files.first { $0.path == "old-only" });XCTAssertEqual(deleted.status,.removed)
        let diff=try await SnapshotDiffWorker.shared.diff(file:deleted,before:"gone\n",after:nil)
        XCTAssertEqual(diff.lines.first?.oldLine,1);XCTAssertNil(diff.lines.first?.newLine)
    }
    func testExactLineDiffMixedInsertDeleteAndWorkLimit() async throws {
        let file=DiffFile(path:"a",status:.modified,patch:nil)
        let value=try await SnapshotDiffWorker.shared.diff(file:file,before:"one\na\nb\nend",after:"one\nb\nc\nend")
        XCTAssertEqual(value.lines.filter { $0.kind == .removed }.map(\.text),["a"])
        XCTAssertEqual(value.lines.filter { $0.kind == .added }.map(\.text),["c"])
        XCTAssertEqual(value.patchState,.available)
        do { _ = try await SnapshotDiffWorker.shared.diff(file:file,before:String(repeating:"x",count:2_000_001),after:"");XCTFail() } catch { XCTAssertEqual(error as? PRDetailFailure,.oversized) }
    }
}

extension SnapshotInterdiffTests {
    func testTerminalNewlineAndEmptySourcesAreExactAndUnchangedIsExplicit() async throws {
        let file=DiffFile(path:"a",status:.modified,patch:nil)
        let changed=try await SnapshotDiffWorker.shared.diff(file:file,before:"same\n",after:"same")
        XCTAssertEqual(changed.lines.filter { $0.kind == .removed }.count,1)
        XCTAssertEqual(changed.lines.filter { $0.kind == .added }.count,1)
        XCTAssertTrue(changed.patch?.contains("\\ No newline") == true)
        let unchanged=try await SnapshotDiffWorker.shared.diff(file:file,before:"same\n",after:"same\n")
        XCTAssertEqual(unchanged.status,.unchanged)
        let added=try await SnapshotDiffWorker.shared.diff(file:.init(path:"empty",status:.added,patch:nil),before:nil,after:"")
        XCTAssertEqual(added.status,.added);XCTAssertEqual(added.patchState,.available)
        let deleted=try await SnapshotDiffWorker.shared.diff(file:.init(path:"empty",status:.removed,patch:nil),before:"",after:nil)
        XCTAssertEqual(deleted.status,.removed)
    }
    func testIncompleteInventoryCannotGuessAbsentOrRenamedSide() throws {
        let forward=DiffDocument(baseSHA:"base",headSHA:"new",files:[],expectedFiles:301)
        let reverse=DiffDocument(baseSHA:"base",headSHA:"old",files:[.init(path:"maybe-renamed",status:.modified,patch:nil)],expectedFiles:1)
        let value=try SnapshotInterdiff.candidates(forward:forward,reverse:reverse,requestedOld:"old",requestedNew:"new")
        XCTAssertTrue(value.files.isEmpty);XCTAssertGreaterThan(value.missingFileCount,0)
        XCTAssertThrowsError(try SnapshotInterdiff.candidates(forward:forward,reverse:.init(baseSHA:"other",headSHA:"old",files:[],expectedFiles:0),requestedOld:"old",requestedNew:"new"))
    }
}

extension SnapshotInterdiffTests {
    func testCandidateAndAllocationCapsAndAmbiguousRenameAreExplicit() async throws {
        let files=(1...201).map { DiffFile(path:"f\($0)",status:.modified,patch:nil) }
        let value=try SnapshotInterdiff.candidates(forward:.init(baseSHA:"b",headSHA:"new",files:files,expectedFiles:201),reverse:.init(baseSHA:"b",headSHA:"old",files:[],expectedFiles:0),requestedOld:"old",requestedNew:"new")
        XCTAssertEqual(value.files.count,200);XCTAssertEqual(value.missingFileCount,1)
        let duplicate=[DiffFile(path:"one",previousPath:"origin",status:.renamed,patch:nil),DiffFile(path:"two",previousPath:"origin",status:.renamed,patch:nil)]
        XCTAssertThrowsError(try SnapshotInterdiff.candidates(forward:.init(baseSHA:"b",headSHA:"new",files:duplicate,expectedFiles:2),reverse:.init(baseSHA:"b",headSHA:"old",files:[],expectedFiles:0),requestedOld:"old",requestedNew:"new"))
        do { _ = try await SnapshotDiffWorker.shared.diff(file:files[0],before:(1...1000).map { "a\($0)" }.joined(separator:"\n"),after:(1...1000).map { "b\($0)" }.joined(separator:"\n"));XCTFail() } catch { XCTAssertEqual(error as? PRDetailFailure,.oversized) }
    }
    func testSmallExactDiffReconstructsBothSidesIncludingTerminalNewline() async throws {
        let samples=["","a","a\n","a\nb","a\nb\n","b\na\n","c\na\nb\n"]
        for before in samples { for after in samples {
            let value=try await SnapshotDiffWorker.shared.diff(file:.init(path:"a",status:.modified,patch:nil),before:before,after:after)
            XCTAssertEqual(value.patchState,.available)
            func lines(_ value:String) -> [String] { if value.isEmpty { return [] };var rows=value.components(separatedBy:"\n");if value.hasSuffix("\n") { rows.removeLast() };return rows }
            XCTAssertEqual(value.lines.filter { $0.kind != .added }.map(\.text),lines(before))
            XCTAssertEqual(value.lines.filter { $0.kind != .removed }.map(\.text),lines(after))
        } }
    }
}
