import Foundation
import MergeProCore
import XCTest
@testable import MergePro

/// Explicit dependencies for app tests, which never reach the real store, the Keychain or GitHub. The hosting app
/// already uses the same isolated values (`AppDependencies.unitTestHost()`); build them here so a test doesn't rely
/// on what `SetupStorage()` defaults to.
enum TestDependencies {
    /// No store (every store access fails), in-memory credentials, refused requests, and no polling, notification
    /// delivery or global shortcuts.
    static func make() -> AppDependencies { .unitTestHost() }
    /// Storage over `make()`.
    static func storage(_ dependencies: AppDependencies = make()) -> SetupStorage { SetupStorage(dependencies:dependencies) }
}

/// Guards the isolation: the hosting app detected XCTest, and the scheme's fallback keeps the real store closed.
final class TestHostIsolationTests: XCTestCase {
    func testTheHostingAppUsesUnitTestDependencies() async throws {
        XCTAssertTrue(AppDependencies.isUnitTestHost)
        let dependencies = AppDependencies.forThisApp()
        XCTAssertNil(dependencies.storageDirectoryName)
        XCTAssertFalse(dependencies.credentials is KeychainTokenStore)
        XCTAssertTrue(dependencies.pollFetchers.isEmpty)
        XCTAssertNotNil(dependencies.globalHotkeysUnavailable)
        XCTAssertNil(dependencies.fixtures)
        do {
            _ = try await SetupStorage().notificationsEnabled()
            XCTFail("The default storage of a unit-test host opened a store")
        } catch {}
        do {
            _ = try await dependencies.transport.send(URLRequest(url:try XCTUnwrap(URL(string:"https://api.github.com/user"))))
            XCTFail("The unit-test transport sent a request")
        } catch {}
    }
    func testTheSchemeKeepsTheRealStoreClosedIfDetectionMisses() {
        XCTAssertEqual(ProcessInfo.processInfo.environment[AppDependencies.disableRealStoreVariable], "1")
        XCTAssertNil(AppDependencies.production(environment:[AppDependencies.disableRealStoreVariable:"1"]).storageDirectoryName)
        XCTAssertEqual(AppDependencies.production(environment:[:]).storageDirectoryName, "MergePro")
    }
    func testInMemoryCredentialsRoundTrip() throws {
        let store = InMemoryCredentialStore(), account = AccountScope(host:"github.com", accountID:"account-1")
        XCTAssertNil(try store.credential(for:account))
        let credential = GitHubCredential(accessToken:"test-token")
        try store.save(credential, account:account)
        XCTAssertEqual(try store.credential(for:account), credential)
        try store.remove(account:account)
        XCTAssertNil(try store.credential(for:account))
    }
}
