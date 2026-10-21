import AppKit
import MergeProCore
import Observation
import SwiftUI

struct MenuBarView: View {
  @Bindable var model: SetupModel
  let showMain: () -> Void
  let showSettings: () -> Void
  let open: (ProviderKey) -> Void
  @AppStorage("menuBarNeedsExpanded") private var needsExpanded = true
  @AppStorage("menuBarMineExpanded") private var mineExpanded = true
  @AppStorage("menuBarRunsExpanded") private var runsExpanded = false
  @AppStorage("menuBarPresetsExpanded") private var presetsExpanded = false
  /// The "Needs me" count beside the status item; on by default, switched off from this popover.
  @AppStorage(PRStatusItemController.showsCountKey) private var showsNeedsCount = true
  var body: some View {
    let needs = model.prs.menuQueue(mine: false)
    let mine = model.prs.menuQueue(mine: true)
    // Active runs, then runs that failed in the last day.
    let runs = PRMenuBarRules.menuRuns(model.cachedRuns, now: Date())
    let running = runs.filter(\.isActive).count
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
      HStack(spacing: 8) {
        MenuStatTile(title: "Needs me", count: needs.count, symbol: "person.crop.circle.badge.exclamationmark", tint: .orange) { needsExpanded = true }
        MenuStatTile(title: "My PRs", count: mine.count, symbol: "arrow.triangle.pull", tint: DesignTokens.cobalt) { mineExpanded = true }
        MenuStatTile(title: "Running", count: running, symbol: "play.circle.fill", tint: .green) { runsExpanded = true }
      }.padding(.horizontal, 12).padding(.bottom, 10)
      Divider().padding(.horizontal, 12)
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          MenuSection(title: "Needs me", symbol: "person.crop.circle.badge.exclamationmark", tint: .orange, count: needs.count, expanded: $needsExpanded) {
            queue(needs, empty: "Nothing waiting on you", showApprove: true)
          }
          MenuSection(title: "My PRs", symbol: "arrow.triangle.pull", tint: DesignTokens.cobalt, count: mine.count, expanded: $mineExpanded) {
            queue(mine, empty: "No open pull requests")
          }
          MenuSection(title: "Workflow runs", symbol: "play.circle", tint: .green, count: runs.count, expanded: $runsExpanded) {
            if runs.isEmpty { MenuEmptyRow(text: "No active or recently failed cached runs") }
            ForEach(runs) { run in
              Button {
                model.showActions(repository: run.repository.key, runID: run.runID); showMain()
              } label: {
                MenuItemRow(symbol: run.isActive ? "clock.fill" : "xmark.octagon.fill", tint: actionsStatusTint(run.conclusion ?? run.status), title: run.name,
                  subtitle: run.isActive ? "\(run.repository.name) · \(run.branch) · attempt \(run.attempt)"
                    : "Failed \(run.updatedAt.formatted(.relative(presentation: .named))) · \(run.repository.name) · \(run.branch)",
                  badge: run.isActive ? nil : "Failed", badgeTint: .red)
              }.buttonStyle(MenuRowButtonStyle())
            }
          }
          MenuSection(title: "Workflow presets", symbol: "bookmark", tint: DesignTokens.violet, count: model.cachedPresets.count, expanded: $presetsExpanded) {
            if model.cachedPresets.isEmpty { MenuEmptyRow(text: "Save a preset from Actions") }
            ForEach(Array(model.cachedPresets.prefix(20))) { preset in
              Button {
                model.showActions(repository: preset.repository, workflowID: preset.workflowID, presetID: preset.id); showMain()
              } label: {
                MenuItemRow(symbol: "play.fill", tint: DesignTokens.violet, title: preset.name, subtitle: preset.ref)
              }.buttonStyle(MenuRowButtonStyle())
            }
          }
        }.padding(.horizontal, 8).padding(.vertical, 8)
      }
      .scrollIndicators(.automatic)
      .frame(maxHeight: 380)
      .fixedSize(horizontal: false, vertical: true)
      Divider().padding(.horizontal, 12)
      HStack(spacing: 8) {
        MenuShortcut(title: "Repositories", symbol: "folder", tint: DesignTokens.cobalt) { model.destination = .repos; showMain() }
        MenuShortcut(title: "Local", symbol: "externaldrive", tint: .teal) { model.localCheckout = nil; model.destination = .local; showMain() }
        MenuShortcut(title: "Activity inbox", symbol: "tray", tint: DesignTokens.violet) { model.destination = .activity; showMain() }
      }.padding(.horizontal, 12).padding(.vertical, 10)
      Toggle("Show “Needs me” count in the menu bar", isOn: $showsNeedsCount)
        .toggleStyle(.checkbox).font(.caption)
        .padding(.horizontal, 16).padding(.bottom, 8)
        .onChange(of: showsNeedsCount) { _, _ in model.statusItem.updateCount() }
        .accessibilityIdentifier("menuBarShowsCount")
      Divider().padding(.horizontal, 12)
      HStack(spacing: 8) {
        Button { showMain() } label: { Label("Open MergePro", systemImage: "macwindow").frame(maxWidth: .infinity) }
          .buttonStyle(.borderedProminent).tint(DesignTokens.cobalt).controlSize(.large)
        Button { showSettings() } label: { Image(systemName: "gearshape") }
          .buttonStyle(.bordered).controlSize(.large).help("Settings…").accessibilityLabel("Settings…")
        Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
          .buttonStyle(.bordered).controlSize(.large).help("Quit MergePro").accessibilityLabel("Quit MergePro")
          .keyboardShortcut("q")
      }.padding(12)
    }
    .frame(width: 380)
    .background {
      LinearGradient(colors: [DesignTokens.cobalt.opacity(0.10), DesignTokens.violet.opacity(0.05), .clear],
        startPoint: .top, endPoint: .center).allowsHitTesting(false)
    }
    .task { await model.refreshFeatureCaches() }
  }
  private var header: some View {
    HStack(spacing: 10) {
      Image("AppLogo").resizable().scaledToFit()
        .frame(width: 34, height: 34).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text("MergePro").font(.system(.headline, design: .rounded))
        HStack(spacing: 5) {
          Circle().fill(model.snapshots.isEmpty ? Color.secondary : model.accountProblems.isEmpty ? Color.green : Color.orange).frame(width: 6, height: 6)
          Text(accountSummary).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      if model.isRefreshing { ProgressView().controlSize(.small) }
    }
  }
  private var accountSummary: String {
    if model.snapshots.isEmpty { return "No accounts connected" }
    let base = "\(model.snapshots.count) \(model.snapshots.count == 1 ? "account" : "accounts") connected"
    return model.accountProblems.isEmpty ? base : base + " · needs attention"
  }
  @ViewBuilder private func queue(_ rows: [PullRequest], empty: String, showApprove: Bool = false) -> some View {
    if rows.isEmpty { MenuEmptyRow(text: empty) }
    ForEach(Array(rows.prefix(20))) { pr in
      let column = BoardProjection.column(for: pr, showDrafts: true)
      HStack(spacing: 4) {
        Button {
          model.destination = .pullRequests
          model.prs.select(pr.key)
          showMain()
          open(pr.key)
        } label: {
          MenuItemRow(symbol: DesignTokens.columnIcon(column), tint: DesignTokens.columnColor(column), title: pr.title,
            subtitle: "\(pr.metadata?.repositoryName ?? pr.key.repositoryID) #\(String(pr.metadata?.number ?? 0))",
            badge: pr.isDraft ? "Draft" : column == .approved ? "Approved" : nil, badgeTint: DesignTokens.columnColor(column))
        }.buttonStyle(MenuRowButtonStyle())
        if showApprove && canApprove(pr) {
          Button { requestApproval(pr) } label: { Label("Approve…", systemImage: "checkmark") }
            .buttonStyle(.bordered).tint(.green).controlSize(.small)
            .fixedSize()
            .help("Review and approve this pull request")
            .accessibilityLabel("Approve \(pr.title)")
            .accessibilityIdentifier("menuBarApprove-\(pr.key.objectID)")
        }
      }.contextMenu {
        Button("Merge…") { requestMerge(pr) }.disabled(!model.prs.mergeEligibility(pr).opensMergeSheet)
        Button("Approve…") { requestApproval(pr) }.disabled(!canApprove(pr))
      }
    }
  }
  /// Approving acts as the action account: only its own cached copy of this row, never your own PR.
  private func canApprove(_ pr: PullRequest) -> Bool {
    PRMenuBarRules.offersApproval(row: pr, actionPR: model.prs.actionPRCached(pr))
  }
  /// While an action sheet is showing it is not replaced: showing the main window brings it forward instead.
  private func requestApproval(_ pr: PullRequest) {
    guard canApprove(pr) else { return }
    model.destination = .pullRequests
    if !model.prs.isPresentingAction { model.prs.select(pr.key) }
    model.prs.requestReview(pr, decision: .approve)
    showMain()
  }
  /// Merging acts as the action account: the merge sheet only for that account's own copy of this row, otherwise
  /// the pull request opens (its window shows the account it acts as).
  private func requestMerge(_ pr: PullRequest) {
    switch PRMenuBarRules.mergeRoute(row: pr, actionPR: model.prs.actionPRCached(pr)) {
    case .mergeSheet:
      model.destination = .pullRequests
      showMain()
      model.prs.requestMerge(pr)
    case .openPullRequest:
      showMain()
      open(pr.key)
    }
  }
}

private struct MenuStatTile: View {
  let title: String
  let count: Int
  let symbol: String
  let tint: Color
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 4) {
        Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(tint).accessibilityHidden(true)
        Text("\(count)").font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(tint.opacity(count > 0 ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(count > 0 ? 0.30 : 0.12), lineWidth: 1))
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title): \(count)")
  }
}

private struct MenuSection<Content: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let title: String
  let symbol: String
  let tint: Color
  let count: Int
  @Binding var expanded: Bool
  @ViewBuilder let content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expanded.toggle() } } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 10)
          Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
          Text(title).font(.body.weight(.semibold))
          Spacer(minLength: 4)
          Text("\(count)").font(.system(.caption, design: .rounded).weight(.semibold)).monospacedDigit()
            .foregroundStyle(count > 0 ? tint.mix(with: .primary, by: 0.5) : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((count > 0 ? tint : Color.secondary).opacity(0.14), in: Capsule())
        }
      }
      .buttonStyle(MenuRowButtonStyle())
      .accessibilityLabel("\(title), \(count)")
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityAddTraits(.isHeader)
      if expanded { VStack(alignment: .leading, spacing: 0) { content }.padding(.leading, 18) }
    }
  }
}

private struct MenuItemRow: View {
  let symbol: String
  let tint: Color
  let title: String
  let subtitle: String
  var badge: String? = nil
  var badgeTint: Color = .secondary
  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(tint).frame(width: 18).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.body).lineLimit(1).truncationMode(.tail)
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 4)
      if let badge {
        Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(badgeTint.mix(with: .primary, by: 0.5))
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(badgeTint.opacity(0.14), in: Capsule())
      }
    }
  }
}

private struct MenuEmptyRow: View {
  let text: String
  var body: some View {
    Text(text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
  }
}

private struct MenuShortcut: View {
  let title: String
  let symbol: String
  let tint: Color
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(systemName: symbol).font(.title3.weight(.medium)).foregroundStyle(tint).accessibilityHidden(true)
        Text(title).font(.caption).lineLimit(1)
      }.frame(maxWidth: .infinity).padding(.vertical, 6)
    }.buttonStyle(MenuRowButtonStyle())
  }
}

/// Full-width rows with a hover highlight, like native menu items.
private struct MenuRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { MenuRowBody(configuration: configuration) }
  private struct MenuRowBody: View {
    let configuration: Configuration
    @State private var hovering = false
    var body: some View {
      configuration.label
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
    }
  }
}
/// One native status item + transient popover for both click and the registered menu-bar hotkey.
@MainActor final class PRStatusItemController: NSObject, NSPopoverDelegate {
  /// UserDefaults key for showing the "Needs me" count beside the icon (default on).
  static let showsCountKey = "menuBarShowsNeedsCount"
  private var item: NSStatusItem?
  private let popover = NSPopover()
  private var showMainAction: (() -> Void)?
  private weak var model: SetupModel?
  private var observingCount = false
  /// A click on the status button first closes the transient popover, then fires `toggle`.
  private var closedAt = Date.distantPast
  func install(
    model: SetupModel, showMain: @escaping () -> Void, showSettings: @escaping () -> Void,
    open: @escaping (ProviderKey) -> Void
  ) {
    if item == nil {
      // Variable length: the optional "Needs me" count sits beside the icon.
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.button?.image = NSImage(
        systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "MergePro Status")
      item.button?.imagePosition = .imageLeading
      item.button?.setAccessibilityIdentifier("mergeProStatus")
      item.button?.setAccessibilityLabel("MergePro Status")
      item.button?.target = self
      item.button?.action = #selector(toggle)
      self.item = item
      popover.behavior = .transient
      popover.delegate = self
    }
    showMainAction = showMain
    let controller = NSHostingController(
      rootView: MenuBarView(
        model: model,
        showMain: { [weak self] in
          self?.popover.close()
          showMain()
        },
        showSettings: { [weak self] in
          self?.popover.close()
          showSettings()
        },
        open: { [weak self] key in
          self?.popover.close()
          open(key)
        }))
    // The popover follows SwiftUI's size as sections expand and collapse.
    controller.sizingOptions = .preferredContentSize
    popover.contentViewController = controller
    self.model = model
    if !observingCount { observingCount = true; observeCount() }
  }
  /// Re-reads the queue whenever its inputs change (rows, default view, pins).
  private func observeCount() {
    guard let model else { observingCount = false; return }
    let count = withObservationTracking { model.prs.menuQueue(mine: false).count } onChange: {
      Task { @MainActor [weak self] in self?.observeCount() }
    }
    updateCount(count)
  }
  /// Shows or hides the count after the preference changes.
  func updateCount() {
    guard let model else { return }
    updateCount(model.prs.menuQueue(mine: false).count)
  }
  private func updateCount(_ needsMe: Int) {
    guard let button = item?.button else { return }
    let enabled = UserDefaults.standard.object(forKey: Self.showsCountKey) as? Bool ?? true
    let title = PRMenuBarRules.statusCount(needsMe: needsMe, enabled: enabled)
    button.title = title.map { " " + $0 } ?? ""
    button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    button.setAccessibilityLabel(needsMe > 0 ? "MergePro Status, \(needsMe) need you" : "MergePro Status")
  }
  /// Opens the main window even when it was closed, e.g. from a notification.
  func showMain() { popover.close(); showMainAction?() }
  func popoverDidClose(_ notification: Notification) { closedAt = Date() }
  @objc func toggle() {
    guard let button = item?.button else { return }
    if popover.isShown {
      popover.close()
    } else if Date().timeIntervalSince(closedAt) > 0.25 {
      NSApplication.shared.activate()
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
  }
}
