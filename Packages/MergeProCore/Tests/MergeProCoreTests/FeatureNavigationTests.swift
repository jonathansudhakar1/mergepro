import XCTest
@testable import MergeProCore

final class FeatureNavigationTests:XCTestCase {
    let a = AccountScope(host:"github.com",accountID:"a")
    let b = AccountScope(host:"github.com",accountID:"b")
    func repo(_ account:AccountScope) -> Repository {
        Repository(key:.init(account:account,repositoryID:"7"),name:"owner/repo",isPrivate:true,capabilities:.init())
    }
    func testNativeRoutesRequireScopedAccountChoice() {
        let url = URL(string:"https://github.com/owner/repo/actions/runs/123")!
        XCTAssertEqual(FeatureRouteResolver.resolve(url,repositories:[repo(a),repo(b)],activeAccount:nil),.chooseAccount([repo(a).key,repo(b).key]))
        XCTAssertEqual(FeatureRouteResolver.resolve(url,repositories:[repo(a),repo(b)],activeAccount:b),.actions(repository:repo(b).key,runID:123))
        XCTAssertEqual(FeatureRouteResolver.resolve(url,repositories:[repo(a)],activeAccount:b),.unavailable)
    }
    func testImmutableAndKnownSlashRefsResolveWithoutGuessing() {
        let repository = repo(a)
        let url = URL(string:"https://github.com/owner/repo/blob/feature/new-ui/Sources/App.swift#L7")!
        XCTAssertEqual(FeatureRouteResolver.resolve(url,repositories:[repository],activeAccount:a),.web(url))
        let resolved = FeatureRouteResolver.resolve(url,repositories:[repository],activeAccount:a,refs:[repository.key:["feature/new-ui"]])
        XCTAssertEqual(resolved,.repository(repository.key,ref:"feature/new-ui",path:"Sources/App.swift",section:"code",line:7))
        let sha = String(repeating:"a",count:40)
        let immutable = URL(string:"https://github.com/owner/repo/tree/\(sha)/Sources")!
        XCTAssertEqual(FeatureRouteResolver.resolve(immutable,repositories:[repository],activeAccount:a),.repository(repository.key,ref:sha,path:"Sources",section:"code",line:nil))
    }
    func testUnknownOriginsAndTraversalNeverBecomeNativeRoutes() {
        for raw in ["https://evil.test/owner/repo", "https://github.com.evil.test/owner/repo", "https://user@github.com/owner/repo", "http://github.com/owner/repo", "https://github.com/owner/repo/blob/main/%2e%2e/private"] {
            let url = URL(string:raw)!
            XCTAssertEqual(FeatureRouteResolver.resolve(url,repositories:[repo(a)],activeAccount:a,refs:[repo(a).key:["main"]]),.web(url))
        }
    }
    func testCommandsExposeActionsAndRepos() {
        XCTAssertEqual(PRPaletteSearch.commands(query:">actions").map(\.destination),[.actions])
        XCTAssertEqual(PRPaletteSearch.commands(query:">repositories").map(\.destination),[.repos])
    }
}
