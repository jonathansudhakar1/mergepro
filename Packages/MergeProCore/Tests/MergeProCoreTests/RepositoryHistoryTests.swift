import XCTest
@testable import MergeProCore

/// The "old" author's query stays in flight at `oldQuery` until the test opens it.
private actor HistoryFixture:RepositoryCommitProvider {
    var pages:[Int]=[]
    let oldQuery=TestGate()
    func commits(repository:RepoCatalogEntry,ref:ResolvedRepositoryRef,path:String?,author:String?,page:Int) async throws -> RepositoryPage<RepositoryCommit> {
        pages.append(page)
        if author=="old" { await oldQuery.enter() }
        return RepositoryPage(values:[RepositoryCommit(sha:(author ?? "new")+String(page),message:"commit",author:author ?? "new",date:nil,webURL:nil)],nextPage:page==1 ? 2:nil)
    }
}
final class RepositoryHistoryTests:XCTestCase,@unchecked Sendable {
    let repository=RepoCatalogEntry(repository:Repository(key:RepositoryKey(account:AccountScope(host:"github.com",accountID:"a"),repositoryID:"1"),name:"o/r",isPrivate:false,capabilities:[]),accountLogin:"a")
    let ref=ResolvedRepositoryRef(name:"main",commitSHA:"sha",treeSHA:"tree")
    func testDelayedOldAuthorQueryCannotAppendToNewQueryAtSameRef() async throws {
        let provider=HistoryFixture(),store=RepositoryHistoryStore(provider:provider)
        let old=Task { try await store.reset(repository:repository,ref:ref,path:nil,author:"old") }
        await provider.oldQuery.arrivals()
        try await store.reset(repository:repository,ref:ref,path:nil,author:"new")
        await provider.oldQuery.open()
        _ = try? await old.value
        let state=await store.snapshot();XCTAssertEqual(state.commits.map(\.author),["new"])
    }
    func testConcurrentLoadMoreReservesOnePage() async throws {
        let store=RepositoryHistoryStore(provider:HistoryFixture())
        try await store.reset(repository:repository,ref:ref,path:nil,author:"new")
        async let first:Void=store.loadMore();async let second:Void=store.loadMore();_ = try await (first,second)
        let state=await store.snapshot();XCTAssertEqual(state.commits.count,2)
        XCTAssertNil(state.nextPage)
    }
}
