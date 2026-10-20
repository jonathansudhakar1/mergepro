import MergeProCore
import SwiftUI

struct PRListView: View {
  @Bindable var workspace: PRWorkspaceModel
  let open: (ProviderKey) -> Void
  private var sortOrder: Binding<[PRListComparator]> {
    Binding(
      get: {
        // Created sorts like the Age column (both use createdAt); sorts with no column show no indicator.
        let sort = workspace.state.current.sort
        guard let column = sort == .created ? .age : PRViewConfiguration.TableColumn(rawValue: sort.rawValue)
        else { return [] }
        return [PRListComparator(column: column, order: workspace.state.current.ascending ? .forward : .reverse)]
      },
      set: { order in
        if let first = order.first {
          workspace.state.current.sort =
            PRViewConfiguration.Sort(rawValue: first.column.rawValue) ?? .updated
          workspace.state.current.ascending = first.order == .forward
        }
      })
  }
  var body: some View {
    VStack(spacing: 0) {
      PRSelectionActionBar(workspace: workspace, open: open)
      Divider()
      table
    }
  }
  private var columnsThroughTitle: [PRViewConfiguration.TableColumn] {
    let columns = workspace.state.current.columns
    // Without a Title column, Actions stays last.
    guard let title = columns.firstIndex(of: .title) else { return columns }
    return Array(columns[...title])
  }
  private var columnsAfterTitle: [PRViewConfiguration.TableColumn] {
    let columns = workspace.state.current.columns
    return Array(columns.dropFirst(columnsThroughTitle.count))
  }
  private func dataColumn(_ column: PRViewConfiguration.TableColumn) -> some TableColumnContent<PRListDisplayRow, PRListComparator> {
    TableColumn(ProviderStateText.tableColumn(column), sortUsing: PRListComparator(column: column)) {
      (row: PRListDisplayRow) in
      // No per-cell menu: right-click shows the full row menu from `contextMenu(forSelectionType:)`.
      if column == .labels, let m = row.pr.metadata, !m.labels.isEmpty {
        LabelChipRow(labels: m.labels, colors: m.labelColors, limit: 3)
          .frame(maxWidth: .infinity, alignment: .leading).clipped()
      } else if column == .mergeability {
        // The action account's eligibility, as cards and menus use, with its age rendered from the read time.
        PRMergeColumnLabel(eligibility: workspace.cardEligibility(row.pr), mergeable: row.pr.metadata?.mergeable)
      } else if let status = row.statuses[column] {
        PRStatusLabel(value: status)
      } else if column == .title, row.checksFailing {
        HStack(spacing: 6) {
          Text(row.values[column] ?? "").lineLimit(1)
          PRChecksFailingBadge(number: row.pr.metadata?.number ?? 0) { workspace.openChecks(row.pr, open: open) }
        }
      } else {
        Text(row.values[column] ?? "").lineLimit(1)
      }
    }.width(min: column == .title ? 240 : 65, ideal: column == .title ? 380 : column == .labels ? 180 : column == .mergeability ? 180 : 110)
  }
  private var table: some View {
    Table(workspace.listRows, selection: $workspace.selection.selected, sortOrder: sortOrder)
    {
      if workspace.state.current.grouping != .none {
        TableColumn("Group", sortUsing: PRListComparator(column: .repository)) {
          (row: PRListDisplayRow) in Text(row.group).foregroundStyle(.secondary)
        }
      }

      // Actions sit right after Title so they stay visible without scrolling a wide table sideways.
      TableColumnForEach(columnsThroughTitle, id: \.self) { column in dataColumn(column) }
      TableColumn("Actions") { (row: PRListDisplayRow) in
        // Same eligibility as the merge column, cards, menus and M; re-rendered when its evidence ages out.
        PRRowQuickActions(pr: row.pr, state: workspace.rowActionState(row.pr), workspace: workspace, open: open)
      }.width(min: 150, ideal: 190)
      TableColumnForEach(columnsAfterTitle, id: \.self) { column in dataColumn(column) }
    }
    .contextMenu(forSelectionType: ProviderKey.self) { keys in
      let rows = workspace.listRows.filter { keys.contains($0.id) }.map(\.pr)
      if !rows.isEmpty {
        PRActionMenuItems(
          rows: rows, state: workspace.actionState(rows), workspace: workspace, open: open,
          stack: rows.count == 1 ? workspace.stack(for: rows[0]) : nil)
      }
    } primaryAction: { keys in
      if let key = keys.first { open(key) }
    }
    .onChange(of: workspace.selection.selected) { _, keys in
      if let key = keys.first, workspace.selection.focused.map({ keys.contains($0) }) != true
      {
        workspace.selection.focused = key
      }
    }
    .scrollPosition(id: $workspace.scrollAnchor)
    .accessibilityIdentifier("prList")
  }
}

/// Immutable display values computed once per input/configuration revision, from row facts only. Native Table
/// cells construct no date formatters during layout. Merge eligibility is not part of it: the merge column and the
/// row actions read the workspace's (`cardEligibility`), the action account's evaluation that cards and menus use,
/// which changes as merge evidence ages.
struct PRListDisplayRow: Identifiable {
  let pr: PullRequest
  let values: [PRViewConfiguration.TableColumn: String]
  /// Glyph-and-text status for the checks and review columns.
  let statuses: [PRViewConfiguration.TableColumn: PRStatusValue]
  let checksFailing: Bool
  let group: String
  var id: ProviderKey { pr.key }
  static func make(
    projection: BoardProjection, view: PRViewConfiguration, freshness: [RepositoryKey: String] = [:],
    logins: [AccountScope: String] = [:]
  ) -> [Self] {
    let relative = RelativeDateTimeFormatter()
    relative.unitsStyle = .abbreviated
    let date = DateFormatter()
    date.dateStyle = .medium
    date.timeStyle = .short
    let now = Date()
    let multipleAccounts = Set(projection.rows.map { $0.key.account }).count > 1
    var relativeValues: [Date: String] = [:]
    var dateValues: [Date: String] = [:]
    func relativeValue(_ value: Date) -> String {
      if let result = relativeValues[value] { return result }
      let result = relative.localizedString(for: value, relativeTo: now)
      relativeValues[value] = result
      return result
    }
    func dateValue(_ value: Date) -> String {
      if let result = dateValues[value] { return result }
      let result = date.string(from: value)
      dateValues[value] = result
      return result
    }
    let source =
      view.grouping == .none
      ? projection.rows : projection.lanes.keys.sorted().flatMap { projection.lanes[$0] ?? [] }
    return source.map { pr in
      let m = pr.metadata
      let group: String =
        switch view.grouping {
        case .none: ""
        case .org: m?.repositoryName.split(separator: "/").first.map(String.init) ?? "Unknown"
        case .repository: m?.repositoryName ?? "Unknown"
        case .author: m?.authorLogin ?? "Unknown"
        case .authorType: m?.authorClassification ?? m?.actorType ?? "Unknown"
        }
      let values = Dictionary(
        uniqueKeysWithValues: view.columns.map {
          column -> (PRViewConfiguration.TableColumn, String) in
          let value: String =
            switch column {
            case .repository:
              (m?.repositoryName ?? pr.key.repositoryID)
                + (multipleAccounts ? " · " + (logins[pr.key.account] ?? "Account " + pr.key.accountID) : "")
                + (freshness[pr.key.repository].map { " · " + $0 } ?? "")
            case .number: "#\(m?.number ?? 0)"
            case .title: pr.title
            case .author: m?.authorLogin ?? "Unknown"
            case .checks: PRStatusSummary.checks(m?.checks).text
            case .review: PRStatusSummary.review(m?.reviewDecision).text
            case .size: m?.sizeClass ?? "Unknown"
            case .age: m?.createdAt.map(relativeValue) ?? "Unknown"
            case .updated: m?.updatedAt.map(dateValue) ?? "Unknown"
            case .labels: m?.labels.joined(separator: ", ") ?? ""
            // Shown by `PRMergeColumnLabel`; GitHub's conflict state is the row's own fact.
            case .mergeability: PRStatusSummary.mergeable(m?.mergeable).text
            }
          return (column, value)
        })
      var statuses: [PRViewConfiguration.TableColumn: PRStatusValue] = [:]
      for column in view.columns {
        switch column {
        case .checks: statuses[column] = PRStatusSummary.checks(m?.checks)
        case .review: statuses[column] = PRStatusSummary.review(m?.reviewDecision)
        default: break
        }
      }
      return Self(
        pr: pr, values: values, statuses: statuses, checksFailing: PRStatusSummary.checksFailing(m), group: group)
    }
  }
}

private struct PRListComparator: SortComparator {
  typealias Compared = PRListDisplayRow
  var column: PRViewConfiguration.TableColumn
  var order: SortOrder = .forward
  func compare(_ lhs: PRListDisplayRow, _ rhs: PRListDisplayRow) -> ComparisonResult {
    let a = lhs.pr.metadata
    let b = rhs.pr.metadata
    let numbers: (Double, Double)? =
      switch column {
      case .number: (Double(a?.number ?? 0), Double(b?.number ?? 0))
      case .size: (Double(a?.size ?? -1), Double(b?.size ?? -1))
      case .age:
        (a?.createdAt?.timeIntervalSince1970 ?? 0, b?.createdAt?.timeIntervalSince1970 ?? 0)
      case .updated:
        (a?.updatedAt?.timeIntervalSince1970 ?? 0, b?.updatedAt?.timeIntervalSince1970 ?? 0)
      default: nil
      }
    let result: ComparisonResult
    if let (a, b) = numbers {
      result = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
    } else {
      func text(_ pr: PullRequest) -> String {
        switch column {
        case .repository: pr.metadata?.repositoryName ?? ""
        case .title: pr.title
        case .author: pr.metadata?.authorLogin ?? ""
        case .checks: pr.metadata?.checks ?? ""
        case .review: pr.metadata?.reviewDecision ?? ""
        case .mergeability: pr.metadata?.mergeable ?? ""
        case .labels: pr.metadata?.labels.joined(separator: ",") ?? ""
        default: ""
        }
      }
      result = text(lhs.pr).localizedStandardCompare(text(rhs.pr))
    }
    return order == .forward
      ? result
      : result == .orderedAscending
        ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
  }
}
