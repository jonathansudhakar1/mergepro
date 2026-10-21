import AppKit
import SwiftUI
import MergeProCore

enum SettingsTab: Hashable { case general, accounts, notifications, code, local, advanced }

/// The Settings scene, one pane per area. Every control saves only on its own explicit action.
struct MergeProSettings: View {
    @Bindable var model: SetupModel
    @State private var tab = SettingsTab.general
    var body: some View {
        TabView(selection:$tab) {
            Tab("General",systemImage:"gearshape",value:.general) { GeneralSettingsPane(model:model) }
            Tab("Accounts",systemImage:"person.crop.circle",value:.accounts) { AccountSettingsPane(model:model) }
            Tab("Notifications",systemImage:"bell.badge",value:.notifications) { NotificationSettingsPane(model:model) }
            Tab("Code",systemImage:"chevron.left.forwardslash.chevron.right",value:.code) { SettingsPane(model:model) { CodeSettings(model:model) } }
            Tab("Local",systemImage:"folder",value:.local) { SettingsPane(model:model) { LocalSettings(model:model) } }
            Tab("Advanced",systemImage:"gearshape.2",value:.advanced) { SettingsPane(model:model) { Section { GlobalHotkeySettings(model:model) } header: { Text("Global shortcuts") } footer: {
                Text("Turn a shortcut on, choose its modifiers and key, then save. \(model.globalHotkeyStatus)").font(.callout).foregroundStyle(.secondary)
            } } }
        }
        // Each pane gets a height that fits its content, so short panes don't leave empty space.
        .frame(width:640,height:Self.height(tab))
        .animation(.default,value:tab)
        .navigationTitle("MergePro Settings")
        .background { SettingsWindowTitle(title:"MergePro Settings") }
        .onDisappear { model.cancelAuthorization() }
    }
    private static func height(_ tab:SettingsTab) -> CGFloat {
        switch tab { case .general:440; case .accounts:340; case .notifications:620; case .code:660; case .local:520; case .advanced:340 }
    }
}

/// A grouped form with the latest setup message on top, so results stay visible without scrolling.
private struct SettingsPane<Content: View>: View {
    @Bindable var model: SetupModel
    let content: Content
    init(model: SetupModel, @ViewBuilder content: () -> Content) { self.model = model; self.content = content() }
    var body: some View {
        Form {
            if let message = model.message {
                Section {
                    HStack(alignment:.firstTextBaseline) {
                        Image(systemName:"info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(message).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { model.message = nil }
                    }
                }
            }
            content
        }.formStyle(.grouped)
    }
}

private struct GeneralSettingsPane: View {
    @Bindable var model: SetupModel
    var body: some View {
        SettingsPane(model:model) {
            Section("Preferences") { SetupPreferences(model:model) }
            Section {
                LabeledContent("Public client ID") {
                    HStack(spacing:8) {
                        TextField("Public client ID",text:$model.clientID,prompt:Text("Ov23…")).labelsHidden()
                            .textFieldStyle(.roundedBorder).font(.body.monospaced()).multilineTextAlignment(.leading)
                            .frame(maxWidth:260).accessibilityIdentifier("githubClientID")
                        Button("Save configuration") { Task { await model.saveClientID() } }.disabled(model.isLoading)
                    }
                }
            } header: { Text("GitHub OAuth App") } footer: {
                Text("Enable device flow in your OAuth App on GitHub. MergePro uses this public client ID and never requires a client secret. The repo permission includes broad repository access.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Appearance") { Text("MergePro follows your Mac’s appearance and accessibility preferences.").foregroundStyle(.secondary) }
        }
    }
}

private struct AccountSettingsPane: View {
    @Bindable var model: SetupModel
    @State private var removing: Account?
    /// Removal deletes local credentials only; GitHub keeps the grant until the user revokes it there.
    @State private var revocation: GitHubGrantLink?
    var body: some View {
        SettingsPane(model:model) {
            Section("Accounts") {
                if model.snapshots.isEmpty { Label("No accounts connected",systemImage:"person.crop.circle") }
                ForEach(model.snapshots,id:\.account?.scope) { snapshot in
                    if let account = snapshot.account {
                        HStack {
                            Text(account.login)
                            Spacer()
                            Button(model.activeAccount == account.scope ? "Active account" : "Use account") { Task { await model.selectAccount(account.scope) } }
                                .disabled(model.activeAccount == account.scope)
                            Button("Reconnect") { model.connect(replacing:account.scope) }.disabled(model.isConnecting)
                            Button("Remove…",role:.destructive) { removing = account }
                        }
                        if let problem = model.accountProblems[account.scope] { Text(problem).foregroundStyle(.orange) }
                    }
                }
                Button("Connect GitHub account") { model.connect() }.disabled(model.clientID.isEmpty || model.isConnecting || model.isLoading)
                AuthorizationPrompt(model:model)
            }
            if let revocation {
                Section("Revoke access on GitHub") {
                    Text("\(revocation.login) was removed from this Mac. GitHub still lists MergePro as an authorized app for that account until you revoke it there.")
                    HStack {
                        Link("Open authorized apps on \(revocation.host)",destination:revocation.url)
                        Spacer()
                        Button("Done") { self.revocation = nil }
                    }
                }
            }
        }
        .alert("Remove \(removing?.login ?? "account")?",isPresented:Binding(get:{ removing != nil },set:{ if !$0 { removing = nil } })) {
            Button("Remove account",role:.destructive) {
                if let account = removing {
                    let link = GitHubGrantLink(login:account.login,host:account.scope.host,clientID:model.clientID)
                    Task {
                        await model.remove(account.scope)
                        guard !model.snapshots.contains(where:{ $0.account?.scope == account.scope }) else { return }
                        revocation = link
                        AccessibilityNotification.Announcement("\(account.login) removed. Revoke MergePro on GitHub to end its access.").post()
                    }
                }
                removing = nil
            }
            Button("Cancel",role:.cancel) { removing = nil }
        } message: { Text("Remove its Keychain credentials and private cached data from this Mac. Unsent drafts remain private locally. This does not revoke MergePro’s access on GitHub; a link to do that appears afterwards.") }
    }
}

/// GitHub's page for this OAuth app's grant on one host, where the user can revoke it.
struct GitHubGrantLink: Equatable {
    let login: String
    let host: String
    let url: URL
    init(login: String, host: String, clientID: String) {
        self.login = login; self.host = host
        url = Self.url(host:host,clientID:clientID)
    }
    /// The app's own grant page when the client ID is a plain identifier; otherwise the list of authorized OAuth apps.
    static func url(host: String, clientID: String) -> URL {
        let id = clientID.trimmingCharacters(in:.whitespacesAndNewlines)
        let plain = !id.isEmpty && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
        var components = URLComponents()
        components.scheme = "https"; components.host = host.isEmpty ? "github.com" : host
        components.path = plain ? "/settings/connections/applications/" + id : "/settings/applications"
        return components.url ?? URL(string:"https://github.com/settings/applications")!
    }
}

private struct NotificationSettingsPane: View {
    @Bindable var model: SetupModel
    @AppStorage(SystemNotificationSink.showTitlesKey) private var showTitles = false
    @State private var preferences = NotificationPreferences()
    /// Controls stay disabled until the saved preferences are read; a failed read is shown, never guessed.
    @State private var loaded = false
    @State private var status: String?
    @State private var repositorySearch = ""
    /// The quiet-hours bounds the pickers show, edited locally and always saved together, so a quick edit of one never
    /// saves the other from an older read. Remembered while quiet hours are off, so turning them back on restores the
    /// user's hours rather than 22:00–07:00.
    @AppStorage("notificationsQuietHoursStartMinute") private var quietStart = 22*60
    @AppStorage("notificationsQuietHoursEndMinute") private var quietEnd = 7*60
    /// Quiet-hours saves run one after another; a reread adopts the stored bounds only when no newer save is pending.
    @State private var quietSave: Task<Void,Never>?
    @State private var quietSavesPending = 0
    private var storage: SetupStorage { model.featureStorage }
    private var accounts: [Account] { model.snapshots.compactMap(\.account) }
    var body: some View {
        SettingsPane(model:model) {
            Section("System notifications") {
                Toggle("Enable system notifications",isOn:Binding(get:{ model.notificationsEnabled },set:{ enabled in Task { await model.setNotifications(enabled) } }))
                Text(model.notificationStatus).font(.callout).foregroundStyle(.secondary)
                Toggle("Show pull request titles in notifications",isOn:$showTitles).accessibilityIdentifier("notificationTitlesPreference")
                Text("Off by default, because titles of private pull requests can appear on the lock screen. Notifications always name the repository and pull request number. More than \(NotificationAggregator.individualLimit) updates in one refresh arrive as one summary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Snooze") {
                Picker("Snooze from a notification for",selection:Binding(get:{ preferences.snooze },set:{ value in save { try await storage.setNotificationSnooze(value) } })) {
                    ForEach(NotificationSnooze.allCases,id:\.self) { Text($0.label).tag($0) }
                }
                TimelineView(.periodic(from:.now,by:30)) { context in
                    HStack {
                        if let until = preferences.snoozedUntil, until > context.date {
                            Text("Snoozed until " + until.formatted(date:Calendar.current.isDateInToday(until) ? .omitted : .abbreviated,time:.shortened))
                            Spacer()
                            Button("Resume now") { save { try await storage.resumeNotifications() } }
                        } else {
                            Text("Not snoozed").foregroundStyle(.secondary)
                            Spacer()
                            Button("Snooze now") { save { _ = try await storage.snoozeNotifications() } }
                        }
                    }
                }
            }.disabled(!loaded)
            Section("Quiet hours") {
                Toggle("Hold notifications during quiet hours",isOn:Binding(get:{ preferences.quietHoursEnabled },set:{ enabled in saveQuietHours(enabled:enabled) }))
                if preferences.quietHoursEnabled {
                    DatePicker("From",selection:quietBinding($quietStart),displayedComponents:.hourAndMinute)
                    DatePicker("To",selection:quietBinding($quietEnd),displayedComponents:.hourAndMinute)
                }
                Text("Updates that arrive while snoozed or during quiet hours are notified when that ends. The in-app inbox always lists them.").font(.caption).foregroundStyle(.secondary)
            }.disabled(!loaded)
            Section("Muted accounts") {
                if accounts.isEmpty { Text("No accounts connected").foregroundStyle(.secondary) }
                ForEach(accounts,id:\.scope) { account in
                    Toggle("Mute \(account.login)",isOn:Binding(get:{ preferences.mutedAccounts.contains(account.scope) },set:{ muted in
                        save { try await storage.setNotificationsMuted(muted,account:account.scope) }
                    }))
                }
            }.disabled(!loaded)
            Section("Muted repositories") {
                let repositories = trackedRepositories
                if repositories.count > 8 { TextField("Search tracked repositories",text:$repositorySearch).textFieldStyle(.roundedBorder) }
                if repositories.isEmpty { Text("No tracked repositories").foregroundStyle(.secondary) }
                ForEach(repositories.filter { repositorySearch.isEmpty || $0.name.localizedCaseInsensitiveContains(repositorySearch) },id:\.key) { repository in
                    Toggle(isOn:Binding(get:{ preferences.mutedRepositories.contains(repository.key) },set:{ muted in
                        save { try await storage.setNotificationsMuted(muted,repository:repository.key) }
                    })) {
                        Text(repository.name)
                        if accounts.count > 1 { Text(accounts.first { $0.scope == repository.key.account }?.login ?? repository.key.account.accountID) }
                    }
                }
            }.disabled(!loaded)
            if let status { Section { Text(status).foregroundStyle(.orange) } }
        }
        .task { await load() }
    }
    private var trackedRepositories: [Repository] {
        model.snapshots.flatMap { snapshot in snapshot.repositories.filter { snapshot.trackedRepositories.contains($0.key) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// One bound as a time of day: a change updates it locally, then saves both bounds.
    private func quietBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(get:{ Calendar.current.date(bySettingHour:minute.wrappedValue/60,minute:minute.wrappedValue%60,second:0,of:Date()) ?? Date() },
                set:{ date in
                    let parts = Calendar.current.dateComponents([.hour,.minute],from:date)
                    let value = (parts.hour ?? 0)*60 + (parts.minute ?? 0)
                    guard value != minute.wrappedValue else { return }
                    minute.wrappedValue = value
                    saveQuietHours(enabled:true)
                })
    }
    /// Saves both current bounds (or turns quiet hours off, keeping the bounds for next time), after any earlier
    /// quiet-hours save, then rereads what is stored.
    private func saveQuietHours(enabled: Bool) {
        let start = enabled ? quietStart : nil, end = enabled ? quietEnd : nil
        quietSavesPending += 1
        let previous = quietSave
        quietSave = Task {
            await previous?.value
            do { try await storage.setQuietHours(startMinute:start,endMinute:end);status = nil } catch { status = "This notification setting could not be saved." }
            quietSavesPending -= 1
            await load()
        }
    }
    /// Saves, then rereads what is stored, so the pane never shows a value that was not saved.
    private func save(_ change: @escaping () async throws -> Void) {
        Task {
            do { try await change();status = nil } catch { status = "This notification setting could not be saved." }
            await load()
        }
    }
    private func load() async {
        do {
            let stored = try await storage.notificationPreferences()
            preferences = stored;loaded = true
            // Stored hours are what the pickers show, unless a newer edit is still being saved.
            if quietSavesPending == 0,let start = stored.quietStartMinute,let end = stored.quietEndMinute { quietStart = start;quietEnd = end }
        }
        catch { loaded = false;status = "Notification settings could not be read from local storage." }
    }
}

/// Keeps the Settings window titled "MergePro Settings" while its toolbar tabs change panes.
private struct SettingsWindowTitle: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> TitleView { TitleView(title:title) }
    func updateNSView(_ view: TitleView, context: Context) { view.title = title;view.apply() }
    final class TitleView: NSView {
        var title: String
        private var observation: NSKeyValueObservation?
        init(title: String) { self.title = title;super.init(frame:.zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.title,options:[.new]) { [weak self] _,_ in MainActor.assumeIsolated { self?.apply() } }
            apply()
        }
        func apply() { if let window, window.title != title { window.title = title } }
    }
}
