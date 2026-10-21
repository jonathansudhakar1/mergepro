import MergeProCore
import SwiftUI

/// The one PR action menu. Board card menus, table row menus, the table's overflow button and the list's
/// selection bar show the same items for the rows they act on, enabled by `PRRowActionState`. Nothing is written
/// from here: approvals, merges, closes and labels open their sheets; draft changes run only on this explicit choice.
struct PRActionMenuItems: View {
  let rows: [PullRequest]
  let state: PRRowActionState
  let workspace: PRWorkspaceModel
  let open: (ProviderKey) -> Void
  var stack: PRStack? = nil
  private var single: PullRequest? { rows.count == 1 ? rows.first : nil }
  var body: some View {
    Button("Open Pull Request") { if let single { open(single.key) } }.disabled(!state.canOpen)
    if state.checksFailing, let single {
      Button("Open Failing Checks") { workspace.openChecks(single, open: open) }
      Button("Open Checks on GitHub") { workspace.openChecksOnWeb(single) }
    }
    Divider()
    Button(state.approveIsBatch ? "Approve \(rows.count) selected…" : "Approve…") { workspace.requestBatch(approve: true, rows: rows) }
      .disabled(!state.canApprove)
    Button("Request changes…") { if let single { workspace.requestReview(single, decision: .requestChanges) } }
      .disabled(!state.canRequestChanges)
    Button("Comment…") { if let single { workspace.requestReview(single, decision: .comment) } }
      .disabled(!state.canComment)
    Divider()
    Button(state.mergeTitle) { workspace.requestBatch(approve: false, rows: rows) }.disabled(!state.canMerge)
    if let single, single.state == .open {
      if let autoMerge = state.autoMerge {
        Button(autoMerge == .enableAutoMerge ? "Enable auto-merge…" : "Disable auto-merge…") {
          workspace.requestMerge(single, action: autoMerge)
        }
      }
      Button("Update branch…") { workspace.requestMerge(single, action: .updateBranch) }.disabled(!state.canUpdateBranch)
      if state.canRemoveFromQueue {
        Button("Remove from merge queue…") { workspace.requestMerge(single, action: .removeQueue) }
      }
      Button("Refresh merge eligibility") { Task { await workspace.refreshMergeEvidence(single) } }
    }
    Divider()
    Button("Labels…") { if let single { workspace.requestLabels(single) } }.disabled(!state.canEditLabels)
    if let draft = state.draft, let single {
      Button(draft == .markReady ? "Ready for review" : "Convert to draft") {
        Task { await workspace.setDraft(single, draft == .convertToDraft) }
      }
    }
    Button("Close…") { if let single { workspace.requestClose(single) } }.disabled(!state.canClose)
    if let stack, !stack.isAmbiguousChain, let single {
      Divider()
      Button("Approve whole stack…") { workspace.requestBatch(approve: true, rows: stack.layers.filter { $0.state == .open }) }
      if stack.kind == .inferred {
        Button("Merge up to here…") {
          if let layers = try? stack.affected(upTo: single.key) { workspace.requestBatch(approve: false, rows: layers) }
        }
      }
    }
    Divider()
    Button(rows.count > 1 ? "Copy \(rows.count) links" : "Copy link") { workspace.copyLinks(rows) }.disabled(!state.canCopyLink)
    if let url = single?.metadata?.webURL {
      ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
    } else if rows.count > 1 {
      ShareLink(items: rows.compactMap { $0.metadata?.webURL }) { Label("Share \(rows.count) links…", systemImage: "square.and.arrow.up") }
    }
    Button("Open on GitHub") { if let single { workspace.web(single) } }.disabled(single?.metadata == nil)
  }
}

/// Visible row actions: Approve and Merge… plus the full menu. Used by the table's actions column.
struct PRRowQuickActions: View {
  let pr: PullRequest
  let state: PRRowActionState
  let workspace: PRWorkspaceModel
  let open: (ProviderKey) -> Void
  var body: some View {
    let number = pr.metadata?.number ?? 0
    HStack(spacing: 6) {
      Button("Approve") { workspace.requestBatch(approve: true, rows: [pr]) }
        .disabled(!state.canApprove)
        .accessibilityLabel("Approve pull request \(number)")
        .accessibilityIdentifier("rowApprove-\(number)")
      Button(state.mergeTitle) { workspace.requestBatch(approve: false, rows: [pr]) }
        .disabled(!state.canMerge)
        .accessibilityLabel("\(state.mergeTitle.replacingOccurrences(of: "…", with: "")) pull request \(number)")
        .accessibilityIdentifier("rowMerge-\(number)")
      Menu {
        PRActionMenuItems(rows: [pr], state: state, workspace: workspace, open: open, stack: workspace.stack(for: pr))
      } label: {
        Label("More actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .help("More actions")
      .accessibilityLabel("More actions for pull request \(number)")
    }
    .buttonStyle(.borderless).controlSize(.small)
  }
}

/// The list's selection bar: the same actions as the menus, acting on the table selection.
struct PRSelectionActionBar: View {
  let workspace: PRWorkspaceModel
  let open: (ProviderKey) -> Void
  var body: some View {
    let rows = workspace.commandRows
    let state = workspace.actionState(rows)
    HStack(spacing: 10) {
      Text(rows.isEmpty ? "No pull request selected" : rows.count == 1 ? "#\(String(rows[0].metadata?.number ?? 0)) selected" : "\(rows.count) selected")
        .font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Button("Open") { if let pr = rows.first, rows.count == 1 { open(pr.key) } }.disabled(!state.canOpen)
      Button(state.approveIsBatch ? "Approve \(rows.count)…" : "Approve…") { workspace.requestBatch(approve: true, rows: rows) }
        .disabled(!state.canApprove).accessibilityIdentifier("selectionApprove")
      Button(state.mergeTitle) { workspace.requestBatch(approve: false, rows: rows) }
        .disabled(!state.canMerge).accessibilityIdentifier("selectionMerge")
      Menu("More") {
        PRActionMenuItems(rows: rows, state: state, workspace: workspace, open: open, stack: rows.count == 1 ? workspace.stack(for: rows[0]) : nil)
      }.fixedSize().disabled(rows.isEmpty)
    }
    .controlSize(.small)
    .padding(.horizontal, 12).padding(.vertical, 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Selection actions")
  }
}
