import MergeProCore
import SwiftUI

struct PRBoardView: View {
  @Bindable var workspace: PRWorkspaceModel
  let open: (ProviderKey) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var targetedColumns: Set<PRColumn> = []
  private var columns: [PRColumn] {
    PRColumn.allCases.filter {
      ($0 != .draft || workspace.state.current.showDrafts)
        && ($0 != .merged || !workspace.state.current.hideMerged)
    }
  }
  /// Read once per update. Cards receive plain values, so selection/focus changes re-render only affected cards.
  private struct CardContext {
    let selection: PRSelection
    let compact: Bool
    let cutoff: Date
    let logins: [AccountScope: String]?
  }
  private func card(_ pr: PullRequest, _ context: CardContext) -> some View {
    PRCardView(
      pr: pr, selected: context.selection.selected.contains(pr.key), focused: context.selection.focused == pr.key,
      compact: context.compact, isNew: (pr.metadata?.activityDate ?? .distantPast) > context.cutoff,
      account: context.logins.map { $0[pr.key.account] ?? pr.key.accountID },
      eligibility: workspace.cardEligibility(pr), stack: workspace.stack(for: pr),
      freshness: workspace.freshnessByRepository[pr.key.repository], workspace: workspace, open: open
    ).equatable()
  }
  var body: some View {
    GeometryReader { geometry in
    let columnWidth = max(296, (geometry.size.width - 48 - CGFloat(columns.count - 1) * 16) / CGFloat(columns.count))
    let board = workspace.board
    let view = workspace.state.current
    let accounts = workspace.accounts
    let context = CardContext(
      selection: workspace.selection, compact: view.compact, cutoff: workspace.previousLookCutoff,
      logins: accounts.count > 1 ? Dictionary(accounts.map { ($0.scope, $0.login) }, uniquingKeysWith: { first, _ in first }) : nil)
    ScrollViewReader { proxy in
    ScrollView([.horizontal, .vertical]) {
      LazyVStack(alignment: .leading, spacing: 22) {
        ForEach(board.lanes) { lane in
          // Lanes can only be collapsed (and expanded again) while grouped.
          let collapsed = view.grouping != .none && view.collapsedLanes.contains(lane.id)
          VStack(alignment: .leading, spacing: 8) {
            if view.grouping != .none {
              Button {
                if !workspace.state.current.collapsedLanes.insert(lane.id).inserted {
                  workspace.state.current.collapsedLanes.remove(lane.id)
                }
              } label: {
                HStack {
                  Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                  Text(lane.id).font(.headline)
                  Text(
                    columns.map { column in "\(ProviderStateText.column(column)) \(lane.cards(column).count)" }
                      .joined(separator: " · ")
                  ).font(.caption).foregroundStyle(.secondary)
                }
              }.buttonStyle(.plain)
              .accessibilityAddTraits(.isHeader)
              .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            }
            if !collapsed {
              HStack(alignment: .top, spacing: 16) {
                ForEach(columns, id: \.self) { column in
                  let cards = lane.cards(column)
                  VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                      Image(systemName: DesignTokens.columnIcon(column)).foregroundStyle(DesignTokens.columnColor(column))
                        .accessibilityHidden(true)
                      Text(ProviderStateText.column(column)).font(.headline)
                        .accessibilityAddTraits(.isHeader)
                      Spacer()
                      Text("\(cards.count)").font(.system(.subheadline, design: .rounded, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(DesignTokens.columnColor(column).opacity(0.12), in: Capsule())
                        .accessibilityLabel("\(cards.count) \(cards.count == 1 ? "pull request" : "pull requests")")
                    }.padding(.horizontal, 12).padding(.vertical, 10).workspacePanel(radius: 10).padding(.bottom, 4)
                    LazyVStack(spacing: 12) {
                      ForEach(cards) { pr in
                        card(pr, context).id(pr.key)
                      }
                    }
                    if cards.isEmpty {
                      Text(column == .merged ? "Drop a PR to review merge options" : "Drop a PR here")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 22)
                    }
                    if view.grouping == .none,
                      let hidden = workspace.projection.olderHidden[column], hidden > 0
                    {
                      Button("\(hidden) older PRs hidden — Show all") { workspace.widen() }.font(
                        .caption)
                    }
                  }.padding(8).frame(width: columnWidth, alignment: .topLeading)
                  .frame(minHeight: view.grouping == .none ? max(280, geometry.size.height - 30) : 160, alignment: .topLeading)
                  .background(Color.primary.opacity(targetedColumns.contains(column) ? 0.07 : 0.03), in: RoundedRectangle(cornerRadius: 14))
                  .contentShape(Rectangle())
                  .overlay {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(targetedColumns.contains(column) ? DesignTokens.columnColor(column) : .clear, lineWidth: 2)
                      .allowsHitTesting(false)
                  }
                  .accessibilityIdentifier("prColumn-"+column.rawValue)
                  .dropDestination(for:String.self,action:{ tokens,_ -> Bool in workspace.drop(tokens,column:column) },isTargeted:{ targeted in
                    if targeted { targetedColumns.insert(column) } else { targetedColumns.remove(column) }
                  })
                }
              }
            }
            if !collapsed, !lane.closed.isEmpty {
              // Inset like column content so closed cards line up with the cards above them.
              Text("Closed without merge").font(.headline).padding(.top, 6).padding(.horizontal, 8)
              LazyVStack(spacing: 12) {
                ForEach(lane.closed) { pr in
                  card(pr, context).frame(width: columnWidth - 16).id(pr.key)
                }
              }.padding(.horizontal, 8)
            }
          }
        }
        if view.grouping != .none {
          ForEach(columns, id: \.self) { column in
            if let count = workspace.projection.olderHidden[column], count > 0 {
              Button("\(count) older PRs hidden in \(ProviderStateText.column(column)) — Show all") {
                workspace.widen()
              }
            }
          }
        }
        // Closed PRs never sit in a column, so their hidden count is reported on its own.
        if workspace.projection.closedHidden > 0 {
          Button("\(workspace.projection.closedHidden) older closed PRs hidden — Show all") { workspace.widen() }
            .font(.caption)
        }
        if !workspace.projection.rows.isEmpty {
          Label("Close zone — drop a PR to review closing it", systemImage: "archivebox")
            .font(.callout).foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity)
            .workspacePanel(radius: 14)
            .dropDestination(for:String.self,action:{ tokens,_ -> Bool in workspace.drop(tokens,column:nil) })
        }
      }.padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 4).scrollTargetLayout()
    }
    .scrollPosition(id: $workspace.scrollAnchor)
    .accessibilityIdentifier("prBoard")
    // Scroll targets above are lanes, so keyboard focus (j/k) reveals its nested card explicitly.
    .onChange(of: workspace.scrollAnchor) { _, key in
      if let key { withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { proxy.scrollTo(key) } }
    }
    }
    }
  }
}
