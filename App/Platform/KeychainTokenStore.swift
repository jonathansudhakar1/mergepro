import Foundation
import Security
import MergeProCore

/// One JSON credential item per immutable provider account. Optional expiry/rotated refresh
/// fields are stored with the token and never in SQLite, defaults, logs, or error strings.
/// Items live in the data-protection keychain; builds without the keychain entitlement use the legacy keychain,
/// and legacy items move forward on first read (see `KeychainCredentialStore`).
struct KeychainTokenStore: GitHubCredentialStore {
    /// Per bundle identifier, so Debug builds (`app.mergepro.mac.debug`) never read or replace the shipped app's tokens.
    static let service = (Bundle.main.bundleIdentifier ?? "app.mergepro.mac") + ".github.oauth"
    private let store: KeychainCredentialStore<SecItemKeychainBackend>
    init(service: String = Self.service) { store = KeychainCredentialStore(backend:SecItemKeychainBackend(service:service)) }
    static func reference(for account: AccountScope) -> String { AccountSessionStore.tokenReference(for:account) }
    func save(_ credential: GitHubCredential, account: AccountScope) throws { try store.save(credential, account:account) }
    func credential(for account: AccountScope) throws -> GitHubCredential? { try store.credential(for:account) }
    func remove(account: AccountScope) throws { try store.remove(account:account) }
}

/// Real SecItem calls for one generic-password service; returns raw statuses and never logs item data.
struct SecItemKeychainBackend: KeychainBackend {
    let service: String
    private func query(_ account: String, _ kind: KeychainKind) -> [String:Any] {
        var query: [String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service,
                                   kSecAttrAccount as String:account, kSecAttrSynchronizable as String:false]
        if kind == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
    private func attributes(_ data: Data) -> [String:Any] {
        [kSecValueData as String:data, kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }
    func copy(account: String, kind: KeychainKind) -> (status: OSStatus, data: Data?) {
        var request = query(account, kind)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        return (status, result as? Data)
    }
    func add(_ data: Data, account: String, kind: KeychainKind) -> OSStatus {
        SecItemAdd(query(account, kind).merging(attributes(data), uniquingKeysWith:{ _, new in new }) as CFDictionary, nil)
    }
    func update(_ data: Data, account: String, kind: KeychainKind) -> OSStatus {
        SecItemUpdate(query(account, kind) as CFDictionary, attributes(data) as CFDictionary)
    }
    func delete(account: String, kind: KeychainKind) -> OSStatus { SecItemDelete(query(account, kind) as CFDictionary) }
}
