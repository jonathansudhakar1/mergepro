import Foundation
import Synchronization

/// One GraphQL read that checks many repositories of an account for PR changes at once: the newest PR update
/// and, for the most recently updated open PRs, head and check rollup (which GitHub changes without bumping
/// `updatedAt`). Mergeability is left out: it roughly doubles the read's server time, and full reads refresh it. A repository whose signature matches the one recorded at its last complete
/// read has nothing new, so its full inventory read is skipped (see `GitHubPRInventoryFetcher`).
final class InventoryProbe: Sendable {
  /// Repositories checked per request. Measured on 25 real repositories: 3 GraphQL points and about 5 s,
  /// where reading them one by one takes about 25 requests and 50 s.
  static let batchSize = 25
  /// Open PRs per repository in the signature; changes beyond them wait for the next full read.
  static let openPerRepository = 10
  /// A signature this recent answers a repository's fetch without another probe.
  static let freshness: TimeInterval = 45
  struct Entry: Sendable { let signature: String; let at: Date }
  private let entries = Mutex<[RepositoryKey: Entry]>([:])
  private let probedAt = Mutex<[RepositoryKey: Date]>([:])
  /// Batches in flight by member: concurrent fetches of repositories in one batch share its single read.
  private let inFlight = Mutex<[RepositoryKey: Task<[RepositoryKey: Entry], any Error>]>([:])

  func fresh(_ repository: RepositoryKey, now: Date) -> String? {
    entries.withLock { $0[repository].flatMap { now.timeIntervalSince($0.at) <= Self.freshness ? $0.signature : nil } }
  }

  /// The signature of `repository`, probing it together with the peers whose last probe is oldest.
  func signature(
    for repository: RepositoryKey, peers: Set<RepositoryKey>, metadata: [RepositoryKey: Repository],
    client: GitHubHTTPClient, token: String, now: Date
  ) async throws -> String? {
    if let cached = fresh(repository, now: now) { return cached }
    if let pending = inFlight.withLock({ $0[repository] }) { return try await pending.value[repository]?.signature }
    let ages = probedAt.withLock { $0 }
    let busy = inFlight.withLock { Set($0.keys) }
    let others = peers.subtracting([repository]).filter { metadata[$0] != nil && fresh($0, now: now) == nil && !busy.contains($0) }
      .sorted { (ages[$0] ?? .distantPast, $0.repositoryID) < (ages[$1] ?? .distantPast, $1.repositoryID) }
    let batch = [repository] + others.prefix(Self.batchSize - 1)
    let task = Task { try await read(batch, metadata: metadata, client: client, token: token) }
    inFlight.withLock { for key in batch where $0[key] == nil { $0[key] = task } }
    defer { inFlight.withLock { for key in batch { $0[key] = nil } } }
    return try await task.value[repository]?.signature
  }

  /// One probe request for `batch`; records and returns the signatures it could read.
  private func read(
    _ batch: [RepositoryKey], metadata: [RepositoryKey: Repository], client: GitHubHTTPClient, token: String
  ) async throws -> [RepositoryKey: Entry] {
    var variables: [String: String?] = [:]
    var fields: [String] = []
    var aliases: [String: RepositoryKey] = [:]
    for (index, key) in batch.enumerated() {
      let parts = metadata[key]?.name.split(separator: "/").map(String.init) ?? []
      guard parts.count == 2 else { continue }
      variables["o\(index)"] = parts[0]; variables["n\(index)"] = parts[1]; aliases["r\(index)"] = key
      fields.append("r\(index): repository(owner: $o\(index), name: $n\(index)) { ...Probe }")
    }
    guard !aliases.isEmpty else { return [:] }
    let declarations = aliases.keys.sorted().map { alias in
      let index = alias.dropFirst()
      return "$o\(index): String!, $n\(index): String!"
    }.joined(separator: ", ")
    let query = """
      query InventoryProbe(\(declarations)) {
        \(fields.joined(separator: "\n  "))
      }
      fragment Probe on Repository {
        databaseId
        latest: pullRequests(first: 1, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { updatedAt } }
        open: pullRequests(states: OPEN, first: \(Self.openPerRepository), orderBy: {field: UPDATED_AT, direction: DESC}) {
          totalCount pageInfo { hasNextPage }
          nodes { id headRefOid commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }
        }
      }
      """
    let response = try await client.readQuery(query, variables: variables, token: token)
    let at = Date()
    probedAt.withLock { for key in batch { $0[key] = at } }
    guard let envelope = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
      let data = envelope["data"] as? [String: Any]
    else { return [:] }
    // Field errors null out only the affected repositories; those simply get no signature and are read in full.
    var found: [RepositoryKey: Entry] = [:]
    for (alias, key) in aliases {
      guard let node = data[alias] as? [String: Any], let id = node["databaseId"] as? NSNumber,
        String(id.int64Value) == key.repositoryID, let signature = Self.signature(node)
      else { continue }
      found[key] = Entry(signature: signature, at: at)
    }
    entries.withLock { $0.merge(found) { _, new in new } }
    return found
  }

  /// Newest update, open count and each probed open PR's head and checks; nil when unreadable.
  static func signature(_ node: [String: Any]) -> String? {
    guard let latest = node["latest"] as? [String: Any], let latestNodes = latest["nodes"] as? [Any],
      let open = node["open"] as? [String: Any], let total = open["totalCount"] as? Int,
      let more = (open["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool,
      let openNodes = open["nodes"] as? [Any]
    else { return nil }
    let newest = (latestNodes.first as? [String: Any])?["updatedAt"] as? String ?? "-"
    var parts = [newest, String(total), more ? "more" : "all"]
    for case let pr as [String: Any] in openNodes {
      let commit = ((pr["commits"] as? [String: Any])?["nodes"] as? [Any])?.first as? [String: Any]
      let checks = ((commit?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any])?["state"] as? String
      parts.append([pr["id"] as? String ?? "?", pr["headRefOid"] as? String ?? "?", checks ?? "-"].joined(separator: ":"))
    }
    return parts.joined(separator: "|")
  }
}
