import AppKit
import SwiftUI
import MergeProCore

/// Activity grouped by pull request (per account), newest first, with reason filters. Select one or more groups
/// and choose Done (or press e) to mark them read in MergePro; j/k move, Return or a double-click opens the PR.
/// GitHub's own read state changes only from the Mark Read menu's explicit GitHub commands.
struct ActivityInboxView: View {
    @Bindable var model: SetupModel
    @Environment(\.openWindow) private var openWindow
    @State private var action:PRActionPresentation?
    @State private var selection: Set<String> = []
    @State private var reason: ActivityReason?
    @State private var unreadOnly = false
    /// Cached pull requests by key and by number, rebuilt when the rows change.
    @State private var lookup = ActivityInbox.PRLookup(rows: [])
    @State private var marking = false
    private var events: [InboxEvent] {
        guard let keys = model.summaryEventKeys else { return model.inboxEvents }
        let selected = Set(keys); return model.inboxEvents.filter { selected.contains($0.id) }
    }
    var body: some View {
        let events = events
        let groups = ActivityInbox.groups(events, reasons: reason.map { [$0] }, unreadOnly: unreadOnly)
        VStack(spacing:0) {
            WorkspaceSectionHeader(title: model.summaryEventKeys == nil ? "Activity inbox" : "Poll summary",
                subtitle: "Reviews, checks, and updates from your tracked repositories.", symbol: "tray") {
                WorkspaceStatusBadge(text: "\(events.filter { !$0.acknowledged }.count) unread", symbol: "envelope.badge", tint: DesignTokens.cobalt)
                if model.summaryEventKeys != nil { Button("All activity") { model.summaryEventKeys = nil } }
                Button { markDone(selection, in: groups) } label: { Label("Done", systemImage: "checkmark.circle") }
                    .disabled(selection.isEmpty || marking)
                    .help("Mark the selected activity read in MergePro (E). GitHub is not changed.")
                    .accessibilityIdentifier("activityDone")
                Button { Task { await refresh() } } label: {
                    if model.isRefreshing { ProgressView("Refreshing…").controlSize(.small) }
                    else { Label("Refresh",systemImage:"arrow.clockwise") }
                }
                    .disabled(model.isRefreshing)
                    .accessibilityIdentifier("refreshActivity")
            }
            filters(events)
            Divider().padding(.horizontal, 24)
            if events.isEmpty && !model.inboxLoaded {
                ProgressView("Loading activity…").controlSize(.small).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if events.isEmpty {
                ContentUnavailableView("No activity yet",systemImage:"tray",description:Text("Updates from tracked repositories appear here. System summaries are optional."))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if groups.isEmpty {
                ContentUnavailableView("No matching activity",systemImage:"line.3.horizontal.decrease.circle",description:Text("Change the reason or show read items."))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ForEach(groups) { group in groupRow(group).tag(group.id).id(group.id) }
                    }
                    .contextMenu(forSelectionType: String.self) { ids in
                        Button("Open Pull Request") { openFirst(ids, in: groups) }.disabled(prKey(ids, in: groups) == nil)
                        Button("Done") { markDone(ids, in: groups) }.disabled(marking)
                    } primaryAction: { ids in openFirst(ids, in: groups) }
                    .background {
                        PRKeyboardMonitor(listIdentifier: "activityInbox") { key in handleKey(key, groups: groups, proxy: proxy) }
                    }
                    .scrollContentBackground(.hidden)
                    .workspacePanel(radius: 16)
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .accessibilityIdentifier("activityInbox")
                }
            }
            if let status = model.pollStatus { Text(status).font(.caption).foregroundStyle(.secondary).padding(.horizontal,24).padding(.vertical,10) }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        .background { WorkspaceCanvas() }
        .navigationTitle("MergePro").navigationSubtitle("Activity")
        .sheet(item:$action) { PRActionSheet(presentation:$0,workspace:model.prs) }
        .task(id: model.prs.pipeline.stackRevision) { lookup = ActivityInbox.PRLookup(rows: model.prs.rows) }
        .onChange(of: groups.map(\.id)) { _, ids in selection.formIntersection(ids) }
    }

    private func filters(_ events: [InboxEvent]) -> some View {
        let counts = ActivityInbox.counts(events)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Picker("Reason", selection: $reason) {
                    Text("All reasons (\(events.count))").tag(ActivityReason?.none)
                    ForEach(ActivityReason.allCases.filter { counts[$0] != nil }, id: \.self) { reason in
                        Text("\(reason.title) (\(counts[reason] ?? 0))").tag(Optional(reason))
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("activityReason")
                Toggle("Unread only", isOn: $unreadOnly).toggleStyle(.checkbox).accessibilityIdentifier("activityUnreadOnly")
                Spacer(minLength: 0)
            }
            // Said once here rather than on every row: read marks are local unless an item is changed on GitHub.
            Text("Read marks are kept in MergePro. GitHub's read state is unknown unless you change an item on GitHub from its Mark Read menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.bottom, 10)
    }

    private func groupRow(_ group: ActivityGroup) -> some View {
        let newest = group.newest
        let key = group.events.lazy.compactMap { lookup.key(for: $0.event) }.first
        let pr = key.flatMap { model.prs.cached($0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment:.top, spacing: 12) {
                Image(systemName: group.unread > 0 ? "envelope.badge" : "envelope.open")
                    .font(.title3).foregroundStyle(group.unread > 0 ? DesignTokens.cobalt : Color.secondary)
                    .frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment:.leading, spacing:4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(newest.event.title ?? category(newest.event.category)).font(.headline).lineLimit(2)
                        Spacer(minLength: 8)
                        relativeTime(newest.event.occurredAt)
                    }
                    Text(context(newest.event)).font(.caption).foregroundStyle(.secondary)
                    ForEach(group.events.prefix(4)) { item in eventLine(item) }
                    if group.events.count > 4 {
                        Text("\(group.events.count - 4) earlier \(group.events.count - 4 == 1 ? "update" : "updates")").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(groupSummary(group))
            actions(group, key: key, pr: pr).padding(.leading, 44)
        }
        .padding(.vertical, 8)
    }

    private func relativeTime(_ date: Date) -> some View {
        Text(date, format: .relative(presentation: .named))
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            .help(date.formatted(date: .abbreviated, time: .shortened))
    }

    /// One update: its reason and time, an unread dot, and any GitHub change in flight or settled for it.
    private func eventLine(_ item: InboxEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(item.acknowledged ? Color.clear : DesignTokens.cobalt).frame(width: 6, height: 6)
                    .overlay(Circle().strokeBorder(item.acknowledged ? Color.secondary.opacity(0.5) : .clear, lineWidth: 1))
                Text(category(item.event.category))
                Text(item.event.occurredAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
            }
            .font(.caption)
            providerState(item)
        }
    }

    @ViewBuilder private func providerState(_ item: InboxEvent) -> some View {
        if model.inboxPending.contains(item.id) { Text("Changing GitHub…").font(.caption).padding(.leading, 12) }
        if let failure=model.inboxFailures[item.id] {
            Text("GitHub change failed: "+failure).font(.caption).foregroundStyle(.orange).padding(.leading, 12)
        }
        if let operation=model.inboxOperations[item.id] {
            Group {
                switch operation.state {
                case .confirmed: Text("GitHub confirmed \(operation.command.intent == .read ? "read" : "done")")
                case .rejected: Text("GitHub did not apply the change")
                default: Text("GitHub's result is unknown until you read it")
                }
            }
            .font(.caption).foregroundStyle(operation.state == .confirmed ? Color.secondary : .orange).padding(.leading, 12)
            if let message=operation.message,operation.state != .confirmed { Text(message).font(.caption).textSelection(.enabled).padding(.leading, 12) }
            if operation.state != .confirmed && operation.state != .rejected {
                Link("Open GitHub inbox",destination:URL(string:"https://github.com/notifications")!).font(.caption).padding(.leading, 12)
            }
        }
    }

    @ViewBuilder private func actions(_ group: ActivityGroup, key: ProviderKey?, pr: PullRequest?) -> some View {
        // The newest GitHub notification thread in the group; GitHub commands act on it explicitly.
        let thread = group.events.first { (try? NotificationThreadCommand(event: $0.event, intent: .read)) != nil }
        let unresolved = group.events.compactMap { item in
            model.inboxOperations[item.id].flatMap { [.prepared,.sending,.uncertain].contains($0.state) ? $0 : nil }
        }
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button("Open") { if let key { open(key) } }
                    .disabled(key == nil)
                    .help(key == nil ? "This pull request isn't cached for this account in MergePro." : "Open in MergePro")
                    .accessibilityLabel("Open pull request")
                if let url = group.events.lazy.compactMap({ $0.event.locator?.webURL }).first, url.scheme == "https",url.host == "github.com",url.user == nil,url.password == nil,(url.port ?? 443) == 443 {
                    Button("Open on GitHub") { ExternalLinkPolicy.open(url) }
                }
                if let pr {
                    if PRMenuBarRules.offersApproval(row: pr, actionPR: model.prs.actionPRCached(pr)) {
                        Button("Approve…") { action = .init(rows:[pr],kind:.review(.approve)) }
                    }
                    // Merging acts as the action account: the sheet only for its own copy of this row, else the PR opens.
                    let eligibility = model.prs.mergeEligibility(pr)
                    let route = PRMenuBarRules.mergeRoute(row: pr, actionPR: model.prs.actionPRCached(pr))
                    Button(eligibility.label+"…") {
                        switch route {
                        case .mergeSheet: action = .init(rows:[pr],kind:.merge(nil))
                        case .openPullRequest: open(pr.key)
                        }
                    }
                    .disabled(!eligibility.opensMergeSheet)
                    .help(route == .mergeSheet ? "Open merge options" : "Opens the pull request: merging acts as the selected account, which is not this pull request's account.")
                }
                Menu {
                    Button("Mark Read in MergePro") { markDone([group.id], in: [group]) }.disabled(group.unread == 0 || marking)
                    if let thread, let command = try? NotificationThreadCommand(event: thread.event, intent: .read) {
                        let blocked = model.inboxPending.contains(thread.id) || !unresolved.isEmpty || model.activeAccount != command.account || model.accountProblems[command.account] != nil
                        Divider()
                        Button("Mark Read on GitHub") { Task { await change(thread, intent: .read) } }.disabled(blocked)
                        Button("Done on GitHub") { Task { await change(thread, intent: .done) } }.disabled(blocked)
                        if model.activeAccount != command.account { Text("Act as this item's account to change GitHub") }
                    }
                } label: {
                    Label("Mark Read", systemImage: "envelope.open")
                } primaryAction: {
                    markDone([group.id], in: [group])
                }
                .fixedSize()
                .help("Mark read in MergePro. Open the menu to mark read or done on GitHub.")
                ForEach(unresolved) { operation in
                    let pending = model.inboxPending.contains(operation.command.eventKey)
                    if operation.state == .prepared { Button("Release unsent command") { Task { await model.releaseUnsentNotification(operation) } }.disabled(pending) }
                    else { Button("Read provider result") { Task { await model.reconcileNotification(operation) } }.disabled(pending) }
                }
            }
        }.scrollIndicators(.hidden)
    }

    private func groupSummary(_ group: ActivityGroup) -> String {
        let newest = group.newest.event
        let reasons = group.reasons.map(\.title).joined(separator: ", ")
        let unread = group.unread == 0 ? "read" : "\(group.unread) unread"
        return "\(newest.title ?? category(newest.category)), \(context(newest)), \(reasons), \(unread), \(newest.occurredAt.formatted(.relative(presentation: .named)))"
    }
    private func context(_ event: ChangeEvent) -> String {
        let key = event.object
        let snapshot=model.snapshots.first { $0.account?.scope == key.account && model.accountProblems[key.account] == nil }
        let login=snapshot?.account?.login ?? "Account unavailable"
        let repository=snapshot?.repositories.first { $0.key == key.repository }?.name ?? "Repository unavailable"
        let number = event.locator?.subjectNumber.map { " #" + $0 } ?? ""
        return "\(repository)\(number) · \(login) · \(key.host)"
    }
    private func category(_ value:String) -> String {
        switch value {
        case "merged":"Pull request merged"
        case "review decision":"Review updated"
        case "checks","CI activity signals":"Checks updated"
        case "review requested","review request signals":"Review requested"
        case "mention signals":"Mentioned you"
        case "assignment signals":"Assignment updated"
        case "ready to merge":"Ready to merge"
        case "ready for merge queue":"Ready for merge queue"
        default:"Repository activity"
        }
    }

    // MARK: Actions

    private func prKey(_ ids: Set<String>, in groups: [ActivityGroup]) -> ProviderKey? {
        groups.first { ids.contains($0.id) }.flatMap { group in group.events.lazy.compactMap { lookup.key(for: $0.event) }.first }
    }
    private func openFirst(_ ids: Set<String>, in groups: [ActivityGroup]) {
        if let key = prKey(ids, in: groups) { open(key) }
        else if !ids.isEmpty { AccessibilityNotification.Announcement("This pull request isn't cached for this account in MergePro.").post() }
    }
    private func open(_ key: ProviderKey) {
        model.prs.recordOpen(key)
        openWindow(id: "pr-detail", value: key)
    }
    /// Marks every unread update in the chosen groups read in MergePro only; GitHub is unchanged.
    private func markDone(_ ids: Set<String>, in groups: [ActivityGroup]) {
        let keys = groups.filter { ids.contains($0.id) }.flatMap(\.events).filter { !$0.acknowledged }.map(\.id)
        guard !keys.isEmpty, !marking else { return }
        marking = true
        Task {
            var failed = 0
            for key in keys {
                do { try await model.featureStorage.acknowledgeActivity(key) } catch { failed += 1 }
            }
            await model.reloadActivity()
            marking = false
            let done = keys.count - failed
            let message = failed == 0 ? "Marked \(done) \(done == 1 ? "update" : "updates") read in MergePro."
                : "\(failed) of \(keys.count) updates could not be marked read."
            if failed > 0 { model.pollStatus = message }
            AccessibilityNotification.Announcement(message).post()
        }
    }
    private func change(_ item: InboxEvent, intent: NotificationThreadIntent) async {
        await model.changeNotification(item, intent: intent)
        let message: String
        if let failure = model.inboxFailures[item.id] { message = "GitHub change failed: " + failure }
        else if let operation = model.inboxOperations[item.id] {
            message = switch operation.state {
            case .confirmed: "GitHub confirmed \(intent == .read ? "read" : "done")."
            case .rejected: "GitHub did not apply the change."
            default: "GitHub's result is unknown. Read it again shortly."
            }
        } else { return }
        AccessibilityNotification.Announcement(message).post()
    }
    private func refresh() async {
        await model.refreshActivity()
        let unread = model.inboxEvents.filter { !$0.acknowledged }.count
        AccessibilityNotification.Announcement(model.pollStatus.map { "\($0). \(unread) unread." } ?? "\(unread) unread.").post()
    }
    /// j/k move the selection between groups, e marks the selection done, Return opens its pull request.
    private func handleKey(_ key: String, groups: [ActivityGroup], proxy: ScrollViewProxy) -> Bool {
        let ids = groups.map(\.id)
        switch key {
        case "j", "k":
            guard !ids.isEmpty else { return true }
            let positions = ids.indices.filter { selection.contains(ids[$0]) }
            let next = key == "j" ? min((positions.max() ?? -1) + 1, ids.count - 1) : max((positions.min() ?? ids.count) - 1, 0)
            selection = [ids[next]]
            proxy.scrollTo(ids[next])
            return true
        case "e":
            markDone(selection, in: groups)
            return true
        case "\r":
            guard !selection.isEmpty else { return false }
            openFirst(selection, in: groups)
            return true
        default:
            return false
        }
    }
}
