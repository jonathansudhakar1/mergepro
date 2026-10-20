import SwiftUI
import MergeProCore

/// Merge commit-text prefill. Read-only: nothing is persisted and no ledger or fence state changes.
extension SetupStorage {
    /// GitHub's default commit title/body for the action-account PR's evidence head; nil when that head moved.
    /// Callers use `try?`: a failure only means the editor starts without a prefill.
    func mergeMessageDefaults(_ pr:PullRequest) async throws -> MergeMessageDefaults? { try await mergeCoordinator().messageDefaults(pr) }
}
