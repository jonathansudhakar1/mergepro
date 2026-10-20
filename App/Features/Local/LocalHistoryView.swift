import SwiftUI
import Observation
import MergeProCore

/// A history browser that owns only read requests. Mutations are reviewed by its host.
struct LocalHistoryView: View {
    let directory: URL
    let folderStore: SecurityScopedFolderStore
    let runner: any GitRunner
    let onCherryPick: (String) -> Void
    let onCreateBranch: (String) -> Void
    @State private var model = LocalHistoryBrowserModel()
    @State private var search = ""
    @State private var refresh = 0
    @State private var pagingTask: Task<Void, Never>?

    private var scope: LocalHistoryScope { .init(directory: directory, search: search, refresh: refresh) }
    private var selectionScope: LocalHistorySelectionScope { .init(scope: scope, commit: model.selectedCommit, path: nil) }
    private var fileScope: LocalHistorySelectionScope { .init(scope: scope, commit: model.selectedCommit, path: model.selectedPath) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.compactSpacing) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(DesignTokens.cobalt)
                Text("History").font(.headline)
                Text("\(model.commits.count) commits").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Search commit messages", text: $search).textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, idealWidth: 230, maxWidth: 340)
                    .accessibilityLabel("Search commit history")
                    .accessibilityIdentifier("localHistorySearch")
                Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh history").accessibilityLabel("Refresh history")
            }.padding(14)
            Divider()
            if let error = model.historyError { errorBanner(error) }
            HSplitView {
                commitList.frame(minWidth: 210, idealWidth: 310, maxWidth: 440)
                detail.frame(minWidth: 320, maxWidth: .infinity)
            }
        }
        .task(id: scope) {
            pagingTask?.cancel()
            await model.load(scope: scope, folderStore: folderStore, runner: runner)
        }
        .task(id: selectionScope) {
            await model.loadDetails(scope: selectionScope, folderStore: folderStore, runner: runner)
        }
        .task(id: fileScope) {
            await model.loadDiff(scope: fileScope, folderStore: folderStore, runner: runner)
        }
        .onDisappear { pagingTask?.cancel(); model.invalidate() }
        .accessibilityIdentifier("localHistoryWorkspace")
    }
    private var commitList: some View {
        VStack(spacing: 0) {
            if model.loading && model.commits.isEmpty {
                ProgressView("Reading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.commits.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No Commits Yet" : "No Matching Commits", systemImage: "clock", description: Text(search.isEmpty ? "Create a commit to begin this worktree’s history." : "Try another phrase from a commit message."))
            } else {
                List(selection: $model.selectedCommit) {
                    ForEach(model.commits) { commit in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: commit.parents.count > 1 ? "arrow.triangle.merge" : "circle.inset.filled")
                                .font(.caption).foregroundStyle(commit.parents.count > 1 ? DesignTokens.violet : DesignTokens.cobalt)
                                .padding(.top, 3).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(commit.subject.isEmpty ? "Untitled commit" : commit.subject).font(.callout.weight(.medium)).lineLimit(2)
                                HStack { Text(commit.authorName).lineLimit(1); Spacer(minLength: 4); Text(commit.committedAt, style: .date) }
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 6) {
                                    Text(String(commit.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    if !commit.refs.isEmpty { Text(commit.refs.joined(separator: " · ")).font(.caption2).foregroundStyle(DesignTokens.cobalt).lineLimit(1) }
                                }
                            }
                        }.padding(.vertical, 6).tag(commit.id)
                            .contextMenu {
                                Button("Create Branch Here…") { onCreateBranch(commit.id) }
                                Button("Cherry-pick Commit…") { onCherryPick(commit.id) }.disabled(commit.parents.count > 1)
                            }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden).accessibilityIdentifier("localHistoryCommits")
            }
            if model.nextCursor != nil {
                Divider()
                Button {
                    pagingTask?.cancel()
                    let captured = scope
                    pagingTask = Task { await model.load(scope: captured, folderStore: folderStore, runner: runner, append: true) }
                } label: {
                    HStack { if model.loading { ProgressView().controlSize(.small) }; Text(model.loading ? "Loading…" : "Load 50 More") }
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderless).padding(12).disabled(model.loading)
                    .accessibilityLabel("Load more commits")
            }
        }
    }
    private var detail: some View {
        VStack(spacing: 0) {
            if let error = model.detailsError { errorBanner(error) }
            if model.detailsLoading {
                ProgressView("Reading commit…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let details = model.details, details.commit.id == model.selectedCommit {
                metadata(details.commit)
                Divider()
                HSplitView {
                    files(details.files).frame(minWidth: 140, idealWidth: 210, maxWidth: 360)
                    diffPreview.frame(minWidth: 220, maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView("Choose a Commit", systemImage: "clock.arrow.circlepath", description: Text("Inspect its message, parents and changes without touching the working tree."))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func metadata(_ commit: LocalHistoryCommit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) { commitTitle(commit); Spacer(); commitActions(commit) }
                VStack(alignment: .leading, spacing: 10) { commitTitle(commit); commitActions(commit) }
            }
            HStack(spacing: 6) {
                Text(commit.authorName).fontWeight(.medium)
                Text("<\(commit.authorEmail)>").foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(commit.authoredAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
            }.font(.caption).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(commit.message.trimmingCharacters(in: .newlines)).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !commit.refs.isEmpty { Text(commit.refs.joined(separator: " · ")).font(.caption).foregroundStyle(DesignTokens.cobalt) }
                    Text("Commit  \(commit.id)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if commit.parents.isEmpty { Text("Root commit · Compared with the empty tree").font(.caption).foregroundStyle(.secondary) }
                    else {
                        Text("\(commit.parents.count > 1 ? "Merge · First-parent changes" : "Parent")  \(commit.parents.joined(separator: " · "))")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if commit.committerName != commit.authorName || commit.committedAt != commit.authoredAt {
                        Text("Committed by \(commit.committerName) · \(commit.committedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxHeight: 145)
        }.padding(14)
    }
    private func commitTitle(_ commit: LocalHistoryCommit) -> some View {
        Text(commit.subject.isEmpty ? "Untitled commit" : commit.subject).font(.headline).lineLimit(2).textSelection(.enabled)
    }
    private func commitActions(_ commit: LocalHistoryCommit) -> some View {
        HStack {
            Button("Create Branch…") { onCreateBranch(commit.id) }.help("Create a branch at this commit")
            Button("Cherry-pick…") { onCherryPick(commit.id) }
                .disabled(commit.parents.count > 1)
                .help(commit.parents.count > 1 ? "Merge commits require a mainline selection in Terminal." : "Review cherry-picking this commit")
        }.controlSize(.small)
    }
    private func files(_ files: [LocalHistoryFile]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(files.count) Changed Files").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(12)
            if files.isEmpty { Text("This commit has no file changes.").font(.caption).foregroundStyle(.secondary).padding(12); Spacer() }
            else {
                List(selection: $model.selectedPath) {
                    ForEach(files) { file in
                        HStack(alignment: .top, spacing: 8) {
                            Text(file.status).font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(file.status == "A" ? Color.green : file.status == "D" ? Color.red : Color.secondary)
                            Text(file.path).font(.callout).lineLimit(3)
                        }.padding(.vertical, 5).tag(file.path)
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden).accessibilityIdentifier("localHistoryFiles")
            }
        }
    }
    private var diffPreview: some View {
        VStack(spacing: 0) {
            if let path = model.selectedPath {
                HStack { Text(path).font(.callout.weight(.medium)).lineLimit(2).textSelection(.enabled); Spacer() }.padding(12)
                Divider()
            }
            if model.diffLoading { ProgressView("Reading file changes…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error = model.diffError { ContentUnavailableView("Changes Unavailable", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else if let diff = model.diff, diff.commit == model.selectedCommit, diff.path == model.selectedPath {
                if let unavailable = diff.unavailable {
                    ContentUnavailableView("Preview Unavailable", systemImage: unavailable == .binary ? "doc.zipper" : "doc.badge.ellipsis", description: Text(unavailableDescription(unavailable)))
                } else if let patch = diff.patch, !patch.isEmpty { CodeTextView(text: patch, wrap: false, path: "commit.diff") }
                else { ContentUnavailableView("No Text Changes", systemImage: "doc.text", description: Text("This entry has no displayable patch.")) }
            } else { ContentUnavailableView("Choose a Changed File", systemImage: "doc.text.magnifyingglass", description: Text("File patches load when selected.")) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func unavailableDescription(_ reason: LocalHistoryDiffUnavailable) -> String {
        switch reason {
        case .binary: "This is a binary change. Inspect the selected commit in your editor or Terminal."
        case .oversized: "This file or its patch exceeds the 1 MB preview limit. Inspect the selected commit in your editor or Terminal."
        case .invalidUTF8: "This patch cannot be decoded as UTF-8. Inspect the selected commit in your editor or Terminal."
        }
    }
    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange); Text(error).font(.caption); Spacer() }
            .padding(12).background(.orange.opacity(0.08)).accessibilityElement(children: .combine)
    }
}

private struct LocalHistoryScope: Equatable {
    let directory: URL
    let search: String
    let refresh: Int
}
private struct LocalHistorySelectionScope: Equatable {
    let scope: LocalHistoryScope
    let commit: String?
    let path: String?
}
@MainActor @Observable private final class LocalHistoryBrowserModel {
    var commits: [LocalHistoryCommit] = []
    var nextCursor: LocalHistoryCursor?
    var selectedCommit: String?
    var selectedPath: String?
    var details: LocalCommitDetails?
    var diff: LocalHistoryFileDiff?
    var historyError: String?
    var detailsError: String?
    var diffError: String?
    var loading = false
    var detailsLoading = false
    var diffLoading = false
    private var currentScope: LocalHistoryScope?
    private var historyRequest = UUID()
    private var detailsRequest = UUID()
    private var diffRequest = UUID()
    func invalidate() { historyRequest = UUID(); detailsRequest = UUID(); diffRequest = UUID() }

    func load(scope: LocalHistoryScope, folderStore: SecurityScopedFolderStore, runner: any GitRunner, append: Bool = false) async {
        let request = UUID(); historyRequest = request
        if currentScope?.directory != scope.directory || currentScope?.search != scope.search {
            commits = []; nextCursor = nil; selectedCommit = nil; selectedPath = nil; details = nil; diff = nil
        }
        currentScope = scope
        let cursor = append ? nextCursor : nil
        if append && cursor == nil { return }
        loading = true; historyError = nil
        defer { if historyRequest == request { loading = false } }
        do {
            if !append && !scope.search.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            let page = try await folderStore.withAllAccess { roots in
                try await LocalGitService(runner: runner, authorizedRoots: roots).history(directory: scope.directory, cursor: cursor, search: scope.search)
            }
            guard !Task.isCancelled, historyRequest == request, currentScope == scope else { return }
            if append { commits.append(contentsOf: page.commits.filter { candidate in !commits.contains(where: { $0.id == candidate.id }) }) }
            else { commits = page.commits }
            nextCursor = page.nextCursor
            if selectedCommit == nil || !commits.contains(where: { $0.id == selectedCommit }) { selectedCommit = commits.first?.id }
        } catch is CancellationError { }
        catch { if !Task.isCancelled, historyRequest == request, currentScope == scope { historyError = error.localizedDescription } }
    }
    func loadDetails(scope: LocalHistorySelectionScope, folderStore: SecurityScopedFolderStore, runner: any GitRunner) async {
        let request = UUID(); detailsRequest = request
        detailsError = nil; detailsLoading = false
        guard let commit = scope.commit else { details = nil; selectedPath = nil; return }
        if details?.commit.id != commit { details = nil; diff = nil; selectedPath = nil }
        detailsLoading = true
        defer { if detailsRequest == request { detailsLoading = false } }
        do {
            let value = try await folderStore.withAllAccess { roots in
                try await LocalGitService(runner: runner, authorizedRoots: roots).commitDetails(commit: commit, directory: scope.scope.directory)
            }
            guard !Task.isCancelled, detailsRequest == request, selectedCommit == commit, currentScope == scope.scope else { return }
            details = value
            if selectedPath == nil || !value.files.contains(where: { $0.path == selectedPath }) { selectedPath = value.files.first?.path }
        } catch is CancellationError { }
        catch { if !Task.isCancelled, detailsRequest == request, currentScope == scope.scope { detailsError = error.localizedDescription } }
    }
    func loadDiff(scope: LocalHistorySelectionScope, folderStore: SecurityScopedFolderStore, runner: any GitRunner) async {
        let request = UUID(); diffRequest = request; diffError = nil; diffLoading = false
        guard let commit = scope.commit, let path = scope.path else { diff = nil; return }
        if diff?.commit != commit || diff?.path != path { diff = nil }
        diffLoading = true
        defer { if diffRequest == request { diffLoading = false } }
        do {
            let value = try await folderStore.withAllAccess { roots in
                try await LocalGitService(runner: runner, authorizedRoots: roots).commitDiff(commit: commit, path: path, directory: scope.scope.directory)
            }
            guard !Task.isCancelled, diffRequest == request, selectedCommit == commit, selectedPath == path, currentScope == scope.scope else { return }
            diff = value
        } catch is CancellationError { }
        catch { if !Task.isCancelled, diffRequest == request, currentScope == scope.scope { diffError = error.localizedDescription } }
    }
}
