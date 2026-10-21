import SwiftUI
import MergeProCore

enum LocalCommandKind: String, CaseIterable, Identifiable, Sendable {
    case commit, createBranch, switchBranch, deleteBranch, renameBranch, fetch, pull, push, stash, applyStash, dropStash, addWorktree, removeWorktree, merge, rebase, cherryPick, checkoutPR
    var id: String { rawValue }
    var title: String {
        switch self {
        case .commit: "Commit Changes"
        case .createBranch: "Create Branch"
        case .switchBranch: "Switch Branch"
        case .deleteBranch: "Delete Branch"
        case .renameBranch: "Rename Branch"
        case .fetch: "Fetch"
        case .pull: "Pull"
        case .push: "Push"
        case .stash: "Save Stash"
        case .applyStash: "Apply Stash"
        case .dropStash: "Drop Stash"
        case .addWorktree: "Create Worktree"
        case .removeWorktree: "Remove Worktree"
        case .merge: "Merge Branch"
        case .rebase: "Rebase Branch"
        case .cherryPick: "Cherry-pick Commit"
        case .checkoutPR: "Check Out Pull Request"
        }
    }
}

struct LocalCommandInput: Sendable {
    let directory: URL
    let kind: LocalCommandKind
    var name = ""
    var target = ""
    var remote = "origin"
    var message = ""
    var amend = false
    var includeUntracked = false
    var dropStash = false
    var createWorktreeBranch = true
    var destination: URL?
}

struct LocalCommandPresentation: Identifiable {
    let id = UUID()
    let input: LocalCommandInput
    let snapshot: LocalGitSnapshot
}

struct LocalCommandSheet: View {
    let presentation: LocalCommandPresentation
    let folderStore: SecurityScopedFolderStore
    let checkout: LocalPRCheckoutRequest?
    var submit: (LocalCommandInput, LocalGitSnapshot, LocalGitComparison?) async -> Bool
    var compare: (String) async throws -> LocalGitComparison
    var template: () async -> String?
    var failureMessage: () -> String?
    var openTerminal: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input: LocalCommandInput
    @State private var working = false
    @State private var comparison: LocalGitComparison?
    @State private var comparisonLoading = false
    @State private var comparisonError: String?
    @State private var comparisonID = UUID()
    @State private var error: String?
    @State private var submissionTask: Task<Void, Never>?
    @State private var destinationParent: URL?
    @State private var destinationName = ""
    /// Return in a single-line field moves to the next field and in the commit message inserts a newline; neither
    /// runs the command. Return runs a non-destructive command only when no text input has focus; ⌘Return runs it
    /// from anywhere. Destructive commands still need a click.
    @FocusState private var focus: Field?
    private enum Field: Hashable { case message, name, target, remote, worktreeFolder }
    init(presentation: LocalCommandPresentation, folderStore: SecurityScopedFolderStore, checkout: LocalPRCheckoutRequest?, submit: @escaping (LocalCommandInput, LocalGitSnapshot, LocalGitComparison?) async -> Bool, compare: @escaping (String) async throws -> LocalGitComparison, template: @escaping () async -> String?, failureMessage: @escaping () -> String?, openTerminal: @escaping () -> Void) {
        self.presentation = presentation; self.folderStore = folderStore; self.checkout = checkout; self.submit = submit; self.compare = compare; self.template = template
        self.failureMessage = failureMessage
        self.openTerminal = openTerminal
        _input = State(initialValue: presentation.input)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(input.kind.title).font(.title2.bold())
            Text(input.directory.path).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            WorkspaceNotice(message: consequence, symbol: "info.circle", tint: input.kind == .deleteBranch || input.kind == .removeWorktree || input.amend ? .orange : DesignTokens.cobalt)
            Form { fields }.formStyle(.grouped).scrollContentBackground(.hidden).disabled(working)
            if let error { WorkspaceNotice(message: error, symbol: "exclamationmark.triangle", tint: .orange); Button("Open in Terminal") { openTerminal() }.disabled(working) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(working ? "Cancel Operation" : "Cancel") { if working { submissionTask?.cancel() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                // Destructive commands are a deliberate click: neither Return nor ⌘Return deletes a branch, drops a
                // stash, removes a worktree or rewrites the current commit. Return while typing never runs a command.
                Button(input.kind.title, role: destructive ? .destructive : nil) { run() }
                    .keyboardShortcut(destructive || focus != nil ? nil : .defaultAction).buttonStyle(.borderedProminent).tint(destructive ? .red : nil).disabled(working || !valid)
                    .background {
                        Button(input.kind.title) { if !destructive && valid { run() } }
                            .keyboardShortcut(destructive ? nil : KeyboardShortcut(.return, modifiers: .command)).hidden().accessibilityHidden(true)
                    }
            }
        }.padding(24).frame(minWidth: 600, idealWidth: 820, maxWidth: .infinity, minHeight: 450, idealHeight: 680, maxHeight: .infinity)
            .interactiveDismissDisabled(working)
            .onExitCommand { if !working { dismiss() } }
            .onChange(of: error) { _, message in if let message { AccessibilityNotification.Announcement(message).post() } }
            .background { WindowFrameMemory(role: "local-command", defaultSize: CGSize(width: 820, height: 680), minimumSize: CGSize(width: 600, height: 450), sheet: true) }
            .task(id: input.target) { await loadComparison() }
    }
    @ViewBuilder private var fields: some View {
        switch input.kind {
        case .commit:
            Text("\(presentation.snapshot.status.entries.filter(\.isStaged).count) staged files · HEAD \(presentation.snapshot.status.head?.prefix(8) ?? "unborn")").font(.caption)
            TextEditor(text: $input.message).font(.body.monospaced()).frame(minHeight: 130).focused($focus, equals: .message).accessibilityLabel("Commit message")
            Section("Staged files included in this commit") {
                ForEach(presentation.snapshot.status.entries.filter { $0.isStaged && !$0.isUnmerged }) { entry in
                    HStack { Text(entry.path).textSelection(.enabled); Spacer(); Text(entry.indexStatus).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
            }
            Toggle("Amend the current commit", isOn: $input.amend)
            Button("Load Repository Message Template") { Task { if let text = await template() { input.message = text } } }
        case .createBranch:
            TextField("New branch name", text: $input.name).focused($focus, equals: .name).onSubmit { focus = .target }
            TextField("Start point", text: $input.target).focused($focus, equals: .target)
        case .switchBranch, .deleteBranch:
            branchPicker("Branch", selection: $input.name)
            if let branch = presentation.snapshot.branches.first(where: { $0.name == input.name }) { Text("Selected head: \(branch.head)").font(.caption.monospaced()).textSelection(.enabled) }
        case .renameBranch: branchPicker("Branch", selection: $input.target); TextField("New branch name", text: $input.name).focused($focus, equals: .name)
        case .fetch: TextField("Remote", text: $input.remote).focused($focus, equals: .remote)
        case .pull, .push:
            TextField("Remote", text: $input.remote).focused($focus, equals: .remote).onSubmit { focus = .target }
            TextField("Remote branch", text: $input.target).focused($focus, equals: .target)
        case .stash: TextField("Stash message", text: $input.message).focused($focus, equals: .message); Toggle("Include untracked files", isOn: $input.includeUntracked)
        case .applyStash, .dropStash:
            Picker("Stash", selection: $input.target) { Text("Select a stash").tag(""); ForEach(presentation.snapshot.stashes, id: \.reference) { stash in Text(stash.reference + " · " + stash.message + " · " + String(stash.head.prefix(8))).tag(stash.reference) } }
            if input.kind == .applyStash { Toggle("Drop this stash after successful apply", isOn: $input.dropStash) }
        case .addWorktree, .checkoutPR:
            if input.kind == .checkoutPR, let checkout { Text("\(checkout.repositoryName) #\(String(checkout.number))").font(.headline); Text("Expected head: \(checkout.expectedHeadSHA)").font(.caption.monospaced()); TextField("Remote", text: $input.remote).focused($focus, equals: .remote).onSubmit { focus = .name } }
            TextField("Branch name", text: $input.name).focused($focus, equals: .name).onSubmit { focus = .worktreeFolder }
            if input.kind == .addWorktree { Toggle("Create a new branch", isOn: $input.createWorktreeBranch) }
            Button(destinationParent == nil ? "Choose Worktree Parent Folder…" : "Change Parent Folder…") { Task { await chooseDestination() } }
            if let destinationParent { Text("Parent: \(destinationParent.path)").font(.caption.monospaced()) }
            TextField("New worktree folder name", text: $destinationName).focused($focus, equals: .worktreeFolder).onChange(of: destinationName) { _, _ in updateDestination() }
            if let destination = input.destination { Text(destination.path).font(.caption.monospaced()).textSelection(.enabled) }
        case .removeWorktree:
            Picker("Worktree to remove", selection: $input.target) { Text("Select a worktree").tag(""); ForEach(presentation.snapshot.repository.worktrees.filter { !$0.isBare && $0.directory != input.directory }) { tree in Text(tree.directory.path).tag(tree.directory.path) } }
        case .merge, .rebase:
            branchPicker("Target branch", selection: $input.target)
            comparisonPreview
        case .cherryPick: TextField("Commit SHA or revision", text: $input.target).focused($focus, equals: .target)
        }
    }
    private func run() {
        guard !working else { return } // a repeated Return must not orphan the running task's cancel handle
        working = true; error = nil
        submissionTask = Task {
            if await submit(input, presentation.snapshot, comparison) { dismiss() }
            else { error = Task.isCancelled ? "Command cancelled. Git may still have an operation in progress. Refresh status and use Continue or Abort, or open this repository in Terminal." : failureMessage() ?? "The operation could not finish. Refresh the repository and try again." }
            working = false; submissionTask = nil
        }
    }
    private func branchPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) { Text("Select a branch").tag(""); ForEach(presentation.snapshot.branches, id: \.name) { branch in Text(branch.name + (branch.isProtected ? " · protected" : "")).tag(branch.name) } }
    }
    private var destructive: Bool { input.kind == .deleteBranch || input.kind == .dropStash || input.kind == .removeWorktree || (input.kind == .commit && input.amend) }
    private var valid: Bool {
        switch input.kind {
        case .commit: !input.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (input.amend || presentation.snapshot.status.entries.contains(where: \.isStaged))
        case .createBranch: !input.name.isEmpty
        case .switchBranch, .deleteBranch: !input.name.isEmpty
        case .renameBranch: !input.name.isEmpty && !input.target.isEmpty
        case .fetch: !input.remote.isEmpty
        case .pull, .push: !input.remote.isEmpty && !input.target.isEmpty
        case .stash: !presentation.snapshot.status.isClean
        case .merge, .rebase: !input.target.isEmpty && !comparisonLoading && comparison?.head == presentation.snapshot.status.head && comparison?.targetReference == input.target
        case .applyStash, .dropStash, .removeWorktree, .cherryPick: !input.target.isEmpty
        case .addWorktree: input.destination != nil && !input.name.isEmpty
        case .checkoutPR: input.destination != nil && !input.name.isEmpty && !input.remote.isEmpty && checkout != nil
        }
    }
    private var consequence: String {
        switch input.kind {
        case .commit: input.amend ? "Amend replaces the current commit and changes its SHA. Review the staged files before continuing. Commit signing and Git configuration are preserved; configured hooks require Terminal when sandbox execution is unsupported." : "Commit the reviewed staged changes in this worktree. Commit signing and Git configuration are preserved; configured hooks require Terminal when sandbox execution is unsupported."
        case .deleteBranch: "Delete the selected local branch reference. Its unmerged commits may become harder to recover. Protected, current or unmerged branches are rejected."
        case .removeWorktree: "Remove the selected worktree directory and registration. Dirty, locked, primary or protected worktrees are rejected."
        case .rebase: "Replay this branch onto the target, changing commit SHAs. A clean worktree is required. Conflicts expose Continue and Abort recovery actions."
        case .merge, .cherryPick, .pull: "Update this worktree using the selected target. A clean worktree is required. Conflicts remain visible with recovery actions."
        case .push: "Send this local branch to the selected remote branch. No force push is used. Configured hooks and credential helpers are preserved; unsupported sandbox execution requires Terminal."
        case .stash: "Save tracked changes and restore a clean worktree. Untracked files are included only when selected."
        case .applyStash: "Apply the selected saved changes to this worktree. Keep the stash unless you explicitly choose to drop it after success."
        case .dropStash: "Delete the selected stash reference. Its saved changes may become unrecoverable. Copy or apply the changes you need before continuing."
        case .checkoutPR: "Map this provider pull request to the selected local clone. Verify its remote and expected head, then create a separate worktree in the folder you authorize."
        default: "Apply this operation to the exact local repository shown above. Current Git configuration, hooks and signing are preserved."
        }
    }
    @ViewBuilder private var comparisonPreview: some View {
        if comparisonLoading { ProgressView("Comparing branches…") }
        else if let comparison {
            VStack(alignment: .leading, spacing: 10) {
                Text("Current HEAD \(comparison.head.prefix(8)) → \(input.target) \(comparison.target.prefix(8))").font(.caption.monospaced()).textSelection(.enabled)
                Text("\(comparison.ahead) commits only on this branch · \(comparison.behind) only on target").font(.callout)
                Text("\(comparison.files.count) files differ between these trees. Conflicts are determined when Git runs the operation.").font(.caption).foregroundStyle(.secondary)
                ForEach(comparison.files.prefix(40)) { file in HStack { Text(file.path).lineLimit(2); Spacer(); Text(file.status).font(.caption.monospaced()).foregroundStyle(.secondary) } }
                if comparison.files.count > 40 { Text("Showing the first 40 files.").font(.caption).foregroundStyle(.secondary) }
            }
        } else if let comparisonError { Text(comparisonError).foregroundStyle(.orange) }
    }
    private func loadComparison() async {
        guard input.kind == .merge || input.kind == .rebase else { return }
        let token = UUID(); comparisonID = token; comparison = nil; comparisonError = nil
        guard !input.target.isEmpty else { comparisonLoading = false; return }
        let target = input.target; comparisonLoading = true
        do {
            let value = try await compare(target)
            guard comparisonID == token, input.target == target, !Task.isCancelled else { return }
            comparisonLoading = false
            guard value.head == presentation.snapshot.status.head else { comparisonError = "HEAD changed. Close this dialog and review the operation again."; return }
            comparison = value
        } catch {
            guard comparisonID == token, !Task.isCancelled else { return }
            comparisonLoading = false; comparisonError = LocalWorkspaceModel.message(for: error)
        }
    }

    private func chooseDestination() async {
        do { if let id = try await folderStore.chooseFolder(message: "Authorize the parent folder in which a new worktree directory will be created. The new child folder must not already exist."), let folder = folderStore.folders.first(where: { $0.id == id }) {
            destinationParent = URL(fileURLWithPath: folder.path)
            if destinationName.isEmpty { destinationName = input.name.replacingOccurrences(of: "/", with: "-") }
            updateDestination()
        } }
        catch { self.error = error.localizedDescription }
    }
    private func updateDestination() {
        let validName = !destinationName.isEmpty && destinationName != "." && destinationName != ".." && !destinationName.contains("/") && !destinationName.contains("\0")
        input.destination = validName ? destinationParent?.appendingPathComponent(destinationName, isDirectory: true) : nil
    }
}
