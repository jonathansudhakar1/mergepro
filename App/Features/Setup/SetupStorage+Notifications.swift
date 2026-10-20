import Foundation
import MergeProCore

/// Notification preferences edited in Settings. Keys and formats match what `NotificationPolicyAssembly` reads:
/// app-wide `.notificationSnoozedUntil` (epoch seconds), `.quietHoursStartMinute`/`.quietHoursEndMinute` (minutes after
/// midnight), and per account `.notificationsMuted` and `.notificationsMuted(repositoryID:)` ("true" mutes).
struct NotificationPreferences: Equatable {
    var snooze = NotificationSnooze.fifteenMinutes
    var snoozedUntil: Date?
    var quietStartMinute: Int?
    var quietEndMinute: Int?
    var mutedAccounts: Set<AccountScope> = []
    var mutedRepositories: Set<RepositoryKey> = []
    var quietHoursEnabled: Bool { quietStartMinute != nil && quietEndMinute != nil }
}

extension SetupStorage {
    func notificationPreferences() throws -> NotificationPreferences {
        let database = try stores().0
        var preferences = NotificationPreferences()
        preferences.snooze = NotificationSnooze(setting:try database.applicationSetting(.notificationSnoozeDuration))
        preferences.snoozedUntil = try database.applicationSetting(.notificationSnoozedUntil).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        preferences.quietStartMinute = try database.applicationSetting(.quietHoursStartMinute).flatMap(Int.init)
        preferences.quietEndMinute = try database.applicationSetting(.quietHoursEndMinute).flatMap(Int.init)
        for account in try database.accounts() {
            let settings = try database.settings(account:account.scope)
            if settings[.notificationsMuted] == "true" { preferences.mutedAccounts.insert(account.scope) }
            for (name,value) in settings where value == "true" {
                if let repositoryID = AccountSettingKey.mutedRepositoryID(name) { preferences.mutedRepositories.insert(RepositoryKey(account:account.scope,repositoryID:repositoryID)) }
            }
        }
        return preferences
    }
    func setNotificationSnooze(_ snooze: NotificationSnooze) throws {
        try stores().0.setApplicationSetting(snooze.rawValue,for:.notificationSnoozeDuration)
    }
    func resumeNotifications() throws { try stores().0.setApplicationSetting(nil,for:.notificationSnoozedUntil) }
    /// Both bounds or neither: nil turns quiet hours off.
    func setQuietHours(startMinute: Int?, endMinute: Int?) throws {
        let database = try stores().0
        guard let startMinute, let endMinute else {
            try database.setApplicationSetting(nil,for:.quietHoursStartMinute); try database.setApplicationSetting(nil,for:.quietHoursEndMinute); return
        }
        try database.setApplicationSetting(String(min(1439,max(0,startMinute))),for:.quietHoursStartMinute)
        try database.setApplicationSetting(String(min(1439,max(0,endMinute))),for:.quietHoursEndMinute)
    }
    func setNotificationsMuted(_ muted: Bool, account: AccountScope) throws {
        try stores().0.setSetting(muted ? "true" : "false",for:.notificationsMuted,account:account)
    }
    func setNotificationsMuted(_ muted: Bool, repository: RepositoryKey) throws {
        try stores().0.setSetting(muted ? "true" : "false",for:.notificationsMuted(repositoryID:repository.repositoryID),account:repository.account)
    }
}
