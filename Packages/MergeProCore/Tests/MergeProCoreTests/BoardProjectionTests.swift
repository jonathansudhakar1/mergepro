import XCTest

@testable import MergeProCore

final class BoardProjectionTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  func pr(
    _ id: String, state: PullRequest.State = .open, draft: Bool = false, decision: String? = nil,
    days: Double = 0, account: String = "1", needs: PRReviewRequest.Kind? = nil
  ) -> PullRequest {
    let key = ProviderKey(
      host: "github.com", accountID: account, repositoryID: "r", objectID: "pull-request:" + id)
    var metadata = PRMetadata(
      number: Int(id) ?? 1, webURL: URL(string: "https://github.com/o/r/pull/\(id)")!,
      repositoryName: "o/r")
    metadata.updatedAt = now.addingTimeInterval(-days * 86400)
    metadata.createdAt = metadata.updatedAt
    metadata.mergedAt = state == .merged ? metadata.updatedAt : nil
    metadata.reviewDecision = decision
    metadata.requests =
      needs.map { [PRReviewRequest(id: "request", name: "Reviewer", kind: $0, isForViewer: true)] }
      ?? []
    return PullRequest(
      key: key, headRevision: RevisionID("sha"), title: "PR \(id)", state: state, isDraft: draft,
      metadata: metadata)
  }
  func testProviderDecisionAndDraftDeriveColumnsWithoutGuessingApprovalCounts() {
    let rows = [
      pr("1", draft: true, decision: "APPROVED"), pr("2", decision: "APPROVED"),
      pr("3", decision: "REVIEW_REQUIRED"), pr("4"),
    ]
    let board = BoardProjection(rows: rows, view: PRViewConfiguration(), now: now)
    XCTAssertEqual(board.columns[.open]?.count, 3)
    XCTAssertEqual(board.columns[.approved]?.map(\.key), [rows[1].key])
    var view = PRViewConfiguration()
    view.showDrafts = true
    XCTAssertEqual(
      BoardProjection(rows: rows, view: view, now: now).columns[.draft]?.map(\.key), [rows[0].key])
  }
  func testMergedWindowClosedFilterAndOlderCounts() throws {
    let rows = [
      pr("1", state: .merged, days: 6), pr("2", state: .merged, days: 8), pr("3", state: .closed),
    ]
    var view = PRViewConfiguration()
    view.timeScope = .allTime
    let board = BoardProjection(rows: rows, view: view, now: now)
    XCTAssertEqual(board.columns[.merged]?.count, 1)
    XCTAssertEqual(board.olderHidden[.merged], 1)
    view.filter = try FilterExpression.parse("state:closed")
    XCTAssertEqual(BoardProjection(rows: rows, view: view, now: now).rows.map(\.key), [rows[2].key])
    XCTAssertTrue(
      BoardProjection(rows: rows, view: view, now: now).columns.values.allSatisfy(\.isEmpty))
  }
  func testClosedRowsOutsideTimeScopeAreNotCountedInAColumn() throws {
    var view = PRViewConfiguration()
    view.timeScope = .last7Days
    view.filter = try FilterExpression.parse("state:closed")
    let rows = [pr("1", state: .closed, days: 30), pr("2", state: .closed, days: 1), pr("3", days: 30)]
    let board = BoardProjection(rows: rows, view: view, now: now)
    XCTAssertEqual(board.rows.map(\.key), [rows[1].key])
    XCTAssertNil(board.olderHidden[.open], "a closed PR can never appear in the Open column")
    XCTAssertEqual(board.closedHidden, 1)
    XCTAssertEqual(board.hiddenCount, 1)
    view.filter = FilterExpression()
    let open = BoardProjection(rows: rows, view: view, now: now)
    XCTAssertEqual(open.olderHidden[.open], 1)
    XCTAssertEqual(open.closedHidden, 0, "closed rows are excluded entirely without state:closed")
  }
  func testStrictAgeAndExplicitWaitingOnMeException() {
    let row = pr("1", days: 40, needs: .team)
    var view = PRViewConfiguration()
    view.timeScope = .last7Days
    XCTAssertTrue(BoardProjection(rows: [row], view: view, now: now).rows.isEmpty)
    view.keepWaitingOnMe = true
    XCTAssertEqual(BoardProjection(rows: [row], view: view, now: now).rows, [row])
  }
  func testAccountScopedDuplicatesAndSelectionSurviveRefresh() {
    let a = pr("1")
    let b = pr("1", account: "2")
    XCTAssertEqual(
      BoardProjection(rows: [a, b], view: PRViewConfiguration(), now: now).rows.count, 2)
    var selection = PRSelection(focused: a.key, selected: [a.key, b.key])
    selection.preserve(in: [b, a])
    XCTAssertEqual(selection.focused, a.key)
    XCTAssertEqual(selection.selected, [a.key, b.key])
  }
  func testDeterministicTokensTextOperatorsAndUnknownServiceFields() throws {
    let row = pr("1", needs: .direct)
    XCTAssertTrue(
      try FilterExpression.parse("repo:o/r request:direct \"PR 1\"").matches(row, now: now))
    XCTAssertFalse(try FilterExpression.parse("risk:high").matches(row, now: now))
    XCTAssertThrowsError(try FilterExpression.parse("nonsense:value"))
    XCTAssertFalse(try FilterExpression.parse("state:closed").matches(row, now: now))
  }
  func testHeadPrefixAndAgeNegationAndNoRequiredReviewFallback() throws {
    let original = pr("1", days: 8)
    var m = original.metadata!
    m.headBranch = "fix/feature"
    m.requiredReviewCount = 0
    m.approvalCount = 1
    m.outstandingChanges = false
    var row = PullRequest(
      key: original.key, headRevision: original.headRevision, title: original.title, state: .open,
      isDraft: false, metadata: m)
    XCTAssertFalse(try FilterExpression.parse("head:feature").matches(row, now: now))
    XCTAssertTrue(try FilterExpression.parse("age:!7d").matches(row, now: now))
    XCTAssertEqual(BoardProjection.column(for: row, showDrafts: false), .open)
    m.reviewEvidenceComplete = true
    row = PullRequest(
      key: row.key, headRevision: row.headRevision, title: row.title, state: .open, isDraft: false,
      metadata: m)
    XCTAssertEqual(BoardProjection.column(for: row, showDrafts: false), .approved)
    m.outstandingChanges = true
    row = PullRequest(
      key: row.key, headRevision: row.headRevision, title: row.title, state: .open, isDraft: false,
      metadata: m)
    XCTAssertEqual(BoardProjection.column(for: row, showDrafts: false), .open)
  }
  func testBackwardCompatibleDecodeAndNormalizedSQLiteReopen() throws {
    let url = try makeTemporaryDirectory().appendingPathComponent("db.sqlite")
    let original = pr("1", needs: .team)
    var metadata = original.metadata!
    metadata.authorID = "actor"
    metadata.authorLogin = "author"
    metadata.actorType = "Bot"
    metadata.viewerID = "viewer"
    metadata.viewerIsAuthor = true
    metadata.headBranch = "feature"
    metadata.baseBranch = "main"
    metadata.baseRevision = "base"
    metadata.fetchedAt = now
    metadata.columnChangedAt = now
    metadata.lastActivityAt = now
    metadata.reviewDecision = "REVIEW_REQUIRED"
    metadata.requiredReviewCount = 3
    metadata.approvalCount = 2
    metadata.outstandingChanges = true
    metadata.reviewEvidenceComplete = true
    metadata.assignees = ["assigned"]
    metadata.reviewers = ["reviewer"]
    metadata.labels = ["ready"]
    metadata.checks = "PENDING"
    metadata.failingRequiredCheck = true
    metadata.mergeable = "UNKNOWN"
    metadata.autoMerge = true
    metadata.autoMergeKnown = true
    metadata.requests[0].viewerStatus = .unknown
    metadata.files = 2
    metadata.additions = 4
    metadata.deletions = 3
    metadata.comments = 9
    metadata.partial = true
    metadata.authorClassification = "automation"
    metadata.riskFlags = ["sensitive"]
    metadata.mergeEligible = false
    let row = PullRequest(
      key: original.key, headRevision: original.headRevision, title: original.title,
      state: original.state, isDraft: original.isDraft, metadata: metadata)
    do {
      let database = try DatabaseStore(path: url.path)
      try database.saveAccount(
        Account(scope: row.key.account, login: "viewer", tokenReference: nil))
      try database.saveRepository(
        Repository(
          key: row.key.repository, name: "o/r", isPrivate: false,
          capabilities: ProviderCapabilities()))
      try database.savePullRequests([row])
    }
    let database = try DatabaseStore(path: url.path)
    XCTAssertEqual(try database.snapshot(for: row.key.account).pullRequests, [row])
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
    object.removeValue(forKey: "metadata")
    XCTAssertNil(
      try JSONDecoder().decode(
        PullRequest.self, from: JSONSerialization.data(withJSONObject: object)
      ).metadata)
  }
  func testViewsSelectionSeenAndRestorationPersistAndImportAtomically() throws {
    let db = try DatabaseStore(path: ":memory:")
    let store = PullRequestStore(database: db)
    var state = PRViewState()
    state.selection = PRSelection(focused: pr("1").key, selected: [pr("1").key])
    state.lastSeenAt = now
    state.views[0].name = "Review queue"
    state.views[0].configuration.mode = .list
    try store.save(state)
    XCTAssertEqual(try store.load(), state)
    let exported = try store.exportViews()
    try store.importViews(exported)
    XCTAssertEqual(try store.load().views, state.views)
    XCTAssertThrowsError(try store.importViews(Data("{}".utf8)))
    XCTAssertEqual(try store.load().views, state.views)
  }
  func testAllViewFieldsAndRestorationSurviveSQLiteCloseReopen() throws {
    let url = try makeTemporaryDirectory().appendingPathComponent("db.sqlite")
    var state = PRViewState()
    state.current.mode = .list
    state.current.grouping = .author
    state.current.sort = .size
    state.current.ascending = true
    state.current.compact = true
    state.current.showDrafts = true
    state.current.hideMerged = true
    state.current.mergedDays = 14
    state.current.timeScope = .custom
    state.current.measuredField = .created
    state.current.customStart = now
    state.current.customEnd = now.addingTimeInterval(86400)
    state.current.keepWaitingOnMe = true
    state.current.columns = [.title, .checks, .labels]
    state.current.collapsedLanes = ["author"]
    state.current.filter = try FilterExpression.parse("request:team repo:~o")
    state.views[0].configuration = state.current
    state.views[0].hidden = true
    state.views[0].notificationRule = true
    state.views[0].icon = "tray"
    state.selection = PRSelection(focused: pr("1").key, selected: [pr("1").key])
    state.scrollAnchor = pr("1").key
    state.lastSeenAt = now
    state.accountFilter = pr("1").key.account
    state.recordVisit(pr("1").key, at: now)
    state.globalShortcuts = PRGlobalShortcuts()
    do { try PullRequestStore(database: DatabaseStore(path: url.path)).save(state) }
    XCTAssertEqual(try PullRequestStore(database: DatabaseStore(path: url.path)).load(), state)
  }
  func testAccountScopedFrecencyPersistsAndRanksFrequentlyOpenedRoutes() throws {
    let db = try DatabaseStore(path: ":memory:")
    let store = PullRequestStore(database: db)
    let a = pr("1").key
    let b = pr("1", account: "2").key
    var state = PRViewState()
    for _ in 0..<10 { state.recordVisit(a, at: now.addingTimeInterval(-3600)) }
    state.recordVisit(b, at: now)
    XCTAssertGreaterThan(state.navigationScore(a, at: now), state.navigationScore(b, at: now))
    try store.save(state)
    XCTAssertEqual(try store.load().navigationScore(a, at: now), state.navigationScore(a, at: now))
  }
  func testExactRoutesRequireAccountIdentityAndDuplicateWebURLsUseExplicitActionAccount() {
    let a = pr("1")
    let b = pr("1", account: "2")
    XCTAssertEqual(
      PRRouteResolver.resolve(a.key.routeURL, cached: [a, b], activeAccount: nil), .native(a.key))
    XCTAssertEqual(
      PRRouteResolver.resolve(a.metadata!.webURL, cached: [a, b], activeAccount: b.key.account),
      .native(b.key))
    XCTAssertEqual(
      PRRouteResolver.resolve(a.metadata!.webURL, cached: [a, b], activeAccount: nil),
      .chooseAccount([a.key, b.key]))
    let unsupported = URL(string: "https://github.com/o/r/actions/runs/42")!
    XCTAssertEqual(
      PRRouteResolver.resolve(unsupported, cached: [a, b], activeAccount: nil), .web(unsupported))
    XCTAssertEqual(
      PRRouteResolver.resolve(
        URL(string: "mergepro://pull?object=1")!, cached: [a], activeAccount: nil), .unavailable)
  }
  func testPaletteFuzzySearchRanksContiguousMatchBeforeScatteredLetters() {
    let exact = PRPaletteSearch.score("cache", "Cache refresh")
    let scattered = PRPaletteSearch.score("cache", "Change a checking engine")
    XCTAssertNotNil(exact)
    XCTAssertNotNil(scattered)
    XCTAssertGreaterThan(exact!, scattered!)
    XCTAssertNil(PRPaletteSearch.score("zebra", "Cache refresh"))
  }
  func testCountUsesSameTimeMergedAndClosedSemanticsAsProjection() throws {
    var view = PRViewConfiguration()
    view.timeScope = .last7Days
    view.filter = try FilterExpression.parse("state:closed")
    let rows = [pr("1", state: .closed), pr("2", state: .merged), pr("3")]
    XCTAssertEqual(
      BoardProjection.count(rows: rows, view: view, now: now),
      BoardProjection(rows: rows, view: view, now: now).rows.count)
  }
  func testFiveThousandRowProjectionPerformance() {
    let rows = (1...5000).map { pr(String($0)) }
    var view = PRViewConfiguration()
    view.mode = .list
    let start = ContinuousClock.now
    let board = BoardProjection(rows: rows, view: view, now: now)
    XCTAssertEqual(board.rows.count, 5000)
    print("TASK5 projection 5000 rows: \(start.duration(to:.now))")
  }
}

extension BoardProjectionTests {
  func testPreviousLookCutoffAndExplicitMarkSeenSurviveReopen() throws {
    let store=PullRequestStore(database:try DatabaseStore(path:":memory:"))
    var state=PRViewState()
    XCTAssertEqual(state.beginLook(at:now),now)
    try store.save(state)
    state=try store.load()
    XCTAssertEqual(state.beginLook(at:now.addingTimeInterval(100)),now)
    state.lastSeenAt=now.addingTimeInterval(120)
    XCTAssertEqual(state.beginLook(at:now.addingTimeInterval(200)),now.addingTimeInterval(120))
    try store.save(state)
    XCTAssertEqual(try store.load().lastLookAt,now.addingTimeInterval(200))
  }
}

extension BoardProjectionTests {
  func testAuthorTypeAgentUsesClassificationNotBotIdentity() throws {
    func row(_ login: String, classification: String) -> PullRequest {
      let original = pr("1")
      var m = original.metadata!
      m.authorLogin = login
      m.actorType = "Bot"
      m.authorClassification = classification
      return PullRequest(key: original.key, headRevision: original.headRevision, title: original.title, state: .open, isDraft: false, metadata: m)
    }
    let agent = try FilterExpression.parse("authorType:agent")
    XCTAssertTrue(agent.matches(row("copilot", classification: "agent"), now: now))
    XCTAssertFalse(agent.matches(row("dependabot[bot]", classification: "automation"), now: now), "bot identity alone is not AI authorship")
    XCTAssertFalse(agent.matches(row("copilot", classification: "human"), now: now), "manual override must win")
    XCTAssertTrue(try FilterExpression.parse("authorType:bot").matches(row("dependabot[bot]", classification: "automation"), now: now))
  }
}
