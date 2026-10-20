import Foundation

public enum PRPaletteSearch {
  /// Case-insensitive subsequence matching; compact/contiguous matches rank first.
  public static func score(_ query: String, _ text: String) -> Double? {
    score(needle: folded(query), haystack: folded(text))
  }
  /// Lowercased Unicode scalar values: compared as integers, so scoring a precomputed field allocates nothing.
  static func folded(_ text: String) -> [UInt32] { text.lowercased().unicodeScalars.map(\.value) }
  static func score(needle: [UInt32], haystack: [UInt32]) -> Double? {
    guard !needle.isEmpty else { return 0 }
    guard needle.count <= haystack.count else { return nil }
    return needle.withUnsafeBufferPointer { n in haystack.withUnsafeBufferPointer { h in score(n, h) } }
  }
  private static func score(_ needle: UnsafeBufferPointer<UInt32>, _ haystack: UnsafeBufferPointer<UInt32>) -> Double? {
    let head = needle[0], count = haystack.count
    // Greedy from each candidate start: a later contiguous run must not lose to an early scattered prefix.
    var best = Int.max
    var first = 0
    while first < count {
      if haystack[first] == head {
        // Gaps only add to a start's cost, so no later start can beat the best found so far.
        if first * 2 >= best { break }
        var prior = first
        var gaps = 0
        var index = 1
        while index < needle.count {
          let char = needle[index]
          var match = prior + 1
          while match < count && haystack[match] != char { match += 1 }
          if match == count { break }
          gaps += match - prior - 1
          prior = match
          index += 1
        }
        // A start that cannot complete means no later start can either.
        if index < needle.count { break }
        best = min(best, first * 2 + gaps * 4)
      }
      first += 1
    }
    return best == .max ? nil : 1000 - Double(best + count - needle.count)
  }
  /// One bit per scalar (mod 64): a field can contain the needle only if it has every needle bit.
  static func mask(_ scalars: [UInt32]) -> UInt64 { scalars.reduce(0) { $0 | 1 << UInt64($1 & 63) } }

  public enum Destination: String, Sendable {
    case board, list, activity, actions, repos, accounts, settings
  }
  public struct Entry: Identifiable, Sendable {
    public var destination: Destination
    public var title: String
    public var id: Destination { destination }
  }
  /// Prefixes that address something other than commands and pull request actions.
  private static let scopedPrefixes = ["repo:", "#", "@", "/", "https:"]
  public static func commands(query: String) -> [Entry] {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !scopedPrefixes.contains(where: text.hasPrefix) else { return [] }
    let input =
      text.hasPrefix(">") ? String(text.dropFirst()).trimmingCharacters(in: .whitespaces) : text
    let entries: [(Destination, String, String)] = [
      (.board, "Pull Requests: Board", "board"), (.list, "Pull Requests: List", "list"),
      (.activity, "Activity inbox", "activity inbox"),
      (.actions, "Actions", "actions workflows runs"),
      (.repos, "Repositories", "repositories browse files"),
      (.accounts, "Setup / Accounts", "setup accounts"),
      (.settings, "Settings", "settings preferences"),
    ]
    return entries.filter { input.isEmpty || score(input, $0.2) != nil }.map {
      Entry(destination: $0.0, title: $0.1)
    }
  }

  /// Commands on the focused pull request. The palette lists only those the focused PR currently offers
  /// (`available`), so nothing is shown as a permanently disabled placeholder.
  public enum PRAction: String, CaseIterable, Sendable {
    case open, approve, requestChanges, comment, merge, labels, copyLink, openOnWeb, refresh
    var keywords: String {
      switch self {
      case .open: "open pull request"
      case .approve: "approve review"
      case .requestChanges: "request changes review"
      case .comment: "comment review"
      case .merge: "merge"
      case .labels: "labels tags"
      case .copyLink: "copy link url"
      case .openOnWeb: "open on github web browser"
      case .refresh: "refresh reload pull request"
      }
    }
  }
  public static func prActions(query: String, available: Set<PRAction>) -> [PRAction] {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !available.isEmpty, !scopedPrefixes.contains(where: text.hasPrefix) else { return [] }
    let input = text.hasPrefix(">") ? String(text.dropFirst()).trimmingCharacters(in: .whitespaces) : text
    return PRAction.allCases.filter { available.contains($0) && (input.isEmpty || score(input, $0.keywords) != nil) }
  }

  /// Arrow-key highlight over palette rows: moves to the next enabled row in `delta`'s direction and stays put
  /// at either end; `delta == 0` re-validates a highlight after the rows changed. Nil when no row is enabled.
  public static func moveHighlight(_ current: Int?, by delta: Int, enabled: [Bool]) -> Int? {
    let candidates = enabled.indices.filter { enabled[$0] }
    guard let first = candidates.first, let last = candidates.last else { return nil }
    guard let current else { return delta < 0 ? last : first }
    if delta > 0 { return candidates.first { $0 > current } ?? (enabled.indices.contains(current) && enabled[current] ? current : last) }
    if delta < 0 { return candidates.last { $0 < current } ?? (enabled.indices.contains(current) && enabled[current] ? current : first) }
    if current > last { return last }
    return candidates.first { $0 >= current } ?? last
  }

  public static func pullRequests(query: String, rows: [PullRequest], state: PRViewState)
    -> [PullRequest]
  {
    PRPaletteIndex(rows: rows, state: state).search(query, limit: .max)
  }
}

/// Search fields lowercased once per row set, plus each row's history score from a single pass over the
/// navigation history, so a keystroke only matches. Immutable and Sendable: search runs off the main actor.
public struct PRPaletteIndex: Sendable {
  struct Field: Sendable {
    let scalars: [UInt32]
    let mask: UInt64
    init(_ text: String) { scalars = PRPaletteSearch.folded(text); mask = PRPaletteSearch.mask(scalars) }
    func score(_ needle: [UInt32], mask needleMask: UInt64) -> Double? {
      mask & needleMask == needleMask ? PRPaletteSearch.score(needle: needle, haystack: scalars) : nil
    }
  }
  struct Row: Sendable {
    let pr: PullRequest
    let title: Field
    let number: Field
    let branch: Field
    let author: Field
    /// Union of the four masks: most rows are rejected here without scoring a field.
    let mask: UInt64
    let history: Double
  }
  let rows: [Row]
  public var count: Int { rows.count }

  public init(rows: [PullRequest], state: PRViewState, at date: Date = Date()) {
    self.init(rows: rows, history: state.navigationHistory, at: date)
  }
  public init(rows: [PullRequest], history: [PRNavigationVisit]?, at date: Date = Date()) {
    let scores = Self.historyScores(history, at: date)
    self.rows = rows.map { pr in
      let title = Field(pr.title), number = Field(String(pr.metadata?.number ?? 0))
      let branch = Field(pr.metadata?.headBranch ?? ""), author = Field(pr.metadata?.authorLogin ?? "")
      return Row(
        pr: pr, title: title, number: number, branch: branch, author: author,
        mask: title.mask | number.mask | branch.mask | author.mask, history: scores[pr.key] ?? 0)
    }
  }

  /// `PRViewState.navigationScore` for every visited key at once (the first visit of a key wins, as there).
  static func historyScores(_ history: [PRNavigationVisit]?, at date: Date) -> [ProviderKey: Double] {
    var scores: [ProviderKey: Double] = [:]
    for visit in history ?? [] where scores[visit.key] == nil {
      let ageDays = max(0, date.timeIntervalSince(visit.lastOpenedAt) / 86400)
      scores[visit.key] = log2(Double(visit.opens) + 1) / (1 + ageDays)
    }
    return scores
  }

  /// Best matches first (ties by object ID, then the rest of the key), at most `limit`. Returns nothing once
  /// `isCancelled` reports true; it is checked every 256 rows.
  public func search(_ query: String, limit: Int = 50, isCancelled: () -> Bool = { false }) -> [PullRequest] {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard limit > 0, !["repo:", ">", "/", "@", "https:"].contains(where: text.hasPrefix) else { return [] }
    let numberOnly = text.hasPrefix("#")
    let needle = PRPaletteSearch.folded(numberOnly ? String(text.dropFirst()) : text)
    let needleMask = PRPaletteSearch.mask(needle)
    // Kept sorted best-first; a candidate is inserted by binary search only when it beats the current last.
    var top: [(score: Double, index: Int)] = []
    if limit < rows.count { top.reserveCapacity(limit + 1) }
    for (index, row) in rows.enumerated() {
      if index & 255 == 0, isCancelled() { return [] }
      if row.mask & needleMask != needleMask { continue }
      var best = row.number.score(needle, mask: needleMask)
      if !numberOnly {
        // Unrolled rather than iterating a temporary array, which would allocate per row.
        if let value = row.title.score(needle, mask: needleMask), value > (best ?? -.infinity) { best = value }
        if let value = row.branch.score(needle, mask: needleMask), value > (best ?? -.infinity) { best = value }
        if let value = row.author.score(needle, mask: needleMask), value > (best ?? -.infinity) { best = value }
      }
      guard let best else { continue }
      let candidate = (score: best + row.history * 10, index: index)
      if top.count == limit, let last = top.last, !precedes(candidate, last) { continue }
      var low = 0, high = top.count
      while low < high {
        let mid = (low + high) / 2
        if precedes(top[mid], candidate) { low = mid + 1 } else { high = mid }
      }
      top.insert(candidate, at: low)
      if top.count > limit { top.removeLast() }
    }
    return isCancelled() ? [] : top.map { rows[$0.index].pr }
  }

  private func precedes(_ a: (score: Double, index: Int), _ b: (score: Double, index: Int)) -> Bool {
    if a.score != b.score { return a.score > b.score }
    let x = rows[a.index].pr.key, y = rows[b.index].pr.key
    if x.objectID != y.objectID { return x.objectID < y.objectID }
    return [x.host, x.accountID, x.repositoryID].lexicographicallyPrecedes([y.host, y.accountID, y.repositoryID])
      || (x == y && a.index < b.index)
  }
}
