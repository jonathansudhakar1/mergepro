import XCTest
@testable import MergeProCore

/// Accepts every merge request (202), counting the writes that reached GitHub.
private func recoveryTransport() -> ScriptedTransport {
    ScriptedTransport(fallback: json(#"{"status":"pending","details":{"uuid":"11111111-1111-1111-1111-111111111111","expected_head_sha":"h2","merge_method":"squash","merge_action":"direct_merge","bypass_rules":false}}"#, status: 202))
}
private actor RecoveryAdapter: MergeAdapter {
    let initial: [MergeInspection]
    var results: [MergeInspection]?
    var readFailure: GitHubFailure?
    var failingKey: ProviderKey?
    var statusFailure: GitHubFailure?
    var failedStatus = false
    var statusReads = 0
    var sent = false
    init(_ values: [MergeInspection]) { initial = values }
    func configure(results: [MergeInspection]? = nil, failingKey: ProviderKey? = nil, readFailure: GitHubFailure? = nil, statusFailure: GitHubFailure? = nil, failedStatus: Bool = false) {
        self.results = results; self.failingKey = failingKey; self.readFailure = readFailure
        self.statusFailure = statusFailure; self.failedStatus = failedStatus; sent = true
    }
    func armForDispatch() { sent = false }
    func inspect(_ target: MergeTarget, client: GitHubHTTPClient, credential: GitHubCredential) async throws -> MergeInspection {
        if sent, target.key == failingKey, let readFailure { throw readFailure }
        return (sent ? results ?? initial : initial).first { $0.pr.key == target.key }!
    }
    func send(_ operation: PRWriteOperation, client: GitHubHTTPClient, credential: GitHubCredential) async throws -> GitHubResponse {
        let result = try await GitHubMergeAdapter().send(operation, client: client, credential: credential)
        sent = true
        return result
    }
    func status(_ id: UUID, target: MergeTarget, client: GitHubHTTPClient, credential: GitHubCredential) async throws -> GitHubResponse {
        statusReads += 1
        if let statusFailure { throw statusFailure }
        return failedStatus ? json(#"{"status":"failed","details":{"message":"provider failure"}}"#) : json(#"{"status":"pending","details":{"uuid":"11111111-1111-1111-1111-111111111111","expected_head_sha":"h2","merge_method":"squash","merge_action":"direct_merge"}}"#)
    }
}
final class MergeRecoveryTests: XCTestCase {
    private func row(_ n: Int, state: PullRequest.State = .open, head: String? = nil) -> MergeInspection {
        let key = ProviderKey(host:"github.com", accountID:"42", repositoryID:"1", objectID:"pull-request:P\(n)")
        var metadata = PRMetadata(number:n, webURL:URL(string:"https://github.com/o/r/pull/\(n)")!, repositoryName:"o/r")
        metadata.baseBranch = "main"; metadata.baseRevision = "base"
        let pr = PullRequest(key:key, headRevision:.init(head ?? "h\(n)"), title:"PR", state:state, isDraft:false, metadata:metadata)
        var e = MergeEvidence(key:key, head:pr.headRevision.rawValue, base:"base", branch:"main", fetchedAt:Date())
        e.open = state == .open; e.draft = false; e.actorAllowed = true; e.tokenCanWrite = true; e.conflictFree = true
        e.rulesComplete = true; e.asyncSupported = true; e.methods = [.squash]
        return .init(pr:pr, evidence:e, mergeCommitSHA:state == .merged ? "commit\(n)" : nil)
    }
    private func fixture(native: Bool = false) throws -> (DatabaseStore, String, MergeCommand, RecoveryAdapter, ScriptedTransport, MergeCoordinator) {
        let path = try makeTemporaryDirectory()
        let db = try DatabaseStore(path:path.appendingPathComponent("db").path)
        var values = native ? [row(1), row(2)] : [row(2)]
        if native {
            let stack = StackGraph.native(id:"S", number:1, size:2, entries:values.enumerated().map { .init(position:$0.offset+1, pr:$0.element.pr) }, complete:true, linear:true)
            for i in values.indices { values[i].stack = stack }
        }
        let selected = values.last!, account = selected.pr.key.account
        try db.saveAccount(.init(scope:account, login:"actor", tokenReference:nil))
        try db.saveRepository(.init(key:selected.pr.key.repository, name:"o/r", isPrivate:true, capabilities:[]))
        try db.savePullRequests(values.map(\.pr))
        try db.setApplicationSetting(AccountSessionStore.tokenReference(for:account),for:"activeActionAccount")
        let adapter = RecoveryAdapter(values), transport = recoveryTransport()
        let coordinator = try coordinator(db, adapter:adapter, transport:transport, path:path)
        return (db, path.path, try .init(selected:selected, affected:values, method:.squash, action:.direct), adapter, transport, coordinator)
    }
    private func coordinator(_ db: DatabaseStore, adapter: RecoveryAdapter, transport: ScriptedTransport, path: URL) throws -> MergeCoordinator {
        let account = AccountScope(host:"github.com", accountID:"42"), credentials = MemoryCredentials()
        credentials.save(.init(accessToken:"offline", scopes:["repo"]), account:account)
        let session = GitHubAccountSession(storage:.init(database:db, cache:try CacheStore(directory:path.appendingPathComponent("cache"), database:db), credentials:credentials), transport:transport)
        return .init(session:session, budget:RateBudget(minimumSpacing:.zero), database:db, clientID:"offline", activeAccount:{ account }, adapter:adapter)
    }
    func testAcceptedMutationReadDenialRetainsUUIDAndReservation() async throws {
        for failure in [GitHubFailure.resourceDenied, .rateLimited(until:Date().addingTimeInterval(60))] {
            let (db, _, command, adapter, transport, coordinator) = try fixture()
            await adapter.configure(failingKey:command.pr, readFailure:failure, statusFailure:failure)
            await adapter.armForDispatch()
            let result = try await coordinator.perform(command)
            XCTAssertEqual(result.state, .uncertain)
            XCTAssertNotNil(result.mergeOperationID)
            XCTAssertThrowsError(try DraftReviewStore(database:db).prepare(.init(command:command.writeCommand)))
            _ = try? await coordinator.reconcile(result.id)
            let writes = await transport.count; XCTAssertEqual(writes, 1)
        }
    }
    func testRestartRecoversValidatedRawPendingReceiptAndFailureResult() async throws {
        let (db, path, command, adapter, transport, _) = try fixture()
        let store = DraftReviewStore(database:db)
        var operation = PRWriteOperation(command:command.writeCommand)
        try store.prepare(operation); operation.state = .sending; try store.update(operation, expectedState:.prepared)
        operation.state = .uncertain
        operation.response = json(#"{"status":"pending","details":{"uuid":"11111111-1111-1111-1111-111111111111","expected_head_sha":"h2","merge_method":"squash","merge_action":"direct_merge","bypass_rules":false}}"#).data
        var encoded = try JSONSerialization.jsonObject(with:JSONEncoder.stable.encode(operation)) as! [String:Any]
        encoded["mergeResponseStatus"] = 202
        operation = try JSONDecoder().decode(PRWriteOperation.self, from:JSONSerialization.data(withJSONObject:encoded))
        try store.update(operation, expectedState:.sending)
        let reopened = try DatabaseStore(path:path+"/db")
        await adapter.configure(failedStatus:true)
        let fresh = try coordinator(reopened, adapter:adapter, transport:transport, path:URL(fileURLWithPath:path))
        let result = try await fresh.reconcile(operation.id)
        XCTAssertEqual(result.state, .rejected)
        XCTAssertEqual(result.mergeOperationID, UUID(uuidString:"11111111-1111-1111-1111-111111111111"))
        let reads = await adapter.statusReads; XCTAssertEqual(reads, 1)
        let writes = await transport.count; XCTAssertEqual(writes, 0)
    }
    func testRawReceiptWithoutProvenanceOrWithConflicting409CannotAdoptUUID() async throws {
        for status in [Int?.none,409] {
            let (db, _, _, adapter, transport, coordinator) = try fixture()
            let snapshot=row(2)
            let command=try MergeCommand(selected:snapshot,affected:[snapshot],method:.squash,action:.direct,title:"private custom title")
            let store=DraftReviewStore(database:db)
            var operation=PRWriteOperation(command:command.writeCommand)
            try store.prepare(operation);operation.state = .sending;try store.update(operation,expectedState:.prepared)
            operation.state = .uncertain;operation.mergeResponseStatus=status
            operation.response=json(#"{"status":"pending","details":{"uuid":"11111111-1111-1111-1111-111111111111","expected_head_sha":"h2","merge_method":"squash","merge_action":"direct_merge","bypass_rules":false}}"#).data
            try store.update(operation,expectedState:.sending)
            await adapter.configure(failedStatus:true)
            let result=try await coordinator.reconcile(operation.id)
            XCTAssertEqual(result.state,.uncertain);XCTAssertNil(result.mergeOperationID)
            let reads=await adapter.statusReads,writes=await transport.count
            XCTAssertEqual(reads,0);XCTAssertEqual(writes,0)
        }
    }
    func testRestartSendingRecoveryIsUncertainWithoutAnotherMutation() async throws {
        let (db, path, command, adapter, transport, _) = try fixture()
        let store = DraftReviewStore(database:db)
        var operation = PRWriteOperation(command:command.writeCommand)
        try store.prepare(operation); operation.state = .sending; try store.update(operation, expectedState:.prepared)
        let reopened = try DatabaseStore(path:path+"/db")
        let fresh = try coordinator(reopened, adapter:adapter, transport:transport, path:URL(fileURLWithPath:path))
        let result = try await fresh.reconcile(operation.id)
        XCTAssertEqual(result.state, .uncertain)
        let writes = await transport.count; XCTAssertEqual(writes, 0)
    }
    func testPartialMergedLayerSurvivesLaterReadFailureAndRestart() async throws {
        let (db, path, command, adapter, transport, _) = try fixture(native:true)
        var operation = PRWriteOperation(command:command.writeCommand)
        let store = DraftReviewStore(database:db); try store.prepare(operation)
        operation.state = .sending; try store.update(operation, expectedState:.prepared)
        await adapter.configure(results:[row(1,state:.merged),row(2)], failingKey:command.pr, readFailure:.resourceDenied)
        let first = try coordinator(db, adapter:adapter, transport:transport, path:URL(fileURLWithPath:path))
        _ = try? await first.reconcile(operation.id)
        let reopened = try DatabaseStore(path:path+"/db")
        XCTAssertEqual(try reopened.snapshot(for:command.pr.account).pullRequests.first { $0.key == command.affected[0].key }?.state, .merged)
        XCTAssertEqual(try reopened.observationFence(for:command.affected[0].key), 1)
        XCTAssertEqual(try DraftReviewStore(database:reopened).operation(operation.id)?.state, .uncertain)
        XCTAssertThrowsError(try DraftReviewStore(database:reopened).prepare(.init(command:command.writeCommand)))
        await adapter.configure(results:[row(1,state:.merged),row(2,state:.merged)])
        let fresh = try coordinator(reopened, adapter:adapter, transport:transport, path:URL(fileURLWithPath:path))
        let result = try await fresh.reconcile(operation.id)
        XCTAssertEqual(result.state, .confirmed)
        let writes = await transport.count; XCTAssertEqual(writes, 0)
    }
    func testMergedChangedLowerRevisionIsOutdatedAndStopsReviewedBatch() async throws {
        let (db, _, command, adapter, _, coordinator) = try fixture(native:true)
        var operation = PRWriteOperation(command:command.writeCommand)
        let store = DraftReviewStore(database:db); try store.prepare(operation)
        operation.state = .sending; try store.update(operation, expectedState:.prepared)
        await adapter.configure(results:[row(1,state:.merged,head:"changed"),row(2,state:.merged)])
        let result = try await coordinator.reconcile(operation.id)
        XCTAssertEqual(result.state, .postedOutdated)
        XCTAssertTrue(result.message?.contains("changed") == true)
        XCTAssertTrue(try db.snapshot(for:command.pr.account).pullRequests.allSatisfy { $0.state == .merged })
        let progress = await StackMergeCoordinator.merge([command], perform:{ _ in result }, progress:{ _ in })
        XCTAssertTrue(progress.completed.isEmpty); XCTAssertNotNil(progress.stopped)
    }
}
