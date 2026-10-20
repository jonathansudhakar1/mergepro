import XCTest
import GRDB
@testable import MergeProCore

/// Scriptable transport: responses can be appended between phases while one session (and its
/// credential epoch) stays alive, which the memory-cache tests depend on.
actor DetailCacheTransport:GitHubTransport {
    private var queue:[GitHubResponse]=[]
    private var requests:[URLRequest]=[]
    private var movingBase:(before:String,after:String)?
    private var filesRead=false
    func moveBaseAfterFiles(from before:String,to after:String) { movingBase=(before,after) }
    func enqueue(_ values:[GitHubResponse]) { queue += values }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        requests.append(request)
        if let movingBase {
            let path=request.url!.path
            if path.hasSuffix("/files") {
                filesRead=true
                return .init(status:200,data:Data(#"[{"filename":"old-base.swift","status":"modified","patch":"@@ -1 +1 @@\n-old\n+new","additions":1,"deletions":1}]"#.utf8))
            }
            if path.contains("/compare/") { return .init(status:200,data:Data(#"{"merge_base_commit":{"sha":"new-origin"}}"#.utf8)) }
            let base=filesRead ? movingBase.after : movingBase.before
            return .init(status:200,data:Data(#"{"body":"Description","head":{"sha":"head"},"base":{"sha":"\#(base)"},"changed_files":1}"#.utf8))
        }
        guard !queue.isEmpty else { throw GitHubFailure.invalidResponse }
        return queue.removeFirst()
    }
    func captured() -> [URLRequest] { requests }
    func clear() { requests=[] }
    func remaining() -> Int { queue.count }
}

@MainActor final class PRDetailCacheTests:XCTestCase {
    let account=AccountScope(host:"github.com",accountID:"a")
    struct Env { let directory:URL;let db:DatabaseStore;let cache:CacheStore;let session:GitHubAccountSession;let transport:DetailCacheTransport;let budget:RateBudget }
    func pr(_ object:String = "p",number:Int = 1,head:String = "head",base:String = "base") -> PullRequest {
        var metadata=PRMetadata(number:number,webURL:URL(string:"https://github.com/o/r/pull/\(number)")!,repositoryName:"o/r")
        metadata.baseRevision=base
        return PullRequest(key:.init(host:"github.com",accountID:"a",repositoryID:"1",objectID:object),headRevision:.init(head),title:"PR \(number)",state:.open,isDraft:false,metadata:metadata)
    }
    func env(_ prs:[PullRequest],reserve:Int = 0) throws -> Env {
        let transport=DetailCacheTransport()
        let fixture=try makeSessionFixture(account:account,login:"a",tokenReference:"fixture",repositories:[.fixture(.init(account:account,repositoryID:"1"))],transport:transport,credential:.init(accessToken:"fixture"),active:false)
        try fixture.database.savePullRequests(prs)
        let budget=RateBudget(minimumSpacing:.zero,interactiveReserve:reserve)
        return Env(directory:fixture.directory,db:fixture.database,cache:fixture.cache,session:fixture.session,transport:transport,budget:budget)
    }
    func service(_ e:Env,_ memory:PRDetailMemoryCache) -> PRDetailService { PRDetailService(session:e.session,budget:e.budget,clientID:"",memory:memory) }
    func pull(head:String = "head",base:String = "base",files:Int = 1,etag:String? = "\"p1\"",rate:Int? = nil) -> GitHubResponse {
        json(#"{"body":"Description","head":{"sha":"\#(head)"},"base":{"sha":"\#(base)"},"changed_files":\#(files)}"#,headers:headers(etag,rate))
    }
    func filesPage(_ names:[String],binary:Set<String> = [],etag:String? = "\"f1\"",rate:Int? = nil) -> GitHubResponse {
        let items=names.map { name in binary.contains(name) ? #"{"filename":"\#(name)","status":"modified","additions":0,"deletions":0}"# : #"{"filename":"\#(name)","status":"modified","patch":"@@ -1 +1 @@\n-a\n+b","additions":1,"deletions":1}"# }
        return json("["+items.joined(separator:",")+"]",headers:headers(etag,rate))
    }
    func compare(_ sha:String = "merge-base",rate:Int? = nil) -> GitHubResponse { json(#"{"merge_base_commit":{"sha":"\#(sha)"}}"#,headers:headers(nil,rate)) }
    func headers(_ etag:String?,_ rate:Int?) -> [String:String] {
        var value:[String:String]=[:]
        if let etag { value["ETag"]=etag }
        if let rate { value["X-RateLimit-Remaining"]=String(rate);value["X-RateLimit-Reset"]=String(Int(Date().timeIntervalSince1970)+3600) }
        return value
    }
    let notModified=GitHubResponse(status:304)
    func paths(_ requests:[URLRequest]) -> [String] { requests.compactMap { $0.url?.path } }
    func names(_ count:Int,prefix:String = "f") -> [String] { (0..<count).map { "\(prefix)\(String(format:"%03d",$0)).swift" } }
}

extension PRDetailCacheTests {
    func testDescriptionDoesNotWaitForFilesOrCompare() async throws {
        let p=pr(),e=try env([p]),memory=PRDetailMemoryCache(),s=service(e,memory)
        await e.transport.enqueue([pull(),filesPage(["a.swift"]),notModified,compare()])
        let value=try await s.description(p)
        XCTAssertEqual(value.body,"Description")
        XCTAssertEqual(value.headSHA,"head")
        let requests=await e.transport.captured()
        XCTAssertEqual(paths(requests),["/repos/o/r/pulls/1"],"Overview needs only the description, not patches or a merge base")
        let diff=try await s.cachedDetail(p)
        XCTAssertNil(diff,"a description must not masquerade as a validated diff")
    }
    func testDescriptionOnlyCacheSurvivesReopenAndConditionalRefresh() async throws {
        let p=pr(),e=try env([p]),memory=PRDetailMemoryCache(),s=service(e,memory)
        await e.transport.enqueue([pull()])
        _ = try await s.description(p)
        await e.transport.clear()
        let reopened=service(e,PRDetailMemoryCache())
        let cached=try await reopened.cachedDescription(p)
        XCTAssertEqual(cached?.body,"Description");XCTAssertTrue(cached?.cached == true)
        let recent=try await reopened.description(p,maxAge:30)
        XCTAssertTrue(recent.cached)
        let offline=await e.transport.captured();XCTAssertTrue(offline.isEmpty)
        await e.transport.enqueue([notModified])
        let fresh=try await reopened.description(p,maxAge:0)
        XCTAssertFalse(fresh.cached);XCTAssertEqual(fresh.body,"Description")
        let requests=await e.transport.captured()
        XCTAssertEqual(requests.count,1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField:"If-None-Match"),"\"p1\"")
        let diff=try await reopened.cachedDetail(p);XCTAssertNil(diff)
    }
    func testDescriptionRefreshDoesNotRenewDiffValidationAge() async throws {
        let p=pr(),e=try env([p]),memory=PRDetailMemoryCache(),s=service(e,memory)
        await e.transport.enqueue([pull(),filesPage(["a.swift"]),notModified,compare()])
        _ = try await s.detail(p)
        let before=try await s.cachedDetail(p)
        await e.transport.enqueue([notModified])
        _ = try await s.description(p,maxAge:0)
        let after=try await s.cachedDetail(p)
        XCTAssertEqual(after?.fetchedAt,before?.fetchedAt,"Reading the description never confirms the mutable file inventory")
        XCTAssertGreaterThan(try XCTUnwrap(after?.bodyFetchedAt),try XCTUnwrap(before?.bodyFetchedAt))
    }
    func testDescriptionRejectsChangedHeadWithoutCachingIt() async throws {
        let p=pr(),e=try env([p]),s=service(e,PRDetailMemoryCache())
        await e.transport.enqueue([pull(head:"new-head")])
        do { _ = try await s.description(p);XCTFail("another head's description accepted") }
        catch { XCTAssertEqual(error as? PRDetailFailure,.revisionChanged) }
        let cached=try await s.cachedDescription(p);XCTAssertNil(cached)
    }
    func testColdDiffRejectsBaseMovementWhileMutableFilesAreRead() async throws {
        let p=pr(base:"old-base"),e=try env([p]),memory=PRDetailMemoryCache(),s=service(e,memory)
        await e.transport.moveBaseAfterFiles(from:"old-base",to:"new-base")
        do { _ = try await s.detail(p);XCTFail("old-base patches accepted under the new base") }
        catch { XCTAssertEqual(error as? PRDetailFailure,.revisionChanged) }
        let cached=try await s.cachedDetail(p)
        XCTAssertNil(cached,"a rejected revision must not populate the detail cache")
    }
    func testWarmReopenFromMemoryMakesNoRequestsAndNoDecodes() async throws {
        let p=pr(),e=try env([p]),memory=PRDetailMemoryCache()
        await e.transport.enqueue([pull(),filesPage(["a.swift"]),notModified,compare()])
        let first=try await service(e,memory).detail(p)
        XCTAssertFalse(first.cached);XCTAssertEqual(first.body,"Description");XCTAssertNotNil(first.fetchedAt);XCTAssertNotNil(first.bodyFetchedAt)
        let cold=await e.transport.captured()
        XCTAssertEqual(paths(cold),["/repos/o/r/pulls/1","/repos/o/r/pulls/1/files","/repos/o/r/pulls/1","/repos/o/r/compare/base...head"],"cold loads bracket mutable files with fresh PR identity reads")
        memory.resetStatistics();await e.transport.clear()
        let reopened=try await service(e,memory).cachedDetail(p)
        XCTAssertEqual(reopened?.files.map(\.path),["a.swift"]);XCTAssertTrue(reopened?.cached == true)
        XCTAssertEqual(reopened?.body,"Description");XCTAssertNotNil(reopened?.bodyFetchedAt);XCTAssertEqual(reopened?.baseSHA,"merge-base")
        XCTAssertEqual(memory.statistics.persistedDecodes,0,"a memory hit decodes nothing")
        let none=await e.transport.captured();XCTAssertTrue(none.isEmpty)
    }
    func testWarmReopenFromDiskRevalidatesWithConditional304s() async throws {
        let p=pr(),e=try env([p])
        await e.transport.enqueue([pull(),filesPage(["a.swift"]),notModified,compare(),
            json(#"{"check_runs":[{"id":1,"name":"Build","status":"completed","conclusion":"success"}]}"#,headers:["ETag":"\"c1\""]),json("[]",headers:["ETag":"\"s1\""])])
        let first=service(e,PRDetailMemoryCache())
        _ = try await first.detail(p);_ = try await first.section(p,tab:.checks)
        let memory=PRDetailMemoryCache(),reopened=service(e,memory)
        await e.transport.clear()
        let cached=try await reopened.cachedDetail(p)
        XCTAssertEqual(cached?.files.map(\.path),["a.swift"]);XCTAssertTrue(cached?.cached == true);XCTAssertEqual(cached?.body,"Description")
        XCTAssertGreaterThan(memory.statistics.persistedDecodes,0)
        let checks=try await reopened.cachedSection(p,tab:.checks)
        XCTAssertTrue(checks?.cached == true);XCTAssertNotNil(checks?.fetchedAt);XCTAssertEqual(checks?.events.count,1)
        let offline=await e.transport.captured();XCTAssertTrue(offline.isEmpty,"cached reads never reach the provider")
        await e.transport.enqueue([notModified])
        let fresh=try await reopened.detail(p)
        XCTAssertFalse(fresh.cached);XCTAssertEqual(fresh.files.map(\.path),["a.swift"]);XCTAssertEqual(fresh.body,"Description");XCTAssertEqual(fresh.baseSHA,"merge-base")
        let revalidation=await e.transport.captured()
        XCTAssertEqual(revalidation.count,1,"warm inventory needs only one conditional PR read")
        XCTAssertEqual(revalidation.map { $0.value(forHTTPHeaderField:"If-None-Match") },["\"p1\""])
        await e.transport.clear();await e.transport.enqueue([notModified,notModified])
        let section=try await reopened.section(p,tab:.checks)
        XCTAssertFalse(section.cached);XCTAssertEqual(section.events.map(\.id),checks?.events.map(\.id))
        let conditional=await e.transport.captured()
        XCTAssertEqual(conditional.map { $0.value(forHTTPHeaderField:"If-None-Match") },["\"c1\"","\"s1\""])
    }
    func testPartialDiffIsCachedWithPerFileStateAndLabeled() async throws {
        let p=pr(),e=try env([p])
        let first=names(100),second=names(50,prefix:"g")
        await e.transport.enqueue([pull(files:150),filesPage(first,binary:[first[0]]),notModified,compare()])
        let loaded=try await service(e,PRDetailMemoryCache()).detail(p)
        XCTAssertTrue(loaded.isPartial);XCTAssertEqual(loaded.nextPage,2)
        let memory=PRDetailMemoryCache(),reopened=service(e,memory)
        let maybe=try await reopened.cachedDetail(p);let cached=try XCTUnwrap(maybe)
        XCTAssertTrue(cached.cached);XCTAssertTrue(cached.isPartial);XCTAssertEqual(cached.document.missingFileCount,50);XCTAssertEqual(cached.nextPage,2)
        XCTAssertEqual(cached.files[0].patchState,.unavailable);XCTAssertEqual(cached.unavailablePatchCount,1);XCTAssertNotNil(cached.fetchedAt)
        await e.transport.clear();await e.transport.enqueue([filesPage(second,etag:"\"f2\""),notModified])
        let more=try await reopened.more(p,snapshot:cached)
        XCTAssertEqual(more.files.count,150);XCTAssertFalse(more.isPartial);XCTAssertNil(more.nextPage)
        let requests=await e.transport.captured()
        XCTAssertEqual(paths(requests),["/repos/o/r/pulls/1/files","/repos/o/r/pulls/1"],"continuation reuses the merge-base memo")
        let grown=try await service(e,PRDetailMemoryCache()).cachedDetail(p)
        XCTAssertEqual(grown?.files.count,150);XCTAssertEqual(grown?.isPartial,false)
    }
    func testHeadMismatchIsNeverServedAsCurrent() async throws {
        let p=pr(),e=try env([p]),memory=PRDetailMemoryCache(),s=service(e,memory)
        await e.transport.enqueue([pull(),filesPage(["a.swift"]),notModified,compare()])
        _ = try await s.detail(p)
        // Provider moved during revalidation: never serve the cached head as current.
        await e.transport.enqueue([pull(head:"other",etag:"\"p2\"")])
        do { _ = try await s.detail(p);XCTFail("moved provider head accepted") } catch { XCTAssertEqual(error as? PRDetailFailure,.revisionChanged) }
        // Inventory moved: the new head has nothing cached, the old head is no longer current.
        let moved=pr(head:"new");try e.db.savePullRequests([moved])
        for cache in [memory,PRDetailMemoryCache()] {
            let none=try await service(e,cache).cachedDetail(moved);XCTAssertNil(none)
            let noSection=try await service(e,cache).cachedSection(moved,tab:.checks);XCTAssertNil(noSection)
            do { _ = try await service(e,cache).cachedDetail(p);XCTFail("stale head served") } catch {}
        }
    }
    func testMergeBaseMemoIsReusedAcrossBaseMovesAndReopen() async throws {
        let p=pr(),e=try env([p]),s=service(e,PRDetailMemoryCache())
        await e.transport.enqueue([pull(base:"b1"),filesPage(["a.swift"]),notModified,compare()])
        _ = try await s.detail(p)
        await e.transport.enqueue([pull(base:"b2",etag:"\"p2\""),compare()])
        let moved=try await s.detail(p)
        XCTAssertEqual(moved.baseBranchSHA,"b2");XCTAssertEqual(moved.baseSHA,"merge-base");XCTAssertEqual(moved.files.map(\.path),["a.swift"])
        await e.transport.enqueue([pull(base:"b1",etag:"\"p3\"")])
        _ = try await s.detail(p)
        await e.transport.enqueue([pull(base:"b2",etag:"\"p4\"")])
        let reopened=try await service(e,PRDetailMemoryCache()).detail(p)
        XCTAssertEqual(reopened.baseBranchSHA,"b2")
        let requests=await e.transport.captured()
        XCTAssertEqual(paths(requests).filter { $0.contains("/compare/") },["/repos/o/r/compare/b1...head","/repos/o/r/compare/b2...head"])
        XCTAssertEqual(paths(requests).filter { $0.hasSuffix("/files") }.count,1,"unchanged merge base reuses the head-keyed inventory")
        let remaining=await e.transport.remaining();XCTAssertEqual(remaining,0)
    }
    func testViewedStatesAreOneQueryAndCachedPerHead() async throws {
        let p=pr(),e=try env([p]),s=service(e,PRDetailMemoryCache())
        await e.transport.enqueue([json(#"{"data":{"repository":{"pullRequest":{"headRefOid":"head","files":{"nodes":[{"path":"a.swift","viewerViewedState":"VIEWED"},{"path":"b.swift","viewerViewedState":"DISMISSED"}],"pageInfo":{"hasNextPage":false,"endCursor":"c"}}}}}}"#)])
        let value=try await s.viewedStates(p,revision:"head")
        XCTAssertEqual(value.viewed,["a.swift":true,"b.swift":false]);XCTAssertTrue(value.complete);XCTAssertEqual(value.headSHA,"head")
        var requests=await e.transport.captured()
        XCTAssertEqual(requests.count,1);XCTAssertEqual(requests.first?.httpMethod,"POST");XCTAssertEqual(requests.first?.url?.path,"/graphql")
        let again=try await s.viewedStates(p,revision:"head");XCTAssertEqual(again,value)
        s.recordViewedState(p,revision:"head",path:"b.swift",viewed:true)
        let recorded=try await s.viewedStates(p,revision:"head");XCTAssertEqual(recorded.isViewed("b.swift"),true)
        requests=await e.transport.captured();XCTAssertEqual(requests.count,1,"switching files makes no requests")
        do { _ = try await s.viewedStates(p,revision:"other");XCTFail() } catch { XCTAssertEqual(error as? PRDetailFailure,.revisionChanged) }
        s.invalidateViewedStates(p)
        await e.transport.enqueue([json(#"{"data":{"repository":{"pullRequest":{"headRefOid":"moved","files":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}"#)])
        do { _ = try await s.viewedStates(p,revision:"head");XCTFail() } catch { XCTAssertEqual(error as? PRDetailFailure,.revisionChanged) }
        requests=await e.transport.captured();XCTAssertEqual(requests.count,2)
    }
    func testPrefetchSkipsCachedPRsAndStopsAtInteractiveReserve() async throws {
        let p1=pr("p1",number:1,head:"h1"),p2=pr("p2",number:2,head:"h2"),p3=pr("p3",number:3,head:"h3"),p4=pr("p4",number:4,head:"h4"),stale=pr("p4",number:4,head:"old")
        let e=try env([p1,p2,p3,p4],reserve:10),memory=PRDetailMemoryCache(),s=service(e,memory)
        await e.transport.enqueue([pull(head:"h1"),filesPage(["a.swift"]),notModified,compare()])
        _ = try await s.detail(p1)
        await e.transport.clear()
        await e.transport.enqueue([pull(head:"h2",rate:13),filesPage(["b.swift"],rate:12),pull(head:"h2",rate:11),compare(rate:10)])
        let result=await s.prefetchDetails([p1,stale,p2,p3],limit:5,sections:[])
        XCTAssertEqual(result.skipped,[p1.key]);XCTAssertEqual(result.fetched,[p2.key]);XCTAssertEqual(result.stop,.reserve)
        XCTAssertEqual(result.failed,[stale.key],"a stale candidate fails alone; the pass continues")
        let requests=await e.transport.captured()
        XCTAssertEqual(paths(requests),["/repos/o/r/pulls/2","/repos/o/r/pulls/2/files","/repos/o/r/pulls/2","/repos/o/r/compare/base...h2"],"PR 3 never touched the reserve")
        let prefetched=try await s.cachedDetail(p2);XCTAssertEqual(prefetched?.files.map(\.path),["b.swift"])
        // Warm is network-free and makes the next open a pure memory hit.
        let fresh=PRDetailMemoryCache(),warmed=service(e,fresh)
        let loaded=await warmed.warm(p2);XCTAssertTrue(loaded);XCTAssertTrue(fresh.containsDetail(p2))
        fresh.resetStatistics()
        _ = try await warmed.cachedDetail(p2);XCTAssertEqual(fresh.statistics.persistedDecodes,0)
        let after=await e.transport.captured();XCTAssertEqual(after.count,4)
        let limited=await s.prefetchDetails([p3],limit:0);XCTAssertEqual(limited.stop,.limit);XCTAssertTrue(limited.fetched.isEmpty)
    }
    func testPrefetchRefetchesPayloadsPurgedByCredentialInvalidationAndKeepsOnlyTheMergeBaseMemo() async throws {
        let p=pr(),e=try env([p])
        await e.transport.enqueue([pull(),filesPage(["a.swift"]),notModified,compare(),json(#"{"check_runs":[]}"#,headers:["ETag":"\"c1\""]),json("[]")])
        let first=service(e,PRDetailMemoryCache())
        _ = try await first.detail(p);_ = try await first.section(p,tab:.checks)
        // Token refresh / reauthorization purges private payloads.
        try await e.cache.invalidatePrivatePayloads(for:account)
        let stored=try XCTUnwrap(PollCycleStore(database:e.db).snapshot(p.key,feature:PRDetailService.cacheFeature))
        let index=try JSONDecoder().decode(PRDetailCacheIndex.self,from:stored.payload)
        XCTAssertNil(index.diff);XCTAssertNil(index.pull);XCTAssertTrue(index.sections.isEmpty,"no content reference survives the purge")
        XCTAssertEqual(index.mergeBases.map(\.mergeBase),["merge-base"],"the merge-base memo holds no private content")
        // A new credential epoch has an empty memory cache: the purged payload is not cached.
        await e.transport.clear();await e.transport.enqueue([pull(),filesPage(["a.swift"]),notModified])
        let s=service(e,PRDetailMemoryCache())
        let result=await s.prefetchDetails([p],limit:5,sections:[])
        XCTAssertEqual(result.fetched,[p.key]);XCTAssertTrue(result.skipped.isEmpty)
        let requests=await e.transport.captured()
        XCTAssertEqual(paths(requests),["/repos/o/r/pulls/1","/repos/o/r/pulls/1/files","/repos/o/r/pulls/1"],"the memo spares the merge-base read")
        let skipped=await service(e,PRDetailMemoryCache()).prefetchDetails([p],limit:5,sections:[])
        XCTAssertEqual(skipped.skipped,[p.key])
    }
    func testPrefetchRefetchesAnEvictedPayloadAndCachesItAgain() async throws {
        let p=pr(),e=try env([p])
        await e.transport.enqueue([pull(),filesPage(["a.swift"]),notModified,compare()])
        _ = try await service(e,PRDetailMemoryCache()).detail(p)
        // LRU eviction removes manifest entries while the index row still names their hashes.
        try e.db.forgetPayloads(account:account)
        await e.transport.clear();await e.transport.enqueue([pull(),filesPage(["a.swift"]),notModified])
        let result=await service(e,PRDetailMemoryCache()).prefetchDetails([p],limit:5,sections:[])
        XCTAssertEqual(result.fetched,[p.key]);XCTAssertTrue(result.skipped.isEmpty)
        let cached=try await service(e,PRDetailMemoryCache()).cachedDetail(p)
        XCTAssertEqual(cached?.files.map(\.path),["a.swift"],"the re-fetched payload is persisted again")
    }
    func testAccountRemovalPurgesMemoryAndPersistedCaches() async throws {
        let p=pr(),e=try env([p]),memory=PRDetailMemoryCache(),s=service(e,memory)
        await e.transport.enqueue([pull(),filesPage(["a.swift"]),notModified,compare(),json(#"{"check_runs":[]}"#,headers:["ETag":"\"c1\""]),json("[]")])
        _ = try await s.detail(p);_ = try await s.section(p,tab:.checks)
        XCTAssertEqual(memory.count(account:account),1)
        XCTAssertNotNil(try PollCycleStore(database:e.db).snapshot(p.key,feature:PRDetailService.cacheFeature))
        let usage=try await e.cache.diskUsage();XCTAssertGreaterThan(usage,0)
        try await e.session.remove(account)
        XCTAssertNil(try PollCycleStore(database:e.db).snapshot(p.key,feature:PRDetailService.cacheFeature))
        let purged=try await e.cache.diskUsage();XCTAssertEqual(purged,0)
        s.purgeCaches(account:account)
        XCTAssertEqual(memory.count(account:account),0);XCTAssertEqual(memory.byteCount,0)
    }
    func testLocalReadingProgressPurgesOnlyTheRemovedAccount() throws {
        let p=pr(),e=try env([p]),store=PRDetailStore(database:e.db)
        let other=ProviderKey(host:"github.com",accountID:"b",repositoryID:"1",objectID:"p")
        var state=PRDetailState(headSHA:"head");state.markViewed("a.swift",viewed:true)
        try store.save(state,key:p.key);try store.save(state,key:other)
        try store.purge(account:account)
        XCTAssertTrue(try store.load(p.key,headSHA:"head").viewed.isEmpty)
        XCTAssertEqual(try store.load(other,headSHA:"head").viewed,["a.swift"])
    }
    func testStaleCredentialEpochIsAMemoryMiss() async throws {
        let p=pr(),e=try env([p]),memory=PRDetailMemoryCache()
        await e.transport.enqueue([pull(),filesPage(["a.swift"]),notModified,compare()])
        _ = try await service(e,memory).detail(p)
        XCTAssertEqual(memory.count(account:account),1)
        // A new session owner is a new credential generation (as after reconnect/removal).
        let credentials=MemoryCredentials();credentials.save(.init(accessToken:"fixture"),account:account)
        let other=GitHubAccountSession(storage:.init(database:e.db,cache:e.cache,credentials:credentials),transport:e.transport)
        memory.resetStatistics()
        _ = try await PRDetailService(session:other,budget:e.budget,clientID:"",memory:memory).cachedDetail(p)
        XCTAssertEqual(memory.statistics.hits,0);XCTAssertGreaterThan(memory.statistics.persistedDecodes,0)
    }
    func testMemoryCacheIsBoundedByEntriesAndBytes() {
        let memory=PRDetailMemoryCache(maximumEntries:2,maximumBytes:1_000)
        func record(_ bytes:Int) -> PRDetailStamped<PRPullRecord> { .init(value:.init(head:"h",base:"b",body:"",changedFiles:0,etag:nil,lastModified:nil),fetchedAt:Date(),hash:"x",bytes:bytes) }
        for object in ["1","2","3"] { memory.update(.init(pr:.init(host:"github.com",accountID:"a",repositoryID:"1",objectID:object),head:"h"),epoch:"e") { $0.pull=record(100) } }
        XCTAssertEqual(memory.count,2)
        memory.update(.init(pr:.init(host:"github.com",accountID:"a",repositoryID:"1",objectID:"4"),head:"h"),epoch:"e") { $0.pull=record(950) }
        XCTAssertLessThanOrEqual(memory.byteCount,1_000)
    }
}
