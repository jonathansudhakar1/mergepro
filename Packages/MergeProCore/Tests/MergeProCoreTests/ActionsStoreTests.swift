import XCTest
@testable import MergeProCore

/// A newer attempt finished between polls: attempt 1 and the run read differ, the active list is empty.
private func ghostAttemptTransport() async -> RoutingTransport {
    let first = #"{"id":3,"workflow_id":2,"name":"CI","head_branch":"main","head_sha":"abc","event":"push","status":"completed","conclusion":"failure","run_attempt":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}"#
    let latest=first.replacingOccurrences(of:"\"run_attempt\":1",with:"\"run_attempt\":2")
    let transport=RoutingTransport()
    await transport.route(suffix:"/attempts/1",json(first))
    await transport.route(suffix:"/runs/3",json(latest))
    await transport.route(query:["status":nil],json(#"{"workflow_runs":[]}"#))
    await transport.route(json("{\"workflow_runs\":["+latest+"]}"))
    return transport
}
final class ActionsStoreTests:XCTestCase {
    let repo = Repository(key:.init(account:.init(host:"github.com",accountID:"42"),repositoryID:"1"),name:"o/r",isPrivate:false,capabilities:[])
    func testRunPaginationPreservesAttemptIdentityAndStatus() async throws {
        let body = #"{"workflow_runs":[{"id":3,"workflow_id":2,"name":"CI","head_branch":"main","head_sha":"abc","event":"push","status":"in_progress","run_attempt":2,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]}"#
        let transport = ScriptedTransport([.init(status:200,headers:["Link":"<https://api.github.com/repos/o/r/actions/runs?page=2>; rel=\"next\""],data:Data(body.utf8)),.init(status:200,data:Data(#"{"workflow_runs":[]}"#.utf8))])
        let runs = try await GitHubActionsProvider(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:[])).runs(repository:repo)
        XCTAssertEqual(runs.count,1); XCTAssertEqual(runs[0].attempt,2); XCTAssertTrue(runs[0].isActive)
        XCTAssertEqual(runs[0].key.repository,repo.key)
        let requests = await transport.requests; XCTAssertEqual(requests.count,2)
    }
    func testUnsafePaginationIsRejectedBeforeCredentialLeavesOrigin() async throws {
        let transport=ScriptedTransport([.init(status:200,headers:["Link":"<https://evil.test/repos/o/r/actions/runs>; rel=\"next\""],data:Data(#"{"workflow_runs":[]}"#.utf8))])
        do { _ = try await GitHubActionsProvider(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:[])).runs(repository:repo); XCTFail() } catch { XCTAssertEqual(error as? GitHubFailure,.unsafeURL) }
        let count=await transport.requests.count;XCTAssertEqual(count,1)
    }
    func testUnavailableLogsDifferFromEmptyLogs() async throws {
        let transport=ScriptedTransport([.init(status:404),.init(status:200)])
        let provider=GitHubActionsProvider(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:[]))
        let unavailable=try await provider.log(repository:repo,jobID:1);XCTAssertEqual(unavailable,.unavailable)
        let empty=try await provider.log(repository:repo,jobID:1);XCTAssertEqual(empty,.available(""))
    }
    func testDispatchCapabilityUsesImmutableDefaultBranchWorkflowContent() async throws {
        let yaml="on: workflow_dispatch"
        let content=Data(yaml.utf8).base64EncodedString()
        let transport=ScriptedTransport(bodies:["{\"id\":1,\"default_branch\":\"main\"}","{\"sha\":\"immutable\"}","{\"encoding\":\"base64\",\"content\":\"\(content)\"}"])
        let provider=GitHubActionsProvider(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:[]))
        let workflow=ActionsWorkflow(id:2,name:"CI",path:".github/workflows/ci.yml",state:"active",webURL:nil)
        let result=try await provider.dispatchCapabilities(repository:repo,workflows:[workflow])
        XCTAssertEqual(result.first?.manualTrigger,true)
        let requests=await transport.requests
        XCTAssertEqual(URLComponents(url:requests[2].url!,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,"immutable")
    }
    func testBuiltInDynamicWorkflowsAreNotDispatchableAndDoNotFailTheCatalog() async throws {
        // A repository with GitHub Pages lists `dynamic/pages/pages-build-deployment` beside its own workflows.
        let content=Data("on: workflow_dispatch".utf8).base64EncodedString()
        let transport=ScriptedTransport(bodies:["{\"id\":1,\"default_branch\":\"main\"}","{\"sha\":\"immutable\"}","{\"encoding\":\"base64\",\"content\":\"\(content)\"}"])
        let provider=GitHubActionsProvider(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:[]))
        let pages=ActionsWorkflow(id:1,name:"pages-build-deployment",path:"dynamic/pages/pages-build-deployment",state:"active",webURL:nil)
        let ci=ActionsWorkflow(id:2,name:"CI",path:".github/workflows/ci.yml",state:"active",webURL:nil)
        let result=try await provider.dispatchCapabilities(repository:repo,workflows:[pages,ci])
        XCTAssertEqual(result.map(\.manualTrigger),[false,true])
        let count=await transport.requests.count;XCTAssertEqual(count,3,"No file read for the built-in workflow")
    }
    func testPollingCommitsChangedActiveRunWithoutTraversingHistoricalPages() async throws {
        let body = #"{"workflow_runs":[{"id":3,"workflow_id":2,"name":"CI","head_branch":"main","head_sha":"abc","event":"push","status":"in_progress","run_attempt":2,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]}"#
        let transport=ScriptedTransport([.init(status:200,headers:["Link":"<https://api.github.com/repos/o/r/actions/runs?page=2>; rel=\"next\""],data:Data(body.utf8))])
        let provider=GitHubActionsProvider(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:[]))
        let runs=try await provider.pollRuns(repository:repo,cached:[],deadline:.now.advanced(by:.seconds(1)))
        XCTAssertEqual(runs.first?.status,"in_progress")
        let count=await transport.requests.count;XCTAssertEqual(count,1)
    }
    func testAttemptJobsAndAnnotationsPreserveStepStatusAndFileLocation() async throws {
        let job = #"{"jobs":[{"id":5,"name":"Build","status":"completed","conclusion":"failure","check_run_url":"https://api.github.com/repos/o/r/check-runs/9","steps":[{"number":1,"name":"Compile","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:00:04Z"}]}]}"#
        let transport=ScriptedTransport(bodies:[job,#"[{"path":"Sources/main.swift","start_line":2,"end_line":4,"annotation_level":"failure","message":"compile error"}]"#])
        let provider=GitHubActionsProvider(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:[]))
        let run=WorkflowRun(repository:repo,runID:3,workflowID:2,attempt:2,name:"CI",branch:"main",headSHA:"abc",event:"push",actor:"actor",status:"completed",conclusion:"failure",createdAt:.distantPast,updatedAt:Date())
        let jobs=try await provider.jobs(run:run)
        let annotations=try await provider.annotations(repository:repo,job:jobs[0])
        XCTAssertEqual(jobs[0].steps[0].conclusion,"failure");XCTAssertEqual(jobs[0].steps[0].completedAt!.timeIntervalSince(jobs[0].steps[0].startedAt!),4)
        XCTAssertEqual(annotations.first?.path,"Sources/main.swift");XCTAssertEqual(annotations.first?.startLine,2)
        let requests=await transport.requests;XCTAssertEqual(requests.first?.url?.path,"/repos/o/r/actions/runs/3/attempts/2/jobs")
    }
    func testFractionalSecondTimestampsParseForStepsAndRuns() async throws {
        // GitHub's documented step format: fractional seconds with a UTC offset.
        let job = #"{"jobs":[{"id":5,"name":"Build","status":"completed","conclusion":"success","steps":[{"number":1,"name":"Compile","status":"completed","conclusion":"success","started_at":"2020-01-20T09:42:40.000-07:00","completed_at":"2020-01-20T09:42:44.250-07:00"}]}]}"#
        let body = #"{"id":3,"workflow_id":2,"name":"CI","head_branch":"main","head_sha":"abc","event":"push","status":"in_progress","run_attempt":2,"created_at":"2026-01-01T00:00:00.123Z","updated_at":"2026-01-01T00:00:01.5Z"}"#
        let transport=ScriptedTransport(bodies:[job,body])
        let provider=GitHubActionsProvider(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:[]))
        let run=WorkflowRun(repository:repo,runID:3,workflowID:2,attempt:2,name:"CI",branch:"main",headSHA:"abc",event:"push",actor:"actor",status:"completed",conclusion:"success",createdAt:.distantPast,updatedAt:Date())
        let step=try await provider.jobs(run:run)[0].steps[0]
        XCTAssertEqual(step.startedAt,Date(timeIntervalSince1970:1_579_538_560))
        XCTAssertEqual(try XCTUnwrap(step.completedAt).timeIntervalSince(try XCTUnwrap(step.startedAt)),4.25,accuracy:0.001)
        let detail=try await provider.run(repository:repo,id:3,attempt:2)
        XCTAssertEqual(detail.updatedAt.timeIntervalSince(detail.createdAt),1.377,accuracy:0.001)
    }
    func testExpiredArtifactDoesNotAttemptDownload() async throws {
        let transport=ScriptedTransport()
        let provider=GitHubActionsProvider(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:[]))
        let artifact=ActionsArtifact(id:1,name:"output",size:1,expired:true,expiresAt:.distantPast)
        do { _=try await provider.artifact(repository:repo,artifact:artifact);XCTFail() } catch { XCTAssertEqual(error as? ActionsFailure,.expiredArtifact) }
        let count=await transport.requests.count;XCTAssertEqual(count,0)
    }
    func testDownloadHostAdmissionRejectsCredentialsAndUntrustedHosts() {
        XCTAssertTrue(GitHubActionsProvider.safeDownloadURL(URL(string:"https://results.blob.core.windows.net/file?sig=fixture")!))
        XCTAssertFalse(GitHubActionsProvider.safeDownloadURL(URL(string:"https://token@results.blob.core.windows.net/file")!))
        XCTAssertFalse(GitHubActionsProvider.safeDownloadURL(URL(string:"https://blob.core.windows.net.evil.test/file")!))
        XCTAssertFalse(GitHubActionsProvider.safeDownloadURL(URL(string:"http://results.blob.core.windows.net/file")!))
    }
    func testRunDetailRejectsProviderResponseForDifferentRunIdentity() async throws {
        let body = #"{"id":3,"workflow_id":2,"name":"CI","head_branch":"main","head_sha":"abc","event":"push","status":"in_progress","run_attempt":2,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}"#
        let transport=ScriptedTransport(bodies:[body])
        let provider=GitHubActionsProvider(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:[]))
        do { _=try await provider.run(repository:repo,id:4,attempt:2);XCTFail("A different run cannot supply admission truth") } catch { XCTAssertEqual(error as? GitHubFailure,.invalidResponse) }
    }
    func testPollingClosesCachedActiveAttemptWhenNewAttemptFinishedBetweenPolls() async throws {
        let old=WorkflowRun(repository:repo,runID:3,workflowID:2,attempt:1,name:"CI",branch:"main",headSHA:"abc",event:"push",actor:"actor",status:"in_progress",conclusion:nil,createdAt:.distantPast,updatedAt:.distantPast)
        let transport=await ghostAttemptTransport()
        let provider=GitHubActionsProvider(client:.init(transport:transport),credential:.init(accessToken:"fixture",scopes:[]))
        let runs=try await provider.pollRuns(repository:repo,cached:[old],deadline:.now.advanced(by:.seconds(30)))
        XCTAssertEqual(runs.first(where:{ $0.attempt==1 })?.status,"completed")
        XCTAssertEqual(runs.first(where:{ $0.attempt==2 })?.status,"completed")
        let requests=await transport.requests;XCTAssertTrue(requests.contains { $0.url?.path=="/repos/o/r/actions/runs/3/attempts/1" })
    }
    func testWholeJobLogWithTwoStepsDoesNotInventExactStepLineCoordinates() {
        let lines=ActionsLog.parse("step one output\nstep two output")
        XCTAssertEqual(lines.count,2)
        let jobURL=URL(string:"https://github.com/o/r/actions/runs/3/job/5")!
        XCTAssertEqual(ActionsLog.safeJobLink(jobURL),jobURL)
        let unverified=URL(string:"https://github.com/o/r/actions/runs/3/job/5#step:2:2")!
        XCTAssertEqual(ActionsLog.safeJobLink(unverified),jobURL)
    }
    func testANSIParserPreservesLinesAndStripsControlSequences() {
        let lines=ActionsLog.parse("\u{1B}[31merror\u{1B}[0m\nokay\n")
        XCTAssertEqual(lines.map(\.text),["error","okay",""]); XCTAssertEqual(lines[0].spans.first?.color,.red)
    }
}
