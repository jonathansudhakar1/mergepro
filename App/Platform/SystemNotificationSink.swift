import AppKit
import Foundation
import UserNotifications
import MergeProCore

/// The only OS publisher/delegate. Permission is requested exclusively by explicit Settings opt-in.
/// A small cycle posts one notification per pull request (or run/thread), replacing that subject's previous one;
/// a burst arrives as one summary (see `NotificationAggregator`).
@MainActor
final class SystemNotificationSink: NSObject, NotificationSink, UNUserNotificationCenterDelegate {
    nonisolated static let summaryIdentifier = "app.mergepro.mac.poll-summary"
    nonisolated static let itemIdentifierPrefix = "app.mergepro.mac.item."
    nonisolated static let category = "MERGEPRO_POLL_SUMMARY"
    nonisolated static let pullRequestCategory = "MERGEPRO_PULL_REQUEST"
    nonisolated static let subjectCategory = "MERGEPRO_SUBJECT"
    /// "Show pull request titles in notifications". Off unless the user opts in: titles can appear on the lock screen.
    nonisolated static let showTitlesKey = "notificationsShowPullRequestTitles"
    enum Action: Sendable { case open(UUID), snooze(UUID) }
    /// One subject's notification. `pullRequest` is nil when only a GitHub notification thread identified it.
    struct Target: Sendable, Equatable {
        let cycleID: UUID
        let eventKeys: [String]
        let pullRequest: ProviderKey?
        let webURL: URL?
    }
    /// "Approve…" only opens the review composer; nothing is sent to GitHub until the user submits there.
    enum PullRequestAction: Sendable { case open(Target), review(Target) }
    enum DeliveryFailure: Error { case disabled, notAuthorized }
    private let isEnabled: @Sendable () async -> Bool
    private let showsTitles: @Sendable () -> Bool
    /// A response that launches the app can arrive before setup installs this handler; the latest one is delivered once it does.
    var onAction: (@MainActor (Action) async -> Void)? {
        didSet {
            if let onAction, let action = pendingAction { pendingAction = nil; Task { await onAction(action) } }
            if onAction != nil, let action = pendingPullRequestAction { pendingPullRequestAction = nil; Task { await self.deliver(action) } }
        }
    }
    /// Installed by the app model to open a pull request or its review composer. Without it, both open the pull request
    /// window through the app's `mergepro://` route, and a subject without a known pull request opens its activity.
    var onPullRequestAction: (@MainActor (PullRequestAction) async -> Void)? {
        didSet { if let onPullRequestAction, let action = pendingPullRequestAction { pendingPullRequestAction = nil; Task { await onPullRequestAction(action) } } }
    }
    private var pendingAction: Action?
    private var pendingPullRequestAction: PullRequestAction?
    init(isEnabled: @escaping @Sendable () async -> Bool, showsTitles: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: SystemNotificationSink.showTitlesKey) }) {
        self.isEnabled = isEnabled
        self.showsTitles = showsTitles
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier:"OPEN_ITEM",title:"Open",options:.foreground)
        let snooze = UNNotificationAction(identifier:"SNOOZE",title:"Snooze",options:[])
        center.setNotificationCategories([
            UNNotificationCategory(identifier:Self.category,actions:[
                UNNotificationAction(identifier:"OPEN_SUMMARY",title:"Open summary",options:.foreground),snooze
            ],intentIdentifiers:[],hiddenPreviewsBodyPlaceholder:"MergePro updates",options:[]),
            UNNotificationCategory(identifier:Self.pullRequestCategory,actions:[
                open,UNNotificationAction(identifier:"REVIEW_ITEM",title:"Approve…",options:.foreground),snooze
            ],intentIdentifiers:[],hiddenPreviewsBodyPlaceholder:"Pull request update",options:[]),
            UNNotificationCategory(identifier:Self.subjectCategory,actions:[open,snooze],intentIdentifiers:[],hiddenPreviewsBodyPlaceholder:"MergePro update",options:[])
        ])
    }
    func post(_ summary: PollSummary) async throws {
        guard await isEnabled() else { throw DeliveryFailure.disabled }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { throw DeliveryFailure.notAuthorized }
        guard !summary.items.isEmpty else {
            let content = UNMutableNotificationContent()
            content.title = summary.title; content.body = summary.body; content.categoryIdentifier = Self.category
            content.userInfo = ["cycleID":summary.cycleID.uuidString,"eventKeys":summary.eventKeys]
            try await center.add(UNNotificationRequest(identifier:Self.summaryIdentifier,content:content,trigger:nil))
            return
        }
        let showTitles = showsTitles()
        for item in summary.items {
            let text = item.content(showingTitles:showTitles)
            let content = UNMutableNotificationContent()
            content.title = text.title; content.subtitle = text.subtitle; content.body = text.body
            content.categoryIdentifier = item.offersReview ? Self.pullRequestCategory : Self.subjectCategory
            content.threadIdentifier = [item.account.host,item.account.accountID,item.repositoryName ?? ""].joined(separator:"/")
            var info: [String:Any] = ["cycleID":summary.cycleID.uuidString,"eventKeys":item.eventKeys]
            if let key = item.pullRequest { info["pullRequest"] = [key.host,key.accountID,key.repositoryID,key.objectID] }
            if let url = item.webURL { info["webURL"] = url.absoluteString }
            content.userInfo = info
            // One identifier per subject: a later update to the same pull request replaces its notification.
            try await center.add(UNNotificationRequest(identifier:Self.itemIdentifierPrefix + item.id,content:content,trigger:nil))
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request, info = request.content.userInfo, action = response.actionIdentifier
        guard let raw = info["cycleID"] as? String, let id = UUID(uuidString:raw) else { return }
        if action == "SNOOZE" { await deliver(.snooze(id)); return }
        if request.identifier == Self.summaryIdentifier {
            if action == "OPEN_SUMMARY" || action == UNNotificationDefaultActionIdentifier { await deliver(.open(id)) }
            return
        }
        guard request.identifier.hasPrefix(Self.itemIdentifierPrefix) else { return }
        let parts = info["pullRequest"] as? [String]
        let key = parts.flatMap { $0.count == 4 ? ProviderKey(host:$0[0],accountID:$0[1],repositoryID:$0[2],objectID:$0[3]) : nil }
        let target = Target(cycleID:id,eventKeys:info["eventKeys"] as? [String] ?? [],pullRequest:key,webURL:(info["webURL"] as? String).flatMap(URL.init(string:)))
        if action == "REVIEW_ITEM" { await deliver(.review(target)) }
        else if action == "OPEN_ITEM" || action == UNNotificationDefaultActionIdentifier { await deliver(.open(target)) }
    }
    private func deliver(_ action: Action) async {
        if let onAction { await onAction(action) } else { pendingAction = action }
    }
    private func deliver(_ action: PullRequestAction) async {
        if let onPullRequestAction { await onPullRequestAction(action); return }
        // Setup has not loaded yet; the action is delivered once a handler is installed.
        guard onAction != nil else { pendingPullRequestAction = action; return }
        switch action {
        case .open(let target), .review(let target):
            if let key = target.pullRequest { NSWorkspace.shared.open(key.routeURL) } else { await deliver(.open(target.cycleID)) }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard await isEnabled() else { return [] }
        return [.banner,.list]
    }
}
