import Foundation
import Synchronization

/// Persisted diff inventory for one head: the snapshot (no body) plus validators per loaded page.
struct PRDiffRecord:Codable,Sendable {
    let snapshot:PRDetailSnapshot
    let pages:[PRFilesPage]
    /// The retained slice for `page`; pages before it are full (100) by construction.
    func page(_ number:Int) -> (tag:PRFilesPage,files:[DiffFile])? {
        guard let tag=pages.first(where:{ $0.page == number }) else { return nil }
        let start=(number-1)*100
        guard start >= 0,start+tag.count <= snapshot.files.count else { return nil }
        return (tag,Array(snapshot.files[start..<start+tag.count]))
    }
}
/// Persisted read-only section plus the conditional page validators that produced it.
struct PRSectionRecord:Codable,Sendable {
    let section:PRDetailSection
    let pages:[String:PRConditionalPage]
}
/// A cached value, when the provider last confirmed it, and its content hash in CacheStore.
struct PRDetailStamped<T:Sendable>:Sendable {
    let value:T
    let fetchedAt:Date
    let hash:String
    let bytes:Int
}

/// Process-wide bounded LRU for revision-bound PR detail, so reopening a window needs no decode
/// and no request. Keys are account + PR + head SHA: one head never serves another. Entries carry
/// the credential epoch that read them; a reconnect, refresh or removal turns them into misses.
/// Bounded by entry count and approximate (encoded) bytes. Call `purge(account:)` on removal.
public final class PRDetailMemoryCache:Sendable {
    public static let shared=PRDetailMemoryCache()
    public struct Statistics:Equatable,Sendable {
        public var hits=0
        public var misses=0
        /// Persisted payloads decoded into memory (each is a CacheStore read + JSON decode).
        public var persistedDecodes=0
    }
    struct Key:Hashable,Sendable { let pr:ProviderKey;let head:String }
    struct Entry:Sendable {
        var epoch:String
        var diff:PRDetailStamped<PRDiffRecord>?
        var pull:PRDetailStamped<PRPullRecord>?
        var sections:[String:PRDetailStamped<PRSectionRecord>]=[:]
        var viewed:PRViewedStates?
        var order:UInt64=0
        var bytes:Int { (diff?.bytes ?? 0)+(pull?.bytes ?? 0)+sections.values.reduce(0) { $0+$1.bytes }+(viewed.map { $0.viewed.keys.reduce(64) { $0+$1.utf8.count+8 } } ?? 0) }
    }
    private struct MergeBaseKey:Hashable { let repository:RepositoryKey;let base:String;let head:String }
    private struct State:~Copyable {
        var entries:[Key:Entry]=[:]
        var mergeBases:[MergeBaseKey:String]=[:]
        var mergeBaseOrder:[MergeBaseKey]=[]
        var tick:UInt64=0
        var stats=Statistics()
        var interactive=0
        mutating func evict(maximumEntries:Int,maximumBytes:Int) {
            while entries.count > maximumEntries || entries.values.reduce(0,{ $0+$1.bytes }) > maximumBytes {
                guard let oldest=entries.min(by:{ $0.value.order < $1.value.order })?.key else { return }
                entries[oldest]=nil
            }
        }
    }
    private let state=Mutex(State())
    public let maximumEntries:Int
    public let maximumBytes:Int
    /// Immutable file contents shared by every PR window; purged and cleared with this cache.
    public let blobs:PRBlobMemoryCache
    public init(maximumEntries:Int = 48,maximumBytes:Int = 64_000_000,blobs:PRBlobMemoryCache = PRBlobMemoryCache()) { self.maximumEntries=max(1,maximumEntries);self.maximumBytes=max(0,maximumBytes);self.blobs=blobs }
    public var count:Int { state.withLock { $0.entries.count } }
    public var byteCount:Int { state.withLock { $0.entries.values.reduce(0) { $0+$1.bytes } } }
    public var statistics:Statistics { state.withLock { $0.stats } }
    public func resetStatistics() { state.withLock { $0.stats=Statistics() } }
    /// Drops every entry and merge-base memo for `account`. Persisted rows and CacheStore payloads
    /// are removed by account removal itself (cascade + account cache directory).
    public func purge(account:AccountScope) {
        blobs.purge(account:account)
        state.withLock { state in
            state.entries=state.entries.filter { $0.key.pr.account != account }
            state.mergeBases=state.mergeBases.filter { $0.key.repository.account != account }
            state.mergeBaseOrder.removeAll { $0.repository.account == account }
        }
    }
    public func removeAll() { blobs.removeAll();state.withLock { $0.entries=[:];$0.mergeBases=[:];$0.mergeBaseOrder=[] } }
    /// Entries held for `account` (any head), for diagnostics and purge verification.
    public func count(account:AccountScope) -> Int { state.withLock { $0.entries.keys.filter { $0.pr.account == account }.count } }
    /// A diff inventory is held for this PR's current head (no credential check; scheduling hint only).
    public func containsDetail(_ pr:PullRequest) -> Bool { state.withLock { $0.entries[Key(pr:pr.key,head:pr.headRevision.rawValue)]?.diff != nil } }

    func entry(_ key:Key,epoch:String) -> Entry? {
        state.withLock { state in
            guard let value=state.entries[key] else { state.stats.misses += 1;return nil }
            guard value.epoch == epoch else { state.entries[key]=nil;state.stats.misses += 1;return nil }
            state.tick += 1;state.entries[key]?.order=state.tick;state.stats.hits += 1
            return state.entries[key]
        }
    }
    func update(_ key:Key,epoch:String,_ body:(inout Entry) -> Void) {
        state.withLock { state in
            var value=state.entries[key].flatMap { $0.epoch == epoch ? $0 : nil } ?? Entry(epoch:epoch)
            body(&value);state.tick += 1;value.order=state.tick;state.entries[key]=value
            state.evict(maximumEntries:maximumEntries,maximumBytes:maximumBytes)
        }
    }
    /// Memory-only edit of an existing entry (any epoch); a stale epoch is still dropped on read.
    func modify(_ key:Key,_ body:(inout Entry) -> Void) { state.withLock { state in guard var value=state.entries[key] else { return };body(&value);state.entries[key]=value } }
    func mergeBase(_ repository:RepositoryKey,base:String,head:String) -> String? { state.withLock { $0.mergeBases[.init(repository:repository,base:base,head:head)] } }
    func rememberMergeBase(_ repository:RepositoryKey,base:String,head:String,mergeBase:String) {
        state.withLock { state in
            let key=MergeBaseKey(repository:repository,base:base,head:head)
            if state.mergeBases.updateValue(mergeBase,forKey:key) == nil { state.mergeBaseOrder.append(key) }
            while state.mergeBaseOrder.count > 4096 { state.mergeBases[state.mergeBaseOrder.removeFirst()]=nil }
        }
    }
    func recordDecode() { state.withLock { $0.stats.persistedDecodes += 1 } }
    /// Interactive provider reads in flight; background prefetch yields to them.
    func beginInteractive() { state.withLock { $0.interactive += 1 } }
    func endInteractive() { state.withLock { $0.interactive=max(0,$0.interactive-1) } }
    var interactiveActive:Bool { state.withLock { $0.interactive > 0 } }
}

/// Process-wide bounded LRU of immutable file contents (a blob read by commit SHA and path), shared by
/// every PR window so revisiting, prefetching or opening a second window never reads the same blob twice.
/// Keys carry the account and repository, so content is never served to another account. Entries larger
/// than a quarter of the bound are not kept. `PRDetailMemoryCache.purge(account:)` purges it.
public final class PRBlobMemoryCache:Sendable {
    public struct Key:Hashable,Sendable {
        public let repository:RepositoryKey
        public let sha:String
        public let path:String
        public init(repository:RepositoryKey,sha:String,path:String) { self.repository=repository;self.sha=sha;self.path=path }
    }
    private struct State:~Copyable {
        var values:[Key:Data]=[:]
        var order:[Key]=[]
        var bytes=0
    }
    private let state=Mutex(State())
    public let maximumBytes:Int
    public init(maximumBytes:Int = 64_000_000) { self.maximumBytes=max(0,maximumBytes) }
    public var count:Int { state.withLock { $0.values.count } }
    public var byteCount:Int { state.withLock { $0.bytes } }
    /// A hit becomes the most recently used entry.
    public func data(_ key:Key) -> Data? {
        state.withLock { state in
            guard let data=state.values[key] else { return nil }
            if let index=state.order.lastIndex(of:key) { state.order.remove(at:index) };state.order.append(key)
            return data
        }
    }
    /// Presence without changing recency (scheduling hint for prefetch).
    public func contains(_ key:Key) -> Bool { state.withLock { $0.values[key] != nil } }
    public func store(_ data:Data,for key:Key) {
        state.withLock { state in
            guard state.values[key] == nil,data.count <= maximumBytes/4 else { return }
            state.values[key]=data;state.order.append(key);state.bytes += data.count
            while state.bytes > maximumBytes,!state.order.isEmpty { state.bytes -= state.values.removeValue(forKey:state.order.removeFirst())?.count ?? 0 }
        }
    }
    public func purge(account:AccountScope) {
        state.withLock { state in
            state.values=state.values.filter { $0.key.repository.account != account };state.order.removeAll { $0.repository.account == account }
            state.bytes=state.values.values.reduce(0) { $0+$1.count }
        }
    }
    public func removeAll() { state.withLock { $0.values=[:];$0.order=[];$0.bytes=0 } }
}
