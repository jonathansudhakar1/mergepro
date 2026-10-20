import Foundation

/// Decisions for the menu-bar popover and status item.
public enum PRMenuBarRules {
  /// "Approve…" acts as the action account, so it is offered only when that account's copy of the row is cached,
  /// it is the row's own account, and that account did not author the pull request (a team request can list your
  /// own PR under "Needs me").
  public static func offersApproval(row: PullRequest, actionPR: PullRequest?) -> Bool {
    guard let actionPR, actsAsRowAccount(row: row, actionPR: actionPR) else { return false }
    return actionPR.metadata?.viewerIsAuthor != true && row.metadata?.viewerIsAuthor != true
  }
  /// Commands from the menu bar, the inbox and notifications act as the action account. They act on a row only
  /// when that account's own copy of it is cached (the action account is the row's account); otherwise another
  /// account would write.
  public static func actsAsRowAccount(row: PullRequest, actionPR: PullRequest?) -> Bool {
    actionPR?.key == row.key
  }
  public enum MergeRoute: Equatable, Sendable { case mergeSheet, openPullRequest }
  /// "Merge…" from the menu bar or inbox opens the merge sheet only as the row's own account; otherwise it opens
  /// the pull request, where the account it acts as is shown.
  public static func mergeRoute(row: PullRequest, actionPR: PullRequest?) -> MergeRoute {
    actsAsRowAccount(row: row, actionPR: actionPR) ? .mergeSheet : .openPullRequest
  }

  static let failedConclusions: Set<String> = ["failure", "timed_out", "startup_failure"]
  /// A completed run that failed within `window` of `now`.
  public static func isRecentFailure(_ run: WorkflowRun, now: Date, window: TimeInterval = 86_400) -> Bool {
    !run.isActive && run.conclusion.map(failedConclusions.contains) == true && now.timeIntervalSince(run.updatedAt) <= window
  }
  /// Active runs, then runs that failed within `window`; each group newest first, at most `limit`.
  public static func menuRuns(_ runs: [WorkflowRun], now: Date, window: TimeInterval = 86_400, limit: Int = 20) -> [WorkflowRun] {
    let newest: (WorkflowRun, WorkflowRun) -> Bool = { $0.updatedAt == $1.updatedAt ? $0.runID > $1.runID : $0.updatedAt > $1.updatedAt }
    let active = runs.filter(\.isActive).sorted(by: newest)
    let failed = runs.filter { isRecentFailure($0, now: now, window: window) }.sorted(by: newest)
    return Array((active + failed).prefix(limit))
  }

  /// Status-item title for the "Needs me" count: nil when hidden or zero.
  public static func statusCount(needsMe: Int, enabled: Bool) -> String? {
    guard enabled, needsMe > 0 else { return nil }
    return needsMe > 99 ? "99+" : String(needsMe)
  }
}
