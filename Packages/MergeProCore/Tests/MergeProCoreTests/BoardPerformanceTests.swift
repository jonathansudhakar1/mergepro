import XCTest

@testable import MergeProCore

/// Board/list main-thread budget: stacks are row-derived (never rebuilt by filter edits), inference is
/// near-linear even for a long-lived deploy branch, and per-card lookups are indexed. Legacy copies of the
/// previous algorithms below are the equivalence oracles: stacks, warnings, cards and order must not change.
final class BoardPerformanceTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }
  func row(
    _ n: Int, head: String, base: String, state: PullRequest.State = .open, repo: String = "R",
    account: String = "42", headRepo: String?? = .none, days: Double = 0, author: String = "dev"
  ) -> PullRequest {
    var m = PRMetadata(
      number: n, webURL: URL(string: "https://github.com/o/\(repo)/pull/\(n)")!,
      repositoryName: "o/\(repo)")
    m.headBranch = head
    m.baseBranch = base
    m.headRepositoryID = headRepo ?? repo
    m.authorLogin = author
    m.updatedAt = now.addingTimeInterval(-days * 86400)
    m.createdAt = m.updatedAt
    m.mergedAt = state == .merged ? m.updatedAt : nil
    m.additions = n % 700
    m.deletions = n % 13
    return PullRequest(
      key: .init(
        host: "github.com", accountID: account, repositoryID: repo,
        objectID: "pull-request:\(repo):\(n)"), headRevision: .init("sha\(n)"),
      title: "PR \(n % 97)", state: state, isDraft: false, metadata: m)
  }
  /// 5k history + open PRs into main, where every release is a PR from main into a long-lived deploy branch.
  func deployPattern(
    history: Int = 5000, open: Int = 200, deploys: Int = 300, backMerges: Int = 0, chains: Int = 0
  ) -> [PullRequest] {
    var rows: [PullRequest] = []
    var n = 0
    for i in 0..<deploys {
      n += 1
      rows.append(row(n, head: "main", base: "deploy", state: i == deploys - 1 ? .open : .merged, days: Double(i % 90)))
    }
    for i in 0..<backMerges {
      n += 1
      rows.append(row(n, head: "deploy", base: "main", state: .merged, days: Double(i % 90)))
    }
    for i in 0..<(history - deploys - backMerges) {
      n += 1
      rows.append(row(n, head: "feature/\(i)", base: "main", state: i % 10 == 0 ? .closed : .merged, days: Double(i % 90), author: "a\(i % 7)"))
    }
    for i in 0..<chains {
      for layer in 1...3 {
        n += 1
        rows.append(row(n, head: "stack/\(i)/\(layer)", base: layer == 1 ? "main" : "stack/\(i)/\(layer - 1)", days: Double(i % 9), author: "a\(i % 7)"))
      }
    }
    for i in 0..<open {
      n += 1
      rows.append(row(n, head: "open/\(i)", base: "main", days: Double(i % 20), author: "a\(i % 7)"))
    }
    return rows
  }
  /// Realistic 5k rows over 50 repositories: independent PRs plus a short stacked chain every 25 PRs.
  func realistic(_ count: Int = 5000) -> [PullRequest] {
    (1...count).map { n in
      row(
        n, head: n % 25 == 0 ? "stack/\(n)" : "feature/\(n)",
        base: n % 25 == 0 ? "feature/\(n - 1)" : "main", state: n % 3 == 0 ? .merged : n % 11 == 0 ? .closed : .open,
        repo: "R\((n - (n % 25 == 0 ? 1 : 0)) % 50)", days: Double(n % 60), author: "a\(n % 9)")
    }
  }
  func randomRows(seed: UInt64, count: Int) -> [PullRequest] {
    var rng = SplitMix64(state: seed)
    let branches = ["", "main", "a", "b", "c", "d", "e", "deploy"]
    return (1...count).map { n in
      let repo = ["R", "S"].randomElement(using: &rng)!
      let headRepo: String?? = .some([repo, repo, repo, "fork", nil].randomElement(using: &rng)!)
      let state = [PullRequest.State.open, .open, .merged, .closed].randomElement(using: &rng)!
      return row(
        n, head: branches.randomElement(using: &rng)!, base: branches.randomElement(using: &rng)!,
        state: state, repo: repo, account: ["42", "43"].randomElement(using: &rng)!, headRepo: headRepo,
        days: Double(Int.random(in: 0...60, using: &rng)), author: ["x", "y", "z"].randomElement(using: &rng)!)
    }
  }
  func withNativeStacks(_ source: [PullRequest], seed: UInt64) -> [PullRequest] {
    var rng = SplitMix64(state: seed)
    var rows = source
    for group in 0..<4 {
      let members = Array(rows.indices.shuffled(using: &rng).prefix(Int.random(in: 1...4, using: &rng)))
      let stack = StackGraph.native(
        id: "S\(group % 2)", number: group, size: members.count,
        entries: members.enumerated().map { .init(position: $0.offset + 1, pr: rows[$0.element]) },
        complete: Bool.random(using: &rng), linear: true)
      for i in members {
        var m = rows[i].metadata!
        m.nativeStack = stack
        m.mergeEvidence = MergeEvidence(
          key: rows[i].key, head: "h", base: "b", branch: "main",
          fetchedAt: now.addingTimeInterval(Double(Int.random(in: -3...0, using: &rng))))
        let revision = Bool.random(using: &rng) ? rows[i].headRevision : RevisionID("moved\(i)")
        rows[i] = PullRequest(
          key: rows[i].key, headRevision: revision, title: rows[i].title, state: rows[i].state,
          isDraft: rows[i].isDraft, metadata: m)
      }
    }
    return rows
  }
  func ms(_ start: ContinuousClock.Instant) -> Double {
    let c = start.duration(to: .now).components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
  }
  func fastest(_ runs: Int = 3, _ body: () -> Void) -> Double {
    (0..<runs).map { _ in
      let start = ContinuousClock.now
      body()
      return ms(start)
    }.min()!
  }

  // MARK: - Stack inference

  func testInferredMatchesLegacyOnRandomBranchGraphs() {
    for seed in UInt64(1)...300 {
      let rows = randomRows(seed: seed, count: Int(seed % 40) + 20)
      XCTAssertEqual(StackGraph.inferred(rows), legacyInferred(rows), "seed \(seed)")
    }
  }
  func testInferredMatchesLegacyOnScaledDeployPatterns() {
    for (backMerges, chains) in [(0, 0), (0, 4), (3, 0), (3, 4)] {
      let rows = deployPattern(history: 240, open: 20, deploys: 15, backMerges: backMerges, chains: chains)
      XCTAssertEqual(StackGraph.inferred(rows), legacyInferred(rows), "backMerges \(backMerges) chains \(chains)")
    }
  }
  /// A relative scaling check: 4x the rows costs well under 10x the time (near-linear; a quadratic pass would
  /// cost ~16x). The absolute cap needs MERGEPRO_PERF_TESTS=1.
  func testDeployPatternInfersNearLinearly() {
    let rows = deployPattern()
    var stacks: [PRStack] = []
    let elapsed = fastest { stacks = StackGraph.inferred(rows) }
    let quarter = deployPattern(history: 1250, open: 50, deploys: 75)
    let quarterElapsed = fastest { _ = StackGraph.inferred(quarter) }
    // Unchanged semantics: every PR into main hangs off the many main → deploy PRs as one ambiguous chain.
    XCTAssertEqual(stacks.count, 1)
    XCTAssertEqual(stacks.first?.layers.count, rows.count)
    XCTAssertEqual(stacks.first?.warnings, ["Branch chain is ambiguous.", "Stack contains a closed, unmerged layer."])
    XCTAssertEqual(stacks.first?.layers.prefix(300).allSatisfy { $0.metadata?.headBranch == "main" }, true)
    let cyclic = deployPattern(backMerges: 25, chains: 30)
    var cyclicStacks: [PRStack] = []
    let cyclicElapsed = fastest { cyclicStacks = StackGraph.inferred(cyclic) }
    XCTAssertEqual(cyclicStacks.first?.warnings.contains("Branch chain contains a cycle."), true)
    print("PERF inferred deploy pattern \(rows.count) rows: \(elapsed) ms (\(quarter.count) rows: \(quarterElapsed) ms); with back-merges and chains \(cyclic.count) rows: \(cyclicElapsed) ms")
    XCTAssertWithinPerformanceBudget(milliseconds: elapsed, 250)
    XCTAssertWithinPerformanceBudget(milliseconds: cyclicElapsed, 250)
    XCTAssertLessThan(elapsed, quarterElapsed * 10, "inference scales near-linearly")
  }
  func testStackProjectionMatchesPreviousWorkspaceRebuild() {
    for seed in UInt64(1)...120 {
      let rows = withNativeStacks(randomRows(seed: seed, count: 40), seed: seed &* 7)
      let projection = PRStackProjection(rows: rows)
      let legacy = legacyWorkspaceStacks(rows)
      XCTAssertEqual(projection.stacks, legacy.stacks, "seed \(seed)")
      for row in rows { XCTAssertEqual(projection.stack(for: row.key), legacy.membership[row.key], "seed \(seed)") }
    }
  }
  func testIndexedVisibleCardsMatchLegacyCollapse() {
    var collapsing = 0, ambiguous = 0
    for seed in UInt64(1)...150 {
      var rng = SplitMix64(state: seed &* 31)
      let rows = withNativeStacks(randomRows(seed: seed, count: 50), seed: seed)
      let projection = PRStackProjection(rows: rows)
      let visible = Array(rows.shuffled(using: &rng).prefix(Int.random(in: 0...50, using: &rng)))
      let expanded = Set(projection.stacks.map(\.id).filter { _ in Bool.random(using: &rng) })
      let legacy = legacyVisibleCards(visible, stacks: projection.stacks, expanded: expanded)
      XCTAssertEqual(StackGraph.visibleCards(visible, projection: projection, expanded: expanded), legacy, "seed \(seed)")
      XCTAssertEqual(StackGraph.visibleCards(visible, stacks: projection.stacks, expanded: expanded), legacy, "seed \(seed)")
      XCTAssertEqual(StackGraph.visibleCards(visible, projection: projection, separate: true), visible)
      collapsing += projection.stacks.filter { !$0.isAmbiguousChain }.count
      ambiguous += projection.stacks.filter(\.isAmbiguousChain).count
    }
    // The random graphs exercise both collapsing stacks and ambiguous inferred stacks.
    XCTAssertGreaterThan(collapsing, 0)
    XCTAssertGreaterThan(ambiguous, 0)
  }

  // MARK: - Projection

  func testDecoratedSortMatchesPreviousComparator() {
    let rows = randomRows(seed: 99, count: 400).filter { $0.state != .closed }
    for sort in PRViewConfiguration.Sort.allCases {
      for ascending in [false, true] {
        var view = PRViewConfiguration()
        view.timeScope = .allTime
        view.mergedDays = 36500
        view.sort = sort
        view.ascending = ascending
        XCTAssertEqual(
          BoardProjection(rows: rows, view: view, now: now).rows.map(\.key),
          legacySorted(rows, view: view).map(\.key), "\(sort) ascending \(ascending)")
      }
    }
  }
  func testFilterChangesNeverRebuildStacksAndLayoutMatchesPreviousBoard() throws {
    let rows = realistic()
    var pipeline = PRBoardPipeline()
    XCTAssertTrue(pipeline.update(rows: rows))
    XCTAssertEqual(pipeline.stackRevision, 1)
    let stacks = pipeline.stacks.stacks
    var timings: [String] = []
    for grouping in [PRViewConfiguration.Grouping.none, .author] {
      var view = PRViewConfiguration()
      view.timeScope = .last30Days
      view.grouping = grouping
      view.collapsedLanes = ["a3"]
      for query in ["", "PR 1", "repo:o/R7", "state:closed", "updated:>2026-12-20", "head:stack", "author:a2 \"PR\""] {
        view.filter = try FilterExpression.parse(query)
        var layout = PRBoardLayout()
        let elapsed = fastest(1) { layout = pipeline.layout(view: view, now: now) }
        timings.append(String(format: "%@ %.1f ms", query.isEmpty ? "(none)" : query, elapsed))
        let previous = BoardProjection(rows: legacyVisibleCards(layout.projection.rows, stacks: stacks), view: view, now: now)
        XCTAssertEqual(layout.projection.rows.map(\.key), BoardProjection(rows: rows, view: view, now: now).rows.map(\.key))
        XCTAssertEqual(layout.cards.rows.map(\.key), previous.rows.map(\.key), query)
        XCTAssertEqual(layout.navigationKeys, legacyNavigationKeys(previous, view: view), query)
        XCTAssertEqual(Set(layout.lanes.map(\.id)), Set(previous.lanes.keys), query)
      }
    }
    XCTAssertEqual(pipeline.stackRevision, 1, "filter and view changes reuse row-derived stacks")
    XCTAssertFalse(pipeline.update(rows: rows))
    XCTAssertEqual(pipeline.stackRevision, 1)
    XCTAssertTrue(pipeline.update(rows: Array(rows.dropLast())))
    XCTAssertEqual(pipeline.stackRevision, 2)
    print("PERF layout for 5k rows per filter change: \(timings.joined(separator: ", "))")
  }

  /// Poll-driven reloads re-project and recount every saved view on a detached task (the App publishes the result
  /// only if no newer projection started). The detached result must equal the synchronous one.
  func testPollReprojectionAndSavedViewCountsRunDetachedAndMatchSynchronousResults() async throws {
    var pipeline = PRBoardPipeline()
    pipeline.update(rows: realistic())
    let state = PRViewState()
    let view = state.views[0].configuration
    let views = state.views
    let now = self.now
    let captured = pipeline
    let start = ContinuousClock.now
    let (layout, counts) = await Task.detached(priority: .userInitiated) {
      (captured.layout(view: view, now: now), captured.counts(views: views, now: now))
    }.value
    let elapsed = start.duration(to: .now)
    XCTAssertEqual(layout.projection.rows.map(\.key), pipeline.layout(view: view, now: now).projection.rows.map(\.key))
    XCTAssertEqual(counts, pipeline.counts(views: views, now: now))
    XCTAssertEqual(counts.count, views.count)
    print("TASK10 detached reprojection + \(views.count) view counts for 5k rows: \(elapsed)")
    XCTAssertWithinPerformanceBudget(elapsed, .seconds(20), "Generous bound for debug builds; the point is that it leaves the main actor")
  }

  // MARK: - Card lookups

  func testCardLookupsAreIndexed() {
    let account = Account(scope: AccountScope(host: "github.com", accountID: "42"), login: "me")
    let repositories = (0..<50).map {
      Repository(
        key: RepositoryKey(account: account.scope, repositoryID: "R\($0)"), name: "o/R\($0)", isPrivate: false,
        capabilities: ProviderCapabilities())
    }
    let rows = realistic()
    let statuses = Dictionary(
      uniqueKeysWithValues: repositories.enumerated().map {
        ($0.element.key, PRInventoryStatus(complete: $0.offset % 5 != 0, fetchedCount: 1, fetchedAt: now.addingTimeInterval($0.offset % 7 == 0 ? -900 : 0), message: nil))
      })
    let cache = PRWorkspaceSnapshot(
      snapshots: [
        LocalSnapshot(
          account: account, repositories: repositories, trackedRepositories: Set(repositories.map(\.key).dropLast()),
          pins: [], settings: [:], pullRequests: rows, drafts: [])
      ], inventory: statuses)
    let freshness = cache.freshnessByRepository(now: now)
    XCTAssertEqual(freshness, Dictionary(uniqueKeysWithValues: cache.freshness(account: nil, now: now).map { ($0.repository, $0) }))
    for pr in rows.enumerated().filter({ $0.offset % 97 == 0 }).map(\.element) {
      XCTAssertEqual(cache.cached(pr.key), cache.rows.first { $0.key == pr.key })
      XCTAssertEqual(cache.rows(in: pr.key.repository), cache.rows.filter { $0.key.repository == pr.key.repository })
      XCTAssertEqual(
        cache.freshness(for: pr.key.repository, now: now),
        cache.freshness(account: pr.key.account, now: now).first { $0.repository == pr.key.repository })
    }
    XCTAssertNil(cache.freshness(for: repositories.last!.key, now: now), "untracked repositories have no freshness")
    let stacks = PRStackProjection(rows: rows)
    var hits = 0
    let elapsed = fastest {
      for pr in rows {
        if cache.cached(pr.key) != nil { hits += 1 }
        if freshness[pr.key.repository] != nil { hits += 1 }
        if stacks.stack(for: pr.key) != nil { hits += 1 }
      }
    }
    // The same card lookups by scanning rows, on a sample (a full scan per card is quadratic).
    let sample = Array(rows.prefix(60))
    let indexed = fastest { for pr in sample.reversed() { _ = cache.cached(pr.key) } }
    let scanned = fastest { for pr in sample.reversed() { _ = cache.rows.last { $0.key == pr.key } } }
    print("PERF card lookups (cached + freshness + stack) for \(rows.count) cards: \(elapsed) ms; \(sample.count) cards indexed \(indexed) ms vs scanned \(scanned) ms")
    XCTAssertGreaterThan(hits, 0)
    XCTAssertWithinPerformanceBudget(milliseconds: elapsed, 250, "per-card lookups must not scan rows or rebuild freshness")
    XCTAssertLessThan(indexed * 10, scanned, "indexed lookups are at least 10x faster than scanning")
  }
}

// MARK: - Legacy oracles (the pre-optimization implementations, verbatim in behavior)

extension BoardPerformanceTests {
  func legacyInferred(_ rows: [PullRequest]) -> [PRStack] {
    var result: [PRStack] = []
    for (_, prs) in Dictionary(grouping: rows, by: { $0.key.repository }) {
      let usable = prs.filter { !($0.metadata?.headBranch ?? "").isEmpty && !($0.metadata?.baseBranch ?? "").isEmpty }
      let byHead = Dictionary(grouping: usable, by: { $0.metadata!.headBranch })
      var neighbors: [ProviderKey: Set<ProviderKey>] = [:], parents: [ProviderKey: [PullRequest]] = [:]
      for pr in usable {
        let candidates = (byHead[pr.metadata!.baseBranch] ?? []).filter { parent in
          parent.key != pr.key && (parent.metadata?.headRepositoryID.map { $0 == parent.key.repositoryID } ?? true)
        }
        parents[pr.key] = candidates
        for parent in candidates {
          neighbors[pr.key, default: []].insert(parent.key)
          neighbors[parent.key, default: []].insert(pr.key)
        }
      }
      var seen: Set<ProviderKey> = []
      for seed in usable where !seen.contains(seed.key) && neighbors[seed.key] != nil {
        var component: Set<ProviderKey> = [], todo = [seed.key]
        while let key = todo.popLast() { if component.insert(key).inserted { todo += Array(neighbors[key] ?? []) } }
        seen.formUnion(component)
        var remaining = usable.filter { component.contains($0.key) }, ordered: [PullRequest] = [], warnings: [String] = []
        if remaining.contains(where: { item in
          (parents[item.key]?.count ?? 0) > 1
            || usable.filter { child in (parents[child.key] ?? []).contains { $0.key == item.key } }.count > 1
        }) { warnings.append("Branch chain is ambiguous.") }
        while !remaining.isEmpty {
          let ready = remaining.filter { item in
            !(parents[item.key] ?? []).contains { parent in remaining.contains { $0.key == parent.key } }
          }.sorted { $0.key.objectID < $1.key.objectID }
          guard !ready.isEmpty else {
            warnings.append("Branch chain contains a cycle.")
            ordered += remaining.sorted { $0.key.objectID < $1.key.objectID }
            break
          }
          ordered += ready
          let keys = Set(ready.map(\.key))
          remaining.removeAll { keys.contains($0.key) }
        }
        if ordered.contains(where: { $0.metadata?.headRepositoryID != $0.key.repositoryID }) { warnings.append("Same-repository head-branch identity is unverified or belongs to a fork.") }
        if ordered.contains(where: { $0.state == .closed }) { warnings.append("Stack contains a closed, unmerged layer.") }
        result.append(.init(id: "inferred:" + (ordered.first?.key.objectID ?? ""), kind: .inferred, number: nil, layers: ordered, warnings: warnings))
      }
    }
    return result.sorted { $0.id < $1.id }
  }
  /// The workspace model's previous `rebuildStackProjection` (membership: last stack listing a layer wins).
  func legacyWorkspaceStacks(_ rows: [PullRequest]) -> (stacks: [PRStack], membership: [ProviderKey: PRStack]) {
    var native: [PRStack] = []
    for row in rows.sorted(by: { ($0.metadata?.mergeEvidence?.fetchedAt ?? .distantPast) > ($1.metadata?.mergeEvidence?.fetchedAt ?? .distantPast) }) {
      if let stack = row.metadata?.nativeStack, !native.contains(where: { $0.id == stack.id && $0.layers.first?.key.repository == stack.layers.first?.key.repository }) {
        native.append(stack.observed(in: rows))
      }
    }
    let keys = Set(native.flatMap { $0.layers.map(\.key) })
    let stacks = native + legacyInferred(rows.filter { !keys.contains($0.key) })
    var membership: [ProviderKey: PRStack] = [:]
    for stack in stacks { for layer in stack.layers { membership[layer.key] = stack } }
    return (stacks, membership)
  }
  /// The previous collapse, except that an ambiguous inferred stack (e.g. the deploy pattern) no longer collapses:
  /// its PRs stay separate cards (StackAmbiguityTests). Every other stack must collapse exactly as before.
  func legacyVisibleCards(_ visible: [PullRequest], stacks: [PRStack], expanded: Set<String> = []) -> [PullRequest] {
    let visibleKeys = Set(visible.map(\.key))
    var result: [PullRequest] = [], seen: Set<ProviderKey> = []
    for pr in visible {
      if let stack = stacks.first(where: { $0.layers.contains(where: { $0.key == pr.key }) }), !expanded.contains(stack.id),
        !(stack.kind == .inferred && stack.warnings.contains("Branch chain is ambiguous.")),
        let representative = stack.layers.first(where: { visibleKeys.contains($0.key) && $0.state != .merged }) ?? stack.layers.last(where: { visibleKeys.contains($0.key) })
      {
        if seen.insert(representative.key).inserted { result.append(representative) }
      } else if seen.insert(pr.key).inserted { result.append(pr) }
    }
    return result
  }
  func legacyNavigationKeys(_ board: BoardProjection, view: PRViewConfiguration) -> [ProviderKey] {
    board.lanes.keys.sorted().filter { view.grouping == .none || !view.collapsedLanes.contains($0) }.flatMap { lane in
      let rows = board.lanes[lane] ?? []
      return PRColumn.allCases.flatMap { column in
        rows.filter { $0.state != .closed && BoardProjection.column(for: $0, showDrafts: view.showDrafts) == column }
      } + rows.filter { $0.state == .closed }
    }.map(\.key)
  }
  func legacySorted(_ rows: [PullRequest], view: PRViewConfiguration) -> [PullRequest] {
    func value(_ row: PullRequest) -> String {
      let m = row.metadata
      switch view.sort {
      case .repository: return m?.repositoryName.lowercased() ?? ""
      case .title: return row.title.lowercased()
      case .author: return m?.authorLogin ?? ""
      case .checks: return m?.checks ?? ""
      case .review: return m?.reviewDecision ?? ""
      case .labels: return m?.labels.joined(separator: ",") ?? ""
      default: return ""
      }
    }
    func number(_ row: PullRequest) -> Double {
      let m = row.metadata
      switch view.sort {
      case .updated: return m?.updatedAt?.timeIntervalSince1970 ?? 0
      case .created, .age: return m?.createdAt?.timeIntervalSince1970 ?? 0
      case .timeInColumn: return m?.columnChangedAt?.timeIntervalSince1970 ?? 0
      case .size: return Double(m?.size ?? -1)
      case .number: return Double(m?.number ?? 0)
      default: return 0
      }
    }
    let numeric: Set<PRViewConfiguration.Sort> = [.updated, .created, .age, .timeInColumn, .size, .number]
    return rows.sorted { a, b in
      if numeric.contains(view.sort), number(a) != number(b) { return view.ascending ? number(a) < number(b) : number(a) > number(b) }
      if !numeric.contains(view.sort), value(a) != value(b) { return view.ascending ? value(a) < value(b) : value(a) > value(b) }
      if let m = a.metadata?.number, let n = b.metadata?.number, m != n { return m > n }
      return [a.key.host, a.key.accountID, a.key.repositoryID, a.key.objectID].lexicographicallyPrecedes([b.key.host, b.key.accountID, b.key.repositoryID, b.key.objectID])
    }
  }
}
