import AppKit
import MergeProCore
import SwiftUI

/// Every rendered value arrives as plain input and the body reads no workspace state, so a selection, focus or
/// filter change re-renders only the cards whose inputs changed (`PRBoardView` wraps cards in `.equatable()`).
struct PRCardView: View, Equatable {
  let pr: PullRequest
  let selected: Bool
  let focused: Bool
  let compact: Bool
  /// Activity since the previous look.
  let isNew: Bool
  /// "Account: login" when more than one account is connected.
  let account: String?
  let eligibility: MergeEligibility
  let stack: PRStack?
  let freshness: PRRepositoryFreshness?
  /// Actions only; never read while rendering.
  let workspace: PRWorkspaceModel
  let open: (ProviderKey) -> Void
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var labelPickerPresented = false
  /// Layers listed inline; a long inferred chain (e.g. everything into a deploy branch) is summarized.
  private static let listedLayers = 8
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.selected == rhs.selected && lhs.focused == rhs.focused && lhs.compact == rhs.compact
      && lhs.isNew == rhs.isNew && lhs.account == rhs.account && lhs.workspace === rhs.workspace
      && lhs.pr == rhs.pr && lhs.eligibility == rhs.eligibility && lhs.freshness == rhs.freshness
      && lhs.stack == rhs.stack
  }
  private var m: PRMetadata? { pr.metadata }
  private var number: Int { m?.number ?? 0 }
  private var column: PRColumn { BoardProjection.column(for: pr, showDrafts: true) }
  private var columnColor: Color { DesignTokens.columnColor(column) }
  private var checks: PRStatusValue { ProviderStateText.checks(m?.checks) }
  private var review: PRStatusValue { ProviderStateText.review(m?.reviewDecision) }
  private var conflicts: PRStatusValue { ProviderStateText.mergeable(m?.mergeable) }
  /// Merge verification says how long ago GitHub was read, so it is rendered from `now` (see `PRVerificationAge`).
  private func verification(_ now: Date) -> PRStatusValue { ProviderStateText.mergeVerification(eligibility, now: now) }
  private var actions: PRRowActionState { PRRowActionState(rows: [pr]) { _ in eligibility } }
  private var viewerRequests: [PRReviewRequest] { m?.requests.filter(\.isForViewer) ?? [] }
  private func requestText(_ request: PRReviewRequest) -> String {
    (request.kind == .direct ? "Direct review request" : "Team: \(request.name)")
      + (request.viewerStatus == .unknown ? " · Request chronology unknown" : "")
  }
  /// Spoken from the same text the card shows, in reading order.
  private func spokenLabel(_ now: Date) -> String {
    var parts = ["\(m?.repositoryName ?? pr.key.repositoryID) pull request \(number)", pr.title]
    parts.append("\(ProviderStateText.column(column)) column")
    if pr.isDraft { parts.append("Draft") }
    if pr.state == .closed { parts.append("Closed") }
    if isNew { parts.append("New since last look") }
    if let account { parts.append("Account \(account)") }
    parts.append("by \(m?.authorLogin ?? "unknown author")")
    parts += [checks.text, review.text, conflicts.text, "Merge: \(verification(now).text)"]
    parts += viewerRequests.map(requestText)
    if let labels = m?.labels, !labels.isEmpty { parts.append("Labels " + labels.joined(separator: ", ")) }
    if !compact, let preview = m?.descriptionPreview, !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append(preview)
    }
    return parts.joined(separator: ", ")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 6 : 10) {
      // The verification age ("Verified ready · 3 min. ago") and the label spoken from it re-render each minute.
      PRVerificationAge(verifiedAt: eligibility.verifiedAt) { now in
        summary(now)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel(now))
        .accessibilityValue(
          "\(selected ? "Selected" : "Unselected"), \(focused ? "Focused" : "Unfocused")"
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(pr.key) }
        .accessibilityAction(named: "Approve") { workspace.requestBatch(approve: true, rows: [pr]) }
        .accessibilityAction(named: "Request changes") { workspace.requestReview(pr, decision: .requestChanges) }
        .accessibilityAction(named: "Merge") { workspace.requestMerge(pr) }
        .accessibilityAction(named: "Labels") { workspace.requestLabels(pr) }
        .accessibilityAction(named: "Close") { workspace.requestClose(pr) }
        .accessibilityIdentifier("prCard-\(number)")
      }
      if actions.checksFailing {
        PRChecksFailingBadge(number: number) { workspace.openChecks(pr, open: open) }
      }
      stackInfo
      Divider().opacity(0.5)
      actionRow
      footer
    }
    .padding(compact ? 12 : 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.cardRadius)
        .fill(DesignTokens.cobalt.opacity(selected ? 0.08 : 0))
        .allowsHitTesting(false)
    }
    .overlay(alignment: .topLeading) {
      Capsule().fill(columnColor).frame(width: 28, height: 3)
        .padding(.leading, compact ? 12 : 16).padding(.top, compact ? 5 : 7)
        .accessibilityHidden(true).allowsHitTesting(false)
    }
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.cardRadius).strokeBorder(
        focused || selected
          ? DesignTokens.cobalt : Color(nsColor: .separatorColor).opacity(contrast == .increased ? 1 : 0.55),
        lineWidth: focused ? 2 : 1).allowsHitTesting(false)
    )
    .shadow(color: .black.opacity(contrast == .increased ? 0 : 0.08), radius: 10, x: 0, y: 4)
    .contentShape(Rectangle())
    .draggable(workspace.dragItem(pr, token: workspace.cardDragToken(pr))) {
      Label(pr.title, systemImage: "arrow.triangle.pull")
        .font(.headline).padding(14).frame(width: 280).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    .simultaneousGesture(TapGesture().onEnded { workspace.select(pr.key, modifiers: NSEvent.modifierFlags) })
    .simultaneousGesture(TapGesture(count: 2).onEnded { open(pr.key) })
    .contextMenu {
      PRActionMenuItems(rows: [pr], state: actions, workspace: workspace, open: open, stack: stack)
    }
    .accessibilityElement(children: .contain)
  }
  /// The card's readable content; one accessibility element whose label is built from the same text.
  private func summary(_ now: Date) -> some View {
    VStack(alignment: .leading, spacing: compact ? 6 : 10) {
      header
      if let account {
        Text("Account: \(account)").font(.caption2).foregroundStyle(.secondary)
      }
      Text(pr.title).font(.body.weight(.semibold)).lineSpacing(2).lineLimit(2)
      if !compact { description }
      statusRows(now).font(.caption)
      if !compact { details }
      if let labels = m?.labels, !labels.isEmpty {
        LabelChipRow(labels: labels, colors: m?.labelColors, limit: compact ? 3 : 4)
          .frame(maxWidth: .infinity, alignment: .leading).clipped()
      }
    }
  }
  private var header: some View {
    HStack {
      Text("\(m?.repositoryName ?? pr.key.repositoryID) #\(number)").font(.subheadline.weight(.medium)).lineLimit(1)
        .foregroundStyle(.secondary)
      Spacer()
      if isNew {
        Image(systemName: "circle.fill").imageScale(.small).font(.caption2).foregroundStyle(DesignTokens.cobalt)
          .accessibilityLabel("New since last look")
      }
      if pr.isDraft {
        Text("Draft").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3)
          .background(Color.secondary.opacity(0.10), in: Capsule())
      }
    }
  }
  @ViewBuilder private var description: some View {
    if let preview = m?.descriptionPreview, !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Text(preview).font(.callout).foregroundStyle(.secondary)
        .lineSpacing(2).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
    }
    Label(m?.authorLogin ?? "Unknown author", systemImage: m?.actorType == "Bot" ? "gearshape" : "person.crop.circle")
      .font(.callout.weight(.medium))
    Text("\(m?.headBranch ?? "Unknown") → \(m?.baseBranch ?? "Unknown")").font(.system(.caption, design: .monospaced))
      .foregroundStyle(.secondary).lineLimit(1)
  }
  @ViewBuilder private var details: some View {
    Text(m?.autoMergeKnown == true ? (m?.autoMerge == true ? "Auto-merge on" : "Auto-merge off") : "Auto-merge unknown")
      .font(.caption).foregroundStyle(.secondary)
    ForEach(Array(viewerRequests.enumerated()), id: \.offset) { _, request in
      Label {
        Text(requestText(request)).foregroundStyle(.primary)
      } icon: {
        Image(systemName: request.kind == .team ? "person.2" : "person").foregroundStyle(.tint)
      }.font(.caption)
    }
    HStack {
      Text("Size: \(m?.sizeClass ?? "Unknown")")
      Text(m?.files.map { "\($0) files" } ?? "Files unknown")
      if let additions = m?.additions, let deletions = m?.deletions { Text("+\(additions) −\(deletions)") }
      Spacer()
      if let date = m?.createdAt { Text(date, style: .relative) }
    }.font(.caption2).foregroundStyle(.secondary)
    HStack {
      Text(m?.comments.map { "\($0) \($0 == 1 ? "comment" : "comments")" } ?? "Comments unknown")
      Spacer()
      if let at = m?.columnChangedAt {
        Text("In column")
        Text(at, style: .relative)
      } else {
        Text("Column age unknown")
      }
    }.font(.caption2).foregroundStyle(.secondary)
  }
  @ViewBuilder private var stackInfo: some View {
    if let stack, stack.isAmbiguousChain {
      // Ambiguous inferred chains don't collapse, so there is nothing to expand; only the warning applies.
      Label { Text(PRStack.ambiguousChainWarning).foregroundStyle(.secondary) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
        .font(.caption2)
        .help("This branch has several possible parent or child pull requests, so it isn't shown as a stack.")
    } else if let stack {
      Button("\(stack.kind == .native ? "Native" : "Inferred") stack · \(stack.layers.count) layers") {
        if !workspace.expandedStacks.insert(stack.presentationID).inserted { workspace.expandedStacks.remove(stack.presentationID) }
      }.buttonStyle(.plain)
      HStack {
        ForEach(stack.layers.prefix(Self.listedLayers)) { layer in
          Text("#\(layer.metadata?.number ?? 0) \(ProviderStateText.column(BoardProjection.column(for: layer, showDrafts: true))) · \(ProviderStateText.checks(layer.metadata?.checks).text)")
            .font(.caption2)
        }
        if stack.layers.count > Self.listedLayers { Text("+\(stack.layers.count - Self.listedLayers) more").font(.caption2).foregroundStyle(.secondary) }
      }
      ForEach(Array(stack.warnings.enumerated()), id: \.offset) { warning in
        Label { Text(warning.element).foregroundStyle(.secondary) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
          .font(.caption2)
      }
    }
  }
  @ViewBuilder private var footer: some View {
    if let freshness, freshness.state != .fresh {
      Label { Text(freshness.label).foregroundStyle(.secondary) } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
        .font(.caption2)
      if let at = freshness.lastSuccessAt {
        Text("Last success \(at.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.secondary)
      }
    }
    if m?.partial == true {
      Label { Text("Partial data").foregroundStyle(.secondary) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
        .font(.caption)
    }
  }
  /// Checks, review, conflicts and merge verification, each as glyph + text. Compact cards show them too.
  @ViewBuilder private func statusRows(_ now: Date) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) { PRStatusLabel(value: checks); PRStatusLabel(value: review); if !compact { PRStatusLabel(value: conflicts) } }
      VStack(alignment: .leading, spacing: 3) { PRStatusLabel(value: checks); PRStatusLabel(value: review); if !compact { PRStatusLabel(value: conflicts) } }
    }
    PRStatusLabel(value: verification(now))
  }
  /// State drag, labels, and visible Approve and Merge. Merge stays draggable onto the Merged column.
  private var actionRow: some View {
    HStack(spacing: 6) {
      Label("State",systemImage:"arrow.up.and.down").font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08), in: Capsule()).draggable(workspace.dragItem(pr, token: workspace.dragToken(pr,merge:false)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("State for pull request \(number)")
        .accessibilityHint("Drag to another column to change state")
        .accessibilityIdentifier("stateDrag-\(number)")
      Button { labelPickerPresented = true } label: {
        Image(systemName: "tag").font(.caption.weight(.medium))
          .padding(.horizontal, 7).padding(.vertical, 5)
          .background(Color.secondary.opacity(0.08), in: Capsule())
      }
      .buttonStyle(.plain)
      .help("Edit labels")
      .accessibilityLabel("Edit labels for pull request \(number)")
      .accessibilityIdentifier("labelButton-\(number)")
      .popover(isPresented: $labelPickerPresented, arrowEdge: .bottom) {
        PRLabelPicker(pr: pr, storage: workspace.storage, workspace: workspace)
      }
      Spacer(minLength: 4)
      if actions.canApprove {
        Button { workspace.requestBatch(approve: true, rows: [pr]) } label: {
          Label("Approve", systemImage: "checkmark").font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.green.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Approve… (A)")
        .accessibilityLabel("Approve pull request \(number)")
        .accessibilityIdentifier("approveButton-\(number)")
      }
      if eligibility.opensMergeSheet && pr.state == .open {
        Button { workspace.requestMerge(pr) } label: {
          Label(eligibility.label,systemImage:"arrow.triangle.merge").font(.caption.weight(.semibold))
            .foregroundStyle(.primary).padding(.horizontal, 8).padding(.vertical, 5)
            .background(DesignTokens.violet.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .draggable(workspace.dragItem(pr, token: workspace.dragToken(pr,merge:true)))
        .help("\(eligibility.label)… (M) — or drag to Merged")
        .accessibilityLabel("\(eligibility.label) pull request \(number)")
        .accessibilityHint("Opens merge options; GitHub is checked again before anything is merged")
        .accessibilityIdentifier("mergeDrag-\(number)")
      }
    }
  }
}
