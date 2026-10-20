import AppKit
import MergeProCore

extension SetupModel {
    /// Open and "Approve…" from a pull request notification. Approve only presents the review composer with Approve
    /// preselected, as the menu bar does; nothing is sent until the user submits the review there. Like the menu bar
    /// (`NotificationApproval`), it applies only when the action account is the pull request's own account and did not
    /// author it, checked again now; otherwise the pull request opens. An action sheet already showing is kept and
    /// brought forward rather than replaced.
    func receivePullRequestNotification(_ action: SystemNotificationSink.PullRequestAction) async {
        let approve: Bool, target: SystemNotificationSink.Target
        switch action {
        case .open(let value): approve = false; target = value
        case .review(let value): approve = true; target = value
        }
        let pr = target.pullRequest.flatMap { prs.cached($0) }
        switch NotificationApproval.route(approve: approve, row: pr, actionPR: pr.flatMap { prs.actionPRCached($0) }) {
        case .activity:
            // Only a GitHub notification thread identified it (or it left the cache): show its activity instead.
            summaryEventKeys = target.eventKeys; destination = .activity
            await reloadActivity()
            statusItem.showMain(); NSApplication.shared.activate()
        case .approve:
            guard let pr else { return }
            destination = .pullRequests
            if !prs.isPresentingAction { prs.select(pr.key) }
            prs.requestReview(pr, decision: .approve)
            statusItem.showMain(); NSApplication.shared.activate()
        case .openPullRequest:
            guard let pr else { return }
            destination = .pullRequests
            if !prs.isPresentingAction { prs.select(pr.key) }
            NSWorkspace.shared.open(pr.key.routeURL)
            NSApplication.shared.activate()
        }
    }
}
