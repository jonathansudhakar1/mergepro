import Foundation

/// Outcome of one background prefetch pass. `stop` explains why the pass ended.
public struct PRPrefetchResult:Sendable,Equatable {
    public enum Stop:String,Sendable {
        /// Every candidate was fetched, skipped or failed.
        case completed
        /// `limit` network-fetched PRs reached.
        case limit
        /// The next background request would have touched the interactive reserve (or a provider backoff is active).
        case reserve
        /// An interactive provider read began; background work yields to the user.
        case interactive
        case cancelled
    }
    public internal(set) var fetched:[ProviderKey]=[]
    /// Already cached for their current head (no request), or not readable (non-GitHub / no metadata).
    public internal(set) var skipped:[ProviderKey]=[]
    public internal(set) var failed:[ProviderKey]=[]
    public internal(set) var stop:Stop = .completed
    public init() {}
}

extension PRDetailService {
    /// Sequentially loads detail + context for up to `limit` PRs at BACKGROUND budget priority, so
    /// opening them later is a cache hit. PRs already cached for their current head are skipped without
    /// a request. Stops before touching the interactive reserve, when an interactive read is in flight,
    /// or on cancellation. Never throws; per-PR failures are recorded and the pass continues.
    @discardableResult public func prefetchDetails(_ prs:[PullRequest],limit:Int,sections:[PRDetailTab] = [.overview,.checks,.conversation]) async -> PRPrefetchResult {
        var result=PRPrefetchResult(),seen=Set<ProviderKey>()
        let tabs=sections.filter { Self.cachedTabs.contains($0) }
        for pr in prs where seen.insert(pr.key).inserted {
            if Task.isCancelled { result.stop = .cancelled;return result }
            guard result.fetched.count < max(0,limit) else { result.stop = .limit;return result }
            guard !memory.interactiveActive else { result.stop = .interactive;return result }
            guard pr.key.host == "github.com",pr.metadata != nil else { result.skipped.append(pr.key);continue }
            do {
                if try await isCached(pr) { result.skipped.append(pr.key);continue }
                _ = try await read(pr,priority:.background) { try await refresh(pr,$0) }
                for tab in tabs {
                    guard !memory.interactiveActive else { result.fetched.append(pr.key);result.stop = .interactive;return result }
                    _ = try await read(pr,priority:.background) { try await refreshSection(pr,tab:tab,$0) }
                }
                result.fetched.append(pr.key)
            } catch {
                if case .rateLimited = error as? GitHubFailure { result.stop = .reserve;return result }
                // A stale candidate (inventory moved) fails validation with CancellationError; only real
                // task cancellation ends the pass.
                if Task.isCancelled { result.stop = .cancelled;return result }
                result.failed.append(pr.key)
            }
        }
        return result
    }
    /// No provider request: loads the persisted inventory, description and cached sections for the
    /// PR's current head into memory so the next open decodes nothing. Returns whether anything loaded.
    @discardableResult public func warm(_ pr:PullRequest) async -> Bool {
        do {
            return try await read(pr,network:false) { ctx in
                var loaded=try await cachedDiff(pr,ctx).diff != nil
                for tab in Self.cachedTabs.sorted(by:{ $0.rawValue < $1.rawValue }) where try await cachedSectionRecord(pr,tab:tab,ctx) != nil { loaded=true }
                return loaded
            }
        } catch { return false }
    }
    /// The diff inventory for the PR's current head is in memory, or its persisted payload still exists (no
    /// network). The index row alone is not proof: credential changes purge payloads and the cache budget evicts
    /// them, so the payload manifest is confirmed (a primary-key lookup; nothing is read or decoded).
    func isCached(_ pr:PullRequest) async throws -> Bool {
        try await read(pr,network:false) { ctx in
            let head=pr.headRevision.rawValue
            if memory.entry(.init(pr:pr.key,head:head),epoch:ctx.epoch)?.diff != nil { return true }
            guard let index=try await index(pr,ctx),index.head == head,let ref=index.diff else { return false }
            return try await payloadExists(pr,ctx,kind:"diff",ref:ref)
        }
    }
}
