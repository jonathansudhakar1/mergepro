import Foundation
import XCTest

/// Absolute wall-clock thresholds fail under load, so they only run with `MERGEPRO_PERF_TESTS=1`;
/// the count-based or relative check beside each one always runs.
enum PerformanceThresholds {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MERGEPRO_PERF_TESTS"] == "1" }
}
/// Asserts `elapsed < limit` only when wall-clock thresholds are enabled.
func XCTAssertWithinPerformanceBudget(_ elapsed: Duration, _ limit: Duration, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard PerformanceThresholds.enabled else { return }
    XCTAssertLessThan(elapsed, limit, message(), file: file, line: line)
}
/// Millisecond variant for tests that already measure in milliseconds.
func XCTAssertWithinPerformanceBudget(milliseconds elapsed: Double, _ limit: Double, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard PerformanceThresholds.enabled else { return }
    XCTAssertLessThan(elapsed, limit, message(), file: file, line: line)
}

/// A rendezvous for fakes: work calls `enter()` and stays parked until `open()`; the test awaits `arrivals(n)`
/// to know the work really is in flight, instead of sleeping and hoping it got there.
actor TestGate {
    private var opened = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var entered = 0
    init(open: Bool = false) { opened = open }
    func enter() async {
        entered += 1
        let ready = waiters.filter { $0.count <= entered }; waiters.removeAll { $0.count <= entered }
        for waiter in ready { waiter.continuation.resume() }
        if !opened { await withCheckedContinuation { parked.append($0) } }
    }
    /// Suspends until `count` callers have entered.
    func arrivals(_ count: Int = 1) async {
        if entered >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    /// Releases everyone parked now and lets later callers straight through.
    func open() { opened = true; let all = parked; parked = []; for continuation in all { continuation.resume() } }
}

struct WaitTimedOut: Error, CustomStringConvertible { let description: String }
/// Explicit synchronization with something outside Swift concurrency (a child process, a file): yields until
/// `condition` holds, and fails after `timeout` rather than hanging the suite.
func waitUntil(_ description: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw WaitTimedOut(description: "Timed out waiting until \(description)") }
        await Task.yield()
    }
}
