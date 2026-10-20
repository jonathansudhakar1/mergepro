import XCTest
@testable import MergeProCore

/// Logged error kinds name the type and case only; associated values and messages never appear.
final class CoreLogTests: XCTestCase {
    func testErrorKindsCarryNoPayload() {
        XCTAssertEqual(Log.kind(GitHubFailure.rateLimited(until: Date(timeIntervalSince1970: 1_790_848_800))), "GitHubFailure.rateLimited")
        XCTAssertEqual(Log.kind(CancellationError()), "cancelled")
        let private_ = "/Users/someone/private-repository"
        for error: any Error in [
            GitRunnerError.executableUnavailable(path: private_),
            PRWriteRejection(kind: .partial, summary: private_),
            NSError(domain: "Fixture", code: 7, userInfo: [NSLocalizedDescriptionKey: private_]),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: private_)),
        ] {
            XCTAssertFalse(Log.kind(error).contains(private_), Log.kind(error))
        }
        XCTAssertEqual(Log.kind(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))), "DecodingError.dataCorrupted")
    }
}

/// Diagnostics that fire on every read or every cancelled work item drown the useful ones.
final class CoreLogNoiseTests: XCTestCase {
    func testAnUndecodableLedgerRowIsReportedOncePerRow() throws {
        let store = try DatabaseStore(path: ":memory:")
        let id = UUID().uuidString
        try store.database.write { db in
            try db.execute(sql: "INSERT INTO reviewOperations(id,identity,json) VALUES (?,?,?)", arguments: [id, "identity", Data(#"{"state":"prepared"}"#.utf8)])
        }
        XCTAssertTrue(try store.database.read { try DatabaseStore.activeReservations($0) }.isEmpty)
        XCTAssertTrue(try store.database.read { try DatabaseStore.activeReservations($0) }.isEmpty)
        XCTAssertEqual(DatabaseStore.undecodableOperationReports.count(id), 1, "a row that cannot decode is reported once, not on every read")
    }
    func testCancelledPollWorkIsNotReportedAsAFailure() {
        XCTAssertFalse(PollCoordinator.reportsWorkFailure(CancellationError()))
        XCTAssertTrue(PollCoordinator.reportsWorkFailure(GitHubFailure.invalidResponse))
    }
}
