import XCTest
import GRDB
@testable import MergeProCore

@MainActor final class PRDetailProviderTests: XCTestCase {
    let key=ProviderKey(host:"github.com",accountID:"a",repositoryID:"1",objectID:"p")
    func testForcePushDuringFilePaginationRejectsMixedDiff() async throws {
        let transport=ScriptedTransport([json(#"{"body":"Description","head":{"sha":"head"},"base":{"sha":"base"},"changed_files":1}"#),json(#"[{"filename":"a.swift","status":"modified","patch":"@@ -1 +1 @@\n-a\n+b","additions":1,"deletions":1}]"#),json(#"{"body":"Description","head":{"sha":"changed"},"base":{"sha":"base"},"changed_files":1}"#)])
        let fetcher=GitHubPRDetailFetcher(client:GitHubHTTPClient(transport:transport))
        do { _ = try await fetcher.detail(repository:"o/r",number:1,headSHA:"head",token:"fixture");XCTFail("mixed revisions accepted") }
        catch { XCTAssertEqual(error as? PRDetailFailure,.revisionChanged) }
    }
    func testCappedFileListIsNotClaimedCompleteAndMissingPatchSurvives() async throws {
        let overview=json(#"{"body":"Description","head":{"sha":"head"},"base":{"sha":"base"},"changed_files":4001}"#)
        let transport=ScriptedTransport([overview,json(#"[{"filename":"a.png","status":"modified","additions":0,"deletions":0}]"#),overview,json(#"{"merge_base_commit":{"sha":"base"}}"#)])
        let result=try await GitHubPRDetailFetcher(client:GitHubHTTPClient(transport:transport)).detail(repository:"o/r",number:1,headSHA:"head",token:"fixture")
        XCTAssertEqual(result.document.missingFileCount,4000)
        XCTAssertEqual(result.files[0].patchState,.unavailable)
    }
    func testUnsafeRepositoryAndBlobPathsNeverReachTransport() async throws {
        let transport=ScriptedTransport([])
        let fetcher=GitHubPRDetailFetcher(client:GitHubHTTPClient(transport:transport))
        do { _ = try await fetcher.blob(repository:"o/r",path:"../secret",sha:"head",token:"fixture");XCTFail() } catch {}
        let requests=await transport.captured();XCTAssertTrue(requests.isEmpty)
    }
    func testDeniedOrChangedRevisionCannotReadOrCommitPrivatePayload() async throws {
        let fixture=try makeSessionFixture(account:key.account,login:"a",tokenReference:"fixture",repositories:[.fixture(key.repository)],transport:ScriptedTransport(),credential:.init(accessToken:"fixture"),active:false)
        let (db,cache,owner)=(fixture.database,fixture.cache,fixture.storage)
        try db.savePullRequests([PullRequest(key:key,headRevision:.init("h"),title:"private",state:.open,isDraft:false)])
        let op=try await owner.operation(for:key.account,now:Date())
        let payload=PayloadKey(object:key,revision:.init("h"),kind:.blob)
        try await owner.detailPayload(Data("private".utf8),key:payload,pr:key,headSHA:"h",operation:op)
        try db.savePullRequests([PullRequest(key:key,headRevision:.init("new"),title:"private",state:.open,isDraft:false)])
        do { _ = try await owner.detailPayload(nil,key:payload,pr:key,headSHA:"h",operation:op);XCTFail() } catch {}
        _ = try await owner.markInvalid(op)
        do { _ = try await owner.detailPayload(nil,key:payload,pr:key,headSHA:"new",operation:op);XCTFail() } catch {}
        let absent=try await cache.data(for:payload);XCTAssertNil(absent)
    }
}

private final class DetailPutGate: @unchecked Sendable {
    private let lock=NSLock()
    private var reached=false
    private var denied=false
    let release=DispatchSemaphore(value:0)
    private let arrival=DispatchSemaphore(value:0)
    var entered:Bool { lock.withLock { reached } }
    var denialObserved:Bool { lock.withLock { denied } }
    func hold() { lock.withLock { reached=true };arrival.signal();_ = release.wait(timeout:.now()+5) }
    /// Suspends (without blocking the cooperative pool) until the SQLite write reaches `hold()`, or `timeout` passes.
    func waitUntilEntered(timeout:DispatchTimeInterval) async {
        await withCheckedContinuation { (done:CheckedContinuation<Void,Never>) in
            DispatchQueue.global().async { [arrival] in _ = arrival.wait(timeout:.now()+timeout);done.resume() }
        }
    }
    func sawDenial() { lock.withLock { denied=true } }
}

extension PRDetailProviderTests {
    func testRevocationWaitsForHeldPayloadPutThenPurgesIt() async throws {
        let fixture=try makeSessionFixture(account:key.account,login:"a",tokenReference:"fixture",repositories:[.fixture(key.repository)],transport:ScriptedTransport(),credential:.init(accessToken:"fixture"),active:false)
        let (db,cache,owner)=(fixture.database,fixture.cache,fixture.storage)
        try db.savePullRequests([.init(key:key,headRevision:.init("h"),title:"private",state:.open,isDraft:false)])
        let operation=try await owner.operation(for:key.account,now:Date())
        let stream=try await owner.authorizationChanges()
        let gate=DetailPutGate()
        let observer=Task { for await change in stream { if case .authorizationRequired = change.state { gate.sawDenial();return } } }
        defer { observer.cancel();gate.release.signal() }
        try await db.database.write { database in database.add(function:DatabaseFunction("hold_detail_put",argumentCount:0,pure:false) { _ in gate.hold();return 0 }) }
        try await db.database.write { database in try database.execute(sql:"CREATE TRIGGER held_payload BEFORE INSERT ON cacheEntries BEGIN SELECT hold_detail_put(); END") }
        let payload=PayloadKey(object:key,revision:.init("h"),kind:.blob)
        let put=Task { try await owner.detailPayload(Data("private".utf8),key:payload,pr:key,headSHA:"h",operation:operation) }
        await gate.waitUntilEntered(timeout:.seconds(3))
        XCTAssertTrue(gate.entered,"CacheStore must reach its real SQLite commit while the account lock is held")
        let revoke=Task { try await owner.markInvalid(operation) }
        // Let the competing actor call reach its lock wait while the real cache write is held.
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertFalse(gate.denialObserved,"Account mutation lock must cover the CacheStore await")
        gate.release.signal()
        _ = try await put.value
        let revoked=try await revoke.value;XCTAssertTrue(revoked)
        let absent=try await cache.data(for:payload);XCTAssertNil(absent)
    }
}

extension PRDetailProviderTests {
    func testCheckAnnotationsAreBoundToExactRevisionAndPath() async throws {
        let transport=ScriptedTransport([json(#"{"check_runs":[{"id":9,"name":"Lint","status":"completed","conclusion":"failure","output":{"annotations_count":1}}]}"#),json(#"[{"path":"a.swift","start_line":3,"end_line":4,"message":"Fix warning","annotation_level":"warning"}]"#),json("[]")])
        let section=try await GitHubPRDetailFetcher(client:.init(transport:transport)).section(repository:"o/r",number:1,sha:"head",tab:.checks,token:"fixture")
        XCTAssertEqual(section.events.first?.anchor,.init(commitSHA:"head",path:"a.swift",side:"RIGHT",startLine:3,endLine:4))
        let requests=await transport.captured();XCTAssertEqual(requests[1].url?.path,"/repos/o/r/check-runs/9/annotations")
    }
    func testDeploymentUsesLatestReadOnlyStatusAndPreview() async throws {
        let transport=ScriptedTransport([json(#"[{"id":7,"environment":"preview"}]"#),json(#"[{"state":"success","environment_url":"https://preview.example.invalid","description":"Ready"}]"#)])
        let section=try await GitHubPRDetailFetcher(client:.init(transport:transport)).section(repository:"o/r",number:1,sha:"head",tab:.deployments,token:"fixture")
        XCTAssertEqual(section.events.first?.url,URL(string:"https://preview.example.invalid"))
        XCTAssertTrue(section.events.first?.title.contains("success") == true)
        let requests=await transport.captured();XCTAssertEqual(requests.count,2);XCTAssertEqual(requests.last?.httpMethod,"GET")
    }
}

extension PRDetailProviderTests {
    func testDetailRiskEnrichmentPreservesCurrentInventoryFields() async throws {
        let overview=json(#"{"body":"Description","head":{"sha":"head"},"base":{"sha":"base"},"changed_files":1}"#)
        let transport=ScriptedTransport([overview,json(#"[{"filename":".github/workflows/ci.yml","status":"modified","patch":"@@ -1 +1 @@\n-old\n+new","additions":1,"deletions":1}]"#),overview,json(#"{"merge_base_commit":{"sha":"base"}}"#)])
        let fixture=try makeSessionFixture(account:key.account,login:"a",tokenReference:"fixture",repositories:[.fixture(key.repository)],transport:transport,credential:.init(accessToken:"fixture"),active:false)
        let (db,session)=(fixture.database,fixture.session)
        var metadata=PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r")
        metadata.baseRevision="base";metadata.comments=99;metadata.authorLogin="copilot";metadata.actorType="Bot"
        let pr=PullRequest(key:key,headRevision:.init("head"),title:"Current title",state:.open,isDraft:false,metadata:metadata)
        try db.savePullRequests([pr])
        let service=PRDetailService(session:session,budget:RateBudget(minimumSpacing:.zero,interactiveReserve:0),clientID:"",memory:PRDetailMemoryCache())
        let absent=try await service.cachedDetail(pr);XCTAssertNil(absent)
        _ = try await service.detail(pr)
        let cached=try await service.cachedDetail(pr)
        XCTAssertEqual(cached?.files.first?.path,".github/workflows/ci.yml")
        XCTAssertEqual(cached?.baseBranchSHA,"base")
        // Descriptions are mutable: cached separately from the head-keyed inventory and labeled by age.
        XCTAssertEqual(cached?.body,"Description");XCTAssertNotNil(cached?.bodyFetchedAt);XCTAssertNotNil(cached?.fetchedAt)
        XCTAssertTrue(cached?.cached == true)
        let requests=await transport.captured();XCTAssertEqual(requests.count,4,"cold loads bracket mutable files; cache reads must not refetch provider data")
        let saved=try XCTUnwrap(db.snapshot(for:key.account).pullRequests.first)
        XCTAssertEqual(saved.metadata?.comments,99)
        XCTAssertEqual(saved.metadata?.authorClassification,"agent")
        XCTAssertTrue(saved.metadata?.riskFlags?.contains("sensitivePath") == true)
    }
}

extension PRDetailProviderTests {
    func testLeftSideUsesMergeBaseInsteadOfAdvancedBaseBranchTip() async throws {
        let overview=json(#"{"body":"Description","head":{"sha":"head"},"base":{"sha":"new-base-tip"},"changed_files":1}"#)
        let transport=ScriptedTransport([overview,json(#"[{"filename":"a","status":"modified","patch":"@@ -1 +1 @@\n-old\n+new","additions":1,"deletions":1}]"#),overview,json(#"{"merge_base_commit":{"sha":"original-base"}}"#)])
        let value=try await GitHubPRDetailFetcher(client:.init(transport:transport)).detail(repository:"o/r",number:1,headSHA:"head",token:"fixture")
        XCTAssertEqual(value.baseSHA,"original-base")
        XCTAssertEqual(try value.document.anchor(file:value.files[0],side:.left,start:1,end:1).commitSHA,"original-base")
    }
}

extension PRDetailProviderTests {
    func testContinuationRejectsMovingBaseEvenWithUnchangedHead() async throws {
        let before=json(#"{"head":{"sha":"head"},"base":{"sha":"base"},"changed_files":101}"#)
        let after=json(#"{"head":{"sha":"head"},"base":{"sha":"new-base"},"changed_files":101}"#)
        let snapshot=PRDetailSnapshot(body:"",baseSHA:"origin",headSHA:"head",files:[],expectedFiles:101,baseBranchSHA:"base",nextPage:2)
        let transport=ScriptedTransport([before,json("[]"),after])
        do { _ = try await GitHubPRDetailFetcher(client:.init(transport:transport)).more(repository:"o/r",number:1,snapshot:snapshot,token:"fixture");XCTFail("mixed base accepted") }
        catch { XCTAssertEqual(error as? PRDetailFailure,.revisionChanged) }
    }
}

extension PRDetailProviderTests {
    func testProviderCommentReviewedHeadIsSeparateFromLeftContentIdentity() async throws {
        let transport=ScriptedTransport([json("[]"),json(#"[{"id":7,"path":"a","line":1,"side":"LEFT","commit_id":"head","body":"Comment"}]"#)])
        let section=try await GitHubPRDetailFetcher(client:.init(transport:transport)).section(repository:"o/r",number:1,sha:"head",tab:.conversation,token:"fixture")
        let event=try XCTUnwrap(section.events.first)
        XCTAssertEqual(event.providerComment?.reviewedHeadSHA,"head")
        XCTAssertNil(event.anchor)
        let file=DiffFile(path:"a",status:.modified,patch:"@@ -1 +1 @@\n-old\n+new")
        let document=DiffDocument(baseSHA:"origin",headSHA:"head",files:[file],expectedFiles:1)
        XCTAssertEqual(event.renderingAnchor(in:document)?.commitSHA,"origin")
        XCTAssertNil(event.renderingAnchor(in:.init(baseSHA:"origin",headSHA:"new-head",files:[file],expectedFiles:1)))
    }
}
