import XCTest
@testable import MergeProCore

final class RepoTreeTests: XCTestCase {
    private func repo(_ account: String, _ name: String = "owner/project", pinned: Bool = false) -> RepoCatalogEntry {
        RepoCatalogEntry(repository: Repository(key: RepositoryKey(account: AccountScope(host: "github.com", accountID: account), repositoryID: "1"), name: name, isPrivate: false, capabilities: []), accountLogin: account, pinned: pinned)
    }
    func testSameRepositoryKeepsDistinctAccountIdentityAndPinnedAlias() {
        let tree = RepoTreeStore(entries: [repo("a", pinned: true), repo("b")])
        XCTAssertEqual(tree.roots.count, 3)
        let repositories = tree.allNodes.filter { $0.repository != nil }
        XCTAssertEqual(repositories.count, 3)
        XCTAssertEqual(Set(repositories.map(\.id)).count, 3)
        XCTAssertEqual(Set(repositories.compactMap { $0.repository?.key.account }).count, 2)
    }
    func testSearchExpansionNeverOverwritesSavedExpansionAndRemovedSelectionFallsBack() {
        var tree = RepoTreeStore(entries: [repo("a")])
        let account = tree.roots[0].id
        tree.expanded = [account]
        tree.search = "project"
        XCTAssertGreaterThan(tree.effectiveExpansion.count, tree.expanded.count)
        tree.search = ""
        XCTAssertEqual(tree.effectiveExpansion, [account])
        tree.selection = tree.allNodes.first { $0.repository != nil }?.id
        tree.refresh([])
        XCTAssertNil(tree.selection)
        XCTAssertTrue(tree.expanded.isEmpty)
    }
    func testFiltersAreAppliedWithoutLosingAccountScope() {
        var filter = RepoCatalogFilter()
        filter.pinnedOnly = true
        XCTAssertEqual(filter.apply([repo("a", pinned:true),repo("b")]).map(\.accountLogin),["a"])
    }
    func testKindsDistinguishSymlinkSubmoduleBinaryAndLFS() {
        XCTAssertEqual(GitTreeEntry(path:"link",mode:"120000",type:"blob",sha:"s").kind,.symlink)
        XCTAssertEqual(GitTreeEntry(path:"dep",mode:"160000",type:"commit",sha:"s").kind,.submodule)
        XCTAssertEqual(RepositoryBlob.classify(Data([0,1,2])),.binary)
        XCTAssertEqual(RepositoryBlob.classify(Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 4\n".utf8)),.lfsPointer)
    }
    func testBranchValidationRejectsDangerousRefs() {
        for name in ["", "main..old", "a@{b", "-danger", "a.lock", "a//b", "a b", "a?b", "a\\b"] {
            XCTAssertFalse(BranchService.validName(name), name)
        }
        XCTAssertTrue(BranchService.validName("feature/new-ui"))
    }
}

extension RepoTreeTests {
    func testOpenPRFilterPreservesUnknownUntilVisibleOverviewLoads() {
        var filter=RepoCatalogFilter();filter.hasOpenPRs=true
        var unknown=repo("unknown"),empty=repo("empty"),open=repo("open")
        unknown.openPRs=nil;empty.openPRs=0;open.openPRs=2
        XCTAssertEqual(Set(filter.apply([unknown,empty,open]).map(\.accountLogin)),["unknown","open"])
    }
    func testFailingCISortRecognizesGitHubUppercaseFailureAndErrorStates() {
        var filter=RepoCatalogFilter();filter.sort = .failingCI
        var passing=repo("a","o/a"),failing=repo("b","o/z"),error=repo("c","o/y")
        passing.defaultCI="SUCCESS";failing.defaultCI="FAILURE";error.defaultCI="ERROR"
        XCTAssertEqual(filter.apply([passing,failing,error]).map(\.accountLogin),["c","b","a"])
    }
}

extension RepoTreeTests {
    func testEmptyOrganizationsAndAccountsRemainExplicitScopedRows() {
        let account=AccountScope(host:"github.com",accountID:"a")
        let tree=RepoTreeStore(entries:[],owners:[RepoCatalogOwner(account:account,accountLogin:"actor",name:"empty-org")])
        XCTAssertEqual(tree.roots.first?.title,"actor")
        XCTAssertEqual(tree.roots.first?.children.first?.title,"empty-org")
        XCTAssertEqual(tree.roots.first?.children.first?.count,0)
    }
}
