import AppKit
import MergeProCore
import SwiftUI
import UniformTypeIdentifiers

struct PRWorkspaceView: View {
  @Bindable var setup: SetupModel
  @Bindable var workspace: PRWorkspaceModel
  /// Embedded workspaces (repository tabs) omit the page header, toolbar and window title.
  var embedded = false
  @Environment(\.openWindow) private var openWindow
  @FocusState private var filterFocused: Bool
  @State private var tokenField: FilterExpression.Field = .repo
  @State private var tokenOperator: FilterExpression.Operator = .equals
  @State private var tokenValue = ""
  @State private var exportDocument = PRViewsDocument()
  @State private var exportReady = false
  @State private var diagnosticsPresented = false
  private func open(_ key: ProviderKey) {
    workspace.instrumentation?.willOpen(key)
    workspace.recordOpen(key)
    // The detail window loads its own data; opening a PR never forces a poll of every repository.
    openWindow(id: "pr-detail", value: key)
  }
  var body: some View {
    VStack(spacing: 0) {
      if embedded { Color.clear.frame(height: 16) } else { workspaceHeader }
      filterBar.padding(.horizontal, 24).padding(.bottom, 12)
      if let error = workspace.filterError {
        Label { Text(error) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
          .font(.callout).padding(.horizontal, 24).padding(.bottom, 8)
      }
      HStack(spacing: 12) {
        Button { diagnosticsPresented = true } label: {
          HStack(spacing: 7) {
            if freshnessNeedsAttention {
              Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.orange)
            } else if setup.isRefreshing || syncingCount > 0 {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "info.circle").foregroundStyle(DesignTokens.cobalt)
            }
            Text(freshnessNeedsAttention || syncingCount > 0 || !setup.isRefreshing ? freshnessSummary : "Refreshing repositories…").lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
          }
          .font(.callout)
        }
        .buttonStyle(.plain)
        .help("View repository freshness and diagnostics")
        .popover(isPresented: $diagnosticsPresented, arrowEdge: .bottom) { freshnessDetails }
        Spacer(minLength: 8)
        if embedded {
          Picker("Layout", selection: $workspace.state.current.mode) {
            Label("Board", systemImage: "rectangle.split.3x1").labelStyle(.iconOnly).help("Board")
              .accessibilityLabel("Board").tag(PRViewConfiguration.Mode.board)
            Label("List", systemImage: "list.bullet").labelStyle(.iconOnly).help("List")
              .accessibilityLabel("List").tag(PRViewConfiguration.Mode.list)
          }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
          .accessibilityLabel("Layout")
        }
        if !setup.isRefreshing, let status = setup.pollStatus {
          Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(status)
        }
        Button("Mark all seen") { workspace.markSeen() }.controlSize(.small)
      }.padding(.horizontal, 24).padding(.bottom, 12)
      ZStack {
        if workspace.state.current.mode == .board {
          PRBoardView(workspace: workspace, open: open)
        } else {
          VStack(spacing: 0) {
            PRListView(workspace: workspace, open: open)
            if workspace.projection.hiddenCount > 0 {
              Button("\(workspace.projection.hiddenCount) older PRs hidden — Show all") { workspace.widen() }.padding(8)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .padding(.horizontal, 24).padding(.bottom, 20)
        }
        if workspace.projection.rows.isEmpty {
          if workspace.hasLoadedRows { emptyState } else { ProgressView("Loading cached pull requests…").controlSize(.small) }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      if let footer = workspace.instrumentation?.footer { footer }
      if let status = workspace.status {
        Text(status).font(.caption).foregroundStyle(.secondary).padding(6)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background { WorkspaceCanvas() }
    .modifier(PRWorkspaceTitle(enabled: !embedded))
    // Shortcuts (⌘1 ⌘2 ⌘F ⌘K ⌘R) belong to the main menu, which calls the published command target; the toolbar
    // only names them in its help text, so no key is registered twice.
    .modifier(PRWorkspaceToolbar(enabled: !embedded, setup: setup, workspace: workspace, find: { filterFocused = true }))
    .background {
      if !embedded {
        PRCommandTargetPublisher(setup: setup, workspace: workspace, open: open, find: { filterFocused = true })
      }
    }
    .background(
      // Embedded, the monitor spans the workspace so it can tell the PR list from the repository list beside it.
      PRKeyboardMonitor(embedded: embedded) { key in
        switch key {
        case "j": workspace.moveFocus(1)
        case "k": workspace.moveFocus(-1)
        case "x": workspace.toggleSelection()
        case "t": workspace.cycleTime()
        case "a","r","c","m": workspace.keyboardAction(key)
        case "\r":
          // The highlighted row: the focused card, or in the list the table row j/k selected.
          guard let key = workspace.visibleFocus else { return false }
          open(key)
        default: return false
        }
        return true
      }.frame(width: embedded ? nil : 0, height: embedded ? nil : 0)
    )
    .sheet(isPresented: $workspace.palettePresented) {
      CommandPalette(setup: setup, workspace: workspace, open: open)
    }
    .sheet(item:$workspace.actionPresentation) { PRActionSheet(presentation:$0,workspace:workspace) }
    .confirmationDialog("Convert to draft?",isPresented:Binding(get:{ workspace.pendingDraftConversion != nil },set:{ if !$0 { workspace.pendingDraftConversion=nil } }),titleVisibility:.visible,presenting:workspace.pendingDraftConversion) { pr in
      Button("Convert to draft") { workspace.pendingDraftConversion=nil;Task { await workspace.setDraft(pr,true) } }
      Button("Cancel",role:.cancel) { workspace.pendingDraftConversion=nil }
    } message: { pr in Text("\(pr.title) becomes a draft. Reviewers stop being asked to review it, and it leaves the merge queue if it was queued.") }
    .alert("Can’t merge #\(String(workspace.blockedMerge?.pr.metadata?.number ?? 0))",isPresented:Binding(get:{ workspace.blockedMerge != nil },set:{ if !$0 { workspace.blockedMerge=nil } })) {
      if let url=workspace.blockedMerge?.pr.metadata?.webURL { Button("Open on GitHub") { ExternalLinkPolicy.open(url);workspace.blockedMerge=nil } }
      Button("OK",role:.cancel) { workspace.blockedMerge=nil }
    } message: {
      Text((workspace.blockedMerge?.reason).map { $0.isEmpty ? "GitHub doesn’t allow this merge yet." : $0 } ?? "")
    }
    .sheet(isPresented: $workspace.viewEditorPresented) { viewEditor }
    .fileImporter(isPresented: $workspace.importPresented, allowedContentTypes: [.json]) { result in
      if case .success(let url) = result {
        let allowed = url.startAccessingSecurityScopedResource()
        defer { if allowed { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url) { Task { await workspace.importViews(data) } }
      }
    }
    .fileExporter(
      isPresented: $exportReady, document: exportDocument, contentType: .json,
      defaultFilename: "MergePro Views"
    ) { result in if case .failure = result { workspace.status = "Views could not be exported." } }
    .task { await workspace.load() }
    .background { if let probe = workspace.instrumentation?.probe { probe } }
  }
  private var workspaceHeader: some View {
    WorkspaceSectionHeader(
      title: workspace.state.views.first { $0.id == workspace.state.currentViewID }?.name ?? "Pull Requests",
      subtitle: "Review, organize, and ship across your repositories.",
      symbol: "arrow.triangle.pull"
    ) {
      WorkspaceStatusBadge(
        text: "\(workspace.projection.rows.count) \(workspace.projection.rows.count == 1 ? "pull request" : "pull requests")",
        symbol: "arrow.triangle.pull", tint: DesignTokens.cobalt
      )
    }
  }

  private var scopedRevokedCount: Int {
    workspace.revoked.filter { workspace.state.accountFilter == nil || $0 == workspace.state.accountFilter }.count
  }
  private var freshnessNeedsAttention: Bool {
    scopedRevokedCount > 0 || workspace.repositoryFreshness.contains(where: \.needsAttention)
  }
  /// Repositories still catching up (first sync, a history walk, a queued read): progress, not a problem.
  private var syncingCount: Int { workspace.repositoryFreshness.filter(\.isSyncing).count }
  private var freshnessSummary: String {
    if scopedRevokedCount > 0 { return "Reconnect \(scopedRevokedCount) \(scopedRevokedCount == 1 ? "account" : "accounts")" }
    let repositories = workspace.repositoryFreshness
    guard !repositories.isEmpty else { return "Choose tracked repositories in Setup" }
    let failing = repositories.filter(\.needsAttention), affected = failing.count
    // A quota pause fails every repository at once and clears by itself at the reset: say so instead of listing them.
    if affected > 1, failing.allSatisfy({ ($0.message ?? "").localizedCaseInsensitiveContains("API budget is paused") || ($0.message ?? "").localizedCaseInsensitiveContains("rate limit") }) {
      return "Paused by GitHub's API limit · showing cached PRs"
    }
    if affected > 0 {
      return repositories.count == 1 ? "Repository needs attention" : "\(affected) of \(repositories.count) repositories need attention"
    }
    if syncingCount > 0 {
      return repositories.count == 1 ? "Syncing repository…" : "Syncing · \(repositories.count - syncingCount) of \(repositories.count) repositories ready"
    }
    return "\(repositories.count) \(repositories.count == 1 ? "repository" : "repositories") current"
  }
  private var freshnessDetails: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Label("Repository status", systemImage: "arrow.triangle.2.circlepath").font(.headline)
        if let status = setup.pollStatus {
          HStack(spacing: 6) {
            if setup.isRefreshing { ProgressView().controlSize(.small) }
            Text(status).font(.callout).foregroundStyle(.secondary)
          }
        } else if setup.isRefreshing { ProgressView("Refreshing repositories…").controlSize(.small) }
        Text(workspace.freshness).font(.callout).textSelection(.enabled)
        // Problems first, then repositories still syncing, then current ones.
        ForEach(workspace.repositoryFreshness.sorted { ($0.needsAttention ? 0 : $0.isSyncing ? 1 : 2) < ($1.needsAttention ? 0 : $1.isSyncing ? 1 : 2) }) { repository in
          VStack(alignment: .leading, spacing: 5) {
            Text(repository.name).font(.callout.weight(.semibold))
            Label {
              Text(repository.label).foregroundStyle(.secondary)
            } icon: {
              Image(systemName: repository.needsAttention ? "exclamationmark.circle" : repository.isSyncing ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                .foregroundStyle(repository.needsAttention ? Color.orange : Color.secondary)
            }
            if let message = repository.message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            if let at = repository.lastSuccessAt {
              Text("Last success \(at.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
            }
          }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
        Button("Open Setup") { diagnosticsPresented = false; setup.destination = .setup }
      }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }.frame(width: 420).frame(maxHeight: 480)
  }
  private var emptyState: some View {
    VStack(spacing: 18) {
      Image(systemName: "arrow.triangle.pull")
        .font(.system(size: 32, weight: .medium))
        .foregroundStyle(LinearGradient(colors: [DesignTokens.cobalt, DesignTokens.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
        .frame(width: 76, height: 76).workspacePanel(radius: 24)
      VStack(spacing: 8) {
        Text("Room for your next review").font(.system(size: 23, weight: .semibold, design: .rounded))
        Text("No matching pull requests. Adjust your filters or choose tracked repositories in Setup.")
          .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .frame(maxWidth: 340)
      }
      HStack(spacing: 10) {
        Button("Open Setup") { setup.destination = .setup }.buttonStyle(.borderedProminent)
        if !workspace.filterText.isEmpty {
          Button("Clear filter") { workspace.filterText = "" }.buttonStyle(.bordered)
        }
        if workspace.projection.hiddenCount > 0 {
          Button("Show older PRs") { workspace.widen() }.buttonStyle(.bordered)
        }
      }.controlSize(.large)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background { WorkspaceCanvas() }
  }
  private var filterBar: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Filter PRs — repo:owner/name request:me or text", text: $workspace.filterText)
          .textFieldStyle(.plain).font(.body).focused($filterFocused).accessibilityIdentifier(
            "prFilter"
          )
          // Debounced; the projection runs off the main actor so typing never waits on the board.
          .onChange(of: workspace.filterText) { _, _ in workspace.filterTextChanged() }
        Menu("Add filter") {
          Picker("Field", selection: $tokenField) {
            ForEach(FilterExpression.Field.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          Picker("Operator", selection: $tokenOperator) {
            ForEach(tokenField.supportedOperators, id: \.self) { Text($0.rawValue).tag($0) }
          }
        }
        TextField("Value", text: $tokenValue).frame(width: 90).textFieldStyle(.roundedBorder)
        Button {
          guard !tokenValue.isEmpty else { return }
          workspace.state.current.filter.tokens.append(
            .init(field: tokenField, operation: tokenOperator, value: tokenValue))
          tokenValue = ""
          workspace.filterText = workspace.state.current.filter.serialized
        } label: {
          Image(systemName: "plus")
        }.help("Add token")
        .accessibilityLabel("Add filter token")
      }
      if !workspace.state.current.filter.tokens.isEmpty {
        ScrollView(.horizontal) {
          HStack {
            ForEach(Array(workspace.state.current.filter.tokens.enumerated()), id: \.offset) {
              index, token in
              Button("\(token.field.rawValue) \(token.operation.rawValue) \(token.value) ×") {
                workspace.state.current.filter.tokens.remove(at: index)
                workspace.filterText = workspace.state.current.filter.serialized
              }.buttonStyle(.bordered).controlSize(.small)
              .accessibilityLabel("Remove filter \(token.field.rawValue) \(token.operation.rawValue) \(token.value)")
            }
          }
        }
      }
      if workspace.state.current.timeScope == .custom {
        HStack {
          DatePicker(
            "From",
            selection: Binding(
              get: { workspace.state.current.customStart ?? Date().addingTimeInterval(-86400) },
              set: { workspace.state.current.customStart = $0 }))
          DatePicker(
            "To",
            selection: Binding(
              get: { workspace.state.current.customEnd ?? Date() },
              set: { workspace.state.current.customEnd = $0 }))
        }
      }
    }.padding(14).workspaceGlass(radius: 18).onChange(of: tokenField) { _, field in
      if !field.supportedOperators.contains(tokenOperator) { tokenOperator = .equals }
    }
    // A nil start applies no lower bound; store the date the "From" picker displays.
    .onChange(of: workspace.state.current.timeScope) { _, scope in
      if scope == .custom, workspace.state.current.customStart == nil {
        workspace.state.current.customStart = Date().addingTimeInterval(-86400)
      }
    }
  }
  private var viewEditor: some View {
    VStack {
      Text("PR view settings").font(.title3.weight(.semibold))
      Form {
        Picker("Grouping", selection: $workspace.state.current.grouping) {
          ForEach(PRViewConfiguration.Grouping.allCases, id: \.self) {
            Text(ProviderStateText.grouping($0)).tag($0)
          }
        }
        Picker("Sort", selection: $workspace.state.current.sort) {
          ForEach(PRViewConfiguration.Sort.allCases, id: \.self) {
            Text(ProviderStateText.sort($0)).tag($0)
          }
        }
        Toggle("Ascending", isOn: $workspace.state.current.ascending)
        Picker("Measured on", selection: $workspace.state.current.measuredField) {
          Text("Last activity (updated fallback)").tag(PRViewConfiguration.MeasuredField.activity)
          Text("Created").tag(PRViewConfiguration.MeasuredField.created)
          Text("Updated").tag(PRViewConfiguration.MeasuredField.updated)
        }
        Toggle(
          "Keep PRs waiting on me regardless of age", isOn: $workspace.state.current.keepWaitingOnMe
        )
        Toggle("Show stack layers as separate cards",isOn:Binding(get:{ workspace.state.current.separateStackLayers == true },set:{ workspace.state.current.separateStackLayers=$0 }))
        Toggle("Compact cards", isOn: $workspace.state.current.compact)
        Toggle("Show Draft column", isOn: $workspace.state.current.showDrafts)
        Toggle("Hide Merged", isOn: $workspace.state.current.hideMerged)
        Stepper(
          "Merged window: \(workspace.state.current.mergedDays) days",
          value: $workspace.state.current.mergedDays, in: 1...36500)
        Section("Table columns — shown in this order") {
          ForEach(workspace.state.current.columns, id: \.self) { column in
            let title = ProviderStateText.tableColumn(column)
            HStack {
              Text(title)
              Spacer()
              Button {
                moveColumn(column, -1)
              } label: {
                Image(systemName: "arrow.up")
              }.help("Move column earlier")
              .accessibilityLabel("Move \(title) column earlier")
              Button {
                moveColumn(column, 1)
              } label: {
                Image(systemName: "arrow.down")
              }.help("Move column later")
              .accessibilityLabel("Move \(title) column later")
              Button {
                workspace.state.current.columns.removeAll { $0 == column }
              } label: {
                Image(systemName: "minus")
              }.help("Hide column")
              .accessibilityLabel("Hide \(title) column")
            }
          }
          Menu("Show column") {
            ForEach(
              PRViewConfiguration.TableColumn.allCases.filter {
                !workspace.state.current.columns.contains($0)
              }, id: \.self
            ) { column in
              Button(ProviderStateText.tableColumn(column)) { workspace.state.current.columns.append(column) }
            }
          }
        }
        Section("Saved views") {
          ForEach(workspace.state.views) { view in
            HStack {
              TextField(
                "Name",
                text: Binding(
                  get: { workspace.state.views.first { $0.id == view.id }?.name ?? "" },
                  set: { name in
                    if !name.isEmpty,
                      let index = workspace.state.views.firstIndex(where: { $0.id == view.id })
                    {
                      workspace.state.views[index].name = name
                    }
                  }))
              Picker(
                "Icon",
                selection: Binding(
                  get: { workspace.state.views.first { $0.id == view.id }?.icon ?? view.icon },
                  set: { icon in
                    if let index = workspace.state.views.firstIndex(where: { $0.id == view.id }) {
                      workspace.state.views[index].icon = icon
                    }
                  })
              ) {
                ForEach(
                  [
                    "line.3.horizontal.decrease.circle", "star", "person", "person.2",
                    "checkmark.circle", "exclamationmark.triangle", "clock",
                  ], id: \.self
                ) { Image(systemName: $0).tag($0) }
              }.labelsHidden().frame(width: 55)
              Button(view.isDefault ? "Default" : "Make default") { workspace.defaultView(view.id) }
                .disabled(view.isDefault)
              Toggle(
                "Notify",
                isOn: Binding(
                  get: {
                    workspace.state.views.first { $0.id == view.id }?.notificationRule ?? false
                  },
                  set: { enabled in
                    if let index = workspace.state.views.firstIndex(where: { $0.id == view.id }) {
                      workspace.state.views[index].notificationRule = enabled
                    }
                  })
              ).toggleStyle(.checkbox)
              Button(view.hidden ? "Show" : "Hide") { workspace.hideView(view.id) }
              Button {
                workspace.moveView(view.id, direction: -1)
              } label: {
                Image(systemName: "arrow.up")
              }.help("Move view up")
              .accessibilityLabel("Move \(view.name) up")
              Button {
                workspace.moveView(view.id, direction: 1)
              } label: {
                Image(systemName: "arrow.down")
              }.help("Move view down")
              .accessibilityLabel("Move \(view.name) down")
            }
          }
          Button("Save current settings to selected view") {
            if let view = workspace.state.views.first(where: {
              $0.id == workspace.state.currentViewID
            }) {
              workspace.updateCurrentView(name: view.name, icon: view.icon)
            }
          }
          Button("Save as new view") {
            workspace.saveCurrent(name: "Saved view \(workspace.state.views.count+1)")
          }
          HStack {
            Button("Import views…") {
              workspace.viewEditorPresented = false
              workspace.importPresented = true
            }
            Button("Export views…") {
              Task {
                if let data = await workspace.exportViews() {
                  exportDocument = PRViewsDocument(data: data)
                  workspace.viewEditorPresented = false
                  exportReady = true
                } else { workspace.status = "Views could not be exported." }
              }
            }
          }
        }
      }.formStyle(.grouped)
      Button("Done") { workspace.viewEditorPresented = false }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
    }.padding(16).frame(width: 580, height: 690)
    // Escape closes the settings like Done; every change already applied as it was made.
    .onExitCommand { workspace.viewEditorPresented = false }
  }
  private func moveColumn(_ column: PRViewConfiguration.TableColumn, _ direction: Int) {
    guard let index = workspace.state.current.columns.firstIndex(of: column),
      workspace.state.current.columns.indices.contains(index + direction)
    else { return }
    workspace.state.current.columns.swapAt(index, index + direction)
  }

}
/// The main workspace toolbar, customizable (View ▸ Customize Toolbar) with stable item identifiers.
private struct PRWorkspaceToolbar: ViewModifier {
  let enabled: Bool
  let setup: SetupModel
  @Bindable var workspace: PRWorkspaceModel
  let find: () -> Void
  func body(content: Content) -> some View {
    if enabled {
      content.toolbar(id: "prWorkspace") {
        ToolbarItem(id: "boardMode") {
          let selected = workspace.state.current.mode == .board
          Button {
            workspace.state.current.mode = .board
          } label: {
            Label("Board", systemImage: selected ? "rectangle.split.3x1.fill" : "rectangle.split.3x1")
              .foregroundStyle(selected ? DesignTokens.cobalt : Color.primary)
          }.help("Board (⌘1)").accessibilityIdentifier("boardMode")
          .accessibilityLabel("Board").accessibilityAddTraits(selected ? .isSelected : [])
        }
        ToolbarItem(id: "listMode") {
          let selected = workspace.state.current.mode == .list
          Button {
            workspace.state.current.mode = .list
          } label: {
            Label("List", systemImage: "list.bullet")
              .foregroundStyle(selected ? DesignTokens.cobalt : Color.primary)
          }.help("List (⌘2)").accessibilityIdentifier("listMode")
          .accessibilityLabel("List").accessibilityAddTraits(selected ? .isSelected : [])
        }
        ToolbarItem(id: "timeScope") {
          Picker("Time scope", selection: $workspace.state.current.timeScope) {
            ForEach(PRTimeScope.allCases, id: \.self) { Text($0.title).tag($0) }
          }.frame(width: 150).help("Time scope (T)")
        }
        ToolbarItem(id: "find") {
          Button(action: find) {
            Label("Find", systemImage: "magnifyingglass")
          }.help("Find (⌘F)")
        }
        ToolbarItem(id: "commandPalette") {
          Button {
            workspace.palettePresented = true
          } label: {
            Label("Command palette", systemImage: "command")
          }.help("Command palette (⌘K)")
        }
        ToolbarItem(id: "refresh") {
          Button {
            Task { await setup.refreshActivity() }
          } label: {
            if setup.isRefreshing {
              ProgressView().controlSize(.small)
            } else {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
          }.help("Refresh (⌘R)")
            .disabled(setup.isRefreshing)
            .accessibilityLabel(setup.isRefreshing ? "Refreshing repositories" : "Refresh")
            .accessibilityIdentifier("refreshPRs")
        }
        ToolbarItem(id: "viewSettings") {
          Button {
            workspace.viewEditorPresented = true
          } label: {
            Label("View settings", systemImage: "slider.horizontal.3")
          }.help("View settings")
        }
      }
    } else {
      content
    }
  }
}
/// Publishes the main menu's PR commands for the focused/selected PRs. A separate view, so only it re-evaluates
/// when j/k moves the selection.
private struct PRCommandTargetPublisher: View {
  let setup: SetupModel
  let workspace: PRWorkspaceModel
  let open: (ProviderKey) -> Void
  let find: () -> Void
  var body: some View {
    let rows = workspace.commandRows
    let state = workspace.actionState(rows)
    let single = rows.count == 1 ? rows.first : nil
    let subject = single.map { "#\(String($0.metadata?.number ?? 0))" } ?? (rows.isEmpty ? nil : "\(rows.count) pull requests")
    // While an action sheet is showing, commands that would present another are disabled: replacing it would
    // dismiss a merge or review mid-write.
    let sheetFree = !workspace.isPresentingAction
    Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
      .focusedSceneValue(
        \.prCommandTarget,
        PRCommandTarget(
          subject: subject,
          open: single.map { pr in { open(pr.key) } },
          approve: state.canApprove && sheetFree ? { workspace.requestBatch(approve: true, rows: rows) } : nil,
          requestChanges: state.canRequestChanges && sheetFree ? single.map { pr in { workspace.requestReview(pr, decision: .requestChanges) } } : nil,
          comment: state.canComment && sheetFree ? single.map { pr in { workspace.requestReview(pr, decision: .comment) } } : nil,
          merge: state.canMerge && sheetFree ? { workspace.requestBatch(approve: false, rows: rows) } : nil,
          labels: state.canEditLabels && sheetFree ? single.map { pr in { workspace.requestLabels(pr) } } : nil,
          refresh: single.map { pr in { Task { await workspace.refreshMergeEvidence(pr) } } },
          copyLink: state.canCopyLink ? { workspace.copyLinks(rows) } : nil,
          openOnWeb: single?.metadata == nil ? nil : single.map { pr in { workspace.web(pr) } },
          nextPR: { workspace.moveFocus(1) },
          previousPR: { workspace.moveFocus(-1) },
          showBoard: { workspace.state.current.mode = .board },
          showList: { workspace.state.current.mode = .list },
          find: find,
          showPalette: { workspace.palettePresented = true },
          refreshWorkspace: { Task { await setup.refreshActivity() } },
          isRefreshing: setup.isRefreshing))
  }
}
private struct PRWorkspaceTitle: ViewModifier {
  let enabled: Bool
  func body(content: Content) -> some View {
    if enabled { content.navigationTitle("MergePro").navigationSubtitle("Pull Requests") } else { content }
  }
}
struct PRViewsDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data = Data()
  init(data: Data = Data()) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
