import XCTest
@testable import MergeProCore
private actor ActionsCommandTransport:GitHubTransport {
    var writes=0
    var reads=0
    var allowed=true
    var loseResponse=false
    var attempt=1
    var originalForkRequired=false
    var laterAttemptFinished=false
    var paths:[String]=[]
    func requireForkApproval() { originalForkRequired=true }
    func finishLaterAttempt() { laterAttemptFinished=true;attempt=2 }
    var canApprove=false
    var environmentProduction=false
    var ambiguousDeploymentResponse=false
    func ambiguousReview() { ambiguousDeploymentResponse=true }
    func allowDeployment(production:Bool) { canApprove=true;environmentProduction=production }
    func deny() { allowed=false }
    func lose() { loseResponse=true }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        paths.append(request.url!.path)
        if request.httpMethod=="POST" { writes += 1;if loseResponse { throw URLError(.networkConnectionLost) };return .init(status:request.url!.path.hasSuffix("/pending_deployments") && !ambiguousDeploymentResponse ? 200:202) }
        reads += 1
        let json:String
        if request.url!.path.hasSuffix("/actions/runs/3") || request.url!.path.hasSuffix("/attempts/1") {
            let original=request.url!.path.hasSuffix("/attempts/1")
            let requestedAttempt=original ? 1:attempt
            let status=laterAttemptFinished ? "completed":originalForkRequired ? "waiting":"in_progress"
            let conclusion:String?
            if laterAttemptFinished { conclusion=original ? (originalForkRequired ? "action_required":"success"):(originalForkRequired ? "success":"cancelled") }
            else { conclusion=originalForkRequired ? "action_required":nil }
            let conclusionJSON=conclusion.map { "\""+$0+"\"" } ?? "null"
            json="{\"id\":3,\"workflow_id\":2,\"name\":\"CI\",\"head_branch\":\"main\",\"head_sha\":\"abc\",\"event\":\"push\",\"status\":\"\(status)\",\"conclusion\":\(conclusionJSON),\"run_attempt\":\(requestedAttempt),\"created_at\":\"2026-01-01T00:00:00Z\",\"updated_at\":\"2026-01-01T00:00:00Z\"}"
        } else if request.url!.path.hasSuffix("/pending_deployments") {
            json="[{\"environment\":{\"id\":9,\"name\":\"release-live\"},\"current_user_can_approve\":\(canApprove)}]"
        } else if request.url!.path.hasSuffix("/deployments") {
            json=environmentProduction ? "[{\"id\":9,\"environment\":\"release-live\",\"ref\":\"main\",\"sha\":\"abc\",\"production_environment\":true}]":"[]"
        } else if request.url!.path.hasSuffix("/statuses") { json="[{\"state\":\"success\"}]" }
        else { json="{\"id\":1,\"permissions\":{\"push\":\(allowed)}}" }
        return .init(status:200,data:Data(json.utf8))
    }
}
private actor PartialActionsTransport:GitHubTransport {
    var paths:[String]=[]
    func recordPrimary(_ detail:ActionsRunDetail) { paths.append("primary:\(detail.jobs.count)") }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        paths.append(request.url!.path)
        let run = #"{"id":3,"workflow_id":2,"name":"CI","head_branch":"main","head_sha":"abc","event":"push","status":"in_progress","run_attempt":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}"#
        let path=request.url!.path
        let body:String
        if path.hasSuffix("/actions/runs") { body="{\"workflow_runs\":["+run+"]}" }
        else if path.hasSuffix("/actions/workflows") { body=#"{"workflows":[]}"# }
        else if path.hasSuffix("/jobs") { body=#"{"jobs":[{"id":5,"name":"Build","status":"in_progress","check_run_url":"https://api.github.com/repos/o/r/check-runs/9","steps":[]}]}"# }
        else if path.hasSuffix("/actions/runs/3") || path.hasSuffix("/attempts/1") { body=run }
        else if path=="/repos/o/r" { body=#"{"id":1,"permissions":{"push":true}}"# }
        else { return .init(status:403,data:Data("{}".utf8)) }
        return .init(status:200,data:Data(body.utf8))
    }
}
@MainActor final class WorkflowCommandTests:XCTestCase {
    let repo=Repository(key:.init(account:.init(host:"github.com",accountID:"42"),repositoryID:"1"),name:"o/r",isPrivate:true,capabilities:[])
    private func fixture(_ transport:any GitHubTransport,_ budget:RateBudget) throws -> (DatabaseStore,ActionsService) {
        let fixture=try makeSessionFixture(account:repo.key.account,repositories:[repo],transport:transport)
        return (fixture.database,.init(session:fixture.session,budget:budget,database:fixture.database,clientID:"fixture",activeAccount:fixture.activeAccount))
    }
    func testPrimaryRunAndJobsPublishBeforeSupplementaryReads() async throws {
        let transport=PartialActionsTransport()
        let (_,service)=try fixture(transport,RateBudget(minimumSpacing:.zero))
        let catalog=try await service.catalog(repository:repo)
        let result=try await service.detail(run:catalog.runs[0],onPrimary:{ primary in
            await transport.recordPrimary(primary)
        })
        XCTAssertEqual(result.jobs.count,1)
        let paths=await transport.paths
        let primary=try XCTUnwrap(paths.firstIndex(of:"primary:1"))
        let artifacts=try XCTUnwrap(paths.firstIndex(where:{ $0.hasSuffix("/artifacts") }))
        XCTAssertLessThan(primary,artifacts,"Slow optional sections must not hold up job navigation")
    }
    func testAccountSwitchWhileWaitingForBudgetRejectsBeforeDispatch() async throws {
        let transport=ActionsCommandTransport(),budget=RateBudget(minimumSpacing:.zero)
        let (db,service)=try fixture(transport,budget)
        try await budget.beginRequest(account:repo.key.account)
        let task=Task { try await service.perform(repository:repo,intent:.cancel(runID:3,attempt:1)) }
        for _ in 0..<100 { await Task.yield() }
        try db.setApplicationSetting("other",for:"activeActionAccount")
        await budget.endRequest(account:repo.key.account)
        do { _=try await task.value;XCTFail() } catch {}
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testPermissionDeniedNeverSendsWrite() async throws {
        let transport=ActionsCommandTransport();await transport.deny()
        let (_,service)=try fixture(transport,RateBudget(minimumSpacing:.zero))
        do { _=try await service.perform(repository:repo,intent:.cancel(runID:3,attempt:1));XCTFail() } catch { XCTAssertEqual(error as? ActionsFailure,.permissionDenied) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testLostWriteResponsePersistsUncertaintyAndBlocksDuplicate() async throws {
        let transport=ActionsCommandTransport();await transport.lose()
        let (db,service)=try fixture(transport,RateBudget(minimumSpacing:.zero))
        let operation=try await service.perform(repository:repo,intent:.cancel(runID:3,attempt:1))
        XCTAssertEqual(operation.state,.uncertain)
        XCTAssertEqual(try ActionsStore(database:db).operation(operation.id)?.state,.uncertain)
        _=try await service.reconcile(operation.id)
        do { _=try await service.perform(repository:repo,intent:.cancel(runID:3,attempt:1));XCTFail() } catch { XCTAssertEqual(error as? ActionsFailure,.operationInProgress) }
        let writes=await transport.writes;XCTAssertEqual(writes,1)
    }
    func testDeploymentReviewUsesFreshViewerPermissionBeforeWrite() async throws {
        let transport=ActionsCommandTransport()
        let (_,service)=try fixture(transport,RateBudget(minimumSpacing:.zero))
        do { _=try await service.perform(repository:repo,intent:.deployment(runID:3,attempt:1,environmentIDs:[9],approve:true,comment:"Reviewed"));XCTFail() } catch { XCTAssertEqual(error as? ActionsFailure,.permissionDenied) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testCustomProductionDeploymentRequiresConfirmationFromFreshProviderFlags() async throws {
        let transport=ActionsCommandTransport();await transport.allowDeployment(production:true)
        let (_,service)=try fixture(transport,RateBudget(minimumSpacing:.zero))
        do { _=try await service.perform(repository:repo,intent:.deployment(runID:3,attempt:1,environmentIDs:[9],approve:true,comment:"Reviewed"));XCTFail() } catch { XCTAssertEqual(error as? ActionsFailure,.productionConfirmationRequired) }
        let zero=await transport.writes;XCTAssertEqual(zero,0)
        let receipt=try await service.perform(repository:repo,intent:.deployment(runID:3,attempt:1,environmentIDs:[9],approve:true,comment:"Reviewed",productionConfirmed:true))
        XCTAssertEqual(receipt.state,.confirmed)
        let writes=await transport.writes;XCTAssertEqual(writes,1)
    }
    func testOptionalPermissionDenialsPreserveAvailableCatalogAndDetailWithExplicitUnavailableSections() async throws {
        let (_,service)=try fixture(PartialActionsTransport(),RateBudget(minimumSpacing:.zero))
        let catalog=try await service.catalog(repository:repo)
        XCTAssertEqual(catalog.runs.count,1);XCTAssertNotNil(catalog.unavailableSections["deployments"]);XCTAssertNotNil(catalog.unavailableSections["environments"])
        let detail=try await service.detail(run:catalog.runs[0])
        XCTAssertEqual(detail.jobs.count,1);XCTAssertNotNil(detail.unavailableSections["artifacts"]);XCTAssertNotNil(detail.unavailableSections["annotations"]);XCTAssertNotNil(detail.unavailableSections["pendingDeployments"])
    }
    func testUnexpectedDeploymentAcceptanceDoesNotClaimConfirmedReview() async throws {
        let transport=ActionsCommandTransport();await transport.allowDeployment(production:false);await transport.ambiguousReview()
        let (_,service)=try fixture(transport,RateBudget(minimumSpacing:.zero))
        let receipt=try await service.perform(repository:repo,intent:.deployment(runID:3,attempt:1,environmentIDs:[9],approve:true,comment:"Reviewed"))
        XCTAssertEqual(receipt.state,.uncertain)
    }
    func testCancelReconciliationDoesNotUseLaterAttemptCancellationEvidence() async throws {
        let transport=ActionsCommandTransport();await transport.lose()
        let (_,service)=try fixture(transport,RateBudget(minimumSpacing:.zero))
        let sent=try await service.perform(repository:repo,intent:.cancel(runID:3,attempt:1))
        XCTAssertEqual(sent.state,.uncertain)
        await transport.finishLaterAttempt()
        let reconciled=try await service.reconcile(sent.id)
        XCTAssertEqual(reconciled.state,.uncertain,"Attempt 1 succeeded; attempt 2 cancellation cannot confirm the attempt 1 request")
        let paths=await transport.paths;XCTAssertTrue(paths.contains("/repos/o/r/actions/runs/3/attempts/1"))
    }
    func testForkApprovalReconciliationDoesNotUseLaterAttemptCompletionEvidence() async throws {
        let transport=ActionsCommandTransport();await transport.requireForkApproval();await transport.lose()
        let (_,service)=try fixture(transport,RateBudget(minimumSpacing:.zero))
        let sent=try await service.perform(repository:repo,intent:.approveFork(runID:3,attempt:1))
        XCTAssertEqual(sent.state,.uncertain)
        await transport.finishLaterAttempt()
        let reconciled=try await service.reconcile(sent.id)
        XCTAssertEqual(reconciled.state,.uncertain,"Attempt 1 still requires approval; attempt 2 completion cannot confirm its approval")
        let paths=await transport.paths;XCTAssertTrue(paths.contains("/repos/o/r/actions/runs/3/attempts/1"))
    }
    func testAcceptedCancelCannotDuplicateBeforeProviderObservesCancellation() async throws {
        let transport=ActionsCommandTransport()
        let (_,service)=try fixture(transport,RateBudget(minimumSpacing:.zero))
        let operation=try await service.perform(repository:repo,intent:.cancel(runID:3,attempt:1))
        XCTAssertEqual(operation.state,.accepted)
        do { _=try await service.perform(repository:repo,intent:.cancel(runID:3,attempt:1));XCTFail("Acceptance must retain the run write lock until cancellation is observed") } catch { XCTAssertEqual(error as? ActionsFailure,.operationInProgress) }
        let writes=await transport.writes;XCTAssertEqual(writes,1)
    }
    func testSecretClassifiedDefaultIsNotPersistedInReceiptSchema() throws {
        let schema=try WorkflowInputSchema.parse(yaml:"on:\n  workflow_dispatch:\n    inputs:\n      token:\n        type: string\n        default: TOP_SECRET",workflowID:2,ref:"main",revision:"sha")
        let workflow=ActionsWorkflow(id:2,name:"deploy",path:".github/workflows/deploy.yml",state:"active",webURL:nil)
        let operation=ActionsWriteOperation(repository:repo,intent:.dispatch(workflow:workflow,schema:schema,inputs:["token":.text("ANOTHER_SECRET")],productionConfirmed:false))
        let json=String(decoding:try JSONEncoder.stable.encode(operation),as:UTF8.self)
        XCTAssertFalse(json.contains("TOP_SECRET"));XCTAssertFalse(json.contains("ANOTHER_SECRET"))
    }
}
