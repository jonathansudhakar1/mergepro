import CryptoKit
import Foundation

public struct PayloadKey: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case diff, log, blob }
    public let object: ProviderKey
    public let revision: RevisionID
    public let kind: Kind
    public init(object: ProviderKey, revision: RevisionID, kind: Kind) {
        self.object = object; self.revision = revision; self.kind = kind
    }
}

/// One actor per dedicated cache directory. Files contain only regenerable provider payloads.
/// SQLite holds manifests; drafts, settings and pins are outside the eviction boundary.
public actor CacheStore {
    /// Present while no payload mutation is in progress. Missing at open means the previous session stopped
    /// mid-mutation (or predates the marker), so only then does the full folder scan run.
    static let cleanMarkerName = ".clean"
    private let directory: URL
    private let database: DatabaseStore
    private let maximumBytes: Int64
    private var reconciled = false
    private let needsFullScan: Bool
    private var markedClean: Bool

    /// Opening does not scan payload files. After a clean shutdown, startup only enforces the budget (one
    /// aggregate read) and reads validate their file lazily. After an unclean one, crash recovery scans the
    /// folder in a utility-priority task that completes before the first payload operation is served.
    public init(directory: URL, database: DatabaseStore, maximumBytes: Int64 = 2_000_000_000, reconcileInBackground: Bool = true) throws {
        guard maximumBytes >= 0 else { throw StorageError.invalidCacheBudget }
        self.directory = directory
        self.database = database
        self.maximumBytes = maximumBytes
        let created = !FileManager.default.fileExists(atPath: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A folder created just now holds no crash leftovers: mark it clean here, not from the background task.
        if created { FileManager.default.createFile(atPath: directory.appendingPathComponent(Self.cleanMarkerName).path, contents: nil,
                                                   attributes: [.posixPermissions: 0o600]) }
        // Regenerable payloads (up to the budget) must not fill Time Machine backups. Best effort: a volume
        // without the attribute still opens the cache.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        do { try excluded.setResourceValues(values) }
        catch { Log.storage.info("Cache directory not excluded from backups: \(Log.kind(error), privacy: .public)") }
        let clean = FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.cleanMarkerName).path)
        needsFullScan = !clean
        markedClean = clean
        if reconcileInBackground {
            Task(priority: .utility) { [weak self] in
                do { try await self?.reconcileIfNeeded() }
                catch { Log.storage.error("Background cache reconciliation failed: \(Log.kind(error), privacy: .public)") }
            }
            StorageMaintenance.schedule(database)
        }
    }

    /// Actor-isolated, so no payload write can interleave with the scan. A failure is retried and
    /// surfaced by the next payload operation.
    private func reconcileIfNeeded() throws {
        guard !reconciled else { return }
        if needsFullScan { try Self.reconcile(directory: directory, database: database) }
        // Eviction removes each file before its manifest row, so it never leaves an unindexed file.
        try Self.evict(directory: directory, database: database, budget: maximumBytes)
        reconciled = true
        endMutation()
    }
    /// Files and manifest rows change together only between these calls. A crash in between leaves no
    /// marker, so the next open runs the full scan (orphans, staging files, missing files).
    private func beginMutation() throws {
        guard markedClean else { return }
        let marker = directory.appendingPathComponent(Self.cleanMarkerName)
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        markedClean = false
    }
    private func endMutation() {
        // Until a required scan has run, the folder may still hold the crashed session's leftovers.
        guard !markedClean, reconciled || !needsFullScan else { return }
        markedClean = FileManager.default.createFile(atPath: directory.appendingPathComponent(Self.cleanMarkerName).path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600])
    }

    /// Immutable payload identity cannot be reassigned while its existing file is cached.
    public func put(_ data: Data, for key: PayloadKey) throws {
        try reconcileIfNeeded()
        guard try database.account(key.object.account) != nil else { throw StorageError.accountMissing(key.object.account) }
        guard Int64(data.count) <= maximumBytes else { throw StorageError.payloadExceedsBudget }
        let id = try Self.identifier(key)
        let url = try Self.fileURL(directory: directory, account: key.object.account, id: id)
        if FileManager.default.fileExists(atPath: url.path), try database.hasPayload(id: id) {
            guard try Data(contentsOf: url) == data else { throw StorageError.revisionConflict }
            try database.touchPayload(id: id)
            return
        }
        try beginMutation()
        if FileManager.default.fileExists(atPath: url.path) {
            // A file without a manifest entry is not a cached payload (its entry was evicted or forgotten):
            // replace it, so the payload is indexed and readable again.
            try FileManager.default.removeItem(at: url)
        }
        // Evict before writing so payload files stay within budget, including during writes.
        try database.forgetPayload(id: id)
        try Self.evict(directory: directory, database: database, budget: maximumBytes - Int64(data.count))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let pendingURL = url.appendingPathExtension("pending")
        do {
            // Explicit staging names let startup recover files left by a process crash.
            try data.write(to: pendingURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingURL.path)
            try FileManager.default.moveItem(at: pendingURL, to: url)
            try database.recordPayload(id: id, account: key.object.account, repositoryID: key.object.repositoryID, byteCount: Int64(data.count))
        } catch {
            if FileManager.default.fileExists(atPath: pendingURL.path) { try FileManager.default.removeItem(at: pendingURL) }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            endMutation()
            throw error
        }
        endMutation()
    }

    /// Validated lazily: a missing file, or one whose size no longer matches its manifest, is a miss.
    public func data(for key: PayloadKey) throws -> Data? {
        try reconcileIfNeeded()
        let id = try Self.identifier(key)
        guard let byteCount = try database.payloadByteCount(id: id) else { return nil }
        let url = try Self.fileURL(directory: directory, account: key.object.account, id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try database.forgetPayload(id: id)
            return nil
        }
        let data = try Data(contentsOf: url)
        guard Int64(data.count) == byteCount else {
            // File first, then manifest: an interruption leaves a manifest miss, never an unindexed file.
            try FileManager.default.removeItem(at: url)
            try database.forgetPayload(id: id)
            return nil
        }
        try database.touchPayload(id: id)
        return data
    }

    /// Supply the app's idempotent Keychain deletion. A failure propagates and keeps the account.
    /// Retained drafts never pass to this callback or a provider write.
    public func removeAccount(_ account: AccountScope, deletingCredential: @Sendable (String) throws -> Void) throws {
        // Purges never wait on, or fail with, startup reconciliation; the scan stays correct afterwards.
        if let reference = try database.account(account)?.tokenReference {
            try deletingCredential(reference)
        }
        try beginMutation()
        let accountDirectory = try Self.accountDirectory(directory: directory, account: account)
        if FileManager.default.fileExists(atPath: accountDirectory.path) {
            // Includes unindexed private files left by an interrupted cache write.
            try FileManager.default.removeItem(at: accountDirectory)
        }
        try database.deleteAccountRecords(account)
        endMutation()
    }

    /// Credential changes purge private cached representations without deleting the account, tracked
    /// scope, pins, or unsent drafts. PR detail index rows keep only their merge-base memo, so no content
    /// reference outlives the payloads it names.
    public func invalidatePrivatePayloads(for account: AccountScope) throws {
        try beginMutation()
        let accountDirectory = try Self.accountDirectory(directory: directory, account: account)
        if FileManager.default.fileExists(atPath: accountDirectory.path) { try FileManager.default.removeItem(at: accountDirectory) }
        try database.purgeFeaturePayloads(account)
        try database.forgetPayloads(account: account)
        endMutation()
    }

    /// A confirmed-invalid (revoked or expired) credential: every payload file of the account plus the private
    /// rows `DatabaseStore.purgePrivateContent` names. Unsent drafts and the whole write ledger stay. The
    /// in-memory PR detail cache is the caller's (see `AccountSessionStore`).
    public func purgePrivateContent(for account: AccountScope) throws {
        try beginMutation()
        let accountDirectory = try Self.accountDirectory(directory: directory, account: account)
        if FileManager.default.fileExists(atPath: accountDirectory.path) { try FileManager.default.removeItem(at: accountDirectory) }
        try database.purgePrivateContent(account)
        endMutation()
    }

    /// Commits a discovery listing. When a complete listing omits a previously known repository, that
    /// repository's cached content is purged, including its payload files. Returns the purged repositories.
    func commitRepositoryDiscovery(_ result: GitHubDiscoveryResult, account: AccountScope) throws -> Set<RepositoryKey> {
        try beginMutation()
        let purge: RepositoryAccessPurge
        do { purge = try database.commitRepositoryDiscovery(result, account: account) } catch { endMutation(); throw error }
        for id in purge.payloadIDs {
            let url = try Self.fileURL(directory: directory, account: account, id: id)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        endMutation()
        return purge.repositories
    }

    /// An explicit request: always a full scan, so the figure counts only indexed, present files.
    public func diskUsage() throws -> Int64 {
        if reconciled {
            try beginMutation()
            try Self.reconcile(directory: directory, database: database)
            endMutation()
        } else { try reconcileIfNeeded() }
        return try database.payloadUsage()
    }

    /// The manifest identity of a payload, for existence checks without reading it.
    static func payloadID(_ key: PayloadKey) throws -> String { try identifier(key) }

    private static func identifier<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder.stable
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    private static func accountDirectory(directory: URL, account: AccountScope) throws -> URL {
        directory.appendingPathComponent(try identifier(account), isDirectory: true)
    }

    private static func fileURL(directory: URL, account: AccountScope, id: String) throws -> URL {
        try accountDirectory(directory: directory, account: account).appendingPathComponent(id + ".payload")
    }

    /// Recover a crash between file/manifest writes: missing files become misses, orphans are removed.
    private static func reconcile(directory: URL, database: DatabaseStore) throws {
        let entries = try database.cacheEntries()
        var knownPaths = Set<String>()
        for entry in entries {
            let url = try fileURL(directory: directory, account: entry.account, id: entry.id)
            if FileManager.default.fileExists(atPath: url.path) {
                knownPaths.insert(url.standardizedFileURL.path)
            } else {
                try database.forgetPayload(id: entry.id)
            }
        }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator where url.pathExtension == "payload" || url.pathExtension == "pending" {
            if url.pathExtension == "pending" || !knownPaths.contains(url.standardizedFileURL.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func evict(directory: URL, database: DatabaseStore, budget: Int64) throws {
        // The common under-budget write reads one aggregate instead of the whole manifest.
        guard try database.payloadUsage() > budget else { return }
        let entries = try database.cacheEntries()
        var usage = entries.reduce(0) { $0 + $1.byteCount }
        for entry in entries where usage > budget {
            let url = try fileURL(directory: directory, account: entry.account, id: entry.id)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try database.forgetPayload(id: entry.id)
            usage -= entry.byteCount
        }
    }
}
