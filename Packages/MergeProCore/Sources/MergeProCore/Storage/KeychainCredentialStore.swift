import Foundation
import Security

/// The data-protection keychain honours `kSecAttrAccessible`; the legacy file keychain is the fallback for
/// builds without the keychain entitlement and the source of items written before the move.
public enum KeychainKind: Sendable, Equatable { case dataProtection, legacy }
/// SecItem operations for one generic-password service, returning raw `OSStatus` values.
/// Implementations must be synchronous, thread safe, and must never log or embed item data.
public protocol KeychainBackend: Sendable {
    func copy(account: String, kind: KeychainKind) -> (status: OSStatus, data: Data?)
    func add(_ data: Data, account: String, kind: KeychainKind) -> OSStatus
    func update(_ data: Data, account: String, kind: KeychainKind) -> OSStatus
    func delete(account: String, kind: KeychainKind) -> OSStatus
}
/// Carries only a status code; credential bytes and decoding details are never included.
public enum KeychainCredentialError: Error, Equatable, Sendable, LocalizedError {
    case operationFailed(OSStatus), invalidItem
    public var errorDescription: String? {
        switch self {
        case .operationFailed(let status): "MergePro could not access the saved GitHub sign-in in the keychain (error \(status)). Reconnect the account in Setup if this continues."
        case .invalidItem: "The saved GitHub sign-in in the keychain is unreadable. Reconnect the account in Setup."
        }
    }
}

/// One JSON credential item per account reference. Prefers the data-protection keychain, falls back to the legacy
/// keychain on `errSecMissingEntitlement`, and moves legacy items forward without ever deleting the only copy.
public struct KeychainCredentialStore<Backend: KeychainBackend>: GitHubCredentialStore {
    public let backend: Backend
    public init(backend: Backend) { self.backend = backend }
    public func credential(for account: AccountScope) throws -> GitHubCredential? {
        let reference = AccountSessionStore.tokenReference(for:account)
        let current = backend.copy(account:reference, kind:.dataProtection)
        switch current.status {
        case errSecSuccess: return try decode(current.data)
        case errSecItemNotFound, errSecMissingEntitlement: break
        default: throw KeychainCredentialError.operationFailed(current.status)
        }
        let legacy = backend.copy(account:reference, kind:.legacy)
        if legacy.status == errSecItemNotFound { return nil }
        guard legacy.status == errSecSuccess, let data = legacy.data else { throw KeychainCredentialError.operationFailed(legacy.status) }
        let credential = try decode(data)
        // The legacy copy is deleted only once the data-protection copy is confirmed; otherwise it stays readable.
        if current.status == errSecItemNotFound, backend.add(data, account:reference, kind:.dataProtection) == errSecSuccess {
            _ = backend.delete(account:reference, kind:.legacy)
        }
        return credential
    }
    public func save(_ credential: GitHubCredential, account: AccountScope) throws {
        let reference = AccountSessionStore.tokenReference(for:account)
        guard let data = try? JSONEncoder.stable.encode(credential) else { throw KeychainCredentialError.invalidItem }
        let status = write(data, reference, .dataProtection)
        // A stale legacy copy is best-effort cleanup: the new credential is already stored and read first.
        if status == errSecSuccess { _ = backend.delete(account:reference, kind:.legacy); return }
        guard status == errSecMissingEntitlement else { throw KeychainCredentialError.operationFailed(status) }
        let legacy = write(data, reference, .legacy)
        guard legacy == errSecSuccess else { throw KeychainCredentialError.operationFailed(legacy) }
    }
    /// Idempotent; both keychains are attempted before any failure is reported.
    public func remove(account: AccountScope) throws {
        let reference = AccountSessionStore.tokenReference(for:account)
        let current = backend.delete(account:reference, kind:.dataProtection), legacy = backend.delete(account:reference, kind:.legacy)
        if ![errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(current) { throw KeychainCredentialError.operationFailed(current) }
        if ![errSecSuccess, errSecItemNotFound].contains(legacy) { throw KeychainCredentialError.operationFailed(legacy) }
    }
    private func write(_ data: Data, _ reference: String, _ kind: KeychainKind) -> OSStatus {
        var status = backend.update(data, account:reference, kind:kind)
        guard status == errSecItemNotFound else { return status }
        status = backend.add(data, account:reference, kind:kind)
        // A concurrent read may have migrated the item between the update and the add.
        return status == errSecDuplicateItem ? backend.update(data, account:reference, kind:kind) : status
    }
    private func decode(_ data: Data?) throws -> GitHubCredential {
        guard let data, let credential = try? JSONDecoder().decode(GitHubCredential.self, from:data) else { throw KeychainCredentialError.invalidItem }
        return credential
    }
}
