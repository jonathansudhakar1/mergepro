import XCTest
import GRDB
@testable import MergeProCore

@MainActor final class FeatureCleanupTests:XCTestCase {
    func testRevocationPurgesFeaturePayloadsButRetainsUncertainWriteEvidence() async throws {
        let database = try DatabaseStore(path:":memory:")
        let directory = try makeTemporaryDirectory()
        let cache = try CacheStore(directory:directory,database:database)
        let account = AccountScope(host:"github.com",accountID:"a")
        try database.saveAccount(.init(scope:account,login:"fixture",tokenReference:nil))
        _ = try ActionsStore(database:database);_ = try RepositoryBrowserPersistence(database:database)
        try await database.database.write { db in
            try db.execute(sql:"INSERT INTO actions_catalog VALUES ('github.com','a','7',X'01')")
            try db.execute(sql:"INSERT INTO actions_presets VALUES ('p','github.com','a','7',X'01')")
            try db.execute(sql:"INSERT INTO actions_operations VALUES ('op','github.com','a','7','uncertain',X'01','lock')")
            try db.execute(sql:"INSERT INTO repo_browser_cache VALUES ('github.com','a','tree',X'01',0)")
            try db.execute(sql:"INSERT INTO repo_browser_state VALUES ('github.com','a','catalog',X'01')")
            try db.execute(sql:"INSERT INTO repo_browser_operations VALUES ('github.com','a','create','unknown',X'01')")
            try db.execute(sql:"INSERT INTO actions_catalog VALUES ('github.com','b','7',X'01')")
        }
        try await cache.invalidatePrivatePayloads(for:account)
        try await database.database.read { db in
            for table in ["actions_catalog","actions_presets"] {
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM \(table) WHERE accountID='a'"),0)
            }
            for table in ["repo_browser_cache","repo_browser_state"] {
                XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM \(table) WHERE account_id='a'"),0)
            }
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM actions_catalog WHERE accountID='b'"),1)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM actions_operations"),1)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM repo_browser_operations"),1)
        }
        try await cache.removeAccount(account,deletingCredential:{ _ in })
        try await database.database.read { db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM actions_operations"),0)
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM repo_browser_operations"),0)
        }
    }
}
