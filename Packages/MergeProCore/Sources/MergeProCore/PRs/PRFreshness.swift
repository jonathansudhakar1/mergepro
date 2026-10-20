import Foundation

public struct PRRepositoryFreshness: Equatable, Sendable, Identifiable {
  public enum State: String, Sendable { case fresh, stale, partial, failed, revoked, notFetched }
  public let repository: RepositoryKey
  public var id: RepositoryKey { repository }
  public let name: String
  public let state: State
  public let lastSuccessAt: Date?
  public let lastFailureAt: Date?
  public let message: String?
  public init(
    repository: RepositoryKey, name: String, status: PRInventoryStatus?, revoked: Bool, now: Date,
    staleAfter: TimeInterval
  ) {
    self.repository = repository
    self.name = name
    lastSuccessAt =
      status?.lastSuccessAt ?? status.flatMap { $0.lastFailureAt == nil ? $0.fetchedAt : nil }
    lastFailureAt = status?.lastFailureAt
    message = status?.failureMessage ?? status?.message
    if revoked {
      state = .revoked
    } else if let failed = lastFailureAt, failed >= (lastSuccessAt ?? .distantPast) {
      state = .failed
    } else if let status {
      if now.timeIntervalSince(lastSuccessAt ?? status.fetchedAt) > staleAfter {
        state = .stale
      } else {
        state = status.complete ? .fresh : .partial
      }
    } else {
      state = .notFetched
    }
  }
  public var label: String {
    switch state {
    case .fresh: "Current"
    case .stale: "Stale cached data"
    case .partial: "Partial provider data"
    case .failed: "Refresh failed; cached data"
    case .revoked: "Access revoked"
    case .notFetched: "Not refreshed yet"
    }
  }
}
