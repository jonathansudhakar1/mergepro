import XCTest
@testable import MergeProCore

final class GitStatusParserTests: XCTestCase {
    func testPorcelainV2PreservesRenameUnicodeAndLiteralPaths() throws {
        let text = "# branch.oid abc123\0# branch.head feature/topic\0# branch.upstream origin/feature/topic\0# branch.ab +2 -3\0"
            + "1 .M N... 100644 100644 100644 a b spaced 雪.txt\0"
            + "2 R. N... 100644 100644 100644 a b R100 new\nname.txt\0old \"name\".txt\0"
            + "? --literal;$(touch injected).txt\0u UU N... 100644 100644 100644 100644 a b c conflict.txt\0"
        let result = try GitStatusParser.parse(Data(text.utf8))
        XCTAssertEqual(result.branch, "feature/topic")
        XCTAssertEqual(result.ahead, 2); XCTAssertEqual(result.behind, 3)
        XCTAssertEqual(result.entries.map(\.path), ["spaced 雪.txt", "new\nname.txt", "--literal;$(touch injected).txt", "conflict.txt"])
        XCTAssertEqual(result.entries[1].originalPath, "old \"name\".txt")
        XCTAssertEqual(result.entries[0].worktreeStatus, "M")
        XCTAssertTrue(result.entries[2].isUntracked); XCTAssertTrue(result.entries[3].isUnmerged)
    }
    func testMalformedStatusFailsInsteadOfShowingCleanTree() {
        for text in ["1 M.\0", "2 R. N... 100644 100644 100644 a b R100 new\0", "? path", "unexpected\0"] {
            XCTAssertThrowsError(try GitStatusParser.parse(Data(text.utf8)))
        }
    }
    func testWorktreeNULRecordsPreservePathsAndLockReasons() throws {
        let data = Data("worktree /tmp/repo 雪\npath\0HEAD abc\0branch refs/heads/main\0\0worktree /tmp/linked\0HEAD def\0detached\0locked manual reason\nnext line\0prunable missing gitdir\0\0".utf8)
        let result = try GitWorktreeParser.parse(data, repositoryID: .init(rawValue: "/tmp/common"))
        XCTAssertEqual(result.count, 2); XCTAssertEqual(result[0].directory.path, "/tmp/repo 雪\npath")
        XCTAssertEqual(result[0].branch, "main"); XCTAssertTrue(result[1].isDetached)
        XCTAssertEqual(result[1].lockReason, "manual reason\nnext line"); XCTAssertTrue(result[1].isPrunable)
        XCTAssertNotEqual(result[0].id, result[1].id)
    }
}
