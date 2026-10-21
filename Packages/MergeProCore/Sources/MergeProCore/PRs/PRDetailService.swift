import CryptoKit
import Foundation
import Synchronization
import GRDB

/// Uses the app's existing authorization/cache owners; no credentials cross into presentation.
///
/// Detail cache v2: every cached value is bound to account + PR + head SHA. Content (diff inventory,
/// description, overview/checks/conversation) lives in CacheStore as content-addressed private
/// payloads, purged with credential changes and account removal. A tiny per-PR index row in
/// `pollFeatureSnapshots` (feature `pr-detail-cache-v2`) records content hashes, `fetchedAt`
/// stamps and a permanent merge-base memo; it cascades away with the account, and a credential
/// purge strips its content references (keeping only the memo). A process-wide
/// `PRDetailMemoryCache` fronts both so a reopen needs no decode and no request.
public struct PRDetailService: Sendable {
    private let session: GitHubAccountSession
    private let budget: RateBudget
    private let clientID:String
    let memory:PRDetailMemoryCache
    public init(session:GitHubAccountSession,budget:RateBudget,clientID:String,memory:PRDetailMemoryCache = .shared) { self.session=session;self.budget=budget;self.clientID=clientID;self.memory=memory }
    static let cacheFeature="pr-detail-cache-v2"
    static let cachedTabs:Set<PRDetailTab>=[.overview,.checks,.conversation]

    struct Context:Sendable {
        let fetcher:GitHubPRDetailFetcher
        let ticket:AccountOperation
        let metadata:PRMetadata
        let fence:Int
        let epoch:String
        var token:String { ticket.credential.accessToken }
    }
    /// The credential generation and token that read a value; memory entries from another epoch are misses.
    static func epoch(_ ticket:AccountOperation) -> String {
        ticket.generation.uuidString+":"+SHA256.hash(data:Data(ticket.credential.accessToken.utf8)).prefix(8).map { String(format:"%02x",$0) }.joined()
    }
    func read<T:Sendable>(_ pr:PullRequest,priority:RateBudget.Priority = .interactive,network:Bool = true,body:@Sendable (Context) async throws -> T) async throws -> T {
        guard pr.key.host == "github.com",let metadata=pr.metadata else { throw PRDetailFailure.unavailable }
        let ticket=try await session.authenticatedOperation(for:pr.key.account,clientID:clientID)
        let fence=try await session.observationFence(pr.key,operation:ticket)
        let tracked=network && priority == .interactive
        if tracked { memory.beginInteractive() }
        defer { if tracked { memory.endInteractive() } }
        do {
            let client=priority == .interactive ? await session.interactiveReadClient(account:pr.key.account,budget:budget) : await session.featureClient(account:pr.key.account,budget:budget)
            let result=try await body(Context(fetcher:GitHubPRDetailFetcher(client:client),ticket:ticket,metadata:metadata,fence:fence,epoch:Self.epoch(ticket)))
            try Task.checkCancellation()
            let expectedFence=fence,head=pr.headRevision
            guard try await session.withCurrentOperation(ticket,body:{ db in
                guard try db.observationFence(for:pr.key) == expectedFence,try Self.current(pr.key,in:db)?.headRevision == head else { throw CancellationError() }
            }) else { throw CancellationError() }
            return result
        } catch {
            // Positively observed trusted authentication failure precedes cancellation guards.
            await session.featureFailed(error,operation:ticket)
            throw error
        }
    }
    /// Targeted single-row read; the full account snapshot is only needed for size baselines.
    static func current(_ key:ProviderKey,in db:DatabaseStore) throws -> PullRequest? {
        try db.database.read { try Data.fetchOne($0,sql:"SELECT json FROM pullRequests WHERE host=? AND accountID=? AND repositoryID=? AND objectID=?",arguments:[key.host,key.accountID,key.repositoryID,key.objectID]).map { try JSONDecoder().decode(PullRequest.self,from:$0) } }
    }

    /// One conditional PR read, independent of files and merge-base resolution. Freshness shortcuts
    /// are display-only; write admission always revalidates separately.
    public func description(_ pr:PullRequest,maxAge:TimeInterval = 0) async throws -> PRDescriptionSnapshot {
        try await read(pr) { ctx in
            let prior=try await cachedPull(pr,ctx)
            if maxAge > 0,let prior,Date().timeIntervalSince(prior.fetchedAt) <= maxAge,prior.fetchedAt <= Date().addingTimeInterval(5) {
                return .init(body:prior.value.body,headSHA:prior.value.head,fetchedAt:prior.fetchedAt,cached:true)
            }
            let value=try await ctx.fetcher.pull(repository:ctx.metadata.repositoryName,number:ctx.metadata.number,cached:prior?.value,token:ctx.token).value
            guard value.head == pr.headRevision.rawValue else { throw PRDetailFailure.revisionChanged }
            let now=Date()
            let stored:PRDetailStamped<PRPullRecord>
            if let prior,prior.value == value { stored = .init(value:value,fetchedAt:now,hash:prior.hash,bytes:prior.bytes) }
            else { stored=try await put(value,pr,ctx,kind:"pull",at:now) }
            // Description reads must not advance the diff's validation timestamp.
            try await updateIndex(pr,ctx) { $0.pull = .init(hash:stored.hash,fetchedAt:now) }
            memory.update(.init(pr:pr.key,head:pr.headRevision.rawValue),epoch:ctx.epoch) { $0.pull=stored }
            return .init(body:value.body,headSHA:value.head,fetchedAt:now,cached:false)
        }
    }
    /// No network and no diff decode: a description can be cached before Files has ever opened.
    public func cachedDescription(_ pr:PullRequest) async throws -> PRDescriptionSnapshot? {
        try await read(pr,network:false) { ctx in
            guard let pull=try await cachedPull(pr,ctx) else { return nil }
            return .init(body:pull.value.body,headSHA:pull.value.head,fetchedAt:pull.fetchedAt,cached:true)
        }
    }
    private func cachedPull(_ pr:PullRequest,_ ctx:Context) async throws -> PRDetailStamped<PRPullRecord>? {
        let head=pr.headRevision.rawValue,key=PRDetailMemoryCache.Key(pr:pr.key,head:head)
        if let pull=memory.entry(key,epoch:ctx.epoch)?.pull,pull.value.head == head { return pull }
        guard let index=try await index(pr,ctx),index.head == head,let ref=index.pull,
              let pull=try await payload(PRPullRecord.self,pr,ctx,kind:"pull",ref:ref),pull.value.head == head else { return nil }
        memory.update(key,epoch:ctx.epoch) { $0.pull=pull }
        return pull
    }

    // MARK: Detail

    /// Revalidates against the provider. With a cached inventory for this head this is one
    /// conditional `pulls/N` (304 when unchanged); the merge base is memoized per (base, head).
    public func detail(_ pr:PullRequest) async throws -> PRDetailSnapshot {
        try await read(pr) { try await refresh(pr,$0) }
    }
    /// Returns the cached detail when both inventory and description were confirmed within `maxAge`
    /// seconds (labeled `cached`, with ages); otherwise revalidates like `detail(_:)`.
    public func detail(_ pr:PullRequest,maxAge:TimeInterval) async throws -> PRDetailSnapshot {
        if maxAge > 0,let value=try await cachedDetail(pr),let diffAge=value.fetchedAt,let bodyAge=value.bodyFetchedAt,
           Date().timeIntervalSince(min(diffAge,bodyAge)) <= maxAge { return value }
        return try await detail(pr)
    }
    func refresh(_ pr:PullRequest,_ ctx:Context) async throws -> PRDetailSnapshot {
        let head=pr.headRevision.rawValue,m=ctx.metadata,now=Date()
        let state=try await cachedDiff(pr,ctx)
        var diff:PRDiffRecord,pull:PRPullRecord,diffChanged=false,fromNetwork=false
        if let cached=state.diff?.value,cached.snapshot.headSHA == head {
            let current=try await ctx.fetcher.pull(repository:m.repositoryName,number:m.number,cached:state.pull?.value,token:ctx.token).value
            guard current.head == head else { throw PRDetailFailure.revisionChanged }
            pull=current;diff=cached
            if current.base != cached.snapshot.baseBranchSHA {
                // The inventory is a function of (merge base, head): an unchanged merge base keeps it.
                if try await mergeBase(pr,ctx,base:current.base) == cached.snapshot.baseSHA {
                    diff = .init(snapshot:cached.snapshot.with(body:"",baseBranchSHA:current.base,cached:false,fetchedAt:nil,bodyFetchedAt:nil),pages:cached.pages)
                } else { (diff,pull)=try await firstPage(pr,ctx,pull:current,prior:cached);fromNetwork=true }
                diffChanged=true
            }
        } else { (diff,pull)=try await firstPage(pr,ctx,pull:state.pull?.value,prior:nil);diffChanged=true;fromNetwork=true }
        try await store(pr,ctx,diff:diffChanged ? diff : nil,pull:pull == state.pull?.value ? nil : pull,at:now)
        try await enrich(diff.snapshot,pr:pr,ctx:ctx,force:fromNetwork)
        return diff.snapshot.with(body:pull.body,cached:false,fetchedAt:now,bodyFetchedAt:now)
    }
    /// Mutable files are bracketed by fresh PR identity reads. A rebuild reuses refresh's
    /// preceding read; a cold load needs its own. Warm inventory validation still reads only once.
    private func firstPage(_ pr:PullRequest,_ ctx:Context,pull prior:PRPullRecord?,prior diff:PRDiffRecord?) async throws -> (PRDiffRecord,PRPullRecord) {
        let head=pr.headRevision.rawValue,m=ctx.metadata
        let before:PRPullRecord
        if diff != nil,let prior { before=prior }
        else { before=try await ctx.fetcher.pull(repository:m.repositoryName,number:m.number,cached:prior,token:ctx.token).value }
        guard before.head == head else { throw PRDetailFailure.revisionChanged }
        let page=try await ctx.fetcher.filesPage(repository:m.repositoryName,number:m.number,page:1,cached:diff?.page(1),token:ctx.token)
        let pull=try await ctx.fetcher.pull(repository:m.repositoryName,number:m.number,cached:before,token:ctx.token).value
        guard pull.head == head,pull.base == before.base else { throw PRDetailFailure.revisionChanged }
        let origin=try await mergeBase(pr,ctx,base:pull.base)
        let snapshot=PRDetailSnapshot(body:"",baseSHA:origin,headSHA:head,files:page.files,expectedFiles:pull.changedFiles,baseBranchSHA:pull.base,nextPage:page.files.count == 100 && page.files.count < pull.changedFiles ? 2 : nil)
        return (.init(snapshot:snapshot,pages:[page.tag]),pull)
    }
    /// Page continuation: the page, then one conditional `pulls/N`; the merge base comes from the memo.
    public func more(_ pr:PullRequest,snapshot:PRDetailSnapshot) async throws -> PRDetailSnapshot {
        guard snapshot.headSHA == pr.headRevision.rawValue else { throw PRDetailFailure.revisionChanged }
        guard let page=snapshot.nextPage,page > 1,page <= 30 else { return snapshot }
        return try await read(pr) { ctx in
            let head=pr.headRevision.rawValue,m=ctx.metadata,now=Date()
            let state=try await cachedDiff(pr,ctx)
            let prior=state.diff?.value.snapshot.headSHA == head && state.diff?.value.snapshot.baseSHA == snapshot.baseSHA ? state.diff?.value : nil
            let fetched=try await ctx.fetcher.filesPage(repository:m.repositoryName,number:m.number,page:page,cached:prior?.page(page),token:ctx.token)
            let pull=try await ctx.fetcher.pull(repository:m.repositoryName,number:m.number,cached:state.pull?.value,token:ctx.token).value
            guard pull.head == snapshot.headSHA,pull.base == snapshot.baseBranchSHA else { throw PRDetailFailure.revisionChanged }
            let origin=try await mergeBase(pr,ctx,base:pull.base)
            guard origin == snapshot.baseSHA else { throw PRDetailFailure.revisionChanged }
            let files=snapshot.files+fetched.files
            guard Set(files.map(\.path)).count == files.count,files.reduce(0,{ $0+($1.patch?.utf8.count ?? 0) }) <= 12_000_000 else { throw PRDetailFailure.oversized }
            let value=PRDetailSnapshot(body:"",baseSHA:origin,headSHA:head,files:files,expectedFiles:pull.changedFiles,baseBranchSHA:pull.base,nextPage:fetched.files.count == 100 && page < 30 && files.count < pull.changedFiles ? page+1 : nil)
            let record=PRDiffRecord(snapshot:value,pages:(prior?.pages.filter { $0.page < page } ?? [])+[fetched.tag])
            try await store(pr,ctx,diff:record,pull:pull == state.pull?.value ? nil : pull,at:now)
            try await enrich(value,pr:pr,ctx:ctx,force:true)
            return value.with(body:pull.body,cached:false,fetchedAt:now,bodyFetchedAt:now)
        }
    }
    /// No network. Memory first, then the persisted head-keyed inventory and description, labeled
    /// `cached` with `fetchedAt`/`bodyFetchedAt`. Never returns another head's inventory.
    public func cachedDetail(_ pr:PullRequest) async throws -> PRDetailSnapshot? {
        try await read(pr,network:false) { ctx in
            let state=try await cachedDiff(pr,ctx)
            guard let diff=state.diff,diff.value.snapshot.headSHA == pr.headRevision.rawValue else { return nil }
            let pull=state.pull?.value.head == pr.headRevision.rawValue ? state.pull : nil
            return diff.value.snapshot.with(body:pull?.value.body ?? "",cached:true,fetchedAt:diff.fetchedAt,bodyFetchedAt:pull?.fetchedAt)
        }
    }

    // MARK: Sections

    /// Overview, checks and conversation are cached per head with `fetchedAt`; checks and conversation
    /// pages revalidate with If-None-Match. Other tabs read through unchanged.
    public func section(_ pr:PullRequest,tab:PRDetailTab) async throws -> PRDetailSection {
        try await read(pr) { try await refreshSection(pr,tab:tab,$0) }
    }
    func refreshSection(_ pr:PullRequest,tab:PRDetailTab,_ ctx:Context) async throws -> PRDetailSection {
        let head=pr.headRevision.rawValue,m=ctx.metadata
        guard Self.cachedTabs.contains(tab) else { return try await ctx.fetcher.section(repository:m.repositoryName,number:m.number,sha:head,tab:tab,token:ctx.token) }
        let prior=try await cachedSectionRecord(pr,tab:tab,ctx),now=Date()
        let record:PRSectionRecord
        if tab == .overview { record = .init(section:try await ctx.fetcher.section(repository:m.repositoryName,number:m.number,sha:head,tab:tab,token:ctx.token),pages:[:]) }
        else {
            let value=try await ctx.fetcher.pagedSection(repository:m.repositoryName,number:m.number,sha:head,tab:tab,token:ctx.token,cached:prior?.value.pages ?? [:])
            record = .init(section:value.section,pages:value.pages)
        }
        try await storeSection(pr,tab:tab,ctx,record:record,prior:prior,at:now)
        return record.section.with(fetchedAt:now,cached:false)
    }
    /// No network: the cached overview/checks/conversation for this head, labeled `cached` + `fetchedAt`.
    public func cachedSection(_ pr:PullRequest,tab:PRDetailTab) async throws -> PRDetailSection? {
        guard Self.cachedTabs.contains(tab) else { return nil }
        return try await read(pr,network:false) { ctx in try await cachedSectionRecord(pr,tab:tab,ctx).map { $0.value.section.with(fetchedAt:$0.fetchedAt,cached:true) } }
    }

    // MARK: Viewed states

    /// Light provider viewed-mark read: one bounded GraphQL connection bound to `revision` (the head
    /// SHA), cached in memory per PR + head so switching files makes no request. `refresh` forces a read.
    public func viewedStates(_ pr:PullRequest,revision:String,refresh:Bool = false) async throws -> PRViewedStates {
        guard revision == pr.headRevision.rawValue else { throw PRDetailFailure.revisionChanged }
        return try await read(pr) { ctx in
            let key=PRDetailMemoryCache.Key(pr:pr.key,head:revision)
            if !refresh,let cached=memory.entry(key,epoch:ctx.epoch)?.viewed,cached.headSHA == revision { return cached }
            let value=try await ctx.fetcher.viewedStates(repository:ctx.metadata.repositoryName,number:ctx.metadata.number,sha:revision,token:ctx.token)
            memory.update(key,epoch:ctx.epoch) { $0.viewed=value }
            return value
        }
    }
    public func viewedStates(_ pr:PullRequest,revision:PRWriteRevision,refresh:Bool = false) async throws -> PRViewedStates {
        try await viewedStates(pr,revision:revision.head,refresh:refresh)
    }
    /// Memory-only: reflect a provider-confirmed viewed write without re-reading.
    public func recordViewedState(_ pr:PullRequest,revision:String,path:String,viewed:Bool) {
        memory.modify(.init(pr:pr.key,head:revision)) { entry in if entry.viewed?.headSHA == revision { entry.viewed=entry.viewed?.setting(path,viewed:viewed) } }
    }
    public func invalidateViewedStates(_ pr:PullRequest) { memory.modify(.init(pr:pr.key,head:pr.headRevision.rawValue)) { $0.viewed=nil } }
    /// Drops this account's in-memory detail and memo. Call after account removal; persisted rows and
    /// payloads are already removed by the account owner (cascade and cache directory).
    public func purgeCaches(account:AccountScope) { memory.purge(account:account) }

    // MARK: Cache plumbing

    func cachedDiff(_ pr:PullRequest,_ ctx:Context) async throws -> (diff:PRDetailStamped<PRDiffRecord>?,pull:PRDetailStamped<PRPullRecord>?) {
        let head=pr.headRevision.rawValue,key=PRDetailMemoryCache.Key(pr:pr.key,head:head)
        if let entry=memory.entry(key,epoch:ctx.epoch),let diff=entry.diff { return (diff,entry.pull) }
        guard let index=try await index(pr,ctx),index.head == head,let ref=index.diff,
              let diff=try await payload(PRDiffRecord.self,pr,ctx,kind:"diff",ref:ref),diff.value.snapshot.headSHA == head else { return (nil,try await cachedPull(pr,ctx)) }
        let pull=try await index.pull.asyncMap { try await payload(PRPullRecord.self,pr,ctx,kind:"pull",ref:$0) } ?? nil
        memory.update(key,epoch:ctx.epoch) { $0.diff=diff;$0.pull=pull }
        return (diff,pull)
    }
    func cachedSectionRecord(_ pr:PullRequest,tab:PRDetailTab,_ ctx:Context) async throws -> PRDetailStamped<PRSectionRecord>? {
        let head=pr.headRevision.rawValue,key=PRDetailMemoryCache.Key(pr:pr.key,head:head)
        if let value=memory.entry(key,epoch:ctx.epoch)?.sections[tab.rawValue] { return value }
        guard let index=try await index(pr,ctx),index.head == head,let ref=index.sections[tab.rawValue],
              let value=try await payload(PRSectionRecord.self,pr,ctx,kind:"section-"+tab.rawValue.lowercased(),ref:ref) else { return nil }
        memory.update(key,epoch:ctx.epoch) { $0.sections[tab.rawValue]=value }
        return value
    }
    private func payloadKey(_ pr:PullRequest,kind:String,hash:String) -> PayloadKey {
        .init(object:.init(host:pr.key.host,accountID:pr.key.accountID,repositoryID:pr.key.repositoryID,objectID:"detail-v2:"+kind+":"+pr.key.objectID+":"+hash),revision:pr.headRevision,kind:kind == "diff" ? .diff : .log)
    }
    private static func hash(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private func payload<T:Codable & Sendable>(_ type:T.Type,_ pr:PullRequest,_ ctx:Context,kind:String,ref:PRDetailCacheIndex.Ref) async throws -> PRDetailStamped<T>? {
        guard let data=try await session.detailPayload(nil,key:payloadKey(pr,kind:kind,hash:ref.hash),pr:pr.key,headSHA:pr.headRevision.rawValue,operation:ctx.ticket),Self.hash(data) == ref.hash else { return nil }
        memory.recordDecode()
        return .init(value:try JSONDecoder().decode(T.self,from:data),fetchedAt:ref.fetchedAt,hash:ref.hash,bytes:data.count)
    }
    /// The payload's manifest entry exists (purge and eviction remove it); nothing is read or decoded.
    func payloadExists(_ pr:PullRequest,_ ctx:Context,kind:String,ref:PRDetailCacheIndex.Ref) async throws -> Bool {
        let id=try CacheStore.payloadID(payloadKey(pr,kind:kind,hash:ref.hash)),box=PRDetailBox<Bool>()
        guard try await session.withCurrentOperation(ctx.ticket,body:{ db in box.set(try db.hasPayload(id:id)) }) else { throw CancellationError() }
        return box.value == true
    }
    private func put<T:Codable & Sendable>(_ value:T,_ pr:PullRequest,_ ctx:Context,kind:String,at date:Date) async throws -> PRDetailStamped<T> {
        let encoder=JSONEncoder.stable;encoder.outputFormatting = [.sortedKeys]
        let data=try encoder.encode(value),hash=Self.hash(data)
        try await session.detailPayload(data,key:payloadKey(pr,kind:kind,hash:hash),pr:pr.key,headSHA:pr.headRevision.rawValue,operation:ctx.ticket)
        return .init(value:value,fetchedAt:date,hash:hash,bytes:data.count)
    }
    /// Persists changed content, then stamps the index (unchanged content only advances `fetchedAt`).
    private func store(_ pr:PullRequest,_ ctx:Context,diff:PRDiffRecord?,pull:PRPullRecord?,at date:Date) async throws {
        let key=PRDetailMemoryCache.Key(pr:pr.key,head:pr.headRevision.rawValue)
        let storedDiff=try await diff.asyncMap { try await put($0,pr,ctx,kind:"diff",at:date) }
        let storedPull=try await pull.asyncMap { try await put($0,pr,ctx,kind:"pull",at:date) }
        try await updateIndex(pr,ctx) { index in
            if let storedDiff { index.diff = .init(hash:storedDiff.hash,fetchedAt:date) } else { index.diff?.fetchedAt=date }
            if let storedPull { index.pull = .init(hash:storedPull.hash,fetchedAt:date) } else { index.pull?.fetchedAt=date }
        }
        memory.update(key,epoch:ctx.epoch) { entry in
            if let storedDiff { entry.diff=storedDiff } else if let old=entry.diff { entry.diff = .init(value:old.value,fetchedAt:date,hash:old.hash,bytes:old.bytes) }
            if let storedPull { entry.pull=storedPull } else if let old=entry.pull { entry.pull = .init(value:old.value,fetchedAt:date,hash:old.hash,bytes:old.bytes) }
        }
    }
    private func storeSection(_ pr:PullRequest,tab:PRDetailTab,_ ctx:Context,record:PRSectionRecord,prior:PRDetailStamped<PRSectionRecord>?,at date:Date) async throws {
        let encoder=JSONEncoder.stable;encoder.outputFormatting = [.sortedKeys]
        let kind="section-"+tab.rawValue.lowercased()
        let stored:PRDetailStamped<PRSectionRecord>
        if let prior,Self.hash(try encoder.encode(record)) == prior.hash { stored = .init(value:prior.value,fetchedAt:date,hash:prior.hash,bytes:prior.bytes) }
        else { stored=try await put(record,pr,ctx,kind:kind,at:date) }
        try await updateIndex(pr,ctx) { $0.sections[tab.rawValue] = .init(hash:stored.hash,fetchedAt:date) }
        memory.update(.init(pr:pr.key,head:pr.headRevision.rawValue),epoch:ctx.epoch) { $0.sections[tab.rawValue]=stored }
    }
    /// Permanent memo per (base, head) SHA pair: memory, then the persisted index, then the provider.
    private func mergeBase(_ pr:PullRequest,_ ctx:Context,base:String) async throws -> String {
        let head=pr.headRevision.rawValue,repository=pr.key.repository
        if let value=memory.mergeBase(repository,base:base,head:head) { return value }
        if let value=try await index(pr,ctx)?.mergeBases.first(where:{ $0.base == base && $0.head == head })?.mergeBase {
            memory.rememberMergeBase(repository,base:base,head:head,mergeBase:value);return value
        }
        let value=try await ctx.fetcher.mergeBase(repository:ctx.metadata.repositoryName,base:base,head:head,token:ctx.token)
        memory.rememberMergeBase(repository,base:base,head:head,mergeBase:value)
        try await updateIndex(pr,ctx) { index in
            index.mergeBases.removeAll { $0.base == base && $0.head == head }
            index.mergeBases=Array((index.mergeBases+[.init(base:base,head:head,mergeBase:value)]).suffix(16))
        }
        return value
    }
    func index(_ pr:PullRequest,_ ctx:Context) async throws -> PRDetailCacheIndex? {
        let box=PRDetailBox<PRDetailCacheIndex>()
        guard try await session.withCurrentOperation(ctx.ticket,body:{ db in
            if let snapshot=try PollCycleStore(database:db).snapshot(pr.key,feature:Self.cacheFeature) {
                do { box.set(try JSONDecoder().decode(PRDetailCacheIndex.self,from:snapshot.payload)) }
                catch { Log.storage.info("PR detail cache index did not decode; treating it as absent: \(Log.kind(error), privacy: .public)") }
            }
        }) else { throw CancellationError() }
        return box.value
    }
    /// Read-modify-write in one SQLite transaction under the account lock, only while the PR is
    /// current at this head. A different head resets content refs but keeps the merge-base memo.
    private func updateIndex(_ pr:PullRequest,_ ctx:Context,_ change:@escaping @Sendable (inout PRDetailCacheIndex) -> Void) async throws {
        let key=pr.key,head=pr.headRevision.rawValue,feature=Self.cacheFeature
        guard try await session.withCurrentOperation(ctx.ticket,body:{ db in
            try db.database.write { sql in
                guard let json=try Data.fetchOne(sql,sql:"SELECT json FROM pullRequests WHERE host=? AND accountID=? AND repositoryID=? AND objectID=?",arguments:[key.host,key.accountID,key.repositoryID,key.objectID]),
                      try JSONDecoder().decode(PullRequest.self,from:json).headRevision.rawValue == head else { throw CancellationError() }
                let existing=try Data.fetchOne(sql,sql:"SELECT json FROM pollFeatureSnapshots WHERE host=? AND accountID=? AND repositoryID=? AND objectID=? AND feature=?",arguments:[key.host,key.accountID,key.repositoryID,key.objectID,feature])
                    .flatMap { try? JSONDecoder().decode(PollFeatureSnapshot.self,from:$0) }.flatMap { try? JSONDecoder().decode(PRDetailCacheIndex.self,from:$0.payload) }
                var index=existing ?? PRDetailCacheIndex(head:head)
                if index.head != head { index=PRDetailCacheIndex(head:head,mergeBases:index.mergeBases) }
                change(&index)
                let snapshot=PollFeatureSnapshot(key:key,feature:feature,payload:try JSONEncoder.stable.encode(index))
                try sql.execute(sql:"INSERT INTO pollFeatureSnapshots VALUES (?,?,?,?,?,?) ON CONFLICT(host,accountID,repositoryID,objectID,feature) DO UPDATE SET json=excluded.json",arguments:[key.host,key.accountID,key.repositoryID,key.objectID,feature,try JSONEncoder.stable.encode(snapshot)])
            }
        }) else { throw CancellationError() }
    }
    /// Risk/classification enrichment. Skipped for revalidated (unchanged) inventories that were
    /// already enriched for this head, and never rewrites an unchanged row.
    private func enrich(_ result:PRDetailSnapshot,pr:PullRequest,ctx:Context,force:Bool) async throws {
        let fence=ctx.fence
        guard try await session.withCurrentOperation(ctx.ticket,body:{ db in
            guard try db.observationFence(for:pr.key) == fence else { throw CancellationError() }
            guard let current=try Self.current(pr.key,in:db),current.headRevision == pr.headRevision else { throw CancellationError() }
            if !force,current.metadata?.riskFlags != nil,current.metadata?.authorClassification != nil { return }
            let baseline=RepositorySizeBaseline.calculate(try db.pullRequests(repository:current.key.repository,states:[.merged]),for:current)
            let risks=Array(Set(RiskRules.evaluate(files:result.files,viewed:[],usualSize:baseline.usualSize).filter { $0.kind != .unviewed }.map { $0.kind.rawValue })).sorted()
            var metadata=current.metadata
            let mergedRisks=result.document.missingFileCount == 0 ? risks : Array(Set((metadata?.riskFlags ?? [])+risks)).sorted()
            metadata?.riskFlags=mergedRisks
            let classification=AgentClassifier.classify(login:metadata?.authorLogin,actorType:metadata?.actorType,branch:metadata?.headBranch ?? "",labels:metadata?.labels ?? []).rawValue
            metadata?.authorClassification=classification
            guard metadata != current.metadata else { return }
            guard try db.saveObservedPullRequests([PullRequest(key:current.key,headRevision:current.headRevision,title:current.title,state:current.state,isDraft:current.isDraft,metadata:metadata)],fences:[pr.key:fence]) else { throw CancellationError() }
        }) else { throw CancellationError() }
    }

    // MARK: Immutable reads

    public func blob(_ pr:PullRequest,path:String,sha:String) async throws -> Data {
        guard GitHubPRDetailFetcher.immutableOID(sha) else { throw PRDetailFailure.invalidPath }
        return try await read(pr) { ctx in
            let object=ProviderKey(host:pr.key.host,accountID:pr.key.accountID,repositoryID:pr.key.repositoryID,objectID:"detail-blob:"+path)
            let key=PayloadKey(object:object,revision:RevisionID(sha),kind:.blob)
            if let cached=try await session.detailPayload(nil,key:key,pr:pr.key,headSHA:pr.headRevision.rawValue,operation:ctx.ticket) { return cached }
            let data=try await ctx.fetcher.blob(repository:ctx.metadata.repositoryName,path:path,sha:sha,token:ctx.token)
            try await session.detailPayload(data,key:key,pr:pr.key,headSHA:pr.headRevision.rawValue,operation:ctx.ticket)
            return data
        }
    }
    public func snapshotInterdiff(_ pr:PullRequest,old:String,new:String) async throws -> DiffDocument {
        try await read(pr) { ctx in try await ctx.fetcher.snapshotInterdiff(repository:ctx.metadata.repositoryName,old:old,new:new,token:ctx.token) }
    }
    public func snapshotFile(_ pr:PullRequest,document:DiffDocument,file:DiffFile) async throws -> DiffFile {
        guard document.comparison == .snapshot,document.files.contains(file),GitHubPRDetailFetcher.immutableOID(document.baseSHA),GitHubPRDetailFetcher.immutableOID(document.headSHA) else { throw PRDetailFailure.unavailable }
        return try await read(pr) { _ in
            let before=try await file.status == .added ? nil : blob(pr,path:file.previousPath ?? file.path,sha:document.baseSHA)
            let after=try await file.status == .removed ? nil : blob(pr,path:file.path,sha:document.headSHA)
            guard before == nil || String(data:before!,encoding:.utf8) != nil,after == nil || String(data:after!,encoding:.utf8) != nil else { throw PRDetailFailure.unavailable }
            return try await SnapshotDiffWorker.shared.diff(file:file,before:before.flatMap { String(data:$0,encoding:.utf8) },after:after.flatMap { String(data:$0,encoding:.utf8) })
        }
    }
    public func compare(_ pr:PullRequest,base:String,head:String) async throws -> DiffDocument {
        try await read(pr) { ctx in try await ctx.fetcher.compare(repository:ctx.metadata.repositoryName,base:base,head:head,token:ctx.token) }
    }
}

/// Small per-PR pointer row: content hashes with provider-confirmation stamps, plus the merge-base memo.
/// Contains no private provider content; content stays in purgeable CacheStore payloads.
struct PRDetailCacheIndex:Codable,Sendable {
    struct Ref:Codable,Sendable { var hash:String;var fetchedAt:Date }
    struct MergeBase:Codable,Sendable { let base:String;let head:String;let mergeBase:String }
    var head:String
    var diff:Ref?
    var pull:Ref?
    var sections:[String:Ref]=[:]
    var mergeBases:[MergeBase]=[]
    init(head:String,mergeBases:[MergeBase] = []) { self.head=head;self.mergeBases=mergeBases }
}
final class PRDetailBox<T:Sendable>:Sendable {
    private let stored=Mutex<T?>(nil)
    func set(_ value:T) { stored.withLock { $0=value } }
    var value:T? { stored.withLock { $0 } }
}
fileprivate extension Optional {
    func asyncMap<U>(_ transform:(Wrapped) async throws -> U) async rethrows -> U? {
        switch self { case .some(let value): return try await transform(value);case .none: return nil }
    }
}
