import SwiftUI
import MergeProCore

/// The reset token advances only after a successful commit in this exact worktree.
struct LocalCommitComposer: View {
    let directory: URL
    let status: GitStatusSnapshot
    let busy: Bool
    var resetToken: UUID? = nil
    let onCommit: (String, Bool) -> Void
    let onTemplate: () async -> String?
    @State private var draft = LocalCommitDraft()
    @State private var loadedDirectory: URL?
    @State private var pendingSave: Task<Void, Never>?
    @State private var templateTask: Task<Void, Never>?
    @State private var templateGeneration = UUID()
    @State private var templateLoading = false
    @State private var templateNotice: String?
    @FocusState private var subjectFocused: Bool
    private let store = LocalCommitDraftStore()
    private var stagedCount: Int { status.entries.filter { $0.isStaged && !$0.isUnmerged }.count }
    private var hasConflicts: Bool { status.entries.contains(where: \.isUnmerged) }
    private var canReview: Bool { !busy && !templateLoading && !hasConflicts && (stagedCount > 0 || draft.amend) && !draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var message: String { draft.subject + (draft.body.isEmpty ? "" : "\n\n" + draft.body) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Commit", systemImage: "checkmark.circle").font(.headline)
                Spacer()
                Text("\(stagedCount) staged \(stagedCount == 1 ? "file" : "files")").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("localCommitStagedCount")
            }
            TextField("Commit subject", text: $draft.subject)
                .textFieldStyle(.roundedBorder).focused($subjectFocused)
                .accessibilityLabel("Commit subject").accessibilityIdentifier("localCommitSubject")
            HStack {
                Text("Describe the change in one line").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(draft.subject.count) / 72").font(.caption.monospacedDigit())
                    .foregroundStyle(draft.subject.count > 72 ? Color.orange : Color.secondary)
                    .help("A subject of 72 characters or fewer is easier to read in Git history. Longer subjects are allowed.")
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.body).font(.callout).scrollContentBackground(.hidden)
                    .padding(4).frame(minHeight: 72, maxHeight: 110)
                    .accessibilityLabel("Commit description").accessibilityIdentifier("localCommitBody")
                if draft.body.isEmpty {
                    Text("Optional description: why this change is needed").font(.callout).foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 12).allowsHitTesting(false).accessibilityHidden(true)
                }
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
            ViewThatFits(in: .horizontal) {
                HStack { options; Spacer(minLength: 8); reviewButton }
                VStack(alignment: .leading, spacing: 10) { options; reviewButton.frame(maxWidth: .infinity, alignment: .trailing) }
            }
            if draft.amend { Text("Amend replaces the latest commit. Review its current staged contents before continuing.").font(.caption).foregroundStyle(.secondary) }
            if hasConflicts { Text("Resolve conflicts before committing.").font(.caption).foregroundStyle(.orange) }
            else if stagedCount == 0 && !draft.amend { Text("Stage changes to include them in this commit.").font(.caption).foregroundStyle(.secondary) }
            if let templateNotice { Text(templateNotice).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14).workspacePanel(radius: 12)
        .disabled(busy)
        .onAppear { loadDraft(directory) }
        .onChange(of: directory) { _, newDirectory in loadDraft(newDirectory) }
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onChange(of: resetToken) { _, token in
            guard token != nil, loadedDirectory == directory else { return }
            cancelTemplate(); pendingSave?.cancel(); pendingSave = nil
            store.clear(directory: directory); draft = .init(); templateNotice = nil
        }
        .onDisappear { flushDraft(); cancelTemplate() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("localCommitComposer")
    }

    private var options: some View {
        HStack(spacing: 12) {
            Toggle("Amend latest", isOn: $draft.amend).toggleStyle(.checkbox)
                .disabled(status.head == nil).accessibilityIdentifier("localCommitAmend")
            Button {
                loadTemplate()
            } label: {
                if templateLoading { ProgressView().controlSize(.mini) }
                else { Label("Template", systemImage: "doc.badge.plus") }
            }.disabled(templateLoading || !draft.subject.isEmpty || !draft.body.isEmpty)
                .help("Load this repository's configured commit template into an empty draft")
                .accessibilityLabel("Load commit template").accessibilityIdentifier("localCommitTemplate")
        }.font(.caption)
    }
    private var reviewButton: some View {
        Button("Review commit…") { flushDraft(); onCommit(message, draft.amend) }
            .buttonStyle(.borderedProminent).tint(DesignTokens.cobalt).disabled(!canReview)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Review the staged changes and commit message before committing")
            .accessibilityIdentifier("localReviewCommit")
    }
    private func loadDraft(_ newDirectory: URL) {
        guard loadedDirectory != newDirectory else { return }
        flushDraft(); cancelTemplate()
        loadedDirectory = newDirectory
        draft = store.load(directory: newDirectory); templateNotice = nil
    }
    private func scheduleSave() {
        pendingSave?.cancel()
        guard let scope = loadedDirectory else { return }
        let captured = draft
        pendingSave = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            store.save(captured, directory: scope)
        }
    }
    private func flushDraft() {
        pendingSave?.cancel(); pendingSave = nil
        if let scope = loadedDirectory { store.save(draft, directory: scope) }
    }
    private func cancelTemplate() {
        templateTask?.cancel(); templateTask = nil; templateGeneration = UUID(); templateLoading = false
    }
    private func loadTemplate() {
        cancelTemplate()
        let generation = UUID(); templateGeneration = generation
        let scope = loadedDirectory
        let original = draft
        templateLoading = true; templateNotice = nil
        templateTask = Task { @MainActor in
            let text = await onTemplate()
            guard !Task.isCancelled, templateGeneration == generation, loadedDirectory == scope else { return }
            templateLoading = false
            guard draft == original else { templateNotice = "Your edits were preserved. Clear the draft to load the template."; return }
            guard let text, !text.isEmpty else { templateNotice = "No commit template is available for this repository."; return }
            let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            draft.subject = String(lines[0])
            draft.body = lines.count > 1 ? String(lines[1]) : ""
            subjectFocused = true
        }
    }
}
