import Foundation
import GRDB
import XCTest
@testable import MergeProCore

private struct OfflineTransport: GitHubTransport {
    func send(_ request: URLRequest) async throws -> GitHubResponse { throw GitHubFailure.resourceDenied }
}
private struct RecordingSink: NotificationSink {
    func post(_ summary: PollSummary) async throws {}
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
private struct MarkerAdapter: MergeAdapter {
    let database: DatabaseStore
    func inspect(_ target: MergeTarget, client: GitHubHTTPClient, credential: GitHubCredential) async throws -> MergeInspection { throw PRWriteFailure.unavailable }
    func send(_ operation: PRWriteOperation, client: GitHubHTTPClient, credential: GitHubCredential) async throws -> GitHubResponse { throw PRWriteFailure.unavailable }
    func status(_ id: UUID, target: MergeTarget, client: GitHubHTTPClient, credential: GitHubCredential) async throws -> GitHubResponse { throw PRWriteFailure.unavailable }
}

final class AppServicesTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppServicesTests-" + UUID().uuidString, isDirectory:true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:directory) }

    private func services(prepare: @escaping @Sendable (DatabaseStore) throws -> Void = { _ in },
                          adapter: @escaping @Sendable (DatabaseStore) -> any MergeAdapter = { _ in GitHubMergeAdapter() }) -> AppServices {
        let folder = directory.appendingPathComponent("Store", isDirectory:true)
        return AppServices(.init(directory:{ folder }, credentials:MemoryCredentials(), transport:OfflineTransport(), pollFetchers:[],
                                 mergeAdapter:adapter, prepareDatabase:prepare))
    }

    func testStoreOpensOnceInAnOwnerOnlyFolder() throws {
        let prepared = Counter()
        let services = services(prepare:{ _ in prepared.increment() })
        let (database, _) = try services.stores()
        let (again, _) = try services.stores()
        XCTAssertTrue(database === again)
        XCTAssertEqual(prepared.count, 1)
        let folder = directory.appendingPathComponent("Store").path
        let mode = try FileManager.default.attributesOfItem(atPath:folder)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder + "/mergepro.sqlite"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder + "/Payloads"))
    }

    func testUnavailableDirectoryFailsEveryAccessUntilItResolves() throws {
        let available = Counter()
        let folder = directory.appendingPathComponent("Later", isDirectory:true)
        let services = AppServices(.init(directory:{
            guard available.count > 0 else { throw CocoaError(.fileReadNoPermission) }
            return folder
        }, credentials:MemoryCredentials(), transport:OfflineTransport(), pollFetchers:[]))
        XCTAssertThrowsError(try services.stores())
        XCTAssertThrowsError(try services.actionsService())
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path))
        available.increment()
        XCTAssertNoThrow(try services.stores())
    }

    func testFailedPreparationLeavesTheStoreClosedAndRetries() throws {
        let attempts = Counter()
        let services = services(prepare:{ _ in attempts.increment(); if attempts.count == 1 { throw CocoaError(.coderInvalidValue) } })
        XCTAssertThrowsError(try services.stores())
        XCTAssertNoThrow(try services.stores())
        XCTAssertEqual(attempts.count, 2)
    }

    func testOpeningMigratesRenamedSettingsBeforePreparation() throws {
        let folder = directory.appendingPathComponent("Store", isDirectory:true)
        try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:true)
        // A store from before the rename migration.
        let queue = try DatabaseQueue(path:folder.appendingPathComponent("mergepro.sqlite").path)
        try Migrations.migrator().migrate(queue, upTo:"v11-storage-maintenance")
        try queue.write { try $0.execute(sql:"INSERT INTO applicationSettings VALUES ('phase4LocalFolders','[folders]')") }
        try queue.close()
        let seen = Counter()
        let services = services(prepare:{ database in if try database.applicationSetting(.localFolders) == "[folders]" { seen.increment() } })
        XCTAssertEqual(try services.stores().0.applicationSetting(.localFolders), "[folders]")
        XCTAssertNil(try services.stores().0.applicationSetting("phase4LocalFolders"))
        XCTAssertEqual(seen.count, 1)
    }

    func testLongLivedServicesAreSharedAndRebuiltAfterTheClientIDChanges() throws {
        let services = services()
        let session = try services.accountSession()
        XCTAssertTrue(session === (try services.accountSession()))
        let actions = try services.actionsService(), browser = try services.repositoryBrowserService()
        XCTAssertTrue(actions === (try services.actionsService()))
        XCTAssertTrue(browser === (try services.repositoryBrowserService()))
        XCTAssertTrue((try services.pollingStore()) === (try services.pollingStore()))
        let coordinator = try services.pollCoordinator(sink:RecordingSink(), policy:{ NotificationPolicy() })
        XCTAssertTrue(coordinator === (try services.pollCoordinator(sink:RecordingSink(), policy:{ NotificationPolicy() })))

        XCTAssertEqual(try services.clientID(), "")
        try services.stores().0.setApplicationSetting("client", for:.githubClientID)
        XCTAssertEqual(try services.clientID(), "client")
        services.clientIDChanged()
        XCTAssertFalse(actions === (try services.actionsService()))
        XCTAssertFalse(browser === (try services.repositoryBrowserService()))
        XCTAssertTrue(session === (try services.accountSession()), "the session never captures the client ID")
        XCTAssertTrue(coordinator === (try services.pollCoordinator(sink:RecordingSink(), policy:{ NotificationPolicy() })),
                      "the coordinator reads the client ID at every cycle")
    }

    func testMergeCoordinatorUsesTheConfiguredAdapterForThisDatabase() throws {
        let built = Counter()
        let services = services(adapter:{ database in built.increment(); return MarkerAdapter(database:database) })
        _ = try services.mergeCoordinator()
        _ = try services.mergeCoordinator()
        XCTAssertEqual(built.count, 2, "each coordinator gets an adapter over the open database")
    }
}
