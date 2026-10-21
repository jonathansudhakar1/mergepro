import Foundation
import GRDB

/// The name of an app-wide setting (the `applicationSettings` table). Settings exist before sign-in and survive
/// account removal; never store credentials in them. A stored name is permanent: a rename needs a database migration
/// (`Migrations`, see `Migrations.renameApplicationSettings`) that moves the stored value once.
public struct SettingsKey: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // MARK: Accounts
    /// The public OAuth App client ID used for device-flow sign-in and every provider service.
    public static let githubClientID = SettingsKey(rawValue: "githubClientID")
    /// The user's extra AI-authorship branch prefixes and labels (`AgentPatterns`), for every account.
    public static let agentPatterns = SettingsKey(rawValue: "agentPatterns")
    /// Token reference (`AccountSessionStore.tokenReference(for:)`) of the account that reviews, merges and writes.
    public static let activeActionAccount = SettingsKey(rawValue: "activeActionAccount")

    // MARK: Notifications
    /// "true" when system summaries are on.
    public static let notificationsEnabled = SettingsKey(rawValue: "notificationsEnabled")
    /// The snooze duration chosen in Settings (`NotificationSnooze` raw value).
    public static let notificationSnoozeDuration = SettingsKey(rawValue: NotificationSnooze.settingName)
    /// Epoch seconds when a snooze ends.
    public static let notificationSnoozedUntil = SettingsKey(rawValue: "notificationSnoozedUntil")
    /// Quiet hours bounds in minutes after midnight; both or neither are set.
    public static let quietHoursStartMinute = SettingsKey(rawValue: "quietHoursStartMinute")
    public static let quietHoursEndMinute = SettingsKey(rawValue: "quietHoursEndMinute")

    // MARK: Reviews and pull requests
    /// "true" requires every file viewed before approving a PR that carries risk flags.
    public static let requireAllFilesViewedBeforeApprove = SettingsKey(rawValue: "requireAllFilesViewedBeforeApprove")
    /// PR navigation history (palette ranking), stored apart from the workspace record.
    public static let prNavigationHistory = SettingsKey(rawValue: "prNavigationHistory")
    /// Default merge method of one repository (`MergeMethod` raw value).
    public static func mergeMethod(_ repository: RepositoryKey) -> SettingsKey {
        SettingsKey(rawValue: "mergeMethod:" + repository.account.host + ":" + repository.account.accountID + ":" + repository.repositoryID)
    }
    static let detailProgressPrefix = "pr-detail-viewed:"
    /// Reading progress of one pull request (`PRDetailState`, base64 JSON). App-wide, so removed with its account.
    static func detailProgress(_ pr: ProviderKey) throws -> SettingsKey { SettingsKey(rawValue: detailProgressPrefix + (try identity(pr))) }
    static let reviewedHeadPrefix = "pr-reviewed-head:"
    /// The head a provider-confirmed review by the key's account covered (`PRReviewedHead`, base64 JSON).
    static func reviewedHead(_ pr: ProviderKey) throws -> SettingsKey { SettingsKey(rawValue: reviewedHeadPrefix + (try identity(pr))) }
    /// One account's author classification rules (base64 JSON).
    static func authorRules(_ account: AccountScope) throws -> SettingsKey { SettingsKey(rawValue: "pr-author-rules:" + (try identity(account))) }

    // MARK: Editor and code
    /// The external editor (`EditorLocation.Editor` raw value).
    public static let editor = SettingsKey(rawValue: "editor")
    public static let codeFontSize = SettingsKey(rawValue: "codeFontSize")
    public static let codeFontName = SettingsKey(rawValue: "codeFontName")
    public static let codeLigatures = SettingsKey(rawValue: "codeLigatures")
    public static let codeTheme = SettingsKey(rawValue: "codeTheme")
    /// The security-scoped folder bookmark that maps one repository to a local editor folder.
    public static func editorBookmark(_ repository: RepositoryKey) throws -> SettingsKey {
        SettingsKey(rawValue: "editor-map:" + (try identity(repository)))
    }

    // MARK: Local
    /// Authorized local folders (security-scoped bookmarks, JSON).
    public static let localFolders = SettingsKey(rawValue: "localFolders")
    /// Recent Git operation states per worktree, which never supersede the current Git metadata (JSON).
    public static let localRecoveryHints = SettingsKey(rawValue: "localRecoveryHints")

    // MARK: Actions
    /// Comma-separated environment names treated as production.
    public static let productionEnvironments = SettingsKey(rawValue: "productionEnvironments")

    /// A key's part of a name: base64 of its sorted-keys JSON.
    private static func identity<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value).base64EncodedString()
    }
}

/// The name of a per-account setting (the `settings` table); removed with the account.
public struct AccountSettingKey: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// "true" while the account's access expired or was revoked.
    public static let authorizationProblem = AccountSettingKey(rawValue: "authorizationProblem")
    /// "true" when recording that problem also failed locally. Only in snapshots (`AccountAuthorizationState.applying(to:)`),
    /// never stored.
    public static let authorizationPersistenceFailed = AccountSettingKey(rawValue: "authorizationPersistenceFailed")
    /// Epoch seconds before which discovery must not run again (empty when unset).
    public static let discoveryRetryAt = AccountSettingKey(rawValue: "discoveryRetryAt")
    /// Newline-separated problems of the last repository discovery.
    public static let discoveryIssues = AccountSettingKey(rawValue: "discoveryIssues")
    /// "true" when the last repository discovery listed everything (only then may it purge lost repositories).
    public static let discoveryComplete = AccountSettingKey(rawValue: "discoveryComplete")
    /// The account's organizations (JSON `[GitHubOrganization]`).
    public static let organizations = AccountSettingKey(rawValue: "organizations")
    /// The account's teams (JSON `[GitHubTeam]`).
    public static let teams = AccountSettingKey(rawValue: "teams")
    /// Repository tracking scope per owner (JSON).
    public static let repositoryOwnerScopes = AccountSettingKey(rawValue: RepositoryScopeConfiguration.settingName)
    /// Tracked repository IDs kept through a purge of their rows, restored when discovery lists them again (JSON).
    static let retainedTrackedRepositories = AccountSettingKey(rawValue: "retainedTrackedRepositories")
    /// "true" mutes every notification of the account.
    public static let notificationsMuted = AccountSettingKey(rawValue: "notificationsMuted")
    static let mutedRepositoryPrefix = "notificationsMutedRepo:"
    /// "true" mutes notifications of one repository of the account.
    public static func notificationsMuted(repositoryID: String) -> AccountSettingKey {
        AccountSettingKey(rawValue: mutedRepositoryPrefix + repositoryID)
    }
    /// The repository a `notificationsMuted(repositoryID:)` name refers to; nil for every other name.
    public static func mutedRepositoryID(_ name: String) -> String? {
        name.hasPrefix(mutedRepositoryPrefix) ? String(name.dropFirst(mutedRepositoryPrefix.count)) : nil
    }
}

/// UserDefaults names read through SwiftUI's `@AppStorage`.
public enum DefaultsKey {
    /// The Git executable the Local workspace runs (`LocalGitExecutableChoice` raw value).
    public static let localGitExecutable = "localGitExecutable"
    /// Defaults names replaced by meaningful ones; see `SettingsMigration.migrateDefaults(_:)`.
    public static let renamed: [(old: String, new: String)] = [("phase4LocalGitExecutable", localGitExecutable)]
}

/// Per-account settings as read in a snapshot (`LocalSnapshot.settings`), indexed by typed name.
public extension Dictionary where Key == String, Value == String {
    subscript(key: AccountSettingKey) -> String? {
        get { self[key.rawValue] }
        set { self[key.rawValue] = newValue }
    }
}

public extension DatabaseStore {
    func setting(_ key: AccountSettingKey, account: AccountScope) throws -> String? { try setting(key.rawValue, account: account) }
    func setSetting(_ value: String, for key: AccountSettingKey, account: AccountScope) throws {
        try setSetting(value, for: key.rawValue, account: account)
    }
}
extension DatabaseStore {
    static func setting(_ key: AccountSettingKey, account: AccountScope, in db: Database) throws -> String? {
        try setting(key.rawValue, account: account, in: db)
    }
    static func applicationSetting(_ key: SettingsKey, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM applicationSettings WHERE name = ?", arguments: [key.rawValue])
    }
}

public enum SettingsMigration {
    /// Copies each `DefaultsKey.renamed` value to its new name (an existing new value wins) and removes the old
    /// name. Idempotent; call before any view reads the new names.
    /// - Returns: the new names that received a copied value.
    @discardableResult public static func migrateDefaults(_ defaults: UserDefaults) -> [String] {
        var copied: [String] = []
        for (old, new) in DefaultsKey.renamed {
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: new) == nil { defaults.set(value, forKey: new); copied.append(new) }
            defaults.removeObject(forKey: old)
        }
        return copied
    }
}

public extension JSONEncoder {
    /// Byte-for-byte reproducible output. Encoded values are hashed and compared (snapshot tokens, write intents,
    /// inventory pages), and macOS 26's encoder does not keep keyed containers in a stable order.
    static var stable: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }
}
