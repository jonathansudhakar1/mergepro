import XCTest

@testable import MergeProCore

final class PRPaletteSearchTests: XCTestCase {
  func testAuthorSearchReturnsPRsAndCommandsNarrowAccountsSettingsAndUnknownQueries() {
    var metadata = PRMetadata(
      number: 4, webURL: URL(string: "https://github.com/o/r/pull/4")!, repositoryName: "o/r")
    metadata.authorLogin = "alice-reviewer"
    metadata.headBranch = "unrelated"
    let pr = PullRequest(
      key: ProviderKey(host: "github.com", accountID: "a", repositoryID: "r", objectID: "pr"),
      headRevision: RevisionID("sha"), title: "Refresh cache", state: .open, isDraft: false,
      metadata: metadata)
    XCTAssertEqual(
      PRPaletteSearch.pullRequests(query: "alice-reviewer", rows: [pr], state: PRViewState()).map(
        \.key), [pr.key])
    XCTAssertEqual(PRPaletteSearch.commands(query: ">setup").map(\.destination), [.accounts])
    XCTAssertEqual(PRPaletteSearch.commands(query: "Accounts").map(\.destination), [.accounts])
    XCTAssertEqual(PRPaletteSearch.commands(query: "Settings").map(\.destination), [.settings])
    XCTAssertTrue(PRPaletteSearch.commands(query: ">nonsense").isEmpty)
  }
}

extension PRPaletteSearchTests {
  func testContiguousMatchAfterEarlyScatteredLettersStillRanksAsCompact() throws {
    // Greedy leftmost matching scored "Clear stale cache entries" via c-a-c from "Clear", missing the contiguous "cache".
    let contiguous = try XCTUnwrap(PRPaletteSearch.score("cache", "Clear stale cache entries"))
    let scattered = try XCTUnwrap(PRPaletteSearch.score("cache", "Change a checking engine"))
    XCTAssertGreaterThan(contiguous, scattered)
    XCTAssertEqual(PRPaletteSearch.score("ab", "a_ab"), 1000 - Double(2 * 2 + 4 - 2))
  }
}

/// Palette index: lowercase fields are precomputed once, history comes from one dictionary, only the top
/// results are kept, and a cancelled search stops. The legacy per-keystroke algorithm is the oracle.
extension PRPaletteSearchTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private func row(_ n: Int, title: String, branch: String = "", author: String = "dev", account: String = "a") -> PullRequest {
    var metadata = PRMetadata(number: n, webURL: URL(string: "https://github.com/o/r/pull/\(n)")!, repositoryName: "o/r")
    metadata.headBranch = branch
    metadata.authorLogin = author
    return PullRequest(
      key: ProviderKey(host: "github.com", accountID: account, repositoryID: "r", objectID: "pr-\(n)"),
      headRevision: RevisionID("sha\(n)"), title: title, state: .open, isDraft: false, metadata: metadata)
  }
  private func corpus(_ count: Int) -> [PullRequest] {
    let words = ["cache", "refresh", "Fix", "ünïcode", "label", "merge", "queue", "deploy", "README", "flaky", "test", "Ω"]
    return (0..<count).map { n in
      row(n + 1, title: "\(words[n % words.count]) \(words[(n / 3) % words.count]) step \(n % 17)",
        branch: "feature/\(words[(n / 7) % words.count].lowercased())-\(n)", author: "author\(n % 23)",
        account: n % 5 == 0 ? "b" : "a")
    }
  }
  private func history(_ rows: [PullRequest], visits: Int) -> PRViewState {
    var state = PRViewState()
    state.navigationHistory = (0..<visits).map { i in
      PRNavigationVisit(key: rows[(i * 7) % rows.count].key, opens: 1 + i % 9,
        lastOpenedAt: Self.now.addingTimeInterval(-Double(i % 40) * 86400))
    }
    return state
  }
  /// The previous algorithm: every field lowercased per row per keystroke and a linear history scan per row.
  private func legacy(_ query: String, _ rows: [PullRequest], _ state: PRViewState) -> [ProviderKey] {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !["repo:", ">", "/", "@", "https:"].contains(where: text.hasPrefix) else { return [] }
    let numberOnly = text.hasPrefix("#")
    let input = numberOnly ? String(text.dropFirst()) : text
    return rows.compactMap { pr -> (PullRequest, Double)? in
      let fields = numberOnly ? [String(pr.metadata?.number ?? 0)]
        : [pr.title, String(pr.metadata?.number ?? 0), pr.metadata?.headBranch ?? "", pr.metadata?.authorLogin ?? ""]
      guard let match = fields.compactMap({ PRPaletteSearch.score(input, $0) }).max() else { return nil }
      return (pr, match + state.navigationScore(pr.key, at: Self.now) * 10)
    }.sorted { $0.1 == $1.1 ? $0.0.key.objectID < $1.0.key.objectID : $0.1 > $1.1 }.map(\.0.key)
  }

  func testIndexReturnsTheLegacyRankingCappedAtFifty() {
    let rows = corpus(600)
    let state = history(rows, visits: 300)
    let index = PRPaletteIndex(rows: rows, state: state, at: Self.now)
    for query in ["", "cache", "CACHE ref", "#12", "#", "feature/merge", "author7", "ünï", "Ω", "zzzz", "repo:x", ">set", "  label  "] {
      let expected = Array(legacy(query, rows, state).prefix(50))
      XCTAssertEqual(index.search(query).map(\.key), expected, "query \(query)")
      XCTAssertLessThanOrEqual(index.search(query).count, 50)
    }
    XCTAssertEqual(index.search("cache", limit: 3).map(\.key), Array(legacy("cache", rows, state).prefix(3)))
    XCTAssertEqual(PRPaletteSearch.pullRequests(query: "cache", rows: rows, state: state).count, legacy("cache", rows, state).count)
  }

  func testHistoryDictionaryMatchesNavigationScore() {
    let rows = corpus(50)
    let state = history(rows, visits: 120)
    let scores = PRPaletteIndex.historyScores(state.navigationHistory, at: Self.now)
    for pr in rows {
      XCTAssertEqual(scores[pr.key] ?? 0, state.navigationScore(pr.key, at: Self.now), accuracy: 1e-12)
    }
  }

  func testCancelledSearchReturnsNothing() {
    let index = PRPaletteIndex(rows: corpus(2000), state: PRViewState(), at: Self.now)
    XCTAssertTrue(index.search("cache", isCancelled: { true }).isEmpty)
    XCTAssertFalse(index.search("cache", isCancelled: { false }).isEmpty)
  }

  func testPaletteNeverListsUnavailableApproveOrMergePlaceholders() {
    let titles = PRPaletteSearch.commands(query: "").map(\.title)
    XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("approve") || $0.localizedCaseInsensitiveContains("merge") })
    XCTAssertTrue(PRPaletteSearch.commands(query: ">approve").isEmpty)
    // PR actions come only from what the focused pull request offers.
    XCTAssertEqual(PRPaletteSearch.prActions(query: "", available: []), [])
    XCTAssertEqual(PRPaletteSearch.prActions(query: "appr", available: [.approve, .merge, .labels]), [.approve])
    XCTAssertEqual(PRPaletteSearch.prActions(query: ">merge", available: [.approve, .merge]), [.merge])
    XCTAssertEqual(PRPaletteSearch.prActions(query: "", available: [.labels, .approve]), [.approve, .labels])
    XCTAssertEqual(PRPaletteSearch.prActions(query: "#12", available: [.approve]), [])
  }

  func testHighlightMovesWithinEnabledRowsAndClamps() {
    let enabled = [true, false, true, true]
    XCTAssertEqual(PRPaletteSearch.moveHighlight(nil, by: 1, enabled: enabled), 0)
    XCTAssertEqual(PRPaletteSearch.moveHighlight(0, by: 1, enabled: enabled), 2)
    XCTAssertEqual(PRPaletteSearch.moveHighlight(2, by: -1, enabled: enabled), 0)
    XCTAssertEqual(PRPaletteSearch.moveHighlight(3, by: 1, enabled: enabled), 3)
    XCTAssertEqual(PRPaletteSearch.moveHighlight(0, by: -1, enabled: enabled), 0)
    XCTAssertNil(PRPaletteSearch.moveHighlight(nil, by: 1, enabled: [false, false]))
    XCTAssertEqual(PRPaletteSearch.moveHighlight(9, by: 0, enabled: enabled), 3, "a stale index clamps to the last enabled row")
  }

  func testPaletteSearchPerformance() {
    let rows = corpus(5000)
    let state = history(rows, visits: 1000)
    func ms(_ body: () -> Void) -> Double {
      var best = Double.infinity
      for _ in 0..<3 {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        best = min(best, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
      }
      return best
    }
    var index: PRPaletteIndex?
    let build = ms { index = PRPaletteIndex(rows: rows, state: state, at: Self.now) }
    guard let index else { return XCTFail("index") }
    let queries = ["c", "ca", "cac", "cache", "cache r", "#4", "feature/fl", "author1"]
    let search = ms { for query in queries { _ = index.search(query) } }
    let legacyTime = ms { for query in queries.prefix(2) { _ = legacy(query, rows, state) } }
    print("PERF palette 5000 rows/1000 visits: index \(build) ms; \(queries.count) queries \(search) ms; legacy 2 queries \(legacyTime) ms")
    XCTAssertWithinPerformanceBudget(milliseconds: search / Double(queries.count), 40, "one keystroke stays well under a frame budget off the main thread")
    XCTAssertLessThan(search / Double(queries.count) * 4, legacyTime / 2, "indexed search is at least 4x faster than the legacy scan")
  }
}
