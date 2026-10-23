import SwiftUI
import MergeProCore

struct OnboardingView: View {
    @Bindable var model: SetupModel
    @State private var disconnecting: Account?
    @State private var revocation: GitHubGrantLink?
    var body: some View {
        VStack(spacing:0) {
            WorkspaceSectionHeader(title: "Set up your workspace",
                subtitle: "Connect GitHub accounts and choose the repositories you want to follow.",
                symbol: "person.crop.circle.badge.plus") {
                WorkspaceStatusBadge(text: "\(model.snapshots.count) \(model.snapshots.count == 1 ? "account" : "accounts")", symbol: "person.crop.circle", tint: DesignTokens.cobalt)
            }
            ScrollView {
                VStack(alignment:.leading, spacing:24) {
                    if model.isLoading { ProgressView("Loading local setup…") }
                    if let message = model.message {
                        HStack(alignment:.top) { WorkspaceNotice(message: message); Button("Dismiss") { model.message = nil }.padding(.top, 12) }
                    }
                    VStack(alignment:.leading, spacing:12) {
                        HStack {
                            Label("GitHub accounts",systemImage:"person.crop.circle").font(.headline)
                            Spacer()
                            Button("Connect GitHub account") { model.connect() }
                                .disabled(model.clientID.isEmpty || model.isConnecting || model.isLoading || SampleMode.isActive)
                                .accessibilityIdentifier("connectGitHub")
                        }
                        if model.snapshots.isEmpty {
                            Text("No accounts connected")
                            Text("Your access tokens stay in this Mac’s Keychain. GitHub authorization requests repository, organization, profile, and notification access.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(model.snapshots, id:\.account?.scope) { snapshot in
                                if let account = snapshot.account {
                                    HStack {
                                        Label(account.login,systemImage:"person.crop.circle")
                                        if model.activeAccount == account.scope { Text("Active account").font(.caption).foregroundStyle(.secondary) }
                                        Spacer()
                                        if model.activeAccount != account.scope { Button("Use account") { Task { await model.selectAccount(account.scope) } } }
                                        Button("Reconnect") { model.connect(replacing:account.scope) }.disabled(model.isConnecting || SampleMode.isActive)
                                        Button("Disconnect…",role:.destructive) { disconnecting = account }.disabled(SampleMode.isActive)
                                    }
                                }
                            }
                        }
                        if model.clientID.isEmpty {
                            Text("Configure your GitHub OAuth App client ID in Settings and enable device flow in the app’s GitHub settings.").foregroundStyle(.secondary)
                            SettingsLink { Text("Configure GitHub") }
                        }
                        if revocation != nil { Divider();GitHubRevocationNotice(revocation:$revocation) }
                        if model.isConnecting { Divider() }
                        AuthorizationPrompt(model:model)
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading).workspacePanel()
                    sampleData
                    if let snapshot = model.snapshots.first(where:{ $0.account?.scope == model.activeAccount }), let account = snapshot.account {
                        repositoryScope(snapshot, account:account).id(account.scope)
                    }
                    VStack(alignment:.leading,spacing:12) { SetupPreferences(model:model) }.padding(16).frame(maxWidth:.infinity,alignment:.leading).workspacePanel()
                }.padding(.horizontal,24).padding(.bottom,24).frame(maxWidth:900,alignment:.leading).frame(maxWidth:.infinity,alignment:.leading)
            }
        }
        .background { WorkspaceCanvas() }
        .navigationTitle("MergePro").navigationSubtitle("Setup")
        .disconnectAccountConfirmation(model:model,account:$disconnecting,revocation:$revocation)
        .onDisappear { model.cancelAuthorization() }
    }
    /// Try the app without a GitHub account, or leave the sample data again.
    @ViewBuilder private var sampleData: some View {
        if SampleMode.isActive {
            HStack(alignment:.top,spacing:12) {
                Image(systemName:"sparkles").font(.title2).foregroundStyle(DesignTokens.cobalt).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:4) {
                    Text("You’re exploring sample data").font(.headline)
                    Text("The repositories, pull requests and people here are made up. Nothing is read from or sent to GitHub. Leave sample data to connect your own accounts; they were never touched.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength:8)
                Button("Leave Sample Data") { SampleMode.set(false) }.accessibilityIdentifier("leaveSampleData")
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading).workspacePanel()
        } else if model.snapshots.isEmpty && !model.isLoading {
            HStack(alignment:.top,spacing:12) {
                Image(systemName:"sparkles").font(.title2).foregroundStyle(DesignTokens.cobalt).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:4) {
                    Text("Just looking?").font(.headline)
                    Text("Explore the board, reviews and diffs with made-up repositories and pull requests. Nothing connects to GitHub, and you can leave at any time.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength:8)
                Button("Explore with Sample Data") { SampleMode.set(true) }.accessibilityIdentifier("exploreSampleData")
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading).workspacePanel()
        }
    }
    @ViewBuilder private func repositoryScope(_ snapshot: LocalSnapshot, account: Account) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Tracked repositories").font(.title2.bold())
                Spacer()
                TimelineView(.periodic(from:.now,by:1)) { context in
                    Button("Refresh discovery") { Task { await model.retryDiscovery(account.scope) } }
                        .disabled(model.discoveryBlocked(account.scope,at:context.date) || snapshot.settings[.authorizationProblem] == "true")
                }
            }
            Text("\(snapshot.trackedRepositories.count) tracked · \(snapshot.repositories.count) known for \(account.login)").foregroundStyle(.secondary)
            if let until = model.retryDeadlines[account.scope] {
                TimelineView(.periodic(from:.now,by:1)) { context in
                    if until > context.date { Text("GitHub rate limited this account. Retry after \(until.formatted(date:.omitted,time:.standard)).").foregroundStyle(.secondary) }
                }
            }
            if let problem = model.accountProblems[account.scope] { Text(problem).foregroundStyle(.orange).textSelection(.enabled) }
            if let issue = snapshot.settings[.discoveryIssues], !issue.isEmpty { Text(issue).foregroundStyle(.orange).textSelection(.enabled) }
            if model.discovering.contains(account.scope) { ProgressView("Discovering repositories and organizations…") }
            if snapshot.repositories.isEmpty, !model.discovering.contains(account.scope) {
                ContentUnavailableView("No repositories discovered",systemImage:"folder",description:Text("Refresh discovery or check GitHub organization access. Existing tracked scope stays saved when discovery is incomplete."))
            }
            SetupRepositoryScopeView(model:model,snapshot:snapshot,account:account)
                .id(account.scope)
        }
    }
}

struct AuthorizationPrompt: View {
    @Bindable var model: SetupModel
    var body: some View {
        if model.isConnecting {
            VStack(alignment:.leading, spacing:10) {
                if let code = model.userCode {
                    Text("Enter this code on GitHub").font(.headline)
                    HStack {
                        Text(code).font(.title.monospaced().bold()).textSelection(.enabled).accessibilityIdentifier("githubUserCode")
                        Button("Copy code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code,forType:.string) }
                    }
                    if let url = model.verificationURL { Text(url.absoluteString).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack {
                        Button("Open GitHub in browser") { model.openVerification() }.buttonStyle(.borderedProminent)
                        Button("Cancel connection") { model.cancelAuthorization() }
                    }
                    Text("Keep this window open while GitHub confirms your authorization. For a work account, establish organization SSO and confirm OAuth App approval before authorizing.").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Requesting a GitHub verification code…"); Button("Cancel connection") { model.cancelAuthorization() } }
                }
            }
        }
    }
}

struct SetupPreferences: View {
    @Bindable var model: SetupModel
    /// Separate rows, so each control gets its own row in Settings; Setup stacks them in a VStack.
    var body: some View {
        Toggle(isOn:Binding(get:{ model.notificationsEnabled },set:{ enabled in Task { await model.setNotifications(enabled) } })) {
            VStack(alignment:.leading,spacing:2) {
                Text("Enable system notifications")
                Text(model.notificationStatus).font(.callout).foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("notificationsPreference")
        Toggle("Launch MergePro at login",isOn:Binding(get:{ model.loginEnabled },set:{ model.setLoginEnabled($0) })).accessibilityIdentifier("loginPreference")
        if model.loginNeedsApproval { Button("Review Login Items in System Settings") { LoginItemService().openSettings() } }
    }
}
