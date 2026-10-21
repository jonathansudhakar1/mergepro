import Foundation
import Synchronization

public struct PRInventoryStatus: Codable, Sendable {
  public var complete: Bool
  public var fetchedCount: Int
  public var fetchedAt: Date
  public var message: String?
  public var continuation: Data? = nil
  public var lastSuccessAt: Date? = nil
  public var lastFailureAt: Date? = nil
  public var failureMessage: String? = nil
}
/// Repository inventory is independent of notification threads. Partial inventory only upserts;
/// uncached/unseen objects are never deleted. Coordinator owns baselines, due timers and commits.
public struct GitHubPRInventoryFetcher: PollFeatureFetcher {
  public let featureID = "github-pr-inventory"
  public let fetchScope: PollFetchScope = .repository
  public var pollInterval: TimeInterval? { 60 }
  /// PR inventory feeds the board, so it leads newly ordered account work.
  public var schedulingPriority: Int { 100 }
  /// Interval between full sweeps of an incrementally synced repository.
  public let fullPassInterval: TimeInterval
  /// Account-scoped team membership shared by every repository this fetcher polls.
  private let teams = TeamMembershipCache()
  public init() { fullPassInterval = 86_400 }
  public init(fullPassInterval: TimeInterval) { self.fullPassInterval = max(0, fullPassInterval) }
  private typealias Payload = GitHubPRInventoryPayload
  private typealias Node = Payload.Node
  private typealias Viewer = Payload.Viewer
  private enum InventoryFailure: Error { case queryRejected, partialPage, partialNode }
  private static func readFailure(_ error: any Error, stage: String) -> String {
    let reason: String
    switch error {
    case InventoryFailure.queryRejected: reason = "GitHub rejected the PR query. Update MergePro or report this error."
    case InventoryFailure.partialPage: reason = "GitHub returned partial data. The page will be retried."
    case InventoryFailure.partialNode: reason = "GitHub returned partial data for one pull request. It will be retried; other PRs stay current."
    case GitHubFailure.scopeRequired: reason = "GitHub permission is missing. Reconnect this account."
    case GitHubFailure.organizationRestricted: reason = "Authorize this account for the GitHub organization."
    case GitHubFailure.resourceDenied: reason = "GitHub denied access. Check repository and organization access."
    case GitHubFailure.rateLimited(let until):
      if let until { reason = "GitHub API budget is paused until \(until.formatted(date: .omitted, time: .shortened)). Refresh can resume after that time." }
      else { reason = "GitHub rate limit reached. Retry after the limit resets." }
    case GitHubFailure.unsafeURL: reason = "GitHub returned an untrusted API destination."
    case is URLError: reason = "Could not reach GitHub. Check your network connection."
    case is DecodingError: reason = "GitHub returned data MergePro could not read."
    default: reason = "GitHub returned an unexpected response. Retry or update MergePro."
    }
    return "\(stage): \(reason) Cached PRs retained."
  }
  public func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
    guard let client = context.client, let operation = context.operation,
      let repo = context.repositories.first, context.repositories.count == 1,
      let metadata = context.repositoryMetadata[repo]
    else { throw GitHubFailure.invalidResponse }
    guard
      client.origin.host == context.account.host
        || client.origin.host == "api." + context.account.host
    else { throw GitHubFailure.unsafeURL }
    let parts = metadata.name.split(separator: "/").map(String.init)
    guard parts.count == 2 else { throw GitHubFailure.invalidResponse }
    let statusKey = ProviderKey(
      host: repo.account.host, accountID: repo.account.accountID, repositoryID: repo.repositoryID,
      objectID: "pull-request-inventory")
    let priorStatus = context.cachedSnapshots.first {
      $0.key == statusKey && $0.feature == featureID
    }.flatMap { Self.decodeStored(PRInventoryStatus.self, from: $0.payload) }
    var checkpoint =
      priorStatus?.continuation.flatMap {
        Self.decodeStored(Payload.Checkpoint.self, from: $0)
      } ?? Payload.Checkpoint()
    let now = Date()
    // A bounded chunk leaves transaction time before the coordinator's fixed deadline.
    // Shared client still owns pacing/quota/lifecycle; one slow request may expire and is rejected.
    let reserve = min(Duration.seconds(2), ContinuousClock.now.duration(to: context.deadline) / 5)
    var requests = 0
    func beforeDeadline() -> Bool { ContinuousClock.now.advanced(by: reserve) < context.deadline }
    func admit() -> Bool { requests < Self.requestChunk && beforeDeadline() }
    func prKey(_ id: String) -> ProviderKey {
      ProviderKey(host: repo.account.host, accountID: repo.account.accountID, repositoryID: repo.repositoryID, objectID: "pull-request:" + id)
    }
    var rows: [ProviderKey: PullRequest] = [:]
    var events: [ChangeEvent] = []
    var silent = Set<String>()
    var membershipFailed = false
    var providerFailed = false
    var failureMessages: [String] = []
    /// Per-PR read problems: reported, but they never make the repository failed or partial.
    var nodeFailures: [String] = []
    var latestSucceeded = false
    let cached = Dictionary(context.cachedPullRequests.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    var sweepIDs = checkpoint.sweepPending ?? []
    var stale = checkpoint.staleOpen ?? [:]
    var staleRead = checkpoint.staleRead ?? [:]
    var staleRetry = checkpoint.staleRetry ?? [:]
    // Membership itself resumes a large team connection, with no inferred positive memberships.
    let previousTeams = checkpoint.teamComplete ? checkpoint.teamIDs : nil
    if checkpoint.teamComplete, let at = checkpoint.teamsFetchedAt,
      now.timeIntervalSince(at) > Self.teamTTL
    {
      checkpoint.recentComplete = []
      checkpoint.teamIDs = []
      checkpoint.teamComplete = false
      checkpoint.teamNext = nil
    }
    // Membership is account-wide: adopt a fresh complete read from another repository's inventory.
    if !checkpoint.teamComplete, checkpoint.teamNext == nil,
      let shared = teams.fresh(context.account, ttl: Self.teamTTL, now: now)
    {
      checkpoint.teamIDs = shared.ids
      checkpoint.teamComplete = true
      checkpoint.teamsFetchedAt = shared.fetchedAt
    }
    if !checkpoint.teamComplete, admit() {
      let url =
        checkpoint.teamNext
        ?? client.origin.appendingPathComponent("user/teams").appending(queryItems: [
          URLQueryItem(name: "per_page", value: "100")
        ])
      do {
        try context.checkDeadline()
        guard client.isSafeAPIURL(url),
          url.path == client.origin.appendingPathComponent("user/teams").path
        else { throw GitHubFailure.unsafeURL }
        requests += 1
        let response = try await client.get(url, token: operation.credential.accessToken)
        let teams = try JSONDecoder().decode([Payload.Team].self, from: response.data)
        checkpoint.teamIDs.formUnion(teams.map(\.node_id))
        guard checkpoint.teamIDs.count <= 10000 else { throw GitHubFailure.invalidResponse }
        checkpoint.teamNext = try GitHubPagination.next(response.header("Link"), client: client, requested: url)
        checkpoint.teamComplete = checkpoint.teamNext == nil
        if checkpoint.teamComplete {
          checkpoint.teamsFetchedAt = Date()
          self.teams.store(context.account, ids: checkpoint.teamIDs, at: checkpoint.teamsFetchedAt!)
        }
      } catch {
        if error as? GitHubFailure == .invalidAuthentication || error is CancellationError {
          throw error
        }
        membershipFailed = true
        failureMessages.append(Self.readFailure(error, stage: "Team membership"))
      }
    }
    // Changed membership changes team-request attribution on PRs that did not change: re-walk fully.
    let teamsChanged = previousTeams.map { checkpoint.teamComplete && $0 != checkpoint.teamIDs } ?? false
    // Sweep-originated continuations are not walk work: they never hold a walk open or make it partial.
    let walkPendingEmpty = checkpoint.pending.allSatisfy { sweepIDs.contains($0.id) }
    let startingTraversal =
      priorStatus == nil || priorStatus?.complete == true || priorStatus?.continuation == nil
      || (checkpoint.outerCursor == nil && !checkpoint.outerFinished && walkPendingEmpty)
      || (checkpoint.outerFinished && walkPendingEmpty && checkpoint.traversalPartial)
      || teamsChanged
    if startingTraversal {
      checkpoint.outerCursor = nil
      checkpoint.outerFinished = false
      // A swept row's cached complete copy stays until its continuation finishes, across walks.
      checkpoint.pending = teamsChanged ? [] : checkpoint.pending.filter { sweepIDs.contains($0.id) }
      checkpoint.traversalPartial = false
      if teamsChanged {
        checkpoint.watermark = nil
        checkpoint.sweeping = nil
        checkpoint.sweepCursor = nil
        sweepIDs = []
      }
      // With a committed watermark the head walk stops there; otherwise it is the full history walk.
      checkpoint.walkTop = nil
      checkpoint.walkStartedAt = now
      checkpoint.walkFull = checkpoint.watermark == nil
    }
    // The incremental walk overlaps its committed watermark: an update GitHub surfaces late, with an
    // updatedAt just below the watermark, is still read. Re-ingesting unchanged rows is idempotent.
    let floor = checkpoint.walkFull == true
      ? nil : checkpoint.watermark.flatMap(Self.date).map { $0.addingTimeInterval(-Self.watermarkOverlap) }
    var recent = Dictionary(checkpoint.recentComplete.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    func save(_ node: Node, partial: Bool) {
      guard let viewer = checkpoint.viewer,
        PullRequest.State(rawValue: node.state.lowercased()) != nil
      else {
        checkpoint.traversalPartial = true
        return
      }
      let membershipPartial = !checkpoint.teamComplete || membershipFailed
      // Rows saved without authoritative membership are re-walked rather than left below a watermark.
      if membershipPartial { checkpoint.traversalPartial = true }
      let normalized = normalize(
        node, repo: repo, name: metadata.name, viewer: viewer, teams: checkpoint.teamIDs,
        partial: partial || membershipPartial, reviewPartial: partial,
        cached: cached)
      rows[normalized.key] = normalized
      // Unseen/unknown fields are a silent baseline per object; complete known deltas
      // remain eligible while historical traversal is unfinished.
      guard let old = cached[normalized.key], old.metadata?.partial == false, !partial else {
        return
      }
      if old.state != normalized.state, normalized.state == .merged {
        events.append(
          event(normalized, category: "merged", state: "merged", cycle: context.cycleID))
      }
      if let before = old.metadata?.reviewDecision, let after = normalized.metadata?.reviewDecision,
        before != after
      {
        events.append(
          event(normalized, category: "review decision", state: after, cycle: context.cycleID))
      }
      if let before = old.metadata?.checks, let after = normalized.metadata?.checks, before != after
      {
        events.append(event(normalized, category: "checks", state: after, cycle: context.cycleID))
      }
      if checkpoint.teamComplete, !old.needsViewer, normalized.needsViewer,
        normalized.metadata?.requests.contains(where: {
          $0.isForViewer && $0.viewerStatus == .needsReview
        }) == true
      {
        events.append(
          event(
            normalized, category: "review requested", state: "requested", cycle: context.cycleID))
      }
    }
    /// `sweep` marks pages of the periodic full sweep, which re-reads rows the head walk already committed.
    /// `targeted` marks a by-node read: its partial data is partial for that PR only, never for the traversal.
    func ingest(_ nodes: [Node?], partial: Bool, sweep: Bool = false, targeted: Bool = false) {
      for var node in nodes.compactMap({ $0 }) {
        if let completed = recent[node.id], completed.headRefOid == node.headRefOid,
          completed.updatedAt == node.updatedAt
        {
          for field in ["reviewRequests", "labels", "assignees", "reviews", "timelineItems"]
          where node.connections[field]?.pageInfo.hasNextPage == true {
            if let fresh = node.connections[field], let saved = completed.connections[field],
              (try? JSONEncoder.stable.encode(fresh.nodes))
                == (try? JSONEncoder.stable.encode(Array(saved.nodes.prefix(fresh.nodes.count))))
            {
              node.connections[field] = saved
            }
          }
        }
        let unfinished = node.connections.values.contains { $0.pageInfo.hasNextPage }
        let missing = ["reviewRequests", "labels", "assignees", "reviews", "timelineItems"].contains
        {
          node.connections[$0] == nil
        }
        // An incomplete swept node never replaces a complete cached row: it waits in `pending` and is
        // saved once its nested connections finish (or is dropped), so the sweep never downgrades a row.
        let keepCached = sweep && (unfinished || missing) && cached[prKey(node.id)]?.metadata?.partial == false
        if (partial || missing) && !keepCached && !targeted { checkpoint.traversalPartial = true }
        // A header from an errored page is never completed into authoritative (non-partial) data;
        // the next clean latest page seeds its continuation instead.
        if unfinished, !partial {
          if let index = checkpoint.pending.firstIndex(where: { $0.id == node.id }) {
            // Same provider revision retains accumulated cursor progress; changed
            // objects replace stale pending payload without mixing revisions.
            if checkpoint.pending[index].headRefOid != node.headRefOid
              || checkpoint.pending[index].updatedAt != node.updatedAt
            {
              checkpoint.pending[index] = node
            }
            // Observed by the walk too: it is walk work now.
            if !sweep { sweepIDs.remove(node.id) }
          } else if checkpoint.pending.count < 100 {
            checkpoint.pending.append(node)
            if sweep { sweepIDs.insert(node.id) }
          } else if !sweep {
            checkpoint.traversalPartial = true
          }
        } else if !unfinished {
          checkpoint.pending.removeAll { $0.id == node.id }
          sweepIDs.remove(node.id)
        }
        if keepCached { continue }
        save(node, partial: partial || missing || unfinished)
      }
    }
    /// True once a head-walk page reaches PRs older than the committed watermark.
    func reachedFloor(_ nodes: [Node?]) -> Bool {
      guard let floor, let last = nodes.compactMap({ $0 }).last.flatMap({ Self.date($0.updatedAt) })
      else { return false }
      return last < floor
    }
    func inventory(_ after: String?, query: String, rejectPartial: Bool = false, sweep: Bool = false) async throws -> (
      prs: Payload.Envelope.Payload.Repo.PRs, open: Payload.OpenPRs?, partial: Bool
    ) {
      try context.checkDeadline()
      requests += 1
      let response = try await client.readQuery(
        query, variables: ["owner": parts[0], "repo": parts[1], "after": after],
        token: operation.credential.accessToken)
      let envelope = try JSONDecoder().decode(Payload.Envelope.self, from: response.data)
      guard let data = envelope.data, let viewer = data.viewer,
        String(viewer.databaseId) == context.account.accountID,
        let repository = data.repository, let connection = repository.pullRequests
      else {
        if !(envelope.errors?.isEmpty ?? true) { throw InventoryFailure.queryRejected }
        throw GitHubFailure.invalidResponse
      }
      let partial = !(envelope.errors?.isEmpty ?? true)
      if partial && rejectPartial { throw InventoryFailure.partialPage }
      checkpoint.viewer = viewer
      ingest(connection.nodes, partial: partial, sweep: sweep)
      return (connection, repository.openVolatile, partial)
    }
    /// One older page of the open-PR volatile alias (see `Checkpoint.openCursor`).
    func openPage(_ after: String) async throws -> Payload.OpenPRs {
      try context.checkDeadline()
      requests += 1
      let response = try await client.readQuery(
        Payload.openVolatileQuery, variables: ["owner": parts[0], "repo": parts[1], "after": after],
        token: operation.credential.accessToken)
      let envelope = try JSONDecoder().decode(Payload.Envelope.self, from: response.data)
      guard envelope.errors?.isEmpty ?? true, let data = envelope.data, let viewer = data.viewer,
        String(viewer.databaseId) == context.account.accountID, let open = data.repository?.openVolatile
      else {
        if !(envelope.errors?.isEmpty ?? true) { throw InventoryFailure.queryRejected }
        throw GitHubFailure.invalidResponse
      }
      return open
    }
    /// Targeted re-read of one PR in this repository, ingested like a head-walk observation.
    /// GraphQL field errors on that PR (e.g. a team reviewer the token cannot read, a SAML-protected reference)
    /// are partial data for that PR only: it is ingested as partial (unknown fields stay unknown) and retried
    /// later, never failing or holding open the repository.
    enum NodeRead { case complete, partial }
    func readNode(_ id: String) async throws -> NodeRead {
      try context.checkDeadline()
      requests += 1
      let response = try await client.readQuery(
        Payload.nodeQuery, variables: ["id": id], token: operation.credential.accessToken)
      let envelope = try JSONDecoder().decode(Payload.NodeEnvelope.self, from: response.data)
      let errored = !(envelope.errors?.isEmpty ?? true)
      guard let data = envelope.data, let viewer = data.viewer,
        String(viewer.databaseId) == context.account.accountID
      else {
        throw errored ? InventoryFailure.partialNode : GitHubFailure.invalidResponse
      }
      // An explicitly null, error-free node is authoritative absence (an errored null node is unknown). A
      // transferred PR belongs to another repository; neither observation may overwrite this repository's row.
      guard let target = data.node else {
        if errored { throw InventoryFailure.partialNode }
        return .complete
      }
      guard target.node.id == id, let repositoryID = target.repository?.databaseId else {
        throw errored ? InventoryFailure.partialNode : GitHubFailure.invalidResponse
      }
      guard String(repositoryID) == repo.repositoryID else { return .complete }
      // A continuation without a cursor can never finish; a missing connection is acceptable only as partial data.
      let fields = ["reviewRequests", "labels", "assignees", "reviews", "timelineItems"]
      let invalidContinuation = fields.contains {
        guard let connection = target.node.connections[$0] else { return false }
        return connection.pageInfo.hasNextPage && connection.pageInfo.endCursor?.isEmpty != false
      }
      guard !invalidContinuation, errored || fields.allSatisfy({ target.node.connections[$0] != nil })
      else { throw InventoryFailure.partialNode }
      checkpoint.viewer = viewer
      ingest([target.node], partial: errored, targeted: true)
      return errored ? .partial : .complete
    }
    /// GitHub changes check rollups and mergeability without bumping `updatedAt`; refresh them on
    /// unchanged cached open PRs so the watermark never hides a checks transition.
    func refreshOpen(_ open: Payload.OpenPRs) {
      for node in open.nodes.compactMap({ $0 }) {
        let key = prKey(node.id)
        guard rows[key] == nil else { continue }
        let observed = Self.date(node.updatedAt)
        // A newer update (or another head) than the cache that this cycle has not read means the ordered
        // walk missed it (surfaced late, below the floor): re-read it by node rather than leave it stale
        // until the sweep. Each distinct observation is read once.
        let behind = cached[key].map { old in
          old.headRevision.rawValue != node.headRefOid
            || old.metadata?.updatedAt.map { cachedAt in observed.map { $0 > cachedAt } ?? false } ?? true
        } ?? true
        if behind {
          let observation = Payload.Checkpoint.Observation(updatedAt: node.updatedAt, head: node.headRefOid)
          if staleRead[node.id] != observation.signature, stale[node.id] != nil || stale.count < 100 {
            // A newer observation is read promptly even if an older one is on its retry cooldown.
            if stale[node.id] != observation { staleRetry[node.id] = nil }
            stale[node.id] = observation
          }
          continue
        }
        guard let old = cached[key], var m = old.metadata, old.state == .open, m.updatedAt == observed
        else { continue }
        let checks = node.commits?.nodes.first??.commit.statusCheckRollup?.state
        let mergeInputsChanged = m.checks != checks || m.mergeable != node.mergeable
        // Only a complete label page is authoritative; more than 20 labels waits for the next head read.
        let labels = node.labels.flatMap { $0.pageInfo.hasNextPage ? nil : $0.nodes.compactMap { $0 } }
        let names = labels?.compactMap(\.name)
        let colors = labels.map { Self.labelColors($0) }
        let labelsChanged = names.map { $0 != m.labels || colors != m.labelColors } ?? false
        guard mergeInputsChanged || labelsChanged else { continue }
        let before = m.checks
        if let names, labelsChanged { m.labels = names; m.labelColors = colors ?? nil }
        m.fetchedAt = Date()
        if mergeInputsChanged {
          m.checks = checks
          m.mergeable = node.mergeable
          // Like normalize: changed merge inputs invalidate carried evidence. Labels are not merge inputs.
          m.mergeEvidence = nil
          m.mergeEligible = nil
          m.nativeStack = nil
        }
        let probe = PullRequest(
          key: key, headRevision: old.headRevision, title: old.title, state: old.state,
          isDraft: old.isDraft, metadata: m)
        if BoardProjection.column(for: old, showDrafts: true)
          != BoardProjection.column(for: probe, showDrafts: true)
        {
          m.columnChangedAt = Date()
        }
        let updated = PullRequest(
          key: key, headRevision: old.headRevision, title: old.title, state: old.state,
          isDraft: old.isDraft, metadata: m)
        rows[key] = updated
        if m.partial == false, let before, let after = checks, before != after {
          events.append(event(updated, category: "checks", state: after, cycle: context.cycleID))
        }
      }
    }
    // Reserve the first inventory read for current work on EVERY cycle, even during history.
    // An incrementally synced repository reads a small head page. The open-PR volatile batch (checks,
    // mergeability and labels GitHub changes without bumping updatedAt) rides on every manual refresh and on
    // every `openVolatileEvery`-th scheduled read, which bounds its GraphQL cost and response size.
    var latestOpen: Payload.OpenPRs?
    let carryOpen = floor != nil
      && (context.reason == .manual || (checkpoint.readsSinceOpenBatch ?? Self.openVolatileEvery) >= Self.openVolatileEvery - 1)
    if admit() {
      do {
        let latest = try await inventory(
          nil,
          query: floor == nil
            ? Payload.inventoryQuery
            : Payload.inventoryQuery(first: Payload.incrementalPageSize, openVolatile: carryOpen))
        latestSucceeded = true
        if floor != nil { checkpoint.readsSinceOpenBatch = carryOpen ? 0 : (checkpoint.readsSinceOpenBatch ?? 0) + 1 }
        if !latest.partial, let open = latest.open { latestOpen = open; refreshOpen(open) }
        if startingTraversal {
          checkpoint.walkTop = Self.top(latest.prs.nodes, above: checkpoint.watermark)
          checkpoint.outerCursor = latest.prs.pageInfo.endCursor
          checkpoint.outerFinished = !latest.prs.pageInfo.hasNextPage || reachedFloor(latest.prs.nodes)
          if !checkpoint.outerFinished && latest.prs.pageInfo.endCursor == nil {
            checkpoint.traversalPartial = true
            checkpoint.outerFinished = true
          }
        }
      } catch {
        if error as? GitHubFailure == .invalidAuthentication || error is CancellationError {
          throw error
        }
        providerFailed = true
        failureMessages.append(Self.readFailure(error, stage: "Pull requests"))
      }
    }
    // Finish one node at a time. Each connection retains its own cursor and accumulated values.
    while latestSucceeded, !checkpoint.pending.isEmpty, admit() {
      var node = checkpoint.pending[0]
      let key = prKey(node.id)
      // A swept continuation that cannot finish is dropped: its complete cached row stays, and the walk
      // owns any newer revision. A walk continuation that cannot finish leaves the traversal partial.
      let swept = sweepIDs.contains(node.id)
      func drop() {
        checkpoint.pending.removeFirst()
        sweepIDs.remove(node.id)
        if !swept { checkpoint.traversalPartial = true }
      }
      // Compare with this cycle's latest observation first; the cycle-start cache may predate it.
      if let current = rows[key] ?? cached[key], current.headRevision.rawValue != node.headRefOid {
        drop()
        continue
      }
      guard
        let field = ["reviewRequests", "labels", "assignees", "reviews", "timelineItems"].first(
          where: {
            node.connections[$0]?.pageInfo.hasNextPage == true
          }),
        let cursor = node.connections[field]?.pageInfo.endCursor
      else {
        if !swept { save(node, partial: true) }
        drop()
        continue
      }
      do {
        try context.checkDeadline()
        requests += 1
        let response = try await client.readQuery(
          Payload.connectionQuery(field), variables: ["id": node.id, "after": cursor],
          token: operation.credential.accessToken)
        let extra = try JSONDecoder().decode(Payload.ConnectionEnvelope.self, from: response.data)
        guard let header = extra.data?.node, header.headRefOid == node.headRefOid,
          header.updatedAt == node.updatedAt
        else {
          // Mutable nested data belongs to a new revision. Discard obsolete continuation;
          // the next latest page seeds its current header rather than overwriting it.
          drop()
          continue
        }
        guard extra.errors?.isEmpty ?? true, let more = header.connections[field],
          !more.pageInfo.hasNextPage || more.pageInfo.endCursor != cursor
        else { throw GitHubFailure.invalidResponse }
        node.connections[field]?.nodes.append(contentsOf: more.nodes)
        node.connections[field]?.pageInfo = more.pageInfo
        guard node.connections.values.reduce(0, { $0 + $1.nodes.count }) <= 10000 else {
          throw GitHubFailure.invalidResponse
        }
        checkpoint.pending[0] = node
        if !node.connections.values.contains(where: { $0.pageInfo.hasNextPage }) {
          checkpoint.pending.removeFirst()
          sweepIDs.remove(node.id)
          checkpoint.recentComplete.removeAll { $0.id == node.id }
          checkpoint.recentComplete.append(node)
          checkpoint.recentComplete = Array(checkpoint.recentComplete.suffix(100))
          recent = Dictionary(checkpoint.recentComplete.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
          save(
            node,
            partial: ["reviewRequests", "labels", "assignees", "reviews", "timelineItems"].contains
            {
              node.connections[$0] == nil
            })
        } else if !swept {
          save(node, partial: true)
        }
      } catch {
        if error as? GitHubFailure == .invalidAuthentication || error is CancellationError {
          throw error
        }
        providerFailed = true
        failureMessages.append(Self.readFailure(error, stage: "PR details"))
        break
      }
    }
    var visited = Set<String>()
    while latestSucceeded, checkpoint.pending.isEmpty, !checkpoint.outerFinished, admit() {
      guard let cursor = checkpoint.outerCursor, visited.insert(cursor).inserted else {
        checkpoint.traversalPartial = true
        break
      }
      do {
        let page = try await inventory(cursor, query: Payload.inventoryQuery)
        checkpoint.outerCursor = page.prs.pageInfo.endCursor
        checkpoint.outerFinished = !page.prs.pageInfo.hasNextPage || reachedFloor(page.prs.nodes)
      } catch {
        if error as? GitHubFailure == .invalidAuthentication || error is CancellationError {
          throw error
        }
        providerFailed = true
        failureMessages.append(Self.readFailure(error, stage: "PR history"))
        break
      }
    }
    // Periodic full sweep of an incrementally synced repository (fields GitHub changes without
    // bumping updatedAt, branch rules). Head data stays current, so it spends only leftover
    // allowance after the head walk and never makes the inventory partial; errored pages are
    // discarded and retried, and a swept row whose nested connections continue keeps its complete
    // cached row until they finish, rather than downgrading complete rows.
    if floor != nil, latestSucceeded, checkpoint.outerFinished, checkpoint.pending.isEmpty,
      checkpoint.teamComplete, !membershipFailed, !providerFailed, !checkpoint.traversalPartial
    {
      if checkpoint.sweeping != true,
        checkpoint.fullPassAt.map({ now.timeIntervalSince($0) > fullPassInterval }) ?? true
      {
        checkpoint.sweeping = true
        checkpoint.sweepCursor = nil
        checkpoint.sweepStartedAt = now
      }
      var swept = Set<String>()
      while checkpoint.sweeping == true, checkpoint.pending.isEmpty, admit() {
        do {
          let page = try await inventory(
            checkpoint.sweepCursor, query: Payload.inventoryQuery, rejectPartial: true, sweep: true)
          if !page.prs.pageInfo.hasNextPage {
            checkpoint.sweeping = false
            checkpoint.sweepCursor = nil
            checkpoint.fullPassAt = checkpoint.sweepStartedAt ?? now
          } else if let cursor = page.prs.pageInfo.endCursor, swept.insert(cursor).inserted {
            checkpoint.sweepCursor = cursor
          } else {
            throw GitHubFailure.invalidResponse
          }
        } catch {
          if error as? GitHubFailure == .invalidAuthentication || error is CancellationError {
            throw error
          }
          providerFailed = true
          failureMessages.append(Self.readFailure(error, stage: "PR sweep"))
          break
        }
      }
    }
    // Older open PRs: one rotating page of the open-PR volatile alias per cycle (the head read carries the
    // newest 100), so every open PR's checks, mergeability and labels refresh within ceil(open/100) cycles.
    // A failed page is retried from the start next cycle; it never makes the inventory partial.
    if floor != nil, latestSucceeded, let first = latestOpen {
      if !first.pageInfo.hasNextPage {
        checkpoint.openCursor = nil
      } else if admit(), let cursor = checkpoint.openCursor ?? first.pageInfo.endCursor {
        do {
          let page = try await openPage(cursor)
          refreshOpen(page)
          checkpoint.openCursor =
            page.pageInfo.hasNextPage && page.pageInfo.endCursor != cursor ? page.pageInfo.endCursor : nil
        } catch {
          if error as? GitHubFailure == .invalidAuthentication || error is CancellationError { throw error }
          Log.inventory.info("Open-PR volatile page failed; restarting its rotation: \(Log.kind(error), privacy: .public)")
          checkpoint.openCursor = nil
        }
      }
    }
    // Re-read, by node, open PRs whose newer observation the ordered walk has not surfaced. Only once the
    // walk is done (an unfinished walk may still reach them); a row that caught up needs no read. One PR's
    // partial GraphQL data never fails the repository or stops later reads: it is retried at the next cycle,
    // then only after `nodeRetry`, so a PR GitHub can never fully return costs one read per cooldown. A read
    // that fails outright (server error, rate limit, network, unreadable response) fails the repository as
    // any other provider read does: that PR is stale, so its repository must not show as current.
    if latestSucceeded, checkpoint.outerFinished {
      var reads = 0
      for (id, observation) in stale.sorted(by: { $0.key < $1.key }) {
        let retry = staleRetry[id]
        if let current = rows[prKey(id)] ?? cached[prKey(id)], current.headRevision.rawValue == observation.head,
          let at = current.metadata?.updatedAt, let seen = Self.date(observation.updatedAt), at >= seen,
          retry == nil || current.metadata?.partial == false
        {
          stale[id] = nil
          staleRetry[id] = nil
          continue
        }
        if let retry, retry.count > 1, now.timeIntervalSince(retry.at) < Self.nodeRetry, retry.at <= now { continue }
        guard reads < Self.staleReadsPerCycle, admit() else { break }
        reads += 1
        do {
          switch try await readNode(id) {
          case .complete:
            stale[id] = nil
            staleRead[id] = observation.signature
            staleRetry[id] = nil
          case .partial:
            staleRetry[id] = .init(count: (retry?.count ?? 0) + 1, at: now)
            nodeFailures.append(Self.readFailure(InventoryFailure.partialNode, stage: "PR refresh"))
          }
        } catch InventoryFailure.partialNode {
          staleRetry[id] = .init(count: (retry?.count ?? 0) + 1, at: now)
          nodeFailures.append(Self.readFailure(InventoryFailure.partialNode, stage: "PR refresh"))
        } catch {
          if error as? GitHubFailure == .invalidAuthentication || error is CancellationError { throw error }
          providerFailed = true
          failureMessages.append(Self.readFailure(error, stage: "PR refresh"))
          break
        }
      }
    }
    // Bounded memo: forgetting it costs at most one repeated node read per still-diverging observation.
    if staleRead.count > 200 { staleRead = [:] }
    // Merge evidence for PRs whose merge inputs changed (or were never read). Candidates are this cycle's
    // rows plus cached open, non-draft, complete rows without evidence: refreshOpen and normalize
    // invalidate evidence on rows a later cycle's head page never reaches, which would otherwise never be
    // re-read. Unchanged rows keep carried evidence: Merge always re-verifies before acting, so background
    // renewal only refreshes PRs that look close to mergeable, and only once their evidence is older than
    // `evidenceRenewal` (well above `MergePolicy.maximumAge`). A failed read is retried only after a cooldown.
    // A quiet repository therefore costs its head read, plus one rotating open page after each carried
    // open batch past 100 open PRs, plus at most `evidenceReadsPerCycle` renewals per `evidenceRenewal`.
    // Reads spend only the chunk's remaining allowance (never starting one that cannot complete), at most
    // `evidenceReadsPerCycle` of them, so other repositories' inventory keeps its share of the cycle; PRs
    // whose blocked evidence was invalidated go first, as they alone can report readiness. The account
    // budget (interactive reserve) and cycle ledger still own every request.
    var tried = checkpoint.evidenceTried ?? [:]
    var blocked = checkpoint.evidenceBlocked ?? [:]
    func signature(_ pr: PullRequest) -> String {
      let m = pr.metadata
      return [
        pr.headRevision.rawValue, m?.baseRevision ?? "", m?.checks ?? "", m?.mergeable ?? "",
        m?.reviewDecision ?? "", String(m?.updatedAt?.timeIntervalSince1970 ?? 0),
      ].joined(separator: "|")
    }
    // Evidence invalidated this cycle: remember whether it was an authoritative blocker, so a re-read in a
    // later cycle (when no cached row carries it any more) still reports the readiness transition. The
    // memo expires, so a long-unreadable PR never produces a stale alert.
    for row in rows.values where row.metadata?.mergeEvidence == nil {
      let id = row.key.objectID
      guard row.state == .open, !row.isDraft else { blocked[id] = nil; continue }
      if let before = cached[row.key]?.metadata?.mergeEvidence {
        blocked[id] = MergePolicy.requirementState(before, now: before.fetchedAt) == .pending ? now : nil
      }
    }
    blocked = blocked.filter { now.timeIntervalSince($0.value) < Self.blockedEvidenceTTL }
    func eligible(_ pr: PullRequest) -> Bool {
      guard pr.state == .open, !pr.isDraft, pr.metadata?.partial == false
      else { return false }
      let evidence = pr.metadata?.mergeEvidence
      // Carried evidence (unchanged merge inputs) is renewed only past the renewal interval, and only for PRs
      // that look close to mergeable; invalidated evidence (nil) is always re-read.
      if let evidence, evidence.fetchedAt <= now.addingTimeInterval(5),
        now.timeIntervalSince(evidence.fetchedAt) < Self.evidenceRenewal || !Self.looksMergeable(pr)
      { return false }
      guard let attempt = tried[pr.key.objectID] else { return true }
      // A successful read is renewed once it is due. A later failed revalidation keeps its cooldown even
      // though the old evidence is still present in the cached row.
      if let evidence, evidence.fetchedAt >= attempt.at { return true }
      return attempt.signature != signature(pr) || now.timeIntervalSince(attempt.at) >= Self.evidenceRetry
    }
    var enrichedCachedRows = 0
    if latestSucceeded {
      let candidates = (rows.values.filter(eligible) + cached.values.filter { rows[$0.key] == nil && eligible($0) })
        .sorted(by: {
          let pa = blocked[$0.key.objectID] != nil, pb = blocked[$1.key.objectID] != nil
          if pa != pb { return pa }
          let a = cached[$0.key]?.metadata?.mergeEvidence?.fetchedAt ?? .distantPast
          let b = cached[$1.key]?.metadata?.mergeEvidence?.fetchedAt ?? .distantPast
          return a == b ? ($0.metadata?.number ?? 0) < ($1.metadata?.number ?? 0) : a < b
        })
      var reads = 0
      for candidate in candidates {
        guard reads < Self.evidenceReadsPerCycle, Self.requestChunk - requests >= Self.evidenceReadRequests,
          beforeDeadline()
        else { break }
        reads += 1
        tried[candidate.key.objectID] = .init(signature: signature(candidate), at: now)
        let bounded=MergeInventoryReadTransport(base:client.transport,limit:Self.requestChunk-requests,deadline:context.deadline)
        do {
          let evidenceClient=GitHubHTTPClient(origin:client.origin,transport:bounded)
          let read=try await GitHubMergeReader(client:evidenceClient,credential:operation.credential).inspect(MergeTarget(candidate))
          guard read.pr.headRevision == candidate.headRevision else { throw PRWriteFailure.revisionChanged }
          var m=candidate.metadata;m?.mergeEvidence=read.evidence;m?.mergeEligible=MergePolicy.evaluate(read.evidence).eligible;m?.nativeStack=read.stack
          let enriched=PullRequest(key:candidate.key,headRevision:candidate.headRevision,title:candidate.title,state:candidate.state,isDraft:candidate.isDraft,metadata:m)
          if rows[candidate.key] == nil { enrichedCachedRows += 1 }
          rows[candidate.key]=enriched
          // Blocked → ready, against the cached evidence or, once that was invalidated, the blocked memo.
          let previous=cached[candidate.key]
          let ready=previous?.metadata?.mergeEvidence != nil
            ? MergePolicy.becameReady(previous:previous,current:enriched)
            : blocked[candidate.key.objectID] != nil && MergePolicy.evaluate(read.evidence).eligible
          blocked[candidate.key.objectID]=nil
          if ready {
            events.append(event(enriched,category:read.evidence.queueRequired ? "ready for merge queue" : "ready to merge",state:"ready",cycle:context.cycleID))
          }
        } catch {
          if error as? GitHubFailure == .invalidAuthentication || error is CancellationError { throw error }
          // Unknown evidence is visible and never a ready transition. Inventory still commits.
          Log.inventory.info("Background merge evidence read failed; evidence stays unknown: \(Log.kind(error), privacy: .public)")
        }
        requests += await bounded.count
      }
    }
    if tried.count > 200 {
      for (key, _) in tried.sorted(by: { $0.value.at < $1.value.at }).prefix(tried.count - 200) { tried[key] = nil }
    }
    if blocked.count > 200 {
      for (key, _) in blocked.sorted(by: { $0.value < $1.value }).prefix(blocked.count - 200) { blocked[key] = nil }
    }
    checkpoint.evidenceTried = tried.isEmpty ? nil : tried
    checkpoint.evidenceBlocked = blocked.isEmpty ? nil : blocked
    sweepIDs.formIntersection(checkpoint.pending.map(\.id))
    checkpoint.sweepPending = sweepIDs.isEmpty ? nil : sweepIDs
    checkpoint.staleOpen = stale.isEmpty ? nil : stale
    checkpoint.staleRead = staleRead.isEmpty ? nil : staleRead
    staleRetry = staleRetry.filter { stale[$0.key] != nil }
    checkpoint.staleRetry = staleRetry.isEmpty ? nil : staleRetry
    // Never retain unbounded opaque provider payloads in a checkpoint.
    if try JSONEncoder.stable.encode(checkpoint).count > 2 * 1024 * 1024 {
      checkpoint.pending = []
      checkpoint.recentComplete = []
      checkpoint.sweepPending = nil
      checkpoint.traversalPartial = true
    }
    // Sweep-originated continuations never count against completeness (their cached rows are complete).
    let complete =
      checkpoint.outerFinished && checkpoint.pending.allSatisfy { checkpoint.sweepPending?.contains($0.id) == true }
      && checkpoint.teamComplete
      && !checkpoint.traversalPartial && !membershipFailed && !providerFailed && latestSucceeded
    if complete {
      // Every PR older than this walk's first-page top is committed at its current revision, so the
      // next walk can stop there. A completed full walk is also the latest full pass.
      checkpoint.watermark = Self.later(checkpoint.walkTop, checkpoint.watermark)
      if checkpoint.walkFull == true {
        checkpoint.fullPassAt = checkpoint.walkStartedAt ?? now
        checkpoint.sweeping = nil
        checkpoint.sweepCursor = nil
      }
    }
    let continuation = try JSONEncoder.stable.encode(checkpoint)
    let status = PRInventoryStatus(
      complete: complete, fetchedCount: rows.count - enrichedCachedRows, fetchedAt: Date(),
      message: complete
        ? nil : "Partial provider data; resumable history, cached unseen PRs retained.",
      continuation: continuation,
      lastSuccessAt: latestSucceeded
        ? Date()
        : priorStatus?.lastSuccessAt
          ?? (priorStatus?.lastFailureAt == nil ? priorStatus?.fetchedAt : nil),
      lastFailureAt: providerFailed || membershipFailed ? Date() : priorStatus?.lastFailureAt,
      // Per-PR read problems are reported without failing a repository whose inventory is otherwise current.
      failureMessage: providerFailed || membershipFailed
        ? (failureMessages + nodeFailures).joined(separator: " ")
        : !nodeFailures.isEmpty ? nodeFailures.joined(separator: " ") : (latestSucceeded ? nil : priorStatus?.failureMessage))
    // Request.baseline suppression is the coordinator's durable cycle flag. A new scope
    // silently seeds only unseen/unknown objects, not indefinitely all known transitions.
    if context.suppressNotifications { silent.formUnion(events.map(\.key)) }
    return PollFetchResult(
      events: events,
      pullRequests: Array(rows.values).sorted { $0.metadata!.number < $1.metadata!.number },
      snapshots: [
        PollFeatureSnapshot(
          key: statusKey, feature: featureID, payload: try JSONEncoder.stable.encode(status))
      ], baselinedRepositories: complete ? [repo] : [], baselineEventKeys: silent)
  }
  private static let teamTTL: TimeInterval = 300
  private static let evidenceRetry: TimeInterval = 600
  /// Unchanged carried merge evidence is renewed in the background no more often than this.
  static let evidenceRenewal: TimeInterval = 600
  /// A by-node read that failed or returned partial data twice waits this long before its next retry.
  static let nodeRetry: TimeInterval = 600
  /// Scheduled incremental head reads carry the open-PR volatile batch once per this many reads.
  static let openVolatileEvery = 3
  /// Not draft, no outstanding review requirement or requested changes, checks passing (or none), no
  /// known conflict: the only PRs whose unchanged evidence is worth renewing in the background.
  static func looksMergeable(_ pr: PullRequest) -> Bool {
    guard pr.state == .open, !pr.isDraft, let m = pr.metadata else { return false }
    return (m.reviewDecision == nil || m.reviewDecision == "APPROVED")
      && (m.checks == nil || m.checks == "SUCCESS") && m.mergeable != "CONFLICTING"
  }
  /// Inventory requests per fetch: a bounded chunk leaves transaction time before the coordinator's deadline.
  static let requestChunk = 8
  /// The incremental walk re-reads this far below its committed watermark.
  static let watermarkOverlap: TimeInterval = 300
  static let staleReadsPerCycle = 2
  static let evidenceReadsPerCycle = 2
  /// One complete merge-evidence read needs at least this many requests (admission query, branch rules,
  /// rulesets, identity recheck).
  static let evidenceReadRequests = 4
  private static let blockedEvidenceTTL: TimeInterval = 3600
  static func date(_ value: String) -> Date? { GitHubDate.parse(value) }
  /// A stored status or checkpoint that no longer decodes restarts the walk from the newest page.
  private static func decodeStored<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
    do { return try JSONDecoder().decode(type, from: data) } catch {
      Log.inventory.error("Stored inventory progress did not decode; reading from the start: \(Log.kind(error), privacy: .public)")
      return nil
    }
  }
  /// Newest `updatedAt` on a head page, never below the committed watermark.
  private static func top(_ nodes: [Node?], above watermark: String?) -> String? {
    later(nodes.compactMap { $0?.updatedAt }.max { (date($0) ?? .distantPast) < (date($1) ?? .distantPast) }, watermark)
  }
  private static func later(_ a: String?, _ b: String?) -> String? {
    guard let a, let da = date(a) else { return b }
    guard let b, let db = date(b) else { return a }
    return da >= db ? a : b
  }
  private func normalize(
    _ node: Node, repo: RepositoryKey, name: String, viewer: Viewer, teams: Set<String>,
    partial: Bool, reviewPartial: Bool, cached: [ProviderKey: PullRequest]
  ) -> PullRequest {
    let key = ProviderKey(
      host: repo.account.host, accountID: repo.account.accountID, repositoryID: repo.repositoryID,
      objectID: "pull-request:" + node.id)
    var m = PRMetadata(number: node.number, webURL: node.url, repositoryName: name)
    m.descriptionPreview = node.bodyText
    m.authorID = node.author?.id
    m.authorLogin = node.author?.login
    m.actorType = node.author?.type
    m.viewerID = viewer.id
    m.viewerIsAuthor = node.author?.id == viewer.id
    m.headBranch = node.headRefName ?? ""
    m.headRepositoryID=node.headRepository?.databaseId.map(String.init)
    m.baseBranch = node.baseRefName
    m.baseRevision = node.baseRefOid
    m.createdAt = GitHubDate.parse(node.createdAt)
    m.updatedAt = GitHubDate.parse(node.updatedAt)
    m.mergedAt = node.mergedAt.flatMap(GitHubDate.parse)
    m.fetchedAt = Date()
    m.requiredReviewCount = node.baseRef?.branchProtectionRule?.requiredApprovingReviewCount
    m.reviewDecision = reviewPartial ? nil : node.reviewDecision
    m.mergeable = node.mergeable
    m.autoMerge = node.autoMergeRequest != nil
    m.autoMergeKnown = reviewPartial ? nil : node.autoMergeKnown ? true : nil
    m.files = node.changedFiles
    m.additions = node.additions
    m.deletions = node.deletions
    m.comments = node.comments?.totalCount
    let labels = node.connections["labels"]?.nodes.compactMap { $0 } ?? []
    m.labels = labels.compactMap(\.name)
    m.labelColors = Self.labelColors(labels)
    m.assignees = node.connections["assignees"]?.nodes.compactMap { $0?.login } ?? []
    let reviews = node.connections["reviews"]?.nodes.compactMap { $0 } ?? []
    // Like GitHub's opinionated review state, a later COMMENTED/PENDING review never replaces
    // an author's APPROVED/CHANGES_REQUESTED/DISMISSED state.
    let latest = Dictionary(
      grouping: reviews.filter {
        $0.commit?.oid == node.headRefOid
          && ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains($0.state ?? "")
      },
      by: { $0.author?.id ?? "unknown" }
    ).compactMap { $0.value.max { ($0.submittedAt ?? "") < ($1.submittedAt ?? "") } }
    m.requests =
      node.connections["reviewRequests"]?.nodes.compactMap { item in
        guard let reviewer = item?.requestedReviewer, let id = reviewer.id else { return nil }
        let team = reviewer.type == "Team"
        let member = teams.contains(id)
        var status: PRReviewRequest.ViewerStatus = .notForViewer
        if !team {
          status = id == viewer.id ? .needsReview : .notForViewer
        } else if member {
          let review = latest.first {
            $0.author?.id == viewer.id
              && ["APPROVED", "CHANGES_REQUESTED"].contains($0.state ?? "")
          }
          if !reviewPartial, review == nil {
            status = .needsReview
          } else if !reviewPartial, let review,
            let timeline = node.connections["timelineItems"], !timeline.pageInfo.hasNextPage,
            let request = timeline.nodes.compactMap({ $0 }).filter({
              $0.requestedReviewer?.id == id
            }).max(by: { ($0.createdAt ?? "") < ($1.createdAt ?? "") }),
            request.type == "ReviewRequestedEvent",
            let at = request.createdAt.flatMap(GitHubDate.parse),
            let submitted = review.submittedAt.flatMap(GitHubDate.parse)
          {
            status = submitted >= at ? .alreadyReviewed : .needsReview
          } else {
            status = .unknown
          }
        }
        return PRReviewRequest(
          id: id, name: reviewer.name ?? reviewer.login ?? reviewer.slug ?? "Unknown",
          kind: team ? .team : .direct,
          isForViewer: status == .needsReview || status == .unknown, viewerStatus: status)
      } ?? []
    m.approvalCount = reviewPartial ? nil : latest.filter { $0.state == "APPROVED" }.count
    m.outstandingChanges = reviewPartial ? nil : latest.contains { $0.state == "CHANGES_REQUESTED" }
    m.reviewers = Array(Set(m.requests.map(\.name) + reviews.compactMap { $0.author?.login }))
      .sorted()
    m.checks = node.commits?.nodes.first??.commit.statusCheckRollup?.state
    m.partial = partial
    m.authorClassification = AgentClassifier.classify(login:m.authorLogin,actorType:m.actorType,branch:m.headBranch,labels:m.labels).rawValue
    let old = cached[key]
    if let prior=old, prior.headRevision.rawValue == node.headRefOid { m.riskFlags=prior.metadata?.riskFlags }
    let state = PullRequest.State(rawValue: node.state.lowercased()) ?? .open
    let pr = PullRequest(
      key: key, headRevision: RevisionID(node.headRefOid), title: node.title, state: state,
      isDraft: node.isDraft, metadata: m)
    if let old,old.headRevision == pr.headRevision,old.state == pr.state,old.isDraft == pr.isDraft,old.metadata?.baseRevision == m.baseRevision,old.metadata?.reviewDecision == m.reviewDecision,old.metadata?.checks == m.checks,old.metadata?.mergeable == m.mergeable {
      m.mergeEvidence=old.metadata?.mergeEvidence;m.mergeEligible=m.mergeEvidence.map { MergePolicy.evaluate($0).eligible };m.nativeStack=old.metadata?.nativeStack
    }
    m.columnChangedAt =
      old.map {
        BoardProjection.column(for: $0, showDrafts: true)
          == BoardProjection.column(for: pr, showDrafts: true)
          ? $0.metadata?.columnChangedAt : Date()
      } ?? Date()
    // An unchanged observation keeps its fetch time, so re-reading it rewrites nothing. Classification is
    // reapplied from account rules when the row is stored, so it is not a provider change.
    if let old, var probe = old.metadata {
      probe.fetchedAt = m.fetchedAt
      probe.authorClassification = m.authorClassification
      if old.headRevision == pr.headRevision, old.title == pr.title, old.state == pr.state, old.isDraft == pr.isDraft,
        probe == m
      {
        m.fetchedAt = old.metadata?.fetchedAt
      }
    }
    return PullRequest(
      key: key, headRevision: pr.headRevision, title: pr.title, state: pr.state,
      isDraft: pr.isDraft, metadata: m)
  }
  /// Label name → normalized color; nil when no label carries a valid color.
  private static func labelColors(_ labels: [Payload.Item]) -> [String: String]? {
    let colors = Dictionary(
      labels.compactMap { label -> (String, String)? in
        guard let name = label.name, let color = label.color.flatMap(Self.hexColor) else { return nil }
        return (name, color)
      }, uniquingKeysWith: { first, _ in first })
    return colors.isEmpty ? nil : colors
  }
  /// Lowercase 6-digit hex without `#`, or nil for anything else.
  static func hexColor(_ value: String) -> String? {
    let hex = (value.hasPrefix("#") ? String(value.dropFirst()) : value).lowercased()
    return hex.count == 6 && hex.allSatisfy(\.isHexDigit) ? hex : nil
  }
  private func event(_ pr: PullRequest, category: String, state: String, cycle: UUID) -> ChangeEvent
  {
    let pieces = [
      "inventory-transition", cycle.uuidString, pr.key.host, pr.key.accountID, pr.key.repositoryID,
      pr.key.objectID,
      pr.headRevision.rawValue, category, state,
      String(pr.metadata?.updatedAt?.timeIntervalSince1970 ?? 0),
    ]
    return ChangeEvent(
      key: pieces.map { "\($0.utf8.count):\($0)" }.joined(), object: pr.key, category: category,
      occurredAt: pr.metadata?.updatedAt ?? Date(), title: pr.title,
      locator: EventLocator(
        subjectType: "PullRequest", subjectNumber: pr.metadata.map { String($0.number) },
        webURL: pr.metadata?.webURL),
      teams: Set(
        pr.metadata?.requests.filter { $0.kind == .team && $0.isForViewer }.map(\.id) ?? []))
  }
}

/// A per-fetch count/deadline bound over the existing budgeted transport, not a rate owner.
private actor MergeInventoryReadTransport:GitHubTransport {
    let base:any GitHubTransport
    let limit:Int
    let deadline:ContinuousClock.Instant
    private(set) var count=0
    init(base:any GitHubTransport,limit:Int,deadline:ContinuousClock.Instant) { self.base=base;self.limit=limit;self.deadline=deadline }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        guard count<limit,ContinuousClock.now<deadline else { throw PRWriteFailure.unavailable };count += 1
        return try await base.send(request)
    }
}

/// Team membership is account-wide; one complete read serves every repository for its TTL.
final class TeamMembershipCache: Sendable {
  struct Entry: Sendable { let ids: Set<String>; let fetchedAt: Date }
  private let entries = Mutex<[AccountScope: Entry]>([:])
  func fresh(_ account: AccountScope, ttl: TimeInterval, now: Date) -> Entry? {
    entries.withLock { $0[account].flatMap { now.timeIntervalSince($0.fetchedAt) <= ttl ? $0 : nil } }
  }
  func store(_ account: AccountScope, ids: Set<String>, at: Date) {
    entries.withLock { $0[account] = Entry(ids: ids, fetchedAt: at) }
  }
}
