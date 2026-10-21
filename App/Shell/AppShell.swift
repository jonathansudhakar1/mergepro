import SwiftUI
import MergeProCore

struct AppShell<Chrome: ViewModifier & Sendable>: View {
    @Bindable var model: SetupModel
    /// The entry point's additions: `EmptyModifier()` in the shipped app, measurement chrome in the fixture app.
    let chrome: Chrome
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image("AppLogo").resizable().scaledToFit()
                        .frame(width:40,height:40).accessibilityLabel("MergePro logo")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MergePro").font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text("Your review workspace").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
                List(selection:Binding<SetupModel.Destination?>(get:{ model.destination },set:{ if let value = $0 { model.destination = value } })) {
                    Section("Workspace") {
                        Label("Pull Requests",systemImage:"arrow.triangle.pull").tag(SetupModel.Destination.pullRequests).accessibilityIdentifier("prNavigation")
                        Label("Actions",systemImage:"play.circle").tag(SetupModel.Destination.actions).accessibilityIdentifier("actionsNavigation")
                        Label("Repositories",systemImage:"folder").tag(SetupModel.Destination.repos).accessibilityIdentifier("reposNavigation")
                        Label("Local",systemImage:"externaldrive").tag(SetupModel.Destination.local).accessibilityIdentifier("localNavigation")
                        Label("Activity inbox",systemImage:"tray").tag(SetupModel.Destination.activity)
                            .accessibilityIdentifier("activityNavigation")
                    }
                    Section("Saved views") {
                        ForEach(model.prs.state.views.filter { !$0.hidden }) { view in
                            let selected = model.destination == .pullRequests && model.prs.state.currentViewID == view.id
                            Button { model.prs.chooseView(view.id); model.destination = .pullRequests } label: {
                                Label {
                                    HStack(spacing: 6) {
                                        Text(view.name).fontWeight(selected ? .semibold : .regular).lineLimit(1).truncationMode(.tail)
                                        Spacer(minLength: 4)
                                        Text("\(model.prs.viewCounts[view.id] ?? 0)")
                                            .font(.system(.caption, design: .rounded).weight(.semibold)).monospacedDigit()
                                            // Cobalt alone is about 4.3:1 on its own tint; mixed toward the label color it stays legible.
                                            .foregroundStyle(selected ? DesignTokens.cobalt.mix(with: .primary, by: 0.45) : .secondary)
                                            .padding(.horizontal, 7).padding(.vertical, 2)
                                            .background(selected ? DesignTokens.cobalt.opacity(0.16) : Color.secondary.opacity(0.10), in: Capsule())
                                    }
                                } icon: {
                                    Image(systemName: view.icon).foregroundStyle(selected ? DesignTokens.cobalt : .secondary)
                                }
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .listRowBackground(selected ? RoundedRectangle(cornerRadius: 8).fill(DesignTokens.cobalt.opacity(0.10)).padding(.horizontal, 10) : nil)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    Section("Manage") {
                        Label("Setup", systemImage:"person.crop.circle.badge.plus").tag(SetupModel.Destination.setup)
                            .accessibilityIdentifier("setupNavigation")
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                VStack(alignment: .leading, spacing: DesignTokens.compactSpacing) {
                    Label(model.snapshots.isEmpty ? "No accounts connected" : "\(model.snapshots.count) \(model.snapshots.count == 1 ? "account" : "accounts") connected", systemImage: "person.crop.circle")
                        .font(DesignTokens.captionFont.weight(.medium))
                        .foregroundStyle(.secondary)
                    if model.snapshots.isEmpty {
                        // Nothing to scope yet; point to Setup instead of an empty account picker.
                        Button("Connect a GitHub account") { model.destination = .setup }
                            .buttonStyle(.link).font(DesignTokens.captionFont)
                            .accessibilityIdentifier("sidebarConnectAccount")
                    } else {
                        Picker("Account scope",selection:Binding<AccountScope?>(get:{ model.prs.state.accountFilter },set:{ model.prs.state.accountFilter = $0 })) {
                            Text("All accounts").tag(AccountScope?.none)
                            ForEach(model.snapshots.compactMap(\.account),id:\.scope) { account in Text("\(account.login) · \(account.scope.host)").tag(Optional(account.scope)) }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("prAccountScope")
                        .help("Accounts shown in workspaces")
                    }
                    if model.snapshots.count > 1 {
                        Picker("Action account",selection:Binding<AccountScope?>(get:{ model.activeAccount },set:{ if let value = $0 { Task { await model.selectAccount(value) } } })) {
                            ForEach(model.snapshots.compactMap(\.account),id:\.scope) { account in Text("Act as \(account.login)").tag(Optional(account.scope)) }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        .help("Account used for actions such as reviews and merges")
                    }
                    if SampleMode.isActive {
                        HStack(spacing: 6) {
                            Label("Sample data", systemImage: "sparkles").font(DesignTokens.captionFont.weight(.medium)).foregroundStyle(DesignTokens.cobalt)
                            Spacer(minLength: 0)
                            Button("Leave") { SampleMode.set(false) }.controlSize(.small).help("Return to your own accounts")
                        }
                    }
                    Divider().padding(.vertical, 2)
                    HStack {
                        SettingsLink {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("sidebarSettings")
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .workspaceGlass(radius: 16)
                .padding(12)
            }
            .background { WorkspaceCanvas() }
            .navigationSplitViewColumnWidth(
                min: DesignTokens.sidebarMinimumWidth,
                ideal: DesignTokens.sidebarIdealWidth,
                max: DesignTokens.sidebarMaximumWidth
            )
        } detail: {
            switch model.destination {
            case .pullRequests: PRWorkspaceView(setup:model,workspace:model.prs)
            case .setup: OnboardingView(model:model)
            case .activity: ActivityInboxView(model:model)
            case .actions:
                ActionsView(storage:model.featureStorage,repositories:model.actionRepositories,
                    accountFilter:model.actionsRepository?.account ?? model.prs.state.accountFilter,
                    repositoryFilter:model.actionsRepository,runID:model.actionRunID,workflowID:model.actionWorkflowID,presetID:model.actionPresetID,
                    onOpenAnnotation:{ repo,ref,path,line in model.showRepository(.init(repository:repo.key,ref:ref,path:path,section:"code",line:line)) },refreshID:model.pollRevision)
                    .modifier(VisibleActionsRepository(storage:model.featureStorage,repository:model.actionsRepository))
                    // An unfiltered Actions list shows every action repository: all of them are on screen.
                    .modifier(FocusedRepositories(storage:model.featureStorage,repositories:model.actionsRepository == nil ? Set(model.actionRepositories.map(\.key)) : []))
                    .id(model.featureGeneration.uuidString + String(model.actionRunID ?? 0) + String(model.actionWorkflowID ?? 0))
                    .navigationTitle("MergePro").navigationSubtitle("Actions")
            case .repos:
                ReposView(setup:model,storage:model.featureStorage,pullRequests:{ key in
                    AnyView(RepositoryPRWorkspace(setup:model,repository:key))
                },actions:{ key in
                    AnyView(RepositoryActionsWorkspace(setup:model,repository:key))
                },openPR:{ key in
                    // The detail route reads its own repository-scoped rows, so the window opens at once; only a PR
                    // missing from the board's cache (e.g. just created) waits for a local reload to record the visit.
                    openWindow(id:"pr-detail",value:key)
                    if model.prs.cached(key) != nil { model.prs.recordOpen(key) } else { Task { await model.prs.reload();model.prs.recordOpen(key) } }
                },route:model.repoRoute)
                // Requesting the current route again rebuilds the browser, which then opens that route.
                .id(model.featureGeneration.uuidString+"|\(model.repoRouteRepeat)")
                .navigationTitle("MergePro").navigationSubtitle("Repositories")
            case .local:
                LocalView(folderStore:model.localFolders,checkout:model.localCheckout,
                    editorPreference:{
                        let name = await AppLog.value(AppLog.storage, "The editor preference could not be read", fallback:"") { try await model.featureStorage.editorPreference() }
                        return EditorLocation.Editor(rawValue:name) ?? .vscode
                    },
                    operationStateSink:{ repository,worktree,state in
                        // Recovery hints are advisory: Git metadata stays authoritative when one is not saved.
                        do { try await model.featureStorage.saveLocalOperationState(repository:repository,worktree:worktree,state:state) }
                        catch { AppLog.failed(AppLog.local, "A local recovery hint could not be saved", error) }
                    },checkoutCompleted:{ model.localCheckout = nil })
                    .navigationTitle("MergePro").navigationSubtitle("Local")
            }
        }
        .toolbar {
            if model.destination != .pullRequests {
                ToolbarItem {
                    // ⌘K lives in View ▸ Command Palette; a second key equivalent here would shadow it.
                    Button { model.prs.palettePresented = true } label: { Image(systemName:"command") }
                        .help("Command palette (⌘K)")
                        .accessibilityLabel("Command palette")
                }
            }
        }
        .sheet(isPresented:Binding(get:{ model.destination != .pullRequests && model.prs.palettePresented },set:{ model.prs.palettePresented = $0 })) {
            CommandPalette(setup:model,workspace:model.prs,open:{ key in model.prs.recordOpen(key);openWindow(id:"pr-detail",value:key) })
        }
        .modifier(chrome)
        .sheet(isPresented:Binding(get:{ !model.prs.routeChoices.isEmpty },set:{ if !$0 { model.prs.routeChoices = [] } })) {
            VStack(alignment:.leading,spacing:12) {
                Text("Choose the account for this pull request").font(.headline)
                ForEach(model.prs.routeChoices,id:\.self) { key in
                    Button(model.prs.accounts.first { $0.scope == key.account }?.login ?? key.accountID) { model.prs.routeChoices = []; model.prs.recordOpen(key); openWindow(id:"pr-detail",value:key) }
                }
                Button("Cancel") { model.prs.routeChoices = [] }.keyboardShortcut(.cancelAction)
            }.padding(20)
        }
        .sheet(isPresented:Binding(get:{ !model.featureRouteChoices.isEmpty },set:{ if !$0 { model.featureRouteChoices = [];model.pendingFeatureURL = nil } })) {
            VStack(alignment:.leading,spacing:12) {
                Text("Choose an account").font(.headline)
                ForEach(model.featureRouteChoices,id:\.self) { key in
                    Button(model.snapshots.compactMap(\.account).first { $0.scope == key.account }?.login ?? key.account.accountID) {
                        let url = model.pendingFeatureURL;model.featureRouteChoices = [];model.pendingFeatureURL = nil
                        if let url { Task { await model.navigateFeatureURL(url,account:key.account) } }
                    }
                }
                Button("Cancel") { model.featureRouteChoices = [];model.pendingFeatureURL = nil }.keyboardShortcut(.cancelAction)
            }.padding(20)
        }
        .onOpenURL { url in Task { await route(url) } }
        .onAppear {
            model.statusItem.install(model:model,showMain:{ openWindow(id:"main"); NSApplication.shared.activate() },showSettings:{ openSettings() },open:{ key in model.prs.recordOpen(key); openWindow(id:"pr-detail",value:key) })
            configureHotkeys()
            KeyboardShortcutsHelp.show = { openWindow(id: KeyboardShortcutsHelp.windowID) }
            AppIntentRouter.shared.showMain = { openWindow(id:"main"); NSApplication.shared.activate() }
        }
        .onChange(of: AppIntentRouter.shared.pending, initial: true) { _, request in
            guard let request else { return }
            AppIntentRouter.shared.pending = nil
            switch request {
            case .needsMe: Task { await showNeedsMe() }
            case .open(let url): Task { await route(url) }
            }
        }
        .onChange(of:model.prs.state.globalShortcuts) { _,_ in configureHotkeys() }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: DesignTokens.minimumWindowSize.width,
            minHeight: DesignTokens.minimumWindowSize.height
        )
        .font(DesignTokens.bodyFont)
    }
    /// mergepro:// and github.com links from Open URL, Shortcuts and the palette's pasted links.
    private func route(_ url: URL) async {
        if await model.navigateFeatureURL(url) { return }
        await model.prs.load(); model.destination = .pullRequests
        switch PRRouteResolver.resolve(url,cached:model.prs.rows,activeAccount:model.activeAccount) {
        case .native(let key):model.prs.recordOpen(key); openWindow(id:"pr-detail",value:key)
        case .chooseAccount(let keys):model.prs.routeChoices = keys
        case .web(let url):ExternalLinkPolicy.open(url)
        case .unavailable:
            model.prs.status = "This destination is unavailable in the selected account."
            AccessibilityNotification.Announcement("This destination is unavailable in the selected account.").post()
        }
    }
    /// The built-in "Needs my review" view (request:me), or that filter when the view was removed.
    private func showNeedsMe() async {
        await model.prs.load()
        if let view = model.prs.state.views.first(where: { !$0.hidden && $0.configuration.filter.serialized == "request:me" }) {
            model.prs.chooseView(view.id)
        } else {
            model.prs.filterText = "request:me"
            model.prs.applyFilter()
        }
        model.destination = .pullRequests
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
    private func configureHotkeys() {
        model.globalHotkeyStatus = model.globalHotkeys.configure(model.prs.state.globalShortcuts ?? PRGlobalShortcuts(),palette:{ model.prs.palettePresented = true; openWindow(id:"main"); NSApplication.shared.activate() },menuBar:{ model.statusItem.toggle() })
    }

}
