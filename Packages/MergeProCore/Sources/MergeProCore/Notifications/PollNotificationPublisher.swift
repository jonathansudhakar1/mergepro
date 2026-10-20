import Foundation

public struct PollNotificationPublisher: Sendable {
    public let store: any NotificationAttemptStore
    public let sink: any NotificationSink
    public init(store: any NotificationAttemptStore, sink: any NotificationSink) { self.store = store; self.sink = sink }
    public func publish(_ summary: PollSummary) async throws {
        guard !summary.eventKeys.isEmpty, try await store.reserve(summary) else { return }
        do {
            try await sink.post(summary)
            try await store.finishAttempt(summary.cycleID,delivered:true)
        } catch {
            // Reservation remains authoritative even if recording the outcome fails.
            do { try await store.finishAttempt(summary.cycleID,delivered:false) }
            catch { Log.notifications.error("Could not record an undelivered notification attempt: \(Log.kind(error), privacy: .public)") }
            throw error
        }
    }
}
