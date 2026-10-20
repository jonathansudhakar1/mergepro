import XCTest
@testable import MergeProCore

/// Reads of the "old" tree stay in flight at `oldRead` until the test opens it.
private actor TreeFixture: GitTreeProvider {
    var calls: [String] = []
    let oldRead = TestGate()
    func children(repository: RepoCatalogEntry, ref: ResolvedRepositoryRef, treeSHA: String) async throws -> GitTreePage {
        calls.append(treeSHA)
        if treeSHA == "old" { await oldRead.enter() }
        if treeSHA == "broken" { throw GitHubFailure.invalidResponse }
        return GitTreePage(entries:[GitTreeEntry(path:treeSHA == "child" ? "file.swift" : "Sources",mode:treeSHA == "child" ? "100644" : "040000",type:treeSHA == "child" ? "blob" : "tree",sha:"child")],truncated:treeSHA == "partial")
    }
}
final class RefTreeTests: XCTestCase, @unchecked Sendable {
    let repo=RepoCatalogEntry(repository:Repository(key:RepositoryKey(account:AccountScope(host:"github.com",accountID:"1"),repositoryID:"2"),name:"o/r",isPrivate:false,capabilities:[]),accountLogin:"a")
    func testLazyDirectoryTraversalAndNearestExistingParent() async throws {
        let store=RefTreeStore(provider:TreeFixture())
        try await store.switchRef(repository:repo,ref:ResolvedRepositoryRef(name:"main",commitSHA:"a",treeSHA:"root"),preserving:"Sources/removed.swift")
        let state=await store.snapshot()
        XCTAssertEqual(state.selection,"Sources")
        XCTAssertNotNil(state.missingPath)
        XCTAssertEqual(state.children["Sources"]?.count,1)
    }
    func testTruncatedTreeCannotAppearComplete() async throws {
        let store=RefTreeStore(provider:TreeFixture())
        try await store.switchRef(repository:repo,ref:ResolvedRepositoryRef(name:"main",commitSHA:"a",treeSHA:"partial"))
        let state=await store.snapshot()
        XCTAssertEqual(state.loading[""],.incomplete)
    }
    func testPreviousRefResponseCannotReplaceNewTree() async throws {
        let provider=TreeFixture(),store=RefTreeStore(provider:provider)
        let old=Task { try await store.switchRef(repository:repo,ref:ResolvedRepositoryRef(name:"old",commitSHA:"a",treeSHA:"old")) }
        await provider.oldRead.arrivals()
        try await store.switchRef(repository:repo,ref:ResolvedRepositoryRef(name:"new",commitSHA:"b",treeSHA:"root"))
        await provider.oldRead.open()
        _ = try? await old.value
        let state=await store.snapshot()
        XCTAssertEqual(state.ref?.name,"new")
    }
}

extension RefTreeTests {
    func testIncompleteRootStillTraversesChildSubtreeSeparately() async throws {
        let store=RefTreeStore(provider:TreeFixture())
        try await store.switchRef(repository:repo,ref:ResolvedRepositoryRef(name:"main",commitSHA:"a",treeSHA:"partial"))
        try await store.expand("Sources")
        let state=await store.snapshot()
        XCTAssertEqual(state.loading[""],.incomplete)
        XCTAssertEqual(state.loading["Sources"],.loaded)
        XCTAssertEqual(state.children["Sources"]?.first?.path,"Sources/file.swift")
    }
}
