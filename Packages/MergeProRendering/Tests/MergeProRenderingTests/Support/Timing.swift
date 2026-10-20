import Foundation
import XCTest

/// Absolute wall-clock thresholds fail under load, so they only run with `MERGEPRO_PERF_TESTS=1`;
/// the count-based or relative check beside each one always runs. (Mirrors MergeProCoreTests' Support/Timing.swift.)
enum PerformanceThresholds {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MERGEPRO_PERF_TESTS"] == "1" }
}
/// Asserts `elapsed < limit` only when wall-clock thresholds are enabled.
func XCTAssertWithinPerformanceBudget(_ elapsed: Duration, _ limit: Duration, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard PerformanceThresholds.enabled else { return }
    XCTAssertLessThan(elapsed, limit, message(), file: file, line: line)
}
/// The fastest of `runs` timings of `body`: scheduling noise only ever adds time.
func fastestDuration(_ runs: Int = 3, _ body: () -> Void) -> Duration {
    (0..<runs).map { _ in ContinuousClock().measure(body) }.min()!
}
