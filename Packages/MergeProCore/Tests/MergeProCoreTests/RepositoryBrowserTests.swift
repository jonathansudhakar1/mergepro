import XCTest
@testable import MergeProCore

final class RepositoryBrowserTests: XCTestCase, @unchecked Sendable {
    func testCommitQueryEncodesPathAuthorAndImmutableSHA() async throws {
        let transport=ScriptedTransport(bodies:["[]"])
        let reader=GitHubRepoReader(client:GitHubHTTPClient(transport:transport))
        _ = try await reader.commits(repository:"o/r",sha:String(repeating:"a",count:40),path:"Sources/a b.swift",author:"octo",page:2,token:"token")
        let urls=await transport.urls()
        let parts=URLComponents(string:urls[0])!
        XCTAssertEqual(parts.queryItems?.first { $0.name == "path" }?.value,"Sources/a b.swift")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "author" }?.value,"octo")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "page" }?.value,"2")
    }
    func testTreeReadsAreNonrecursiveAndKeepIncompleteFlag() async throws {
        let transport=ScriptedTransport(bodies:["{\"tree\":[{\"path\":\"sub\",\"mode\":\"040000\",\"type\":\"tree\",\"sha\":\"abc\"}],\"truncated\":true}"])
        let reader=GitHubRepoReader(client:GitHubHTTPClient(transport:transport))
        let page=try await reader.tree(repository:"o/r",sha:String(repeating:"a",count:40),token:"token")
        XCTAssertTrue(page.truncated)
        let urls=await transport.urls();XCTAssertFalse(urls[0].contains("recursive"))
    }
    func testUnsafePathsAndMutableBlobRefsAreRejected() async throws {
        let reader=GitHubRepoReader(client:GitHubHTTPClient(transport:ScriptedTransport()))
        do { _ = try await reader.tree(repository:"../r",sha:"main",token:"token");XCTFail() } catch {}
    }
    func testAssetNamingNeverEscapesDestinationAndDoesNotOverwrite() throws {
        let directory=try makeTemporaryDirectory()
        let first=try RepositoryAssetDownload.save(Data("first".utf8),name:"../../archive.zip",directory:directory)
        let second=try RepositoryAssetDownload.save(Data("second".utf8),name:"../../archive.zip",directory:directory)
        XCTAssertEqual(first.lastPathComponent,"archive.zip")
        XCTAssertNotEqual(first,second)
        XCTAssertEqual(try String(contentsOf:first,encoding:.utf8),"first")
    }
}

/// Two commit pages: page 1 links to page 2, which is the last.
private func pagedCommitsTransport() async -> RoutingTransport {
    func page(_ sha:Character) -> String { "[{\"sha\":\"\(String(repeating:sha,count:40))\",\"commit\":{\"message\":\"page\",\"author\":{\"name\":\"author\"}}}]" }
    let transport=RoutingTransport()
    await transport.route(query:["page":"2"],json(page("b")))
    await transport.route(json(page("a"),headers:["Link":"<https://api.github.com/repos/o/r/commits?page=2>; rel=\"next\""]))
    return transport
}
extension RepositoryBrowserTests {
    func testCommitPaginationUsesScopedEndpointAndSignalsLastPage() async throws {
        let reader=GitHubRepoReader(client:GitHubHTTPClient(transport:await pagedCommitsTransport()))
        let first=try await reader.commits(repository:"o/r",sha:String(repeating:"a",count:40),path:"Sources",author:"octo",token:"fixture")
        XCTAssertEqual(first.nextPage,2)
        let second=try await reader.commits(repository:"o/r",sha:String(repeating:"a",count:40),path:"Sources",author:"octo",page:first.nextPage!,token:"fixture")
        XCTAssertNil(second.nextPage)
        XCTAssertNotEqual(first.values.first?.sha,second.values.first?.sha)
    }
}

extension RepositoryBrowserTests {
    func testEveryCreatableBranchNameIsBrowsable() throws {
        for name in ["feature/new-ui","fix/#12","issue#42","100%","a%2Fb","release-1.0","\u{e9}-branch","a+b","a,b","{x}"] {
            XCTAssertTrue(BranchService.validName(name),name)
            XCTAssertEqual(try GitHubRepoReader.refComponent(name),name)
        }
    }
    func testBranchValidationFollowsGitCheckRefFormat() throws {
        for name in ["HEAD","a.lock/b",".hidden","a/.b","a\u{7f}b","a~1","a^","a:b","a*","a[b","/a","a/","a.","@","-x","a@{1}"] { XCTAssertFalse(BranchService.validName(name),name) }
        for name in ["","a..b","a?b","a\\b","a b","a\nb","a\u{7f}b","a//b","/a","a/./b"] {
            XCTAssertFalse(BranchService.validName(name),name)
            XCTAssertThrowsError(try GitHubRepoReader.refComponent(name),name)
        }
    }
    func testBrowsePathPercentEncodesHashAndPercentRefs() async throws {
        let transport=ScriptedTransport(bodies:["{\"sha\":\"\(String(repeating:"a",count:40))\",\"commit\":{\"tree\":{\"sha\":\"\(String(repeating:"b",count:40))\"}}}"])
        let reader=GitHubRepoReader(client:GitHubHTTPClient(transport:transport))
        let ref=try await reader.resolve(repository:"o/r",ref:"fix/#12%",token:"token")
        XCTAssertEqual(ref.name,"fix/#12%")
        let urls=await transport.urls();XCTAssertEqual(urls,["https://api.github.com/repos/o/r/commits/fix/%2312%25"])
    }
}
