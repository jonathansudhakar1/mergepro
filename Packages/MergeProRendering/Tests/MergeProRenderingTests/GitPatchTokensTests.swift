import XCTest
@testable import MergeProRendering

final class GitPatchTokensTests:XCTestCase {
    func testClassifiesHeadersHunksAndChangedLines() {
        let patch="WORKING TREE CHANGES\ndiff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@ func f() {\n context\n-old\n+new\n\\ No newline at end of file"
        let scopes=GitPatchTokens.tokens(in:patch).map { token -> String in
            let text=(patch as NSString).substring(with:token.range).trimmingCharacters(in:.newlines)
            return "\(token.scopes[0]):\(text)"
        }
        XCTAssertEqual(scopes,[
            "diff.meta:diff --git a/x b/x","diff.meta:index 1..2 100644","diff.meta:--- a/x","diff.meta:+++ b/x",
            "diff.hunk:@@ -1,2 +1,2 @@",
            "diff.removed:-old","diff.sign.removed:-","diff.added:+new","diff.sign.added:+",
            "diff.meta:\\ No newline at end of file",
        ])
    }
    func testRangesStayInsideTextWithoutTrailingNewline() {
        let patch="@@ -1 +1 @@\n+é"
        for token in GitPatchTokens.tokens(in:patch) { XCTAssertLessThanOrEqual(NSMaxRange(token.range),patch.utf16.count) }
    }
}
