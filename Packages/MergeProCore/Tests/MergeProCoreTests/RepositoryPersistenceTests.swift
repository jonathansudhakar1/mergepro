import XCTest
@testable import MergeProCore

final class RepositoryPersistenceTests:XCTestCase {
    func testCodeStateRestoresPerAccountRefSelectionExpansionAndScroll() throws {
        let database=try DatabaseStore(path:":memory:")
        let a=RepositoryKey(account:AccountScope(host:"github.com",accountID:"a"),repositoryID:"1"),b=RepositoryKey(account:AccountScope(host:"github.com",accountID:"b"),repositoryID:"1")
        let store=try RepositoryBrowserPersistence(database:database)
        let state=RepoCodePersistence(refName:"feature/a",selection:"Sources/app.swift",expanded:["Sources"],scrollAnchor:"Sources/app.swift")
        try store.saveCodeState(state,repository:a)
        XCTAssertEqual(try store.codeState(a),state)
        XCTAssertEqual(try store.codeState(b),RepoCodePersistence())
    }
    func testImmutableTreeCacheIsAccountScoped() throws {
        let database=try DatabaseStore(path:":memory:"),store=try RepositoryBrowserPersistence(database:database)
        let a=AccountScope(host:"github.com",accountID:"a"),b=AccountScope(host:"github.com",accountID:"b")
        let value=GitTreePage(entries:[GitTreeEntry(path:"private.txt",mode:"100644",type:"blob",sha:"sha")],truncated:false)
        try store.cache(value,key:"tree|1|ref|tree",account:a)
        XCTAssertEqual(try store.cached("tree|1|ref|tree",account:a,as:GitTreePage.self),value)
        XCTAssertNil(try store.cached("tree|1|ref|tree",account:b,as:GitTreePage.self))
    }
    func testLateProviderReceiptCannotRecreateOperationAfterAccountRemoval() throws {
        let database=try DatabaseStore(path:":memory:"),store=try RepositoryBrowserPersistence(database:database),account=AccountScope(host:"github.com",accountID:"a")
        try database.saveAccount(Account(scope:account,login:"a",tokenReference:nil))
        try store.record("branch-create|1|feature",account:account,state:"unknown",data:Data("intent".utf8))
        try database.deleteAccountRecords(account)
        try store.record("branch-create|1|feature",account:account,state:"applied",data:Data("late private payload".utf8))
        XCTAssertNil(try store.operationState("branch-create|1|feature",account:account))
    }
}
