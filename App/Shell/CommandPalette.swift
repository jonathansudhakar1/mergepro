import AppKit
import MergeProCore
import SwiftUI

struct CommandPalette: View {
  @Bindable var setup: SetupModel
  @Bindable var workspace: PRWorkspaceModel
  let open: (ProviderKey) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openSettings) private var openSettings
  @State private var query = ""
  /// Built off the main actor once per row set; each keystroke only searches it.
  @State private var index: PRPaletteIndex?
  @State private var indexGeneration = 0
  @State private var results = Results()
  /// The query and index `results` were searched for. Return runs a row only once they match the current ones, so it
  /// never runs a result of an earlier keystroke while the newest search is still running.
  @State private var resultsKey: SearchKey?
  /// Return pressed while the newest search was running; it runs when that search finishes (typing cancels it).
  @State private var pendingReturn = false
  /// Arrow keys move it; Return runs it. Nil follows the default row for the current query.
  @State private var highlight: Int?
  /// Runs once the sheet is gone, so an action that presents its own sheet is not dropped.
  @State private var afterDismiss: (() -> Void)?
  @FocusState private var focused: Bool
  private var text: String { query.lowercased() }

  /// Search results for one query, computed together off the main actor.
  private struct Results {
    var prs: [PullRequest] = []
    var workflows: [FeatureWorkflowEntry] = []
    var runs: [WorkflowRun] = []
    var presets: [WorkflowPreset] = []
    var repoEntries: [RepoPaletteEntry] = []
  }
  private struct SearchKey: Hashable { let query: String; let generation: Int }

  /// One palette row. Lower `priority` is what Return chose before rows could be highlighted.
  private struct Row: Identifiable {
    let id: String
    let title: String
    let icon: String
    var enabled = true
    let priority: Int
    let run: () -> Void
  }

  private var showsLocal: Bool {
    let localQuery = query.hasPrefix(">") ? String(query.dropFirst()).trimmingCharacters(in:.whitespaces) : query
    return localQuery.isEmpty || PRPaletteSearch.score(localQuery,"Local repositories folders worktrees") != nil
  }
  private var viewMatches: [PRSavedView] {
    guard !text.hasPrefix("#"), !text.hasPrefix("@"), !text.hasPrefix("/"), !text.hasPrefix(">") else { return [] }
    return workspace.state.views.filter { !$0.hidden && (query.isEmpty || $0.name.lowercased().contains(text)) }
  }
  private var repoMatches: [Repository] {
    guard text.hasPrefix("repo:") else { return [] }
    return workspace.repositories.filter { $0.name.lowercased().contains(String(text.dropFirst(5))) }
      .sorted { workspace.pinned.contains($0.key) && !workspace.pinned.contains($1.key) }
  }
  private var loginMatches: [String] {
    guard text.hasPrefix("@") else { return [] }
    return Array(Set(workspace.rows.compactMap { $0.metadata?.authorLogin } + workspace.rows.flatMap { $0.metadata?.reviewers ?? [] }))
      .filter { $0.lowercased().contains(String(text.dropFirst())) }.sorted()
  }
  private var exactURL: URL? {
    // navigateInput only routes github.com URLs; other hosts would leave this row inert.
    guard let url = URL(string: query), url.scheme == "https", url.host?.lowercased() == "github.com" else { return nil }
    return url
  }
  /// The focused (or selected) pull requests' commands, when their workspace is on screen to present them.
  private var target: PRCommandTarget? {
    guard workspace !== setup.prs || setup.destination == .pullRequests else { return nil }
    return PRCommandTarget.palette(in: workspace, open: open)
  }

  private var rows: [Row] {
    var rows: [Row] = []
    let commandsFirst = text.hasPrefix(">")
    if let url = exactURL {
      rows.append(Row(id: "url", title: "Open exact destination", icon: "link", priority: 0) { navigate(url) })
    }
    if let target {
      let subject = target.subject ?? "pull request"
      let actions: [(PRPaletteSearch.PRAction, (() -> Void)?, String, String)] = [
        (.open, target.open, "Open \(subject)", "arrow.up.forward.app"),
        (.approve, target.approve, "Approve \(subject)…", "checkmark.circle"),
        (.requestChanges, target.requestChanges, "Request changes on \(subject)…", "exclamationmark.bubble"),
        (.comment, target.comment, "Comment on \(subject)…", "text.bubble"),
        (.merge, target.merge, "Merge \(subject)…", "arrow.triangle.merge"),
        (.labels, target.labels, "Labels for \(subject)…", "tag"),
        (.copyLink, target.copyLink, "Copy link to \(subject)", "link"),
        (.openOnWeb, target.openOnWeb, "Open \(subject) on GitHub", "safari"),
      ]
      let available = Set(actions.filter { $0.1 != nil }.map(\.0))
      let shown = PRPaletteSearch.prActions(query: query, available: available)
      // An empty query lists recent pull requests first; the focused PR's commands show once you type.
      for action in actions where shown.contains(action.0) && !query.isEmpty {
        guard let run = action.1 else { continue }
        rows.append(Row(id: "action-" + action.0.rawValue, title: action.2, icon: action.3, priority: commandsFirst ? 1 : 3) { finish(run) })
      }
    }
    for entry in PRPaletteSearch.commands(query: query) {
      rows.append(Row(id: "command-" + entry.destination.rawValue, title: entry.title, icon: icon(entry.destination),
        priority: commandsFirst ? 1 : 3) { navigate(entry.destination) })
    }
    if showsLocal {
      rows.append(Row(id: "local", title: "Local repositories", icon: "externaldrive", priority: 4) { openLocal() })
    }
    for view in viewMatches {
      rows.append(Row(id: "view-" + view.id.uuidString, title: view.name, icon: view.icon, priority: 5) { choose(view) })
    }
    for pr in results.prs {
      rows.append(Row(id: "pr-" + pr.key.routeURL.absoluteString, title: "\(pr.metadata?.repositoryName ?? "") #\(pr.metadata?.number ?? 0) · \(pr.title)",
        icon: "arrow.triangle.pull", priority: 2) { open(pr.key); dismiss() })
    }
    for entry in results.workflows {
      rows.append(Row(id: "workflow-" + entry.id, title: entry.workflow.name + " · " + entry.repository.name, icon: "play.circle", priority: 6) {
        setup.showActions(repository: entry.repository.key, workflowID: entry.workflow.id); dismiss()
      })
    }
    for run in results.runs {
      rows.append(Row(id: "run-" + run.key.objectID + run.key.accountID + run.key.repositoryID,
        title: "\(run.name) #\(run.runID) · \(run.status) · attempt \(run.attempt)", icon: "gearshape.2", priority: 7) {
        setup.showActions(repository: run.repository.key, runID: run.runID); dismiss()
      })
    }
    for preset in results.presets {
      rows.append(Row(id: "preset-" + preset.id.uuidString, title: preset.name + " · " + preset.ref, icon: "bookmark", priority: 8) {
        setup.showActions(repository: preset.repository, workflowID: preset.workflowID, presetID: preset.id); dismiss()
      })
    }
    for entry in results.repoEntries {
      rows.append(Row(id: "entry-" + entry.id, title: entry.title, icon: entry.kind == "file" ? "doc.text" : "folder", priority: 9) {
        setup.showRepository(entry.route); dismiss()
      })
    }
    if text.hasPrefix("repo:") {
      for repo in repoMatches {
        let id = repo.key.account.host + "|" + repo.key.account.accountID + "|" + repo.key.repositoryID
        rows.append(Row(id: "browse-" + id, title: "Browse \(repo.name) · Account \(repo.key.account.accountID)", icon: "folder", priority: 10) {
          setup.showRepository(.init(repository: repo.key)); dismiss()
        })
        rows.append(Row(id: "scope-" + id, title: "Scope PRs to \(repo.name) · Account \(repo.key.account.accountID)",
          icon: "line.3.horizontal.decrease.circle", priority: 11) {
          workspace.state.accountFilter = repo.key.account
          workspace.filterText = "repo:\(repo.name)"
          workspace.applyFilter()
          setup.destination = .pullRequests
          dismiss()
        })
      }
      rows.append(Row(id: "track", title: "Track more repositories in Setup", icon: "plus.circle", priority: 12) {
        setup.destination = .setup
        dismiss()
      })
    }
    for login in loginMatches {
      rows.append(Row(id: "login-" + login, title: "@\(login) · Open GitHub profile", icon: "person.crop.circle", priority: 13) { openProfile(login) })
    }
    return rows
  }
  /// The row Return runs before any arrow key: the best match in the order Return has always used.
  private func defaultHighlight(_ rows: [Row]) -> Int? {
    rows.indices.filter { rows[$0].enabled }.min { rows[$0].priority < rows[$1].priority }
  }
  private func current(_ rows: [Row]) -> Int? {
    PRPaletteSearch.moveHighlight(highlight ?? defaultHighlight(rows), by: 0, enabled: rows.map(\.enabled))
  }
  private var resultsAreCurrent: Bool { index != nil && resultsKey == SearchKey(query: query, generation: indexGeneration) }
  /// Return: runs the highlighted row once the results are for the current query, else when its search finishes.
  private func submit() {
    guard resultsAreCurrent else { pendingReturn = true; return }
    pendingReturn = false
    let rows = self.rows
    activate(current(rows), in: rows)
  }

  private func openLocal() { setup.localCheckout=nil;setup.destination = .local;dismiss() }
  private func choose(_ view: PRSavedView) { workspace.chooseView(view.id);setup.destination = .pullRequests;dismiss() }
  private func openProfile(_ login: String) {
    ExternalLinkPolicy.open(URL(string: "https://github.com")!.appendingPathComponent(login))
    dismiss()
  }
  /// Closes the palette, then runs a pull request command (which may present its own sheet).
  private func finish(_ action: @escaping () -> Void) {
    afterDismiss = action
    dismiss()
  }

  var body: some View {
    let rows = rows
    let selected = current(rows)
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
        TextField(
          "Search PRs, workflows, refs, /files, repo: or paste a GitHub URL", text: $query
        ).textFieldStyle(.plain).font(.title3).focused($focused).onSubmit { submit() }
          .accessibilityIdentifier("commandPaletteInput")
          .accessibilityHint("Up and down arrows move through results; Return opens the highlighted result.")
      }.padding(.horizontal, 18).padding(.vertical, 14)
      Divider()
      ScrollViewReader { proxy in
        List {
          ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
            Button { row.run() } label: { Label(row.title, systemImage: row.icon) }
              .buttonStyle(PaletteRowStyle(highlighted: offset == selected))
              .disabled(!row.enabled)
              .accessibilityAddTraits(offset == selected ? .isSelected : [])
              .id(row.id)
          }
          if text.hasPrefix("/") && !setup.cachedRepoEntries.contains(where:{ $0.kind == "file" }) {
            Text("Open a pinned repository to index its files at the selected ref.").foregroundStyle(.secondary)
          }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .onChange(of: selected.map { rows[$0].id }) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
    }
    .frame(width: 700, height: 500)
    .background {
      WindowKeyMonitor { event in
        guard event.editingModifiers.isEmpty else { return false }
        switch event.specialKey {
        case .downArrow?, .upArrow?:
          let rows = self.rows
          let next = PRPaletteSearch.moveHighlight(current(rows), by: event.specialKey == .downArrow ? 1 : -1, enabled: rows.map(\.enabled))
          highlight = next
          if let next { AccessibilityNotification.Announcement(rows[next].title).post() }
          return true
        case .carriageReturn?, .enter?:
          submit()
          return true
        default: return false
        }
      }
    }
    // Escape closes the palette wherever focus is.
    .background { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).hidden().accessibilityHidden(true) }
    .onExitCommand { dismiss() }
    .onAppear { focused = true }
    .onDisappear {
      let action = afterDismiss
      afterDismiss = nil
      if let action { DispatchQueue.main.async { action() } }
    }
    .onChange(of: query) { _, _ in highlight = nil; pendingReturn = false }
    .task { await setup.refreshFeatureCaches() }
    .task(id: workspace.pipeline.stackRevision) {
      let rows = workspace.rows, state = workspace.state
      let built = await Task.detached(priority: .userInitiated) { PRPaletteIndex(rows: rows, state: state) }.value
      guard !Task.isCancelled else { return }
      index = built
      indexGeneration += 1
    }
    .task(id: SearchKey(query: query, generation: indexGeneration)) { await search() }
  }

  /// Searches pull requests and feature caches off the main actor; a newer keystroke cancels this one.
  private func search() async {
    let key = SearchKey(query: query, generation: indexGeneration)
    let query = query, index = index
    let workflows = setup.cachedWorkflows, runs = setup.cachedRuns, presets = setup.cachedPresets, entries = setup.cachedRepoEntries
    let job = Task.detached(priority: .userInitiated) { () -> Results in
      var results = Results()
      results.prs = index?.search(query, limit: 50, isCancelled: { Task.isCancelled }) ?? []
      let text = query.lowercased()
      let showsFeatures = !text.hasPrefix(">") && !text.hasPrefix("@") && !text.hasPrefix("#") && !text.hasPrefix("https:") && !text.hasPrefix("repo:")
      guard showsFeatures, !Task.isCancelled else { return results }
      let input = query.hasPrefix("/") ? String(query.dropFirst()) : query
      func matches(_ title: String) -> Bool { input.isEmpty || PRPaletteSearch.score(input, title) != nil }
      results.workflows = Array(workflows.lazy.filter { matches($0.workflow.name + " " + $0.repository.name) }.prefix(20))
      results.runs = Array(runs.lazy.filter { matches($0.name + " " + $0.branch + " " + String($0.runID)) }.prefix(20))
      results.presets = Array(presets.lazy.filter { matches($0.name + " " + $0.ref) }.prefix(20))
      results.repoEntries = Array(entries.lazy.filter { matches($0.title) && (!text.hasPrefix("/") || $0.kind == "file") }.prefix(40))
      return results
    }
    let found = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    guard !Task.isCancelled else { return }
    // An arrow-key highlight stays on the same row as results arrive, never on whatever now has its position.
    let before = rows
    let highlighted = highlight.flatMap { before.indices.contains($0) ? before[$0].id : nil }
    results = found
    resultsKey = key
    if let highlighted { highlight = rows.firstIndex { $0.id == highlighted } }
    if pendingReturn { submit() }
  }

  private func activate(_ index: Int?, in rows: [Row]) {
    guard let index, rows.indices.contains(index), rows[index].enabled else { return }
    rows[index].run()
  }
  private func navigate(_ url: URL) {
    let parts = url.path.split(separator:"/")
    if parts.count == 2 || parts.count > 2 && ["actions","blob","tree","releases","branches","tags","commits","pulls"].contains(String(parts[2])) {
      Task { await setup.navigateFeatureURL(url);dismiss() };return
    }
    switch PRRouteResolver.resolve(
      url, cached: workspace.rows, activeAccount: setup.activeAccount)
    {
    case .native(let key): open(key)
    case .chooseAccount(let keys): workspace.routeChoices = keys
    case .web(let url): ExternalLinkPolicy.open(url)
    case .unavailable:
      workspace.status = "This destination is unavailable in the selected account."
      AccessibilityNotification.Announcement("This destination is unavailable in the selected account.").post()
    }
    dismiss()
  }
  private func icon(_ destination: PRPaletteSearch.Destination) -> String {
    switch destination {
    case .board: "rectangle.split.3x1"
    case .list: "list.bullet"
    case .activity: "tray"
    case .actions: "play.circle"
    case .repos: "folder"
    case .accounts: "person.crop.circle.badge.plus"
    case .settings: "gearshape"
    }
  }
  private func navigate(_ destination: PRPaletteSearch.Destination) {
    switch destination {
    case .board:
      workspace.state.current.mode = .board
      setup.destination = .pullRequests
    case .list:
      workspace.state.current.mode = .list
      setup.destination = .pullRequests
    case .activity: setup.destination = .activity
    case .actions: setup.showActions()
    case .repos: setup.destination = .repos
    case .accounts: setup.destination = .setup
    case .settings: openSettings()
    }
    dismiss()
  }
}

extension PRCommandTarget {
  /// The palette's commands for the workspace's focused (or multi-selected) pull requests, enabled by the same
  /// `PRRowActionState` rules as the Pull Request menu and the board keys. Approving or requesting changes is
  /// not offered on your own pull request, which GitHub refuses.
  @MainActor static func palette(in workspace: PRWorkspaceModel, open: @escaping (ProviderKey) -> Void) -> PRCommandTarget? {
    let rows = workspace.commandRows
    guard !rows.isEmpty else { return nil }
    let state = workspace.actionState(rows)
    let single = rows.count == 1 ? rows.first : nil
    let own = single?.metadata?.viewerIsAuthor == true
    // An action sheet already showing is never replaced.
    let sheetFree = !workspace.isPresentingAction
    return PRCommandTarget(
      subject: single.map { $0.metadata.map { "#\($0.number)" } ?? $0.title } ?? "\(rows.count) pull requests",
      open: single.map { pr in { open(pr.key) } },
      approve: state.canApprove && !own && sheetFree ? { workspace.requestBatch(approve: true, rows: rows) } : nil,
      requestChanges: state.canRequestChanges && !own && sheetFree ? single.map { pr in { workspace.requestReview(pr, decision: .requestChanges) } } : nil,
      comment: state.canComment && sheetFree ? single.map { pr in { workspace.requestReview(pr, decision: .comment) } } : nil,
      merge: state.canMerge && sheetFree ? { workspace.requestBatch(approve: false, rows: rows) } : nil,
      labels: state.canEditLabels && sheetFree ? single.map { pr in { workspace.requestLabels(pr) } } : nil,
      copyLink: state.canCopyLink ? { workspace.copyLinks(rows) } : nil,
      openOnWeb: single?.metadata == nil ? nil : single.map { pr in { workspace.web(pr) } })
  }
}

/// Full-width palette rows; the highlighted row follows the arrow keys.
private struct PaletteRowStyle: ButtonStyle {
  var highlighted = false
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(PaletteLabelStyle())
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 5).padding(.horizontal, 6)
      .foregroundStyle(isEnabled ? .primary : .tertiary)
      .background(configuration.isPressed ? DesignTokens.cobalt.opacity(0.22) : highlighted ? DesignTokens.cobalt.opacity(0.14) : .clear,
        in: RoundedRectangle(cornerRadius: 6))
      .contentShape(Rectangle())
  }
}
private struct PaletteLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 10) {
      configuration.icon.foregroundStyle(DesignTokens.cobalt).frame(width: 20)
      configuration.title.lineLimit(1)
    }
  }
}
