import SwiftUI
import MergeProCore

struct LocalChangesView: View {
    @Bindable var model: LocalWorkspaceModel
    let compact: Bool
    var stage: (String, Bool) -> Void = { _, _ in }
    var loadHunks: (Bool) -> Void = { _ in }
    var stageHunk: (LocalDiffHunk, Bool) -> Void = { _, _ in }
    var selectPreview: ((String, Bool) -> Void)? = nil
    var stageFiles: (([String], Bool) -> Void)? = nil
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private struct FileSelection: Hashable { let path: String; let staged: Bool }
    /// Shared by the file list and preview headers so the dividers under them line up.
    private static let paneHeaderHeight: CGFloat = 44
    private var entries: [GitStatusEntry] { model.status?.entries ?? [] }
    private var staged: [GitStatusEntry] { entries.filter { $0.isStaged && !$0.isUnmerged } }
    private var unstaged: [GitStatusEntry] { entries.filter { $0.isUntracked || $0.isUnmerged || ($0.worktreeStatus != "." && $0.worktreeStatus != " ") } }
    private var busy: Bool { model.mutating || model.loading || model.preparingCommand }
    private var previewStaged: Bool { model.previewStaged ?? selectedEntry.map { $0.isStaged && !hasUnstaged($0) } ?? false }
    private var selectedEntry: GitStatusEntry? { entries.first { $0.path == model.selectedPath } }
    private var selection: Binding<FileSelection?> {
        Binding(get: { model.selectedPath.map { FileSelection(path: $0, staged: previewStaged) } }, set: { value in if let value { select(value.path, staged: value.staged) } })
    }

    var body: some View {
        Group {
            if entries.isEmpty { ContentUnavailableView("Working Tree Clean", systemImage: "checkmark.circle", description: Text("No staged, unstaged or untracked changes.")) }
            else if compact { VStack(spacing: 0) { files.frame(minHeight: 130, idealHeight: 200, maxHeight: 240); Divider(); preview } }
            else { HSplitView { files.frame(minWidth: 230, idealWidth: 300, maxWidth: 420); preview.frame(minWidth: 260) } }
        }.accessibilityElement(children: .contain)
    }

    private var files: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { searchFocused = true } label: { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).keyboardShortcut("f", modifiers: .command)
                    .accessibilityLabel("Focus changed file search").help("Search changed files (⌘F)")
                TextField("Search changed files", text: $query).textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Search changed files").accessibilityIdentifier("localChangesSearch")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear changed file search")
                }
            }.padding(.horizontal, 12).frame(height: Self.paneHeaderHeight)
            Divider()
            List(selection: selection) {
                fileSection("Staged", entries: staged, staged: true)
                fileSection("Unstaged", entries: unstaged, staged: false)
            }.listStyle(.inset).scrollContentBackground(.hidden).accessibilityIdentifier("localChangedFiles")
            if !query.isEmpty && filtered(staged).isEmpty && filtered(unstaged).isEmpty {
                Text("No changed files match “\(query)”.").font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
    }
    private func fileSection(_ title: String, entries: [GitStatusEntry], staged: Bool) -> some View {
        Section {
            ForEach(filtered(entries)) { entry in
                fileRow(entry, staged: staged).tag(FileSelection(path: entry.path, staged: staged))
                    .contextMenu {
                        Button(staged ? "Unstage File" : "Stage File") { stage(entry.path, staged) }
                            .disabled(busy || entry.isUnmerged)
                        Button(staged ? "Preview Staged Changes" : "Preview Unstaged Changes") { select(entry.path, staged: staged) }
                    }
            }
            if entries.isEmpty {
                Text(staged ? "No staged changes" : "No unstaged changes").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
        } header: {
            HStack {
                Text(title); Text("\(entries.count)").monospacedDigit().foregroundStyle(.secondary); Spacer()
                if let stageFiles, !entries.isEmpty {
                    let paths = filtered(entries).filter { !$0.isUnmerged }.map(\.path)
                    Button(query.isEmpty ? (staged ? "Unstage All" : "Stage All") : (staged ? "Unstage Matches" : "Stage Matches")) { stageFiles(paths, staged) }
                        .buttonStyle(.borderless).font(.caption).disabled(busy || paths.isEmpty)
                        .help("\(staged ? "Unstage" : "Stage") complete files in this group. Active search limits the action to matching files.")
                }
            }
                .accessibilityLabel("\(title), \(entries.count) files")
        }
    }
    private func fileRow(_ entry: GitStatusEntry, staged: Bool) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: entry.isUnmerged ? "exclamationmark.triangle.fill" : entry.isUntracked ? "doc.badge.plus" : "doc.text")
                .foregroundStyle(entry.isUnmerged ? Color.orange : Color.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.path).font(.callout).lineLimit(1).truncationMode(.middle).help(entry.path)
                if let original = entry.originalPath { Text("From \(original)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if entry.isUnmerged { Text("Unresolved conflict").font(.caption).foregroundStyle(.orange) }
                else if entry.isUntracked { Text("Untracked").font(.caption).foregroundStyle(.secondary) }
                else if entry.isStaged && hasUnstaged(entry) { Text("Partially staged").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Text(staged ? entry.indexStatus : entry.worktreeStatus).font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(width: 14).accessibilityHidden(true)
            Button { stage(entry.path, staged) } label: {
                Image(systemName: staged ? "minus.circle" : "plus.circle")
            }.buttonStyle(.borderless).disabled(busy || entry.isUnmerged)
                .accessibilityLabel("\(staged ? "Unstage" : "Stage") \(entry.path)")
                .help(staged ? "Unstage this complete file" : "Stage this complete file")
        }.padding(.vertical, 6).contentShape(Rectangle())
            .accessibilityElement(children: .contain)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = model.selectedPath, let entry = selectedEntry {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { pathTitle(path); Spacer(minLength: 12); modePicker(path, entry: entry); fileControls(path, entry: entry) }
                    VStack(alignment: .leading, spacing: 8) {
                        pathTitle(path)
                        HStack(spacing: 12) { modePicker(path, entry: entry); Spacer(minLength: 8); fileControls(path, entry: entry) }
                    }.padding(.vertical, 10)
                }.controlSize(.small).padding(.horizontal, 14).frame(minHeight: Self.paneHeaderHeight)
                Divider()
                if let diff = model.fileDiff, diff.path == path, diff.isBinary {
                    Text("Binary changes can be staged as a complete file.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
                    Divider()
                } else if let diff = model.fileDiff, diff.path == path, diff.snapshot.status.entries.contains(where: { $0.path == path }), model.fileDiffStaged == previewStaged, !diff.hunks.isEmpty {
                    hunkControls(diff).padding(.vertical, 8)
                    Divider()
                }
            }
            if model.previewLoading { ProgressView("Reading changes…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if model.preview.isEmpty {
                ContentUnavailableView(model.selectedPath == nil ? "Choose a Changed File" : "No Changes in This View", systemImage: "doc.text.magnifyingglass", description: Text("Select a file in Staged or Unstaged to inspect its changes."))
            } else { CodeTextView(text: model.preview, wrap: false, path: model.selectedPath ?? "changes.diff", patch: selectedEntry?.isUntracked != true) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func pathTitle(_ path: String) -> some View {
        Text(path).font(.headline).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(path)
    }
    private func modePicker(_ path: String, entry: GitStatusEntry) -> some View {
        Picker("Diff view", selection: Binding(get: { previewStaged }, set: { select(path, staged: $0) })) {
            Text("Unstaged").tag(false).disabled(!hasUnstaged(entry))
            Text("Staged").tag(true).disabled(!entry.isStaged || entry.isUnmerged)
        }.pickerStyle(.segmented).fixedSize().disabled(busy)
            .accessibilityLabel("Diff view").accessibilityIdentifier("localDiffMode")
    }
    private func fileControls(_ path: String, entry: GitStatusEntry) -> some View {
        HStack(spacing: 8) {
            if entry.isUnmerged { Label("Resolve conflict", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            else {
                Button(previewStaged ? "Unstage File" : "Stage File", systemImage: previewStaged ? "minus.circle" : "plus.circle") { stage(path, previewStaged) }
                if !entry.isUntracked {
                    Button("Load Hunks", systemImage: "line.3.horizontal.decrease") { loadHunks(previewStaged) }
                        .help("Read individual \(previewStaged ? "staged" : "unstaged") hunks for this file")
                }
            }
        }.disabled(busy || model.previewLoading)
    }
    private func hunkControls(_ diff: LocalFileDiff) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(Array(diff.hunks.enumerated()), id: \.element.id) { index, hunk in
                    Button("\(model.fileDiffStaged ? "Unstage" : "Stage") hunk \(index + 1)") { stageHunk(hunk, model.fileDiffStaged) }
                        .help(hunk.header).accessibilityLabel("\(model.fileDiffStaged ? "Unstage" : "Stage") hunk \(index + 1), \(hunk.header)")
                }
            }.padding(.horizontal, 14)
        }.controlSize(.small).disabled(busy || model.previewLoading)
    }
    private func filtered(_ entries: [GitStatusEntry]) -> [GitStatusEntry] {
        entries.filter { query.isEmpty || $0.path.localizedStandardContains(query) || $0.originalPath?.localizedStandardContains(query) == true }
    }
    private func hasUnstaged(_ entry: GitStatusEntry) -> Bool {
        entry.isUntracked || entry.isUnmerged || (entry.worktreeStatus != "." && entry.worktreeStatus != " ")
    }
    private func select(_ path: String, staged: Bool) {
        if let selectPreview { selectPreview(path, staged) }
        else { model.selectedPath = path; model.previewStaged = staged; loadHunks(staged) }
    }
}
