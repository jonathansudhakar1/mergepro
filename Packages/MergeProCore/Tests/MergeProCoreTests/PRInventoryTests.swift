import XCTest

@testable import MergeProCore

actor InventoryTransport: GitHubTransport {
  let bodyText: String?
  var calls: [URLRequest] = []
  let headRevision:String
  let baseRevision:String
  let secondPageFails: Bool
  let partialErrors: Bool
  let nestedPage: Bool
  let reviewedTeam: Bool
  let nestedHead: String
  let dismissedReview: Bool
  let renewedTeam: Bool
  let unknownChronology: Bool
  let firstPageFails: Bool
  let commentedAfterApproval: Bool
  init(
    headRevision:String="sha",baseRevision:String="base",secondPageFails: Bool = false, partialErrors: Bool = false, nestedPage: Bool = false,
    reviewedTeam: Bool = false, nestedHead: String = "sha", dismissedReview: Bool = false,
    renewedTeam: Bool = false, unknownChronology: Bool = false, firstPageFails: Bool = false, bodyText: String? = nil,
    commentedAfterApproval: Bool = false
  ) {
    self.commentedAfterApproval = commentedAfterApproval
    self.headRevision=headRevision;self.baseRevision=baseRevision
    self.secondPageFails = secondPageFails
    self.partialErrors = partialErrors
    self.nestedPage = nestedPage
    self.reviewedTeam = reviewedTeam
    self.nestedHead = nestedHead
    self.dismissedReview = dismissedReview
    self.renewedTeam = renewedTeam
    self.unknownChronology = unknownChronology
    self.firstPageFails = firstPageFails
    self.bodyText = bodyText
  }
  func send(_ request: URLRequest) async throws -> GitHubResponse {
    calls.append(request)
    if request.url!.path == "/user/teams" {
      return GitHubResponse(
        status: 200, data: Data("[{\"node_id\":\"TEAM\",\"name\":\"Reviewers\"}]".utf8))
    }
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    // Actor exposes login, but identity must be selected on concrete User/Bot types.
    if (body["query"] as? String)?.contains("author { id login }") == true {
      return GitHubResponse(status: 200, data: Data("{\"errors\":[{\"message\":\"Field 'id' doesn't exist on type 'Actor'\"}]}".utf8))
    }
    // Official GitHub ReviewRequest schema has no createdAt field.
    if (body["query"] as? String)?.contains("nodes { createdAt requestedReviewer") == true {
      throw GitHubFailure.invalidResponse
    }
    let vars = body["variables"] as! [String: Any]
    if (body["query"] as? String)?.contains("PRConnection") == true {
      let node: [String: Any] = [
        "headRefOid": nestedHead, "updatedAt": "2026-10-01T11:00:00Z",
        "reviewRequests": [
          "nodes": [
            [
              "requestedReviewer": [
                "__typename": "User", "id": "VIEWER", "login": "authoritative viewer",
              ]
            ]
          ], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
        ],
      ]
      return GitHubResponse(
        status: 200, data: try JSONSerialization.data(withJSONObject: ["data": ["node": node]]))
    }
    if firstPageFails { throw GitHubFailure.resourceDenied }
    let second = vars["after"] as? String == "page2"
    if second && secondPageFails { throw GitHubFailure.resourceDenied }
    let info: [String: Any] = ["hasNextPage": !second, "endCursor": second ? NSNull() : "page2"]
    let empty: [String: Any] = [
      "nodes": [], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
    ]
    var nodes = (second ? 101...101 : 1...100).map { n -> [String: Any] in
      [
        "id": "NODE\(n)", "number": n, "url": "https://github.com/o/r/pull/\(n)",
        "title": "Fixture \(n)", "state": "OPEN", "isDraft": false, "headRefOid": headRevision,
        "baseRefOid": baseRevision, "baseRefName": "main", "headRefName": "feature",
        "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T11:00:00Z",
        "author": ["id": "VIEWER", "login": "viewer", "__typename": "User"],
        "reviewDecision": "APPROVED", "mergeable": "MERGEABLE",
        "reviewRequests": [
          "nodes": [
            [
              "requestedReviewer": [
                "__typename": "Team", "id": "TEAM", "name": "Reviewers", "slug": "reviewers",
              ]
            ]
          ], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
        ], "labels": empty, "assignees": empty, "reviews": empty, "timelineItems": empty,
      ]
    }
    for index in nodes.indices {
      if (body["query"] as? String)?.contains("bodyText") == true { nodes[index]["bodyText"] = bodyText }
      nodes[index]["commits"] = ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"]]]]]
    }
    if reviewedTeam && !second {
      if !unknownChronology {
        nodes[0]["timelineItems"] = [
          "nodes": [
            [
              "__typename": "ReviewRequestedEvent",
              "createdAt": renewedTeam ? "2026-10-01T13:00:00Z" : "2026-10-01T10:00:00Z",
              "requestedReviewer": ["__typename": "Team", "id": "TEAM", "name": "Reviewers"],
            ]
          ], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
        ]
      }
      nodes[0]["reviews"] = [
        "nodes": [
          [
            "id": "REVIEW", "state": "APPROVED", "submittedAt": "2026-10-01T12:00:00Z",
            "author": ["id": "VIEWER", "login": "viewer"], "commit": ["oid": headRevision],
          ]
        ], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
      ]
    }
    if dismissedReview && !second {
      nodes[0]["reviews"] = [
        "nodes": [
          [
            "id": "REVIEW1", "state": "APPROVED", "submittedAt": "2026-10-01T12:00:00Z",
            "author": ["id": "VIEWER", "login": "viewer"], "commit": ["oid": headRevision],
          ],
          [
            "id": "REVIEW2", "state": "DISMISSED", "submittedAt": "2026-10-01T13:00:00Z",
            "author": ["id": "VIEWER", "login": "viewer"], "commit": ["oid": headRevision],
          ],
        ], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
      ]
    }
    if commentedAfterApproval && !second {
      nodes[0]["reviews"] = [
        "nodes": [
          [
            "id": "REVIEW1", "state": "APPROVED", "submittedAt": "2026-10-01T12:00:00Z",
            "author": ["id": "VIEWER", "login": "viewer"], "commit": ["oid": headRevision],
          ],
          [
            "id": "REVIEW2", "state": "COMMENTED", "submittedAt": "2026-10-01T13:00:00Z",
            "author": ["id": "VIEWER", "login": "viewer"], "commit": ["oid": headRevision],
          ],
        ], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
      ]
    }
    if nestedPage && !second {
      nodes[0]["reviewRequests"] = [
        "nodes": [], "pageInfo": ["hasNextPage": true, "endCursor": "requests2"],
      ]
    }
    var envelope: [String: Any] = [
      "data": [
        "viewer": ["id": "VIEWER", "databaseId": 1, "login": "viewer"],
        "repository": ["pullRequests": ["nodes": nodes, "pageInfo": info]],
        "rateLimit": ["cost": 4, "remaining": 4000, "resetAt": "2026-10-02T10:00:00Z"],
      ]
    ]
    if partialErrors { envelope["errors"] = [["message": "fixture inaccessible field"]] }
    return GitHubResponse(status: 200, data: try JSONSerialization.data(withJSONObject: envelope))
  }
}
final class PRInventoryTests: XCTestCase {
  func testInventoryStoresBoundedDescriptionPreview() async throws {
    let body = "A short summary.\n" + String(repeating: "More details. ", count: 100)
    let result = try await GitHubPRInventoryFetcher().fetch(context(InventoryTransport(bodyText: body)))
    let metadata = try XCTUnwrap(result.pullRequests.first?.metadata)
    let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as! [String: Any]
    XCTAssertEqual(value["descriptionPreview"] as? String, String(body.prefix(600)))
  }
  func testInventoryQueryUsesSupportedReviewAuthorSelection() async throws {
    let result = try await GitHubPRInventoryFetcher().fetch(context(InventoryTransport()))
    XCTAssertEqual(result.pullRequests.count, 101)
    let status = try JSONDecoder().decode(PRInventoryStatus.self, from: result.snapshots[0].payload)
    XCTAssertTrue(status.complete)
    XCTAssertNil(status.failureMessage)
  }

  func testSuccessfulRetryClearsFailureMessage() async throws {
    let failed = try await GitHubPRInventoryFetcher().fetch(context(InventoryTransport(firstPageFails: true)))
    let result = try await GitHubPRInventoryFetcher().fetch(context(InventoryTransport(), snapshots: failed.snapshots))
    let status = try JSONDecoder().decode(PRInventoryStatus.self, from: result.snapshots[0].payload)
    XCTAssertTrue(status.complete)
    XCTAssertNil(status.failureMessage)
    XCTAssertNotNil(status.lastFailureAt)
  }

  func testQueryRejectionExplainsFailureWithoutPersistingRawProviderMessage() async throws {
    let transport = ScriptedTransport([json("[]"), json(#"{"errors":[{"message":"private-provider-payload"}]}"#)])
    let result = try await GitHubPRInventoryFetcher().fetch(context(transport))
    let status = try JSONDecoder().decode(PRInventoryStatus.self, from: result.snapshots[0].payload)
    XCTAssertTrue(status.failureMessage?.contains("query") == true)
    XCTAssertFalse(status.failureMessage?.contains("private-provider-payload") == true)
    XCTAssertFalse(status.complete)
    XCTAssertTrue(result.pullRequests.isEmpty)
  }

  func testSkippedInventoryReadPreservesPreviousFailureDiagnosis() async throws {
    let failed = try await GitHubPRInventoryFetcher().fetch(context(InventoryTransport(firstPageFails: true)))
    let prior = try JSONDecoder().decode(PRInventoryStatus.self, from: failed.snapshots[0].payload)
    let result = try await GitHubPRInventoryFetcher().fetch(
      context(ScriptedTransport([]), snapshots: failed.snapshots, deadline: .now))
    let status = try JSONDecoder().decode(PRInventoryStatus.self, from: result.snapshots[0].payload)
    XCTAssertNotNil(prior.failureMessage)
    XCTAssertEqual(status.failureMessage, prior.failureMessage)
    XCTAssertEqual(status.lastFailureAt, prior.lastFailureAt)
    XCTAssertNil(status.lastSuccessAt)
  }

  func context(
    _ transport: any GitHubTransport, cached: [PullRequest] = [], baseline: Bool = false,
    snapshots: [PollFeatureSnapshot] = [], deadline: ContinuousClock.Instant? = nil
  ) -> PollFetchContext {
    let account = AccountScope(host: "github.com", accountID: "1")
    let repo = RepositoryKey(account: account, repositoryID: "1")
    return PollFetchContext(
      cycleID: UUID(), account: account, repositories: [repo], featureID: "github-pr-inventory",
      cachedPullRequests: cached, cachedSnapshots: snapshots,
      repositoryMetadata: [
        repo: Repository(
          key: repo, name: "o/r", isPrivate: false, capabilities: ProviderCapabilities())
      ], deadline: deadline ?? .now.advanced(by: .seconds(10)),
      operation: AccountOperation(
        account: account,
        credential: GitHubCredential(
          accessToken: "fixture", refreshToken: nil, expiresAt: nil, refreshExpiresAt: nil,
          scopes: []), generation: UUID()), client: GitHubHTTPClient(transport: transport),
      budget: RateBudget(minimumSpacing: .zero), baselinedRepositories: baseline ? [repo] : [],
      suppressNotifications: false, cachedResponses: [:])
  }
  func testTitleAndViewedConfirmationDoNotInventTeamReviewRequestOnNextActualInventoryPoll() async throws {
    for reviewed in [false,true] {
      let initial=try await GitHubPRInventoryFetcher().fetch(context(InventoryTransport(reviewedTeam:reviewed)))
      let old=try XCTUnwrap(initial.pullRequests.first)
      let fixture=try makeSessionFixture(account:old.key.account,login:"viewer",repositories:[.fixture(old.key.repository,isPrivate:false)],transport:ScriptedTransport(fallback:json("{\"id\":\"receipt\"}")))
      let (db,session)=(fixture.database,fixture.session);try db.savePullRequests(initial.pullRequests)
      var lossy=try XCTUnwrap(old.metadata);lossy.requests=lossy.requests.map { .init(id:$0.id,name:$0.name,kind:$0.kind,isForViewer:false) };lossy.approvalCount=nil;lossy.reviewEvidenceComplete=false
      let fresh=PullRequest(key:old.key,headRevision:old.headRevision,title:"After",state:old.state,isDraft:old.isDraft,metadata:lossy)
      let subject=PRWriteCoordinator(session:session,budget:.init(minimumSpacing:.zero),database:db,clientID:"fixture",activeAccount:{ old.key.account },adapter:InventoryMutationAdapter(normalized:fresh))
      for intent in [PRWriteIntent.metadata(.title("After")),.viewed(path:"file",viewed:true)] {
        _ = try await subject.perform(.init(key:old.key,repository:"o/r",number:old.metadata!.number,revision:.init(head:"sha",origin:"origin",target:"base"),intent:intent))
        let cached=try db.snapshot(for:old.key.account).pullRequests
        XCTAssertEqual(cached.first(where:{ $0.key == old.key })?.needsViewer,old.needsViewer)
        let nextContext=context(InventoryTransport(reviewedTeam:reviewed),cached:cached)
        let next=try await GitHubPRInventoryFetcher().fetch(nextContext)
        XCTAssertFalse(next.events.contains { $0.object == old.key && $0.category == "review requested" })
        let store=PollCycleStore(database:db);try store.begin(nextContext.cycleID,at:Date(),baseline:false)
        try store.apply(next,context:nextContext,deadline:nextContext.deadline,requireTracked:false)
        let summary=try store.close(nextContext.cycleID,at:Date(),policy:.init(enabled:true))
        XCTAssertTrue(summary.eventKeys.isEmpty)
      }
    }
  }
  func testInventoryExhausts101PRsAndUsesStableKindIdentityAndAuthoritativeTeamMembership()
    async throws
  {
    let transport = InventoryTransport()
    let result = try await GitHubPRInventoryFetcher().fetch(context(transport))
    XCTAssertEqual(result.pullRequests.count, 101)
    XCTAssertEqual(result.pullRequests.last?.key.objectID, "pull-request:NODE101")
    XCTAssertEqual(result.pullRequests.last?.metadata?.number, 101)
    XCTAssertTrue(result.pullRequests[0].needsViewer)
    XCTAssertTrue(result.pullRequests[0].metadata?.viewerIsAuthor == true)
    let snapshot = try JSONDecoder().decode(
      PRInventoryStatus.self, from: result.snapshots[0].payload)
    XCTAssertTrue(snapshot.complete)
    XCTAssertEqual(snapshot.fetchedCount, 101)
    let calls = await transport.calls
    XCTAssertEqual(calls.filter { $0.httpBody.map { String(decoding:$0,as:UTF8.self).contains("query Inventory") } == true }.count, 2)
    XCTAssertLessThanOrEqual(calls.count,8)
  }
  func testFailedSecondPageReturnsPartialFirstPageAndPreservesUnseenCache() async throws {
    let transport = InventoryTransport(secondPageFails: true)
    let context = context(transport)
    let result = try await GitHubPRInventoryFetcher().fetch(context)
    XCTAssertEqual(result.pullRequests.count, 100)
    let status = try JSONDecoder().decode(PRInventoryStatus.self, from: result.snapshots[0].payload)
    XCTAssertFalse(status.complete)
    XCTAssertTrue(result.baselinedRepositories.isEmpty)
  }
  func testPartialGraphQLErrorsDisableAuthoritativeApprovalAndKeepPartialState() async throws {
    let result = try await GitHubPRInventoryFetcher().fetch(
      context(InventoryTransport(partialErrors: true)))
    XCTAssertEqual(result.pullRequests.count, 101)
    XCTAssertTrue(
      result.pullRequests.allSatisfy {
        $0.metadata?.partial == true && $0.metadata?.reviewDecision == nil
      })
    XCTAssertFalse(
      try JSONDecoder().decode(PRInventoryStatus.self, from: result.snapshots[0].payload).complete)
  }
  func testPreviouslyUnseenInventoryPRsSeedObjectBaselineSilently() async throws {
    let result = try await GitHubPRInventoryFetcher().fetch(
      context(InventoryTransport(), baseline: true))
    XCTAssertTrue(result.events.isEmpty)
    XCTAssertTrue(result.baselineEventKeys.isEmpty)
  }
  func testDismissedLatestReviewDoesNotHideOutstandingTeamRequest() async throws {
    let result = try await GitHubPRInventoryFetcher().fetch(
      context(InventoryTransport(dismissedReview: true)))
    XCTAssertTrue(result.pullRequests[0].needsViewer)
  }
  func testTeamRequestDoesNotNeedMemberWhoAlreadyReviewedCurrentHead() async throws {
    let result = try await GitHubPRInventoryFetcher().fetch(
      context(InventoryTransport(reviewedTeam: true)))
    XCTAssertFalse(result.pullRequests[0].needsViewer)
    XCTAssertEqual(result.pullRequests[0].metadata?.requests.first?.kind, .team)
    XCTAssertTrue(result.pullRequests[1].needsViewer)
  }
  func testLaterCommentDoesNotReopenMembersApprovedTeamRequest() async throws {
    // GitHub keeps an author's APPROVED state when they later only comment on the same head.
    let result = try await GitHubPRInventoryFetcher().fetch(
      context(InventoryTransport(reviewedTeam: true, commentedAfterApproval: true)))
    let request = try XCTUnwrap(result.pullRequests[0].metadata?.requests.first)
    XCTAssertEqual(request.kind, .team)
    XCTAssertEqual(request.viewerStatus, .alreadyReviewed)
    XCTAssertFalse(result.pullRequests[0].needsViewer)
    XCTAssertEqual(result.pullRequests[0].metadata?.approvalCount, 1)
  }
  func testRenewedSameHeadTeamRequestAfterReviewRemainsActionable() async throws {
    let initial = try await GitHubPRInventoryFetcher().fetch(
      context(InventoryTransport(reviewedTeam: true)))
    let result = try await GitHubPRInventoryFetcher().fetch(
      context(
        InventoryTransport(reviewedTeam: true, renewedTeam: true), cached: initial.pullRequests))
    XCTAssertTrue(result.pullRequests[0].needsViewer)
    XCTAssertEqual(result.pullRequests[0].metadata?.requests.first?.viewerStatus, .needsReview)
    XCTAssertTrue(
      result.events.contains {
        $0.category == "review requested" && $0.object == result.pullRequests[0].key
      })
  }
  func testUnknownTeamRequestChronologyRemainsVisibleWithoutInventedRequestDelta() async throws {
    let initial = try await GitHubPRInventoryFetcher().fetch(
      context(InventoryTransport(reviewedTeam: true)))
    let result = try await GitHubPRInventoryFetcher().fetch(
      context(
        InventoryTransport(reviewedTeam: true, unknownChronology: true),
        cached: initial.pullRequests))
    XCTAssertTrue(result.pullRequests[0].needsViewer)
    XCTAssertEqual(result.pullRequests[0].metadata?.requests.first?.viewerStatus, .unknown)
    XCTAssertFalse(result.events.contains { $0.category == "review requested" })
  }
  func testFailedLatestPagePersistsScopedFailureAndPriorSuccessWithoutDeletingCachedPRs()
    async throws
  {
    let initial = try await GitHubPRInventoryFetcher().fetch(context(InventoryTransport()))
    let first = try JSONDecoder().decode(PRInventoryStatus.self, from: initial.snapshots[0].payload)
    let failedContext = context(
      InventoryTransport(firstPageFails: true), cached: initial.pullRequests,
      snapshots: initial.snapshots)
    let result = try await GitHubPRInventoryFetcher().fetch(failedContext)
    let failed = try JSONDecoder().decode(PRInventoryStatus.self, from: result.snapshots[0].payload)
    XCTAssertNotNil(first.lastSuccessAt)
    XCTAssertEqual(failed.lastSuccessAt, first.lastSuccessAt)
    XCTAssertNotNil(failed.lastFailureAt)
    XCTAssertFalse(failed.complete)
    let database = try DatabaseStore(path: ":memory:")
    try database.saveAccount(
      Account(scope: failedContext.account, login: "viewer", tokenReference: nil))
    try database.saveRepository(failedContext.repositoryMetadata.values.first!)
    try database.savePullRequests(initial.pullRequests)
    let store = PollCycleStore(database: database)
    try store.begin(failedContext.cycleID, at: Date(), baseline: false)
    try store.apply(
      result, context: failedContext, deadline: failedContext.deadline, requireTracked: false)
    XCTAssertEqual(try store.pullRequests(account: failedContext.account).count, 101)
    let persisted = try store.featureSnapshots(
      account: failedContext.account, feature: "github-pr-inventory")
    XCTAssertEqual(
      try JSONDecoder().decode(PRInventoryStatus.self, from: persisted[0].payload).lastFailureAt,
      failed.lastFailureAt)
  }
  func testNestedConnectionCannotCompleteOldHeadAfterProviderChangesRevision() async throws {
    let result = try await GitHubPRInventoryFetcher().fetch(
      context(InventoryTransport(nestedPage: true, nestedHead: "new-head")))
    let first = result.pullRequests.first { $0.metadata?.number == 1 }
    XCTAssertTrue(
      first?.metadata?.partial == true,
      "Never mix new-head connections with checkpoint old-head header")
    XCTAssertFalse(
      try JSONDecoder().decode(PRInventoryStatus.self, from: result.snapshots[0].payload).complete)
  }
  func testReviewRequestConnectionPaginatesIndependently() async throws {
    let transport = InventoryTransport(nestedPage: true)
    let result = try await GitHubPRInventoryFetcher().fetch(context(transport))
    XCTAssertEqual(result.pullRequests[0].metadata?.requests.first?.kind, .direct)
    XCTAssertTrue(result.pullRequests[0].needsViewer)
    let calls = await transport.calls
    XCTAssertEqual(calls.filter { $0.httpBody.map { let body=String(decoding:$0,as:UTF8.self);return body.contains("query Inventory") || body.contains("query PRConnection") } == true }.count, 3)
    XCTAssertLessThanOrEqual(calls.count,8)
  }
  func testPartialApplyKeepsCachedUnseenObjectInActualDatabase() async throws {
    let transport = InventoryTransport(secondPageFails: true)
    let context = context(transport)
    let unseen = PullRequest(
      key: ProviderKey(
        host: "github.com", accountID: "1", repositoryID: "1", objectID: "pull-request:unseen"),
      headRevision: RevisionID("old"), title: "Unseen", state: .open, isDraft: false)
    let database = try DatabaseStore(path: ":memory:")
    try database.saveAccount(Account(scope: context.account, login: "viewer", tokenReference: nil))
    try database.saveRepository(context.repositoryMetadata.values.first!)
    try database.savePullRequests([unseen])
    let store = PollCycleStore(database: database)
    try store.begin(context.cycleID, at: Date(), baseline: true)
    try store.apply(
      try await GitHubPRInventoryFetcher().fetch(context), context: context,
      deadline: context.deadline, requireTracked: false)
    XCTAssertEqual(try store.pullRequests(account: context.account).count, 101)
    XCTAssertTrue(try store.pullRequests(account: context.account).contains(unseen))
  }

  func testPacedLargeInventoryCommitsResumableProgressAndRefreshesLatestDuringHistory() async throws
  {
    let transport = LongInventoryTransport()
    let database = try DatabaseStore(path: ":memory:")
    let store = PollCycleStore(database: database)
    let seed = context(transport)
    try database.saveAccount(Account(scope: seed.account, login: "viewer", tokenReference: nil))
    try database.saveRepository(seed.repositoryMetadata.values.first!)
    var complete = false
    var cycle = 0
    var counts: [Int] = []
    // Each fetch is cut by its request chunk (`GitHubPRInventoryFetcher.requestChunk`), not by the clock, so the
    // traversal spans the same cycles however loaded the machine is.
    while !complete && cycle < 50 {
      cycle += 1
      let current = context(
        transport, cached: try store.pullRequests(account: seed.account),
        snapshots: try store.featureSnapshots(
          account: seed.account, feature: "github-pr-inventory"))
      try store.begin(current.cycleID, at: Date(), baseline: cycle == 1)
      let result = try await GitHubPRInventoryFetcher().fetch(current)
      try store.apply(result, context: current, deadline: current.deadline, requireTracked: false)
      let status = try JSONDecoder().decode(
        PRInventoryStatus.self, from: result.snapshots[0].payload)
      complete = status.complete
      counts.append(try store.pullRequests(account: seed.account).count)
      if cycle == 1 {
        XCTAssertFalse(complete)
        XCTAssertGreaterThan(counts.last!, 0)
        XCTAssertTrue(result.baselineEventKeys.count == result.events.count)
      }
      if cycle == 2 {
        XCTAssertTrue(
          result.events.contains { $0.category == "review decision" },
          "Known latest changes must alert before history completes")
      }
      _ = try store.close(current.cycleID, at: Date(), policy: NotificationPolicy())
    }
    XCTAssertTrue(complete)
    XCTAssertGreaterThan(cycle, 1)
    XCTAssertEqual(counts.last, 102)
    let calls = await transport.outerCursors
    XCTAssertEqual(
      calls.filter { $0 == "latest" }.count, cycle, "Refresh latest every cycle during traversal")
    XCTAssertTrue(Set(calls).contains("100"), "Resume to final historical cursor")
    let latest = try store.pullRequests(account: seed.account).first { $0.metadata?.number == 1 }
    XCTAssertEqual(latest?.metadata?.labels.count, 12, "Nested cursors survive checkpoint commits")
  }
  func testGraphQLQuotaRemainsSeparateAndProtectsInteractiveReserve() async throws {
    let budget = RateBudget(minimumSpacing: .zero)
    let account = AccountScope(host: "github.com", accountID: "1")
    let response = GitHubResponse(
      status: 200, headers: ["X-RateLimit-Remaining": "1", "X-RateLimit-Reset": "1900000000"],
      data: Data(
        "{\"data\":{\"rateLimit\":{\"cost\":4,\"remaining\":4000,\"resetAt\":\"2030-01-01T00:00:00Z\"}}}"
          .utf8))
    await budget.observe(response, account: account, resource: .rest)
    await budget.observeGraphQL(response, account: account)
    try await budget.acquire(account: account, resource: .graphql, priority: .background, cost: 100)
    do {
      try await budget.acquire(account: account, resource: .rest, priority: .background)
      XCTFail("REST reserve ignored")
    } catch {}
    do {
      try await budget.acquire(
        account: account, resource: .graphql, priority: .background, cost: 3801)
      XCTFail("GraphQL reserve ignored")
    } catch {}
    try await budget.acquire(
      account: account, resource: .graphql, priority: .interactive, cost: 3801)
  }
  func testRepeatedKnownCheckTransitionHasDistinctIdentityWhenPRUpdatedAtDoesNotChange()
    async throws
  {
    let initial = try await GitHubPRInventoryFetcher().fetch(context(InventoryTransport()))
    let cached = initial.pullRequests.map { pr in
      var metadata = pr.metadata
      metadata?.checks = "FAILURE"
      return PullRequest(
        key: pr.key, headRevision: pr.headRevision, title: pr.title, state: pr.state,
        isDraft: pr.isDraft, metadata: metadata)
    }
    // Check reruns can recover/fail repeatedly without mutating the PR updatedAt field.
    let first = try await GitHubPRInventoryFetcher().fetch(
      context(InventoryTransport(), cached: cached))
    let second = try await GitHubPRInventoryFetcher().fetch(
      context(InventoryTransport(), cached: cached))
    let firstEvent = first.events.first { $0.category == "checks" }
    let secondEvent = second.events.first { $0.category == "checks" }
    XCTAssertNotNil(firstEvent)
    XCTAssertNotNil(secondEvent)
    XCTAssertNotEqual(firstEvent?.key, secondEvent?.key)
  }
  func testReadQueryRefusesMutationBeforeAnyTransportRequest() async throws {
    let transport = InventoryTransport()
    let client = GitHubHTTPClient(transport: transport)
    do {
      _ = try await client.readQuery("mutation { deleteThing }", variables: [:], token: "fixture")
      XCTFail("mutation accepted")
    } catch { XCTAssertEqual(error as? GitHubFailure, .unsafeURL) }
    let calls = await transport.calls
    XCTAssertTrue(calls.isEmpty)
  }
}

/// The repository tab's reads: the repository identity (id 7), then `InventoryTransport`'s GraphQL pages.
/// `holdingFirstGraphQL` parks the first inventory read until `release()`.
extension RoutingTransport {
  static func repositoryInventory(holdingFirstGraphQL: Bool = false) async -> RoutingTransport {
    let transport = RoutingTransport(fallback: InventoryTransport())
    await transport.route(path: "/repos/o/r", json("{\"id\":7}"))
    if holdingFirstGraphQL { await transport.hold(where: { $0.url?.lastPathComponent == "graphql" }) }
    return transport
  }
  var identityReads: Int { requests.filter { $0.url?.path == "/repos/o/r" }.count }
  var graphQLReads: Int { requests.filter { $0.url?.lastPathComponent == "graphql" }.count }
}

private actor LongInventoryTransport: GitHubTransport {
  var outerCursors: [String] = []
  var latestCount = 0
  func send(_ request: URLRequest) async throws -> GitHubResponse {
    if request.url!.path == "/user/teams" {
      return GitHubResponse(status: 200, data: Data("[]".utf8))
    }
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    let vars = body["variables"] as! [String: Any]
    let empty: [String: Any] = [
      "nodes": [], "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
    ]
    if (body["query"] as? String)?.contains("PRConnection") == true {
      let index = Int(vars["after"] as! String)!
      let connection: [String: Any] = [
        "nodes": [["name": "label\(index)"]],
        "pageInfo": [
          "hasNextPage": index < 11, "endCursor": index < 11 ? String(index + 1) as Any : NSNull(),
        ],
      ]
      return GitHubResponse(
        status: 200,
        data: try JSONSerialization.data(withJSONObject: [
          "data": [
            "node": [
              "headRefOid": "sha", "updatedAt": "2026-10-01T11:00:00Z", "labels": connection,
            ]
          ]
        ]))
    }
    let cursor = vars["after"] as? String
    outerCursors.append(cursor ?? "latest")
    if cursor == nil { latestCount += 1 }
    let index = cursor.flatMap(Int.init) ?? 0
    func node(_ n: Int) -> [String: Any] {
      [
        "id": "NODE\(n)", "number": n, "url": "https://github.com/o/r/pull/\(n)",
        "title": "Fixture", "state": "OPEN", "isDraft": false, "headRefOid": "sha",
        "baseRefOid": "base", "baseRefName": "main", "createdAt": "2026-10-01T10:00:00Z",
        "updatedAt": "2026-10-01T11:00:00Z",
        "reviewDecision": n == 2 && latestCount > 1 ? "CHANGES_REQUESTED" : "APPROVED",
        "reviewRequests": empty, "labels": empty, "reviews": empty, "assignees": empty,
        "timelineItems": empty,
      ]
    }
    var nodes = index == 0 ? [node(1), node(2)] : [node(index + 2)]
    if index == 0 {
      nodes[0]["labels"] = [
        "nodes": [["name": "label0"]], "pageInfo": ["hasNextPage": true, "endCursor": "1"],
      ]
    }
    return GitHubResponse(
      status: 200,
      data: try JSONSerialization.data(withJSONObject: [
        "data": [
          "viewer": ["id": "VIEWER", "databaseId": 1, "login": "viewer"],
          "repository": [
            "pullRequests": [
              "nodes": nodes,
              "pageInfo": [
                "hasNextPage": index < 100,
                "endCursor": index < 100 ? String(index + 1) as Any : NSNull(),
              ],
            ]
          ],
        ]
      ]))
  }
}
private struct InventoryMutationAdapter:PRWriteAdapter {
    let normalized:PullRequest
    func read(_ command:PRWriteCommand,operation:PRWriteOperation?,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> PRWriteTruth {
        .init(key:command.key,revision:command.revision,viewerIsAuthor:false,canReview:true,canComment:true,canUpdate:true,canReopen:true,canLabel:true,isOpen:true,files:["file"],filesComplete:true,matchingOperationIDs:operation == nil ? [] : ["receipt"],normalized:normalized)
    }
    func send(_ operation:PRWriteOperation,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse { try await client.mutate(path:"repos/o/r/pulls/1",method:"PATCH",body:Data("{}".utf8),token:credential.accessToken) }
    func providerIDs(_ response:GitHubResponse) -> [String] { ["receipt"] }
}
