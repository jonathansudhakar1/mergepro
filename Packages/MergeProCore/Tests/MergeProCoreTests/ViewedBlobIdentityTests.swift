import XCTest
@testable import MergeProCore

/// Viewed marks are keyed by what the reviewer saw. With a usable patch that is the patch itself (status, rename
/// origin and both sides of every hunk), so a change on the base side alone (a merge from main that keeps the
/// author's version) is new content to review. Only without a usable patch (binary or oversized) does the
/// provider's head blob identify the content. Marks stored with the patch hash keep matching.
final class ViewedBlobIdentityTests: XCTestCase {
    static let patch = "@@ -1 +1 @@\n-a\n+b"
    /// SHA-256 of "modified\0\0<patch>\0": the identity every mark stored before this change carries.
    static let legacyIdentity = "f9520a26cf9d5bfb9837766f48cddaaee826f086c23149517a7089e0e24c23b3"
    static let blob = String(repeating: "1", count: 40), otherBlob = String(repeating: "2", count: 40)
    func document(_ head: String, _ files: [DiffFile]) -> DiffDocument { DiffDocument(baseSHA: "base", headSHA: head, files: files, expectedFiles: files.count) }

    func testPatchIdentityIsUnchanged() {
        XCTAssertEqual(DiffFile(path: "a.swift", status: .modified, patch: Self.patch).viewedContentIdentity, Self.legacyIdentity)
        XCTAssertEqual(DiffFile(path: "a.swift", status: .modified, patch: Self.patch).patchContentIdentity, Self.legacyIdentity)
    }
    func testAPatchIdentifiesContentEvenWhenTheHeadBlobIsKnown() throws {
        let file = DiffFile(path: "a.swift", status: .modified, patch: Self.patch, sha: Self.blob)
        XCTAssertEqual(file.viewedContentIdentity, Self.legacyIdentity, "the patch covers both sides; the head blob alone does not")
        XCTAssertNotEqual(DiffFile(path: "a.swift", status: .modified, patch: "@@ -1 +1 @@\n-z\n+b", sha: Self.blob).viewedContentIdentity, file.viewedContentIdentity,
                          "same head blob, different base side: the diff changed")
    }
    func testBlobIdentityCoversBlobStatusAndRenameWhenThereIsNoPatch() throws {
        let file = DiffFile(path: "image.png", status: .modified, patch: nil, sha: Self.blob)
        let identity = try XCTUnwrap(file.viewedContentIdentity)
        XCTAssertTrue(identity.hasPrefix("blob:"))
        XCTAssertNil(file.patchContentIdentity)
        XCTAssertNotEqual(DiffFile(path: "image.png", status: .modified, patch: nil, sha: Self.otherBlob).viewedContentIdentity, identity)
        XCTAssertNotEqual(DiffFile(path: "image.png", status: .added, patch: nil, sha: Self.blob).viewedContentIdentity, identity)
        XCTAssertNotEqual(DiffFile(path: "image.png", previousPath: "old.png", status: .renamed, patch: nil, sha: Self.blob).viewedContentIdentity, identity)
        XCTAssertNil(DiffFile(path: "image.png", status: .modified, patch: nil).viewedContentIdentity, "neither patch nor blob: unknown")
        for sha in ["", "abc", String(repeating: "g", count: 40), String(repeating: "0", count: 40)] {
            XCTAssertNil(DiffFile(path: "image.png", status: .modified, patch: nil, sha: sha).viewedContentIdentity, sha)
        }
        XCTAssertEqual(DiffFile(path: "image.png", status: .modified, patch: nil, sha: String(repeating: "a", count: 64)).viewedContentIdentity?.hasPrefix("blob:"), true, "SHA-256 repositories")
    }
    func testOldStoredMarksAreHonouredWhereStillValid() throws {
        let blobMark = DiffFile(path: "c.png", status: .modified, patch: nil, sha: Self.blob).viewedContentIdentity!
        let legacy = #"{"headSHA":"h1","viewed":["a.swift","b.swift","c.png"],"viewedContent":{"a.swift":"\#(Self.legacyIdentity)","b.swift":"\#(Self.legacyIdentity)","c.png":"\#(blobMark)"}}"#
        var state = try JSONDecoder().decode(PRDetailState.self, from: Data(legacy.utf8))
        state.acceptRevision("h2")
        let a = DiffFile(path: "a.swift", status: .modified, patch: Self.patch, sha: Self.blob)
        let b = DiffFile(path: "b.swift", status: .modified, patch: "@@ -1 +1 @@\n-a\n+c", sha: Self.otherBlob)
        let c = DiffFile(path: "c.png", status: .modified, patch: nil, sha: Self.blob)
        XCTAssertTrue(state.reconcile(document("h2", [a, b, c])))
        XCTAssertEqual(state.viewed, ["a.swift", "c.png"], "an unchanged patch keeps its mark; an unchanged blob without a patch keeps its mark; a changed patch drops it")
        XCTAssertEqual(state.viewedContent["a.swift"], Self.legacyIdentity)
        state.acceptRevision("h3")
        state.reconcile(document("h3", [DiffFile(path: "a.swift", status: .modified, patch: "@@ -1 +1 @@\n-x\n+b", sha: Self.blob), c]))
        XCTAssertEqual(state.viewed, ["c.png"], "the same head blob with a changed base side is new content to review")
    }
    func testABlobMarkDoesNotCarryOnceAPatchShowsTheDiff() {
        // A mark keyed by the head blob alone cannot prove the base side is unchanged.
        let blobMark = "blob:" + String(repeating: "9", count: 64)
        let legacy = #"{"headSHA":"h1","viewed":["a.swift"],"viewedContent":{"a.swift":"\#(blobMark)"}}"#
        var state = try! JSONDecoder().decode(PRDetailState.self, from: Data(legacy.utf8))
        state.acceptRevision("h2")
        state.reconcile(document("h2", [DiffFile(path: "a.swift", status: .modified, patch: Self.patch, sha: Self.blob)]))
        XCTAssertTrue(state.viewed.isEmpty)
    }
    func testMarksCarryByPatchWhenTheBlobIsMissing() {
        let marked = DiffFile(path: "a.swift", status: .modified, patch: Self.patch, sha: Self.blob)
        var state = PRDetailState(headSHA: "h1")
        state.markViewed("a.swift", viewed: true, displayed: document("h1", [marked]), canonical: document("h1", [marked]))
        state.acceptRevision("h2")
        state.reconcile(document("h2", [DiffFile(path: "a.swift", status: .modified, patch: Self.patch)]))
        XCTAssertEqual(state.viewed, ["a.swift"], "the identical patch proves the diff is unchanged")
        state.acceptRevision("h3")
        state.reconcile(document("h3", [DiffFile(path: "a.swift", status: .modified, patch: nil, sha: Self.blob)]))
        XCTAssertTrue(state.viewed.isEmpty, "without a patch the earlier diff cannot be compared")
    }
    func testCodableAndEqualityCarryTheSHA() throws {
        let file = DiffFile(path: "a.swift", status: .modified, patch: Self.patch, additions: 1, deletions: 1, sha: Self.blob)
        let decoded = try JSONDecoder().decode(DiffFile.self, from: JSONEncoder.stable.encode(file))
        XCTAssertEqual(decoded.sha, Self.blob)
        XCTAssertEqual(decoded, file)
        XCTAssertNotEqual(file, DiffFile(path: "a.swift", status: .modified, patch: Self.patch, additions: 1, deletions: 1))
        let legacy = try JSONDecoder().decode(DiffFile.self, from: Data(#"{"path":"a.swift","status":"modified","patch":"@@ -1 +1 @@\n-a\n+b","additions":1,"deletions":1}"#.utf8))
        XCTAssertNil(legacy.sha)
        XCTAssertEqual(legacy.viewedContentIdentity, Self.legacyIdentity)
    }
    func testDetailFetcherReadsTheFilesAPISHA() async throws {
        let transport = RecordedGitHub { path, _, _ in
            switch path {
            case "/repos/o/r/pulls/7": return recorded(WriteReaderRecordedResponseTests.overview)
            case "/repos/o/r/pulls/7/files": return recorded(WriteReaderRecordedResponseTests.files)
            case "/repos/o/r/compare/\(WriteReaderRecordedResponseTests.target)...\(WriteReaderRecordedResponseTests.head)": return recorded(WriteReaderRecordedResponseTests.compare)
            default: return nil
            }
        }
        let snapshot = try await GitHubPRDetailFetcher(client: .init(transport: transport)).detail(repository: "o/r", number: 7, headSHA: WriteReaderRecordedResponseTests.head, token: "fixture")
        XCTAssertEqual(snapshot.files.map(\.sha), [String(repeating: "1", count: 40), String(repeating: "2", count: 40)])
        XCTAssertTrue(snapshot.files.allSatisfy { $0.viewedContentIdentity != nil && $0.viewedContentIdentity == ($0.patchContentIdentity ?? $0.viewedContentIdentity) })
    }
}
