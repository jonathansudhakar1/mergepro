import Foundation
import GRDB

/// Durable, nonregenerable local views and restoration. Inventory writes belong to PollCycleStore.
public final class PullRequestStore: Sendable {
  private let database: DatabaseStore
  public init(database: DatabaseStore) { self.database = database }
  public func load() throws -> PRViewState {
    try database.database.read { db in
      try Data.fetchOne(db, sql: "SELECT json FROM prWorkspace WHERE id=1").map {
        try JSONDecoder().decode(PRViewState.self, from: $0)
      } ?? PRViewState()
    }
  }
  public func save(_ state: PRViewState) throws {
    try Self.validate(state.views)
    let data = try JSONEncoder.stable.encode(state)
    try database.database.write {
      try $0.execute(
        sql:
          "INSERT INTO prWorkspace(id,json) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",
        arguments: [data])
    }
  }
  public func exportViews() throws -> Data {
    let encoder = JSONEncoder.stable
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(load().views)
  }
  public func importViews(_ data: Data) throws {
    guard data.count <= 5_000_000 else { throw ViewError.invalidFile }
    let views = try JSONDecoder().decode([PRSavedView].self, from: data)
    try Self.validate(views)
    var state = try load()
    state.views = views
    if !views.contains(where: { $0.id == state.currentViewID }) {
      state.currentViewID = views.first(where: \.isDefault)?.id ?? views.first?.id
    }
    if let chosen = views.first(where: { $0.id == state.currentViewID }) {
      state.current = chosen.configuration
    }
    try save(state)
  }
  public enum ViewError: Error { case invalidFile }
  private static func validate(_ views: [PRSavedView]) throws {
    guard views.count <= 500, Set(views.map(\.id)).count == views.count,
      views.filter(\.isDefault).count <= 1,
      views.allSatisfy({
        !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && $0.configuration.mergedDays > 0
          && Set($0.configuration.columns).count == $0.configuration.columns.count
      })
    else { throw ViewError.invalidFile }
  }
}
