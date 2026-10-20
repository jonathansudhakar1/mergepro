import Foundation
import XCTest
import GRDB
@testable import MergeProCore

@MainActor
final class RepositoryScopeTests: XCTestCase {
    private let account = AccountScope(host:"github.com",accountID:"scope")
    private func repository(_ id:String,owner:String = "org",account:AccountScope? = nil) -> Repository {
        Repository(key:RepositoryKey(account:account ?? self.account,repositoryID:id),name:owner+"/r"+id,isPrivate:true,capabilities:[.readPullRequests])
    }
    private func fixture() throws -> (DatabaseStore,AccountSessionStore) {
        let directory = try makeTemporaryDirectory()
        let database = try DatabaseStore(path:directory.appendingPathComponent("db.sqlite").path)
        try database.saveAccount(Account(scope:account,login:"me",tokenReference:"scope"))
        let credentials = MemoryCredentials()
        credentials.save(GitHubCredential(accessToken:"fixture",scopes:["repo"]),account:account)
        return (database,AccountSessionStore(database:database,cache:try CacheStore(directory:directory.appendingPathComponent("cache"),database:database),credentials:credentials))
    }
    private func result(_ repositories:[Repository],complete:Bool = true,organizations:[GitHubOrganization] = []) -> GitHubDiscoveryResult {
        GitHubDiscoveryResult(repositories:repositories,organizations:organizations,teams:[],issues:complete ? [] : ["partial"],isComplete:complete,retryAt:nil)
    }
    func testNewOwnerDefaultsToAllAndLaterDiscoveryTracksNewRepositories() async throws {
        let (database,session) = try fixture()
        let operation = try await session.operation(for:account,now:Date())
        _ = try await session.saveDiscovery(result([repository("1")]),operation:operation)
        XCTAssertEqual(try database.trackedRepositories(account:account),[repository("1").key])
        _ = try await session.saveDiscovery(result([repository("1"),repository("2")]),operation:operation)
        XCTAssertEqual(try database.trackedRepositories(account:account),[repository("1").key,repository("2").key])
    }
    func testLegacySelectionsIncludingEmptyRemainExplicitAndNewOwnersDefaultAll() async throws {
        let (database,session) = try fixture()
        try database.saveRepository(repository("1"));try database.saveRepository(repository("2"))
        try database.saveRepository(repository("3",owner:"empty"))
        try database.setTracked(repository("1").key,tracked:true)
        let operation = try await session.operation(for:account,now:Date())
        _ = try await session.saveDiscovery(result([repository("1"),repository("2"),repository("3",owner:"empty"),repository("4"),repository("5",owner:"new")]),operation:operation)
        XCTAssertEqual(try database.trackedRepositories(account:account),[repository("1").key,repository("5",owner:"new").key])
    }
    func testSpecificModePreservesSelectionsAcrossPagesAndRediscovery() async throws {
        let (database,session) = try fixture()
        let operation = try await session.operation(for:account,now:Date())
        let repositories = (1...60).map { repository(String($0)) }
        _ = try await session.saveDiscovery(result(repositories),operation:operation)
        try database.setRepositoryScope(.selectedRepositories,owner:"org",account:account)
        XCTAssertEqual(try database.trackedRepositories(account:account).count,60)
        try database.setRepositorySelection(Set(repositories.prefix(25).map(\.key)),enabled:false,owner:"org",account:account)
        try database.setRepositorySelection([repositories[40].key],enabled:false,owner:"org",account:account)
        _ = try await session.saveDiscovery(result(repositories+[repository("61")]),operation:operation)
        let tracked = try database.trackedRepositories(account:account)
        XCTAssertEqual(tracked.count,34)
        XCTAssertFalse(tracked.contains(repository("61").key))
        XCTAssertTrue(tracked.contains(repositories[59].key))
        try database.setRepositoryScope(.allAccessible,owner:"ORG",account:account)
        XCTAssertEqual(try database.trackedRepositories(account:account).count,61)
    }
    func testPartialDiscoveryRetainsSavedTrackingAndOrganizationMetadata() async throws {
        let (database,session) = try fixture()
        let operation = try await session.operation(for:account,now:Date())
        let organization = GitHubOrganization(id:"99",login:"empty")
        _ = try await session.saveDiscovery(result([repository("1"),repository("2")],organizations:[organization]),operation:operation)
        try database.setRepositoryScope(.selectedRepositories,owner:"org",account:account)
        _ = try await session.saveDiscovery(result([repository("3")],complete:false),operation:operation)
        let snapshot = try database.snapshot(for:account)
        XCTAssertEqual(snapshot.repositories.count,3)
        XCTAssertEqual(snapshot.trackedRepositories,[repository("1").key,repository("2").key])
        XCTAssertEqual(try JSONDecoder().decode([GitHubOrganization].self,from:Data(snapshot.settings["organizations"]!.utf8)),[organization])
        XCTAssertEqual(snapshot.settings["discoveryComplete"],"false")
        let configuration = try RepositoryScopeConfiguration(settings:snapshot.settings,repositories:snapshot.repositories)
        XCTAssertEqual(configuration.mode(for:"empty"),.allAccessible)
    }
    func testDiscoveryBatchWithForeignRepositoryRollsBackEveryChange() async throws {
        let (database,session) = try fixture()
        let operation = try await session.operation(for:account,now:Date())
        let before = try database.snapshot(for:account)
        do {
            _ = try await session.saveDiscovery(result([repository("1"),repository("2",account:AccountScope(host:"github.com",accountID:"other"))]),operation:operation)
            XCTFail("Foreign discovery membership must fail")
        } catch { XCTAssertEqual(error as? RepositoryScopeFailure,.invalidRepositories) }
        XCTAssertEqual(try database.snapshot(for:account),before)
    }
    func testStaleActiveAccountAndInvalidPageMembershipLeaveSelectionUnchanged() async throws {
        let (database,session) = try fixture()
        let operation = try await session.operation(for:account,now:Date())
        _ = try await session.saveDiscovery(result([repository("1"),repository("2",owner:"other")]),operation:operation)
        let before = try database.snapshot(for:account)
        try database.setApplicationSetting("github.com:different",for:"activeActionAccount")
        XCTAssertThrowsError(try database.setRepositoryScope(.selectedRepositories,owner:"org",account:account,expectedActiveAccount:account)) {
            XCTAssertEqual($0 as? RepositoryScopeFailure,.accountChanged)
        }
        try database.setApplicationSetting(AccountSessionStore.tokenReference(for:account),for:"activeActionAccount")
        XCTAssertThrowsError(try database.setRepositorySelection([repository("1").key,repository("2",owner:"other").key],enabled:false,owner:"org",account:account,expectedActiveAccount:account)) {
            XCTAssertEqual($0 as? RepositoryScopeFailure,.invalidRepositories)
        }
        XCTAssertEqual(try database.snapshot(for:account),before)
    }
    func testSameOwnerAndRepositoryIDsAreIsolatedByConnectedAccount() async throws {
        let (database,session) = try fixture()
        let other = AccountScope(host:"github.com",accountID:"other")
        try database.saveAccount(Account(scope:other,login:"other",tokenReference:"other"))
        try database.saveRepository(repository("1",account:other))
        try database.setTracked(repository("1",account:other).key,tracked:true)
        let operation = try await session.operation(for:account,now:Date())
        _ = try await session.saveDiscovery(result([repository("1")]),operation:operation)
        try database.setRepositorySelection([repository("1").key],enabled:false,owner:"org",account:account)
        XCTAssertTrue(try database.trackedRepositories(account:account).isEmpty)
        XCTAssertEqual(try database.trackedRepositories(account:other),[repository("1",account:other).key])
        XCTAssertNil(try database.settings(account:other)[RepositoryScopeConfiguration.settingName])
    }
    func testReconnectKeepsSpecificModeAndNewRepositoriesExcluded() async throws {
        let (database,session) = try fixture()
        var operation = try await session.operation(for:account,now:Date())
        _ = try await session.saveDiscovery(result([repository("1")]),operation:operation)
        try database.setRepositorySelection([repository("1").key],enabled:false,owner:"org",account:account)
        try await session.saveAuthorized(AuthorizedGitHubAccount(scope:account,login:"me",credential:GitHubCredential(accessToken:"new",scopes:["repo"])))
        operation = try await session.operation(for:account,now:Date())
        _ = try await session.saveDiscovery(result([repository("1"),repository("2")]),operation:operation)
        XCTAssertTrue(try database.trackedRepositories(account:account).isEmpty)
        let snapshot = try database.snapshot(for:account)
        XCTAssertEqual(try RepositoryScopeConfiguration(settings:snapshot.settings,repositories:snapshot.repositories).mode(for:"org"),.selectedRepositories)
    }
    func testOwnerWithoutRepositoriesDefaultsAllAndIncludesFutureDiscovery() async throws {
        let (database,session) = try fixture()
        let operation = try await session.operation(for:account,now:Date())
        _ = try await session.saveDiscovery(result([],organizations:[GitHubOrganization(id:"99",login:"org")]),operation:operation)
        _ = try await session.saveDiscovery(result([repository("1")]),operation:operation)
        XCTAssertEqual(try database.trackedRepositories(account:account),[repository("1").key])
    }
    func testSavedOwnerModesSurviveDatabaseReopen() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("db.sqlite").path
        let database = try DatabaseStore(path:path)
        try database.saveAccount(Account(scope:account,login:"me",tokenReference:"scope"))
        try database.commitRepositoryDiscovery(result([repository("1"),repository("2",owner:"another")]),account:account)
        try database.setRepositorySelection([repository("1").key],enabled:false,owner:"org",account:account)
        let reopened = try DatabaseStore(path:path)
        let snapshot = try reopened.snapshot(for:account)
        let configuration = try RepositoryScopeConfiguration(settings:snapshot.settings,repositories:snapshot.repositories)
        XCTAssertEqual(configuration.mode(for:"org"),.selectedRepositories)
        XCTAssertEqual(configuration.mode(for:"another"),.allAccessible)
        try reopened.commitRepositoryDiscovery(result([repository("3"),repository("4",owner:"another")]),account:account)
        XCTAssertEqual(try reopened.trackedRepositories(account:account),[repository("2",owner:"another").key,repository("4",owner:"another").key])
    }
    func testLegacyOrganizationWithoutRepositoriesKeepsEmptyExplicitScope() async throws {
        let (database,session) = try fixture()
        try database.setSetting("[{\"id\":\"99\",\"login\":\"org\"}]",for:"organizations",account:account)
        let operation = try await session.operation(for:account,now:Date())
        _ = try await session.saveDiscovery(result([repository("1")]),operation:operation)
        XCTAssertTrue(try database.trackedRepositories(account:account).isEmpty)
    }
    func testSingleRepositoryUntrackingSwitchesAllModeToSpecific() async throws {
        let (database,session) = try fixture()
        let operation = try await session.operation(for:account,now:Date())
        _ = try await session.saveDiscovery(result([repository("1"),repository("2")]),operation:operation)
        try database.setTracked(repository("1").key,tracked:false)
        _ = try await session.saveDiscovery(result([repository("1"),repository("2"),repository("3")]),operation:operation)
        XCTAssertEqual(try database.trackedRepositories(account:account),[repository("2").key])
    }
    func testSearchPagingIsBoundedStableAndClampsAfterFiltering() {
        let repositories = (1...63).reversed().map { repository(String($0)) }
        let first = RepositoryScopePage(repositories:repositories,query:"",page:0)
        let last = RepositoryScopePage(repositories:repositories,query:"",page:99)
        XCTAssertEqual(first.repositories.count,25)
        XCTAssertEqual(first.pageCount,3)
        XCTAssertEqual(first.repositories.first?.name,"org/r1")
        XCTAssertEqual(last.page,2)
        XCTAssertEqual(last.repositories.count,13)
        let filtered = RepositoryScopePage(repositories:repositories,query:"R63",page:2)
        XCTAssertEqual(filtered.page,0)
        XCTAssertEqual(filtered.totalCount,1)
        XCTAssertEqual(filtered.repositories.map(\.name),["org/r63"])
        XCTAssertEqual(RepositoryScopePage(repositories:repositories,query:"missing",page:3).repositories.count,0)
    }

}
