import Foundation
import GRDB
import XCTest
@testable import MergeProCore

final class SettingsKeyTests: XCTestCase {
    private let account = AccountScope(host:"github.com", accountID:"7")

    /// Stored names are permanent: existing users' settings are read under these exact names.
    func testTypedKeysKeepTheirStoredNames() throws {
        let names:[(SettingsKey,String)] = [
            (.githubClientID,"githubClientID"),(.activeActionAccount,"activeActionAccount"),
            (.notificationsEnabled,"notificationsEnabled"),(.notificationSnoozeDuration,"notificationSnoozeDuration"),
            (.notificationSnoozedUntil,"notificationSnoozedUntil"),(.quietHoursStartMinute,"quietHoursStartMinute"),(.quietHoursEndMinute,"quietHoursEndMinute"),
            (.requireAllFilesViewedBeforeApprove,"requireAllFilesViewedBeforeApprove"),(.prNavigationHistory,"prNavigationHistory"),
            (.editor,"editor"),(.codeFontSize,"codeFontSize"),(.codeFontName,"codeFontName"),(.codeLigatures,"codeLigatures"),(.codeTheme,"codeTheme"),
            (.localFolders,"localFolders"),(.localRecoveryHints,"localRecoveryHints"),(.productionEnvironments,"productionEnvironments"),
        ]
        for (key,name) in names { XCTAssertEqual(key.rawValue, name) }
        XCTAssertEqual(SettingsKey.notificationSnoozeDuration.rawValue, NotificationSnooze.settingName)
        let accountNames:[(AccountSettingKey,String)] = [
            (.authorizationProblem,"authorizationProblem"),(.authorizationPersistenceFailed,"authorizationPersistenceFailed"),
            (.discoveryRetryAt,"discoveryRetryAt"),(.discoveryIssues,"discoveryIssues"),(.discoveryComplete,"discoveryComplete"),
            (.organizations,"organizations"),(.teams,"teams"),(.repositoryOwnerScopes,"repositoryOwnerScopes"),
            (.retainedTrackedRepositories,"retainedTrackedRepositories"),(.notificationsMuted,"notificationsMuted"),
        ]
        for (key,name) in accountNames { XCTAssertEqual(key.rawValue, name) }
        let repository = RepositoryKey(account:account, repositoryID:"42")
        let pr = ProviderKey(host:"github.com", accountID:"7", repositoryID:"42", objectID:"PR_1")
        XCTAssertEqual(SettingsKey.mergeMethod(repository).rawValue, "mergeMethod:github.com:7:42")
        let encoder = JSONEncoder.stable; encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try SettingsKey.editorBookmark(repository).rawValue, "editor-map:" + (try encoder.encode(repository)).base64EncodedString())
        XCTAssertEqual(try SettingsKey.detailProgress(pr).rawValue, "pr-detail-viewed:" + (try encoder.encode(pr)).base64EncodedString())
        XCTAssertEqual(try SettingsKey.reviewedHead(pr).rawValue, "pr-reviewed-head:" + (try encoder.encode(pr)).base64EncodedString())
        XCTAssertEqual(try SettingsKey.authorRules(account).rawValue, "pr-author-rules:" + (try encoder.encode(account)).base64EncodedString())
        XCTAssertEqual(AccountSettingKey.notificationsMuted(repositoryID:"42").rawValue, "notificationsMutedRepo:42")
        XCTAssertEqual(AccountSettingKey.mutedRepositoryID("notificationsMutedRepo:42"), "42")
        XCTAssertNil(AccountSettingKey.mutedRepositoryID("notificationsMuted"))
        XCTAssertEqual(AccountSettingKey.repositoryOwnerScopes.rawValue, RepositoryScopeConfiguration.settingName)
    }

    /// Stores that build names from keys still write the rows existing installations have.
    func testKeyedStoresWriteTheirStoredNames() throws {
        let store = try DatabaseStore(path:":memory:")
        try store.saveAccount(Account(scope:account, login:"octo", tokenReference:nil))
        let pr = ProviderKey(host:"github.com", accountID:"7", repositoryID:"42", objectID:"PR_1")
        let encoder = JSONEncoder.stable; encoder.outputFormatting = [.sortedKeys]
        let identity = try encoder.encode(pr).base64EncodedString()
        let details = PRDetailStore(database:store)
        try details.save(PRDetailState(headSHA:"head"), key:pr)
        try details.recordReview(pr, headSHA:"head")
        XCTAssertNotNil(try store.applicationSetting("pr-detail-viewed:" + identity))
        XCTAssertNotNil(try store.applicationSetting("pr-reviewed-head:" + identity))
        XCTAssertEqual(try details.reviewedHead(pr)?.head, "head")
        try PRClassificationStore(database:store).save([:], account:account)
        XCTAssertNotNil(try store.applicationSetting("pr-author-rules:" + (try encoder.encode(account)).base64EncodedString()))
        try details.purge(account:account)
        XCTAssertNil(try store.applicationSetting("pr-detail-viewed:" + identity))
        XCTAssertNil(try store.applicationSetting("pr-reviewed-head:" + identity))
    }

    func testSnapshotSettingsAreWrittenAndReadByTypedName() {
        var settings:[String:String] = [:]
        settings[.authorizationProblem] = "true"
        XCTAssertEqual(settings["authorizationProblem"], "true")
        XCTAssertEqual(settings[.authorizationProblem], "true")
        settings[.authorizationProblem] = nil
        XCTAssertTrue(settings.isEmpty)
    }

    func testTypedAccessorsReadAndWriteTheSameRowsAsNames() throws {
        let store = try DatabaseStore(path:":memory:")
        try store.setApplicationSetting("client", for:.githubClientID)
        XCTAssertEqual(try store.applicationSetting("githubClientID"), "client")
        try store.setApplicationSetting(nil, for:.githubClientID)
        XCTAssertNil(try store.applicationSetting(.githubClientID))
        try store.saveAccount(Account(scope:account, login:"octo", tokenReference:nil))
        try store.setSetting("true", for:.notificationsMuted, account:account)
        XCTAssertEqual(try store.setting("notificationsMuted", account:account), "true")
        XCTAssertEqual(try store.setting(.notificationsMuted, account:account), "true")
        XCTAssertEqual(try store.settings(account:account)[.notificationsMuted], "true")
    }

    func testActiveActionAccountResolvesOnlyAnExistingAccount() throws {
        let store = try DatabaseStore(path:":memory:")
        XCTAssertNil(try store.activeActionAccount())
        try store.setApplicationSetting(AccountSessionStore.tokenReference(for:account), for:.activeActionAccount)
        XCTAssertNil(try store.activeActionAccount(), "a reference without its account selects nothing")
        try store.saveAccount(Account(scope:account, login:"octo", tokenReference:nil))
        XCTAssertEqual(try store.activeActionAccount(), account)
    }

    /// A store at the schema before the rename migration, holding `settings`.
    private func storeBeforeRenamedSettings(_ settings:[String:String]) throws -> String {
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("settings.sqlite").path
        let queue = try DatabaseQueue(path:path)
        try Migrations.migrator().migrate(queue, upTo:"v11-storage-maintenance")
        try queue.write { db in
            for (name,value) in settings { try db.execute(sql:"INSERT INTO applicationSettings VALUES (?,?)", arguments:[name,value]) }
        }
        try queue.close()
        return path
    }

    func testRenamedSettingsMigrateWithoutOverwritingNewValues() throws {
        let path = try storeBeforeRenamedSettings(["phase4LocalFolders":"[folders]", "phase4LocalRecoveryHints":"[old hints]", "localRecoveryHints":"[new hints]"])
        let store = try DatabaseStore(path:path)
        XCTAssertEqual(try store.applicationSetting(.localFolders), "[folders]")
        XCTAssertEqual(try store.applicationSetting(.localRecoveryHints), "[new hints]", "an existing new value wins")
        XCTAssertNil(try store.applicationSetting("phase4LocalFolders"))
        XCTAssertNil(try store.applicationSetting("phase4LocalRecoveryHints"))
        XCTAssertTrue(try store.database.read { try Migrations.migrator().appliedMigrations($0) }.contains("v12-renamed-settings"))
    }

    func testRenamedSettingsMigrateOnceAndSurviveReopeningAStore() throws {
        let path = try storeBeforeRenamedSettings(["phase4LocalFolders":"[folders]"])
        XCTAssertEqual(try DatabaseStore(path:path).applicationSetting(.localFolders), "[folders]")
        // Reopening never runs the migration again over a value changed since.
        try DatabaseStore(path:path).setApplicationSetting("[changed]", for:.localFolders)
        XCTAssertEqual(try DatabaseStore(path:path).applicationSetting(.localFolders), "[changed]")
    }

    func testRenameMigrationIgnoresAbsentNames() throws {
        let store = try DatabaseStore(path:try storeBeforeRenamedSettings([:]))
        XCTAssertNil(try store.applicationSetting(.localFolders))
        XCTAssertNil(try store.applicationSetting(.localRecoveryHints))
    }

    func testRenamedDefaultsMigrateOnceWithoutOverwritingNewValues() throws {
        let suite = "SettingsKeyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        XCTAssertEqual(SettingsMigration.migrateDefaults(defaults), [])
        defaults.set("/opt/homebrew/bin/git", forKey:"phase4LocalGitExecutable")
        XCTAssertEqual(SettingsMigration.migrateDefaults(defaults), [DefaultsKey.localGitExecutable])
        XCTAssertEqual(defaults.string(forKey:DefaultsKey.localGitExecutable), "/opt/homebrew/bin/git")
        XCTAssertNil(defaults.object(forKey:"phase4LocalGitExecutable"))
        defaults.set("/usr/local/bin/git", forKey:"phase4LocalGitExecutable")
        XCTAssertEqual(SettingsMigration.migrateDefaults(defaults), [])
        XCTAssertEqual(defaults.string(forKey:DefaultsKey.localGitExecutable), "/opt/homebrew/bin/git", "an existing new value wins")
        XCTAssertNil(defaults.object(forKey:"phase4LocalGitExecutable"))
    }
}
