import Foundation

public protocol NotificationAttemptStore: Sendable {
    /// Atomically reserves a closed cycle and marks its persisted events surfaced.
    func reserve(_ summary: PollSummary) async throws -> Bool
    func finishAttempt(_ cycleID: UUID, delivered: Bool) async throws
}
public extension NotificationAttemptStore {
    func finishAttempt(_ cycleID: UUID, delivered: Bool) async throws {}
}
