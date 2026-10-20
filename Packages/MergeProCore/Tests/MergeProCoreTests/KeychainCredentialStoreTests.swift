import Foundation
import Security
import XCTest
import MergeProCore

/// In-memory stand-in for SecItem: never touches a real keychain.
final class FakeKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [KeychainKind:[String:Data]] = [:]
    private var log: [String] = []
    private var failures: [String:OSStatus] = [:]
    let entitled: Bool
    init(entitled: Bool = true) { self.entitled = entitled }
    func seed(_ data: Data, account: String, kind: KeychainKind) { lock.withLock { items[kind, default:[:]][account] = data } }
    func stored(_ account: String, kind: KeychainKind) -> Data? { lock.withLock { items[kind]?[account] } }
    func fail(_ operation: String, _ kind: KeychainKind, with status: OSStatus) { lock.withLock { failures["\(operation) \(kind)"] = status } }
    func calls() -> [String] { lock.withLock { log } }
    private func run(_ operation: String, _ kind: KeychainKind, _ body: () -> OSStatus) -> OSStatus {
        lock.withLock {
            log.append("\(operation) \(kind)")
            if kind == .dataProtection, !entitled { return errSecMissingEntitlement }
            if let status = failures["\(operation) \(kind)"] { return status }
            return body()
        }
    }
    func copy(account: String, kind: KeychainKind) -> (status: OSStatus, data: Data?) {
        var data: Data?
        let status = run("copy", kind) { data = items[kind]?[account]; return data == nil ? errSecItemNotFound : errSecSuccess }
        return (status, data)
    }
    func add(_ data: Data, account: String, kind: KeychainKind) -> OSStatus {
        run("add", kind) { guard items[kind]?[account] == nil else { return errSecDuplicateItem }; items[kind, default:[:]][account] = data; return errSecSuccess }
    }
    func update(_ data: Data, account: String, kind: KeychainKind) -> OSStatus {
        run("update", kind) { guard items[kind]?[account] != nil else { return errSecItemNotFound }; items[kind]?[account] = data; return errSecSuccess }
    }
    func delete(account: String, kind: KeychainKind) -> OSStatus {
        run("delete", kind) { items[kind]?.removeValue(forKey:account) == nil ? errSecItemNotFound : errSecSuccess }
    }
}

final class KeychainCredentialStoreTests: XCTestCase {
    let account = AccountScope(host:"github.com", accountID:"42")
    var reference: String { AccountSessionStore.tokenReference(for:account) }
    let credential = GitHubCredential(accessToken:"fixture-access-value", refreshToken:"fixture-refresh-value", scopes:["repo"])
    func encoded(_ value: GitHubCredential) throws -> Data { try JSONEncoder().encode(value) }

    func testDataProtectionKeychainRoundTripLeavesLegacyKeychainEmpty() throws {
        let backend = FakeKeychainBackend(), store = KeychainCredentialStore(backend:backend)
        try store.save(credential, account:account)
        XCTAssertNotNil(backend.stored(reference, kind:.dataProtection))
        XCTAssertNil(backend.stored(reference, kind:.legacy))
        XCTAssertEqual(try store.credential(for:account), credential)
        let rotated = GitHubCredential(accessToken:"fixture-rotated-value", scopes:["repo"])
        try store.save(rotated, account:account)
        XCTAssertEqual(try store.credential(for:account), rotated)
        try store.remove(account:account)
        XCTAssertNil(try store.credential(for:account))
        XCTAssertNoThrow(try store.remove(account:account))
        XCTAssertFalse(backend.calls().contains("add legacy"))
    }
    func testMissingEntitlementFallsBackToLegacyKeychainForSaveReadAndRemove() throws {
        let backend = FakeKeychainBackend(entitled:false), store = KeychainCredentialStore(backend:backend)
        try store.save(credential, account:account)
        XCTAssertNotNil(backend.stored(reference, kind:.legacy))
        XCTAssertEqual(try store.credential(for:account), credential)
        try store.remove(account:account)
        XCTAssertNil(backend.stored(reference, kind:.legacy))
        XCTAssertNil(try store.credential(for:account))
        XCTAssertNoThrow(try store.remove(account:account))
    }
    func testLegacyCredentialMigratesAndLegacyCopyIsDeletedOnlyAfterDataProtectionAdd() throws {
        let backend = FakeKeychainBackend(), store = KeychainCredentialStore(backend:backend)
        backend.seed(try encoded(credential), account:reference, kind:.legacy)
        XCTAssertEqual(try store.credential(for:account), credential)
        XCTAssertNil(backend.stored(reference, kind:.legacy))
        XCTAssertEqual(backend.stored(reference, kind:.dataProtection), try encoded(credential))
        let calls = backend.calls()
        let added = try XCTUnwrap(calls.firstIndex(of:"add dataProtection")), deleted = try XCTUnwrap(calls.firstIndex(of:"delete legacy"))
        XCTAssertLessThan(added, deleted)
        XCTAssertEqual(try store.credential(for:account), credential)
    }
    func testFailedMigrationKeepsLegacyCredentialReadable() throws {
        let backend = FakeKeychainBackend(), store = KeychainCredentialStore(backend:backend)
        backend.seed(try encoded(credential), account:reference, kind:.legacy)
        backend.fail("add", .dataProtection, with:errSecInteractionNotAllowed)
        XCTAssertEqual(try store.credential(for:account), credential)
        XCTAssertEqual(try store.credential(for:account), credential)
        XCTAssertNotNil(backend.stored(reference, kind:.legacy))
        XCTAssertNil(backend.stored(reference, kind:.dataProtection))
        XCTAssertFalse(backend.calls().contains("delete legacy"))
    }
    func testSaveKeepsLegacyCopyWhenDataProtectionWriteFailsAndCleansItAfterSuccess() throws {
        let backend = FakeKeychainBackend(), store = KeychainCredentialStore(backend:backend)
        backend.seed(try encoded(credential), account:reference, kind:.legacy)
        backend.fail("add", .dataProtection, with:errSecInteractionNotAllowed)
        let rotated = GitHubCredential(accessToken:"fixture-rotated-value")
        XCTAssertThrowsError(try store.save(rotated, account:account)) { XCTAssertEqual($0 as? KeychainCredentialError, .operationFailed(errSecInteractionNotAllowed)) }
        XCTAssertNotNil(backend.stored(reference, kind:.legacy))
        XCTAssertFalse(backend.calls().contains("delete legacy"))
        let working = FakeKeychainBackend(), recovered = KeychainCredentialStore(backend:working)
        working.seed(try encoded(credential), account:reference, kind:.legacy)
        try recovered.save(rotated, account:account)
        XCTAssertNil(working.stored(reference, kind:.legacy))
        XCTAssertEqual(try recovered.credential(for:account), rotated)
    }
    func testRemoveDeletesFromBothKeychains() throws {
        let backend = FakeKeychainBackend(), store = KeychainCredentialStore(backend:backend)
        backend.seed(try encoded(credential), account:reference, kind:.dataProtection)
        backend.seed(try encoded(credential), account:reference, kind:.legacy)
        try store.remove(account:account)
        XCTAssertNil(backend.stored(reference, kind:.dataProtection))
        XCTAssertNil(backend.stored(reference, kind:.legacy))
        XCTAssertNil(try store.credential(for:account))
    }
    func testRemoveAttemptsBothKeychainsBeforeReportingAFailure() throws {
        let backend = FakeKeychainBackend(), store = KeychainCredentialStore(backend:backend)
        backend.seed(try encoded(credential), account:reference, kind:.legacy)
        backend.fail("delete", .dataProtection, with:errSecInteractionNotAllowed)
        XCTAssertThrowsError(try store.remove(account:account))
        XCTAssertNil(backend.stored(reference, kind:.legacy))
    }
    func testFailuresNeverCarryCredentialData() throws {
        let backend = FakeKeychainBackend(), store = KeychainCredentialStore(backend:backend)
        backend.seed(Data("{\"accessToken\":fixture-access-value".utf8), account:reference, kind:.dataProtection)
        XCTAssertThrowsError(try store.credential(for:account)) { error in
            XCTAssertEqual(error as? KeychainCredentialError, .invalidItem)
            for text in [String(describing:error), String(reflecting:error), error.localizedDescription] { XCTAssertFalse(text.contains("fixture-access-value")) }
        }
        backend.fail("copy", .dataProtection, with:errSecInteractionNotAllowed)
        XCTAssertThrowsError(try store.credential(for:account)) { XCTAssertFalse($0.localizedDescription.contains("fixture")) }
    }
}
