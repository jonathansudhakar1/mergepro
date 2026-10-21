import Foundation
import XCTest
@testable import MergeProCore

/// Answers 200 at once, except the request for `/first`, which stays in flight until released.
private func pacingTransport() async -> ScriptedTransport {
    let transport=ScriptedTransport(fallback:GitHubResponse(status:200))
    await transport.hold(where:{ $0.url?.path == "/first" })
    return transport
}

private func pacingRequest(_ path:String) -> URLRequest { URLRequest(url:URL(string:"https://api.github.com/"+path)!) }

private actor PacingAdmission {
    private(set) var calls=0
    func markSending() { calls += 1 }
}

/// RateBudget paces on the real ContinuousClock with no injection point, so pacing is checked with lower bounds
/// (load only widens gaps) and upper bounds relative to the pacing they must undercut; absolute budgets need
/// MERGEPRO_PERF_TESTS=1. Tests await the budget's waiter counts (`untilWaiting`) to know queued requests reached it.
final class RateBudgetTests:XCTestCase {
    func testQueuedBackgroundRequestsKeepActualStartSpacingAfterSlowResponse() async throws {
        let account=AccountScope(host:"github.com",accountID:"pacing")
        let budget=RateBudget(minimumSpacing:.milliseconds(100))
        let base=await pacingTransport()
        let transport=BudgetedGitHubTransport(base:base,budget:budget,account:account)
        let first=Task { try await transport.send(pacingRequest("first")) }
        await base.waitUntilHolding()
        let second=Task { try await transport.send(pacingRequest("second")) }
        let third=Task { try await transport.send(pacingRequest("third")) }
        // Both reserved pacing times expire while the first request still owns the account slot: both wait for it.
        await budget.untilWaiting(account:account,slot:2)
        await base.release()
        _ = try await first.value;_ = try await second.value;_ = try await third.value
        let starts=await base.arrivals()
        XCTAssertEqual(starts.count,3)
        XCTAssertGreaterThanOrEqual(starts[1].duration(to:starts[2]),.milliseconds(90),"Queued requests must recheck spacing against the preceding actual start")
    }

    func testQueuedBackgroundRequestsHonorQuotaFromPrecedingResponse() async throws {
        let account=AccountScope(host:"github.com",accountID:"quota")
        // Reserve accounting only; quota pacing would space these reads a minute apart (see QuotaPacingTests).
        let budget=RateBudget(minimumSpacing:.zero,interactiveReserve:2,pacesQuota:false)
        let headers=["X-RateLimit-Remaining":"5","X-RateLimit-Reset":String(Date().addingTimeInterval(3600).timeIntervalSince1970)]
        await budget.observe(GitHubResponse(status:200,headers:headers),account:account)
        let base=await pacingTransport()
        let transport=BudgetedGitHubTransport(base:base,budget:budget,account:account)
        let first=Task { try await transport.send(pacingRequest("first")) }
        await base.waitUntilHolding()
        let second=Task { try await transport.send(pacingRequest("second")) }
        let third=Task { try await transport.send(pacingRequest("third")) }
        await budget.untilWaiting(account:account,slot:2)
        var refreshed=headers;refreshed["X-RateLimit-Remaining"]="3"
        await base.release(GitHubResponse(status:200,headers:refreshed))
        _ = try await first.value
        var accepted=0
        for task in [second,third] {
            do { _ = try await task.value;accepted += 1 }
            catch GitHubFailure.rateLimited {}
        }
        XCTAssertEqual(accepted,1,"The refreshed quota allows one queued send while preserving the interactive reserve")
        let starts=await base.arrivals()
        XCTAssertEqual(starts.count,2)
    }

    func testQueuedWriteDeniedByRefreshedQuotaDoesNotMarkSending() async throws {
        let account=AccountScope(host:"github.com",accountID:"write-quota")
        let budget=RateBudget(minimumSpacing:.zero)
        let headers=["X-RateLimit-Remaining":"200","X-RateLimit-Reset":String(Date().addingTimeInterval(3600).timeIntervalSince1970)]
        await budget.observe(GitHubResponse(status:200,headers:headers),account:account)
        let base=await pacingTransport(),admission=PacingAdmission()
        let background=BudgetedGitHubTransport(base:base,budget:budget,account:account)
        let writer=BudgetedGitHubTransport(base:base,budget:budget,account:account,beforeSend:{ await admission.markSending() })
        let first=Task { try await background.send(pacingRequest("first")) }
        await base.waitUntilHolding()
        var request=pacingRequest("write");request.httpMethod="PATCH"
        let queued=Task { [request] in try await writer.send(request) }
        await budget.untilWaiting(account:account,slot:1)
        var refreshed=headers;refreshed["X-RateLimit-Remaining"]="0"
        // A primary quota can be exhausted on a successful response without setting secondary backoff.
        await base.release(GitHubResponse(status:200,headers:refreshed))
        _ = try await first.value
        do { _ = try await queued.value;XCTFail("The exhausted quota must reject the queued write") }
        catch GitHubFailure.rateLimited {}
        let calls=await admission.calls
        XCTAssertEqual(calls,0,"Quota rejection must happen before the durable sending marker")
        let starts=await base.arrivals()
        XCTAssertEqual(starts.count,1)
    }

    /// Default pacing: background reads go out about 250 ms apart (still one at a time), while user writes keep
    /// a full second between mutations.
    func testDefaultBudgetPacesBackgroundReadsAt250msAndKeepsTheOneSecondWriteGap() async throws {
        let account=AccountScope(host:"github.com",accountID:"default-pacing")
        let budget=RateBudget()
        let base=await pacingTransport()
        let background=BudgetedGitHubTransport(base:base,budget:budget,account:account)
        let start=ContinuousClock.now
        for index in 0..<5 { _ = try await background.send(pacingRequest("read-\(index)")) }
        let reads=await base.arrivals()
        XCTAssertEqual(reads.count,5)
        for index in 1..<reads.count {
            XCTAssertGreaterThanOrEqual(reads[index-1].duration(to:reads[index]),.milliseconds(240),"Background reads stay paced")
        }
        // At the one-second write spacing the four gaps could not take less than four seconds.
        XCTAssertLessThan(start.duration(to:reads[4]),.seconds(4),"Four read gaps take about one second, not four")
        XCTAssertWithinPerformanceBudget(start.duration(to:reads[4]),.milliseconds(1_600),"Four read gaps take about one second, not four")
        let writer=BudgetedGitHubTransport(base:base,budget:budget,account:account,beforeSend:{})
        var first=pacingRequest("write-1");first.httpMethod="PATCH"
        var second=pacingRequest("write-2");second.httpMethod="PATCH"
        _ = try await writer.send(first);_ = try await writer.send(second)
        let all=await base.arrivals()
        XCTAssertGreaterThanOrEqual(all[5].duration(to:all[6]),.milliseconds(990),"User writes keep one second between mutations")
    }
}
