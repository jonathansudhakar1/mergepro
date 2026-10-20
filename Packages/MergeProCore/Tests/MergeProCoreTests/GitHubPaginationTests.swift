import XCTest
@testable import MergeProCore

/// RFC 8288 parsing and the one continuation validation shared by every REST list reader.
final class GitHubPaginationTests: XCTestCase {
    let client = GitHubHTTPClient(transport: PagingTransport([]))
    let runs = URL(string: "https://api.github.com/repos/o/r/actions/runs?per_page=100")!
    typealias P = GitHubPagination

    func testParsesQuotedUnquotedAndMultipleRelationsInAnyOrder() {
        let header = #"<https://api.github.com/x?page=9>; title="last, really; yes"; rel="last", <https://api.github.com/x?a=1,2&page=2>;rel=next , <https://api.github.com/x?page=1>; REL="Prev First""#
        XCTAssertEqual(P.links(header), [
            .init(target: "https://api.github.com/x?page=9", relations: ["last"]),
            .init(target: "https://api.github.com/x?a=1,2&page=2", relations: ["next"]),
            .init(target: "https://api.github.com/x?page=1", relations: ["prev", "first"]),
        ])
        XCTAssertEqual(P.links(#"<u>; rel="next last""#).first?.relations, ["next", "last"])
        XCTAssertEqual(P.links(#"<u>; rel = "next""#).first?.relations, ["next"])
        // RFC 8288 §3.3: occurrences of rel after the first are ignored.
        XCTAssertEqual(P.links(#"<u>; rel="prev"; rel="next""#).first?.relations, ["prev"])
        XCTAssertEqual(P.links(#"<u>; title="rel=\"next\""; rel=last"#).first?.relations, ["last"])
        XCTAssertEqual(P.links(nil), [])
        XCTAssertEqual(P.links(""), [])
        XCTAssertEqual(P.links(#"not-a-link; rel="next""#), [.init(target: nil, relations: ["next"])])
    }
    func testHintNeverReportsTheLastPageFromAnUnreadableHeader() {
        XCTAssertTrue(P.hasNext(#"<https://api.github.com/x?page=2>; rel="next""#))
        XCTAssertTrue(P.hasNext(#"<x>; rel="next""#))
        XCTAssertTrue(P.hasNext(#"<x>; rel=next"#))
        XCTAssertTrue(P.hasNext(#"<x>; rel="last next""#))
        XCTAssertTrue(P.hasNext(#"not-a-link; rel="next""#))
        XCTAssertTrue(P.hasNext(#"rel="next""#))
        XCTAssertFalse(P.hasNext(nil))
        XCTAssertFalse(P.hasNext(#"<https://api.github.com/x?page=1>; rel="prev", <https://api.github.com/x?page=1>; rel="first""#))
        XCTAssertFalse(P.hasNext(#"<https://api.github.com/x?rel="next">; rel="last""#))
    }
    func testNextAcceptsSamePathAndPinnedRepositoryForm() throws {
        XCTAssertNil(try P.next(nil, client: client, requested: runs))
        XCTAssertNil(try P.next(#"<https://api.github.com/repos/o/r/actions/runs?page=1>; rel="prev""#, client: client, requested: runs))
        XCTAssertEqual(try P.next(#"<https://api.github.com/repos/o/r/actions/runs?page=2>; rel="next""#, client: client, requested: runs),
                       URL(string: "https://api.github.com/repos/o/r/actions/runs?page=2"))
        XCTAssertEqual(try P.next(#"<https://API.github.com/repositories/7/actions/runs?page=2>; rel="next last""#, client: client, requested: runs, repositoryID: "7"),
                       URL(string: "https://API.github.com/repositories/7/actions/runs?page=2"))
        XCTAssertEqual(try P.next(#"<https://api.github.com/repos/o/r/actions/runs?status=a,b&page=2>; rel=next"#, client: client, requested: runs),
                       URL(string: "https://api.github.com/repos/o/r/actions/runs?status=a,b&page=2"))
        let same = #"<https://api.github.com/repos/o/r/actions/runs?page=2>; rel="next", <https://api.github.com/repos/o/r/actions/runs?page=2>; rel="next""#
        XCTAssertEqual(try P.next(same, client: client, requested: runs), URL(string: "https://api.github.com/repos/o/r/actions/runs?page=2"))
    }
    func testNextRejectsEveryUnsafeContinuation() {
        let unsafe = [
            "<https://evil.test/repos/o/r/actions/runs?page=2>",
            "<http://api.github.com/repos/o/r/actions/runs?page=2>",
            "<https://user@api.github.com/repos/o/r/actions/runs?page=2>",
            "<https://user:secret@api.github.com/repos/o/r/actions/runs?page=2>",
            "<https://api.github.com:444/repos/o/r/actions/runs?page=2>",
            "<//evil.test/repos/o/r/actions/runs?page=2>",
            "</repos/o/r/actions/runs?page=2>",
            "<repos/o/r/actions/runs?page=2>",
            "<https://api.github.com/repos/o/r/actions/workflows?page=2>",
            "<https://api.github.com/repos/o/other/actions/runs?page=2>",
            "<https://api.github.com/repositories/8/actions/runs?page=2>",
            "<https://api.github.com/repositories/7/actions/workflows?page=2>",
            "<not a url>",
            "not-a-link",
        ].map { $0 + #"; rel="next""# }
        for header in unsafe {
            XCTAssertThrowsError(try P.next(header, client: client, requested: runs, repositoryID: "7"), header) { XCTAssertEqual($0 as? GitHubFailure, .unsafeURL, header) }
        }
        // Without a pinned repository ID only the requested path itself is accepted.
        XCTAssertThrowsError(try P.next(#"<https://api.github.com/repositories/7/actions/runs?page=2>; rel="next""#, client: client, requested: runs))
        // Disagreeing continuations, or one unsafe among several, reject the page.
        XCTAssertThrowsError(try P.next(#"<https://api.github.com/repos/o/r/actions/runs?page=2>; rel="next", <https://api.github.com/repos/o/r/actions/runs?page=3>; rel="next""#, client: client, requested: runs))
        XCTAssertThrowsError(try P.next(#"<https://api.github.com/repos/o/r/actions/runs?page=2>; rel="next", <https://evil.test/x>; rel="next""#, client: client, requested: runs))
        // An unsafe link with another relation is not a continuation and is ignored.
        XCTAssertNil(try P.next(#"<https://evil.test/x>; rel="last""#, client: client, requested: runs))
    }
    /// Only a `next` relation is a continuation: a link-value without a bracketed target (or a stray
    /// parameter) that names no `next` never makes a hint reader page on.
    func testHintCountsOnlyNextRelations() {
        XCTAssertFalse(P.hasNext("garbage"))
        XCTAssertFalse(P.hasNext(#"not-a-link; rel="last""#))
        XCTAssertFalse(P.hasNext(#"<https://api.github.com/x?page=1>; rel="prev", junk"#))
        XCTAssertTrue(P.hasNext(#"junk, <https://api.github.com/x?page=2>; rel="next""#))
    }
    /// A `<` inside a parameter value is not a target: it must not swallow the following link-values.
    func testStrayAngleBracketInAParameterDoesNotHideLaterLinks() throws {
        let header = #"<https://api.github.com/repos/o/r/actions/runs?page=9>; title=a<b; rel="last", <https://api.github.com/repos/o/r/actions/runs?page=2>; rel="next""#
        XCTAssertEqual(P.links(header).map(\.relations), [["last"], ["next"]])
        XCTAssertTrue(P.hasNext(header))
        XCTAssertEqual(try P.next(header, client: client, requested: runs), URL(string: "https://api.github.com/repos/o/r/actions/runs?page=2"))
    }
    /// An HTTP origin (test or misconfigured enterprise host) never yields a continuation.
    func testNonHTTPSOriginNeverFollows() {
        let insecure = GitHubHTTPClient(origin: URL(string: "http://api.github.com")!, transport: PagingTransport([]))
        XCTAssertThrowsError(try P.next(#"<http://api.github.com/repos/o/r/actions/runs?page=2>; rel="next""#, client: insecure, requested: URL(string: "http://api.github.com/repos/o/r/actions/runs")!))
    }
}
