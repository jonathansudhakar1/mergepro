import GRDB

/// App-wide local settings exist before sign-in and survive account removal. Never store credentials here.
/// Names are `SettingsKey`s; the internal string overloads are for tests and names that are no longer keys.
public extension DatabaseStore {
    internal func applicationSetting(_ name: String) throws -> String? {
        try database.read { try String.fetchOne($0, sql:"SELECT value FROM applicationSettings WHERE name = ?", arguments:[name]) }
    }
    internal func setApplicationSetting(_ value: String?, for name: String) throws {
        try database.write { db in
            if let value {
                try db.execute(sql:"INSERT INTO applicationSettings VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value WHERE value IS NOT excluded.value", arguments:[name,value])
            } else {
                try db.execute(sql:"DELETE FROM applicationSettings WHERE name = ?", arguments:[name])
            }
        }
    }
    func applicationSetting(_ key: SettingsKey) throws -> String? { try applicationSetting(key.rawValue) }
    /// Nil removes the setting.
    func setApplicationSetting(_ value: String?, for key: SettingsKey) throws { try setApplicationSetting(value, for: key.rawValue) }
    /// The account `activeActionAccount` names, if it still exists.
    func activeActionAccount() throws -> AccountScope? {
        guard let selected = try applicationSetting(.activeActionAccount) else { return nil }
        return try accounts().first { AccountSessionStore.tokenReference(for:$0.scope) == selected }?.scope
    }
}
