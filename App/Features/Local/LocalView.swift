import AppKit
import SwiftUI
import MergeProCore

struct LocalView: View {
    let folderStore: SecurityScopedFolderStore
    var runner: any GitRunner = ProcessGitRunner()
    var checkout: LocalPRCheckoutRequest? = nil
    var editorPreference: @Sendable () async -> EditorLocation.Editor = { .vscode }
    var operationStateSink: (@Sendable (LocalRepositoryID, LocalWorktreeID, GitOperationState) async -> Void)? = nil
    var checkoutCompleted: () -> Void = {}
    @State private var model = LocalWorkspaceModel()
    @State private var section = "changes"
    @State private var folderPopover = false
    /// Bumped by each refresh request; its task cancels the refresh a newer request supersedes.
    @State private var refreshRequest = 0
    @State private var conflict: ConflictSelection?
    @State private var commitExpanded = false
    private struct PreviewSelection: Hashable { let directory: URL?; let path: String?; let staged: Bool? }
    private struct ConflictSelection: Identifiable { let id = UUID(); let directory: URL; let path: String }
    private var busy: Bool { model.mutating || model.preparingCommand || model.loading }
    @AppStorage(DefaultsKey.localGitExecutable) private var gitExecutable = LocalGitExecutableChoice.system.rawValue
    private var tool: LocalGitExecutableChoice { LocalGitExecutableChoice(rawValue: gitExecutable) ?? .system }
    private var activeRunner: any GitRunner { tool == .system ? runner : ProcessGitRunner(executableURL: URL(fileURLWithPath: tool.rawValue)) }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 920
            VStack(spacing: 0) {
                WorkspaceSectionHeader(title: "Local", subtitle: model.directory?.path ?? "Your authorized repositories and worktrees", symbol: "externaldrive") {
                    if model.loading || model.preparingCommand { ProgressView().controlSize(.small) }
                    if compact { Button("Folders", systemImage: "sidebar.left") { folderPopover.toggle() }.popover(isPresented: $folderPopover) { folders.frame(width: 300, height: 400) } }
                    Button("Add Folder…", systemImage: "folder.badge.plus") { Task { await addFolder() } }.disabled(busy).accessibilityIdentifier("localAddFolder")
                    Button { Task { await model.refresh(folderStore: folderStore, runner: activeRunner) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(busy).help("Refresh local status").accessibilityLabel("Refresh local status").keyboardShortcut("r", modifiers: .command)
                }
                HStack(spacing: 12) {
                    Picker("Git Tool", selection: $gitExecutable) {
                        ForEach(LocalGitExecutableChoice.allCases.filter { $0.isAvailable || $0 == .system || $0 == tool }) { choice in Text(choice.label + (choice.isAvailable ? "" : " · unavailable")).tag(choice.rawValue).disabled(!choice.isAvailable && choice != .system) }
                    }.frame(maxWidth: 240).disabled(busy || model.commandPresentation != nil)
                    Text(tool.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 24).padding(.bottom, 12)
                if let checkout {
                    WorkspaceNotice(message: "Check out \(checkout.repositoryName) #\(checkout.number): select the corresponding local clone and a new worktree folder. Expected head \(checkout.expectedHeadSHA.prefix(8)).", symbol: "arrow.triangle.pull", tint: DesignTokens.cobalt).padding(.horizontal, 24).padding(.bottom, 10)
                }
                if let error = model.error {
                    HStack(alignment: .top) {
                        WorkspaceNotice(message: error, symbol: "exclamationmark.triangle", tint: .orange)
                        if let path = model.requiredAuthorizationPath { Button("Authorize Folder…") { Task { await addFolder(message: "Git requires access to \(path). Select that folder to continue.") } }.padding(.top, 12) }
                        else if let id = model.selectedFolder, folderStore.authorizationIssue(for: id) != nil { Button("Authorize Again…") { Task { await addFolder(replacing: id) } }.padding(.top, 12) }
                        if tool == .system, model.error?.hasPrefix("Git ") == true, LocalGitExecutableChoice.xcode.isAvailable { Button("Use Xcode Git") { gitExecutable = LocalGitExecutableChoice.xcode.rawValue }.padding(.top, 12) }
                        if model.directory != nil { Button("Open in Terminal") { Task { await model.openDirectory(terminal: true, folderStore: folderStore) } }.padding(.top, 12) }
                        Button("Dismiss") { model.error = nil }.padding(.top, 12)
                    }.padding(.horizontal, 24).padding(.bottom, 10)
                }
                if let message = model.message { HStack(alignment: .top) { WorkspaceNotice(message: message, symbol: "checkmark.circle", tint: .green); Button("Dismiss") { model.message = nil }.padding(.top, 12) }.padding(.horizontal, 24).padding(.bottom, 10) }
                if model.catalogIsTruncated { WorkspaceNotice(message: "Folder discovery reached its depth or directory limit. Select a closer parent folder to reveal repositories that were not scanned.", symbol: "exclamationmark.triangle", tint: .orange).padding(.horizontal, 24).padding(.bottom, 10) }
                if model.catalogRepositories.count > 1 || model.needsRepositorySelection {
                    Picker("Repository", selection: $model.selectedRepositoryDirectory) { ForEach(model.catalogRepositories) { repository in Text(repository.directory.path).tag(Optional(repository.directory)) } }.padding(.horizontal, 24).padding(.bottom, 12).disabled(busy)
                }
                HStack(spacing: 0) {
                    if !compact { folders.frame(width: min(260, geometry.size.width * 0.25)); Divider() }
                    VStack(spacing: 0) {
                        if let status = model.status {
                            repositoryHeader(status)
                            if let directory = model.directory {
                                ConflictView(state: model.operation, status: status, directory: directory, busy: busy,
                                    select: { path in conflict = .init(directory: directory, path: path) },
                                    recover: { abort in Task { await model.prepareRecovery(abort: abort, folderStore: folderStore, runner: activeRunner) } })
                            }
                            Divider()
                            Group {
                                if section == "worktrees" { WorktreesView(repository: model.repository, selected: $model.selectedWorktree, open: { tree, terminal in Task { await model.openDirectory(terminal: terminal, folderStore: folderStore, target: tree.directory) } }, edit: { tree in Task { await model.openEditor(await editorPreference(), folderStore: folderStore, target: tree.directory, folderOnly: true) } }).disabled(model.mutating || model.preparingCommand) }
                                else if section == "history", let directory = model.directory {
                                    LocalHistoryView(directory: directory, folderStore: folderStore, runner: activeRunner,
                                        onCherryPick: { prepare(.cherryPick, target: $0) }, onCreateBranch: { prepare(.createBranch, target: $0) }).id(directory).disabled(model.mutating || model.preparingCommand)
                                } else {
                                    VStack(spacing: 0) {
                                        LocalChangesView(model: model, compact: compact,
                                            stage: { path, unstage in Task { await model.stageFile(path: path, unstage: unstage, folderStore: folderStore, runner: activeRunner) } },
                                            loadHunks: { staged in Task { await model.loadHunks(staged: staged, folderStore: folderStore, runner: activeRunner) } },
                                            stageHunk: { hunk, unstage in Task { await model.stageHunk(hunk, unstage: unstage, folderStore: folderStore, runner: activeRunner) } },
                                            selectPreview: { path, staged in model.previewStaged = staged; model.selectedPath = path },
                                            stageFiles: { paths, unstage in Task { await model.stageFiles(paths: paths, unstage: unstage, folderStore: folderStore, runner: activeRunner) } })
                                        if let directory = model.directory {
                                            Divider()
                                            commitComposer(directory: directory, status: status, compact: geometry.size.height < 760)

                                        }
                                    }
                                }
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if model.loading { ProgressView("Reading Git status…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                        else { ContentUnavailableView("Choose a Local Repository", systemImage: "folder.badge.plus", description: Text("Add a Git repository folder to read changes, branches and worktrees. Folder access persists across relaunch.")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.clipShape(RoundedRectangle(cornerRadius: 16)).workspacePanel().padding(.horizontal, 24).padding(.bottom, 20)
            }
        }.background { WorkspaceCanvas() }
        .task { model.operationStateSink = operationStateSink; await model.load(folderStore: folderStore, runner: activeRunner) }
        .onChange(of: gitExecutable) { _, _ in model.commandPresentation = nil; reload() }
        .onChangeTask(of: refreshRequest) { _ in await model.refresh(folderStore: folderStore, runner: activeRunner) }
        // Only user selections refresh: values the model assigned itself (or a reset recorded by reload()) are already applied.
        .onChange(of: model.selectedFolder) { _, selected in if selected != model.appliedFolder { folderPopover = false; model.selectedWorktree = nil; model.selectedRepositoryDirectory = nil; reload() } }
        .onChange(of: model.selectedRepositoryDirectory) { _, selected in if let selected, selected != model.appliedRepositoryDirectory { model.selectedWorktree = nil; reload() } }
        .onChange(of: model.selectedWorktree) { _, selected in if model.repository != nil, selected != model.appliedWorktree { reload() } }
        .task(id: PreviewSelection(directory: model.directory, path: model.selectedPath, staged: model.previewStaged)) {
            if model.selectedPath != model.previewPath || model.previewStaged != model.appliedPreviewStaged { await model.loadPreview(folderStore: folderStore, runner: activeRunner) }
        }
        // Command results and failures arrive after Git finishes; VoiceOver hears them without moving focus.
        .onChange(of: model.message) { _, message in if let message { AccessibilityNotification.Announcement(message).post() } }
        // A command sheet announces its own failure.
        .onChange(of: model.error) { _, message in if let message, model.commandPresentation == nil { AccessibilityNotification.Announcement(message).post() } }
        .sheet(item: $conflict) { selected in
            LocalConflictResolver(directory: selected.directory, path: selected.path, folderStore: folderStore, runner: activeRunner, onResolved: { Task { await model.refresh(folderStore: folderStore, runner: activeRunner) } }, onOpenEditor: { Task { await model.openEditor(await editorPreference(), folderStore: folderStore, target: selected.directory, path: selected.path) } })
                .background { WindowFrameMemory(role: "local-conflicts", defaultSize: CGSize(width: 1280, height: 840), minimumSize: CGSize(width: 900, height: 600), sheet: true) }
        }
        .sheet(item: $model.commandPresentation) { presentation in
            LocalCommandSheet(presentation: presentation, folderStore: folderStore, checkout: checkout, submit: { input, expected, comparison in
                let succeeded = await model.execute(input, expected: expected, checkout: checkout, folderStore: folderStore, runner: activeRunner, reviewedComparison: comparison)
                if succeeded, input.kind == .checkoutPR { checkoutCompleted() }
                return succeeded
            }, compare: { target in try await folderStore.withAllAccess { roots in try await LocalGitService(runner: activeRunner, authorizedRoots: roots, requiresTerminalForHooks: true).compare(target: target, directory: presentation.input.directory) } }, template: { await model.commitTemplate(directory: presentation.input.directory, folderStore: folderStore, runner: activeRunner) }, failureMessage: { model.error }, openTerminal: { Task { await model.openDirectory(terminal: true, folderStore: folderStore, target: presentation.input.directory) } })
        }
        .onDisappear { model.cancelPreview() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localWorkspace")
    }

    @ViewBuilder private func commitComposer(directory: URL, status: GitStatusSnapshot, compact: Bool) -> some View {
        if compact {
            DisclosureGroup(isExpanded: $commitExpanded) {
                composer(directory: directory, status: status)
            } label: { Label("Commit staged changes", systemImage: "checkmark.circle").font(.headline) }.padding(12)
        } else { composer(directory: directory, status: status).padding(12) }
    }
    private func composer(directory: URL, status: GitStatusSnapshot) -> some View {
        LocalCommitComposer(directory: directory, status: status, busy: busy, resetToken: model.commitSuccessToken,
            onCommit: { message, amend in Task { await model.prepare(.commit, folderStore: folderStore, runner: activeRunner, checkout: checkout, commitMessage: message, amend: amend) } },
            onTemplate: { await model.commitTemplate(directory: directory, folderStore: folderStore, runner: activeRunner) }).id(directory)
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Height matches the branch row beside it (16pt panel padding around a regular-size control).
            Text("Authorized Folders").font(.headline).padding(.horizontal, 14).frame(height: 56)
            Divider()
            if folderStore.folders.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No folders yet").font(.callout.weight(.medium))
                    Text("Only folders you select are accessed. Use Add Folder… above.").font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
            List(selection: $model.selectedFolder) {
                ForEach(folderStore.folders) { folder in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(folder.name, systemImage: "folder").font(.callout.weight(.medium))
                        Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if folderStore.authorizationIssue(for: folder.id) != nil {
                            Label { Text("Authorization needs renewal").foregroundStyle(.secondary) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true) }.font(.caption)
                        }
                    }.padding(.vertical, 6).tag(folder.id)
                        .contextMenu { Button("Authorize Again…") { Task { await addFolder(replacing: folder.id) } }; Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(folder.path, forType: .string) } }
                }
            }.disabled(busy).listStyle(.sidebar).scrollContentBackground(.hidden)
            }
            if !model.catalogIssues.isEmpty {
                Divider()
                ScrollView { VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.catalogIssues) { issue in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(issue.directory.lastPathComponent).font(.callout.weight(.medium))
                            Text(issue.message).font(.caption).foregroundStyle(.secondary)
                            if let required = issue.requiredAccessURL { Button("Authorize Folder…") { Task { await addFolder(message: "Repository discovery requires access to \(required.path). Select that exact folder.") } } }
                        }
                    }
                }.padding(14) }.frame(maxHeight: 180)
            }
        }
    }
    private func repositoryHeader(_ status: GitStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { branchHeading(status); Spacer(); navigation }
                VStack(alignment: .leading, spacing: 10) { branchHeading(status); navigation }
            }
            Picker("Local section", selection: $section) { Text("Changes").tag("changes"); Text("History").tag("history"); Text("Worktrees").tag("worktrees") }.pickerStyle(.segmented).disabled(model.mutating || model.preparingCommand).labelsHidden().fixedSize()
            ScrollView(.horizontal) { HStack(spacing: 10) {
                Button("Fetch", systemImage: "arrow.clockwise") { prepare(.fetch) }
                Button("Pull", systemImage: "arrow.down") { prepare(.pull) }
                Button("Push", systemImage: "arrow.up") { prepare(.push) }
                Menu("Branches") { command(.createBranch); command(.switchBranch); command(.renameBranch); command(.deleteBranch) }
                Menu("Remotes") { command(.fetch); command(.pull); command(.push) }
                Menu("Stash") { command(.stash); command(.applyStash); command(.dropStash) }
                Menu("Operations") { command(.merge); command(.rebase); command(.cherryPick) }
                Menu("Worktrees") { command(.addWorktree); command(.removeWorktree); if checkout != nil { command(.checkoutPR) } }
            }.fixedSize(horizontal: true, vertical: false) }.disabled(busy)
        }.padding(16)
    }
    private func branchHeading(_ status: GitStatusSnapshot) -> some View {
        HStack(spacing: 10) {
            LocalBranchPicker(branches: model.branches, busy: busy, onSelect: { prepare(.switchBranch, target: $0.name) }, onCreate: { prepare(.createBranch) })
            WorkspaceStatusBadge(text: status.isClean ? "Clean" : "\(status.entries.count) changed", tint: status.isClean ? .green : .orange)
            if let upstream = status.upstream { Text("\(upstream) · ↑\(status.ahead) ↓\(status.behind)").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var navigation: some View {
        HStack(spacing: 10) {
            Button("Finder", systemImage: "folder") { Task { await model.openDirectory(terminal: false, folderStore: folderStore) } }
            Button("Terminal", systemImage: "terminal") { Task { await model.openDirectory(terminal: true, folderStore: folderStore) } }
            Button("Editor", systemImage: "curlybraces") { Task { await model.openEditor(await editorPreference(), folderStore: folderStore) } }
        }
    }
    /// Records the selection synchronously so the onChange callbacks for resets made just before don't refresh again.
    private func reload() { model.markSelectionApplied(); refreshRequest &+= 1 }
    private func addFolder(replacing id: UUID? = nil, message: String? = nil) async {
        do {
            if let selected = try await folderStore.chooseFolder(replacing: id, message: message) {
                if model.requiredAuthorizationPath == nil, model.selectedFolder != selected { model.selectedFolder = selected; model.selectedWorktree = nil; model.selectedRepositoryDirectory = nil }
                await model.refresh(folderStore: folderStore, runner: activeRunner)
            }
        } catch { model.error = error.localizedDescription }
    }
    private func command(_ kind: LocalCommandKind) -> some View { Button(kind.title + "…") { prepare(kind) } }
    private func prepare(_ kind: LocalCommandKind, target: String? = nil) { Task { await model.prepare(kind, folderStore: folderStore, runner: activeRunner, checkout: checkout, presetTarget: target) } }
}
