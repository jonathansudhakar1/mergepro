import Foundation

/// Provider DTOs and durable, bounded continuation. Stored only in scoped value snapshots.
enum GitHubPRInventoryPayload {
  static let pageInfo = "pageInfo { hasNextPage endCursor }"
  static func fields(_ name: String) -> String {
    switch name {
    case "labels": "nodes { name color }"
    case "assignees": "nodes { id login }"
    case "timelineItems":
      "nodes { __typename ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on User { id login } ... on Team { id name slug } } } ... on ReviewRequestRemovedEvent { createdAt requestedReviewer { __typename ... on User { id login } ... on Team { id name slug } } } }"
    case "reviews": "nodes { id state submittedAt author { login ... on User { id } ... on Bot { id } } commit { oid } }"
    default:
      "nodes { requestedReviewer { __typename ... on User { id login } ... on Team { id name slug } } }"
    }
  }
  static func connectionQuery(_ field: String) -> String {
    let itemTypes = field == "timelineItems" ? ",itemTypes:[REVIEW_REQUESTED_EVENT,REVIEW_REQUEST_REMOVED_EVENT]" : ""
    return """
      query PRConnection($id:ID!,$after:String) {
        node(id:$id) { ... on PullRequest {
          headRefOid updatedAt
          \(field)(first:100,after:$after\(itemTypes)) { \(fields(field)) \(pageInfo) }
        } }
        rateLimit { cost remaining resetAt }
      }
      """
  }
  static var inventoryQuery: String { inventoryQuery(first: walkPageSize, openVolatile: false) }
  /// Incremental head reads are small.
  static let incrementalPageSize = 25
  /// History walks and sweeps read 25 PRs a page: every PR carries five nested connections, and on busy
  /// repositories a 100-PR page outlasts GitHub's 10 s GraphQL timeout (502) while 50 lands close to it.
  static let walkPageSize = 25
  /// Every inventory field of one PR, shared by connection pages and targeted node reads.
  static var nodeFields: String {
    """
    id number url title bodyText state isDraft headRefOid headRefName baseRefOid baseRefName createdAt updatedAt mergedAt
          headRepository { databaseId }
          baseRef { branchProtectionRule { requiredApprovingReviewCount } }
          author { __typename login ... on User { id } ... on Bot { id } } reviewDecision mergeable changedFiles additions deletions
          autoMergeRequest { enabledAt } comments { totalCount }
          commits(last:1) { nodes { commit { message statusCheckRollup { state } } } }
          reviewRequests(first:100) { \(fields("reviewRequests")) \(pageInfo) }
          timelineItems(first:100,itemTypes:[REVIEW_REQUESTED_EVENT,REVIEW_REQUEST_REMOVED_EVENT]) { \(fields("timelineItems")) \(pageInfo) }
          reviews(first:100) { \(fields("reviews")) \(pageInfo) }
          labels(first:100) { \(fields("labels")) \(pageInfo) } assignees(first:100) { \(fields("assignees")) \(pageInfo) }
    """
  }
  /// Light open-PR fields GitHub changes without bumping `updatedAt` (check rollup, mergeability,
  /// repository label renames/recolors), 100 open PRs per page, most recently updated first.
  static func openVolatile(after: Bool) -> String {
    "openVolatile: pullRequests(first:100,\(after ? "after:$after," : "")states:[OPEN],orderBy:{field:UPDATED_AT,direction:DESC}) { \(pageInfo) nodes { id headRefOid updatedAt mergeable commits(last:1) { nodes { commit { statusCheckRollup { state } } } } labels(first:20) { nodes { name color } \(pageInfo) } } }"
  }
  /// `openVolatile` adds the newest open page to an incremental head read: every manual refresh and every
  /// `GitHubPRInventoryFetcher.openVolatileEvery`-th scheduled read. Older open pages are covered by
  /// `openVolatileQuery`, one rotating page after each carried batch (see `Checkpoint.openCursor`), so every
  /// open PR's volatile fields are refreshed within ceil(open/100) batches and a watermark never hides them.
  static func inventoryQuery(first: Int, openVolatile: Bool) -> String {
    """
    query Inventory($owner:String!,$repo:String!,$after:String) {
      viewer { id databaseId login }
      repository(owner:$owner,name:$repo) { \(openVolatile ? Self.openVolatile(after: false) : "") pullRequests(first:\(first),after:$after,states:[OPEN,CLOSED,MERGED],orderBy:{field:UPDATED_AT,direction:DESC}) {
        \(pageInfo) nodes { \(nodeFields)
        }
      } } rateLimit { cost remaining resetAt }
    }
    """
  }
  /// One older page of the open-PR volatile alias.
  static var openVolatileQuery: String {
    """
    query OpenVolatile($owner:String!,$repo:String!,$after:String) {
      viewer { id databaseId login }
      repository(owner:$owner,name:$repo) { \(openVolatile(after: true)) }
      rateLimit { cost remaining resetAt }
    }
    """
  }
  /// Targeted re-read of one PR the ordered walk has not surfaced (see `Checkpoint.staleOpen`).
  static var nodeQuery: String {
    """
    query PRNode($id:ID!) {
      viewer { id databaseId login }
      node(id:$id) { ... on PullRequest {
        \(nodeFields)
        repository { databaseId }
      } }
      rateLimit { cost remaining resetAt }
    }
    """
  }
  struct Team: Codable, Sendable { let node_id: String }
  struct Viewer: Codable, Sendable {
    let id: String
    let databaseId: Int64
    let login: String
  }
  struct Page: Codable, Sendable {
    var hasNextPage: Bool
    var endCursor: String?
  }
  struct Item: Codable, Sendable {
    let id: String?
    let name: String?
    /// Label color (6-hex, no #); absent in checkpoints written before colors were requested.
    var color: String? = nil
    let login: String?
    let slug: String?
    let type: String?
    let state: String?
    let submittedAt: String?
    let createdAt: String?
    let author: ReviewActor?
    let commit: ReviewCommit?
    let requestedReviewer: Reviewer?
    enum CodingKeys: String, CodingKey {
      case id, name, color, login, slug, state, submittedAt, createdAt, author, commit, requestedReviewer
      case type = "__typename"
    }
  }
  struct ReviewActor: Codable, Sendable {
    let id: String?
    let login: String?
  }
  struct ReviewCommit: Codable, Sendable { let oid: String }
  struct Reviewer: Codable, Sendable {
    let id: String?
    let name: String?
    let login: String?
    let slug: String?
    let type: String
    enum CodingKeys: String, CodingKey {
      case id, name, login, slug
      case type = "__typename"
    }
  }
  struct Connection: Codable, Sendable {
    var nodes: [Item?]
    var pageInfo: Page
  }
  struct Envelope: Codable, Sendable {
    struct Payload: Codable, Sendable {
      struct Repo: Codable, Sendable {
        struct PRs: Codable, Sendable {
          let nodes: [Node?]
          let pageInfo: Page
        }
        let pullRequests: PRs?
        var openVolatile: OpenPRs? = nil
      }
      let viewer: Viewer?
      let repository: Repo?
    }
    let data: Payload?
    let errors: [ErrorItem]?
  }
  struct ErrorItem: Codable, Sendable { let message: String }
  /// `nodeQuery` response. Only an explicitly null node means authoritative absence; malformed
  /// target data throws so the same provider observation can be retried.
  struct NodeEnvelope: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
      struct Target: Decodable, Sendable {
        struct Repository: Decodable, Sendable { let databaseId: Int64? }
        let node: Node
        let repository: Repository?
        enum CodingKeys: String, CodingKey { case repository }
        init(from decoder: any Decoder) throws {
          node = try Node(from: decoder)
          repository = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Repository.self, forKey: .repository)
        }
      }
      let viewer: Viewer?
      let node: Target?
      enum CodingKeys: String, CodingKey { case viewer, node }
      init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        viewer = try c.decodeIfPresent(Viewer.self, forKey: .viewer)
        node = try c.decode(Target?.self, forKey: .node)
      }
    }
    let data: Payload?
    let errors: [ErrorItem]?
  }
  struct OpenPRs: Codable, Sendable {
    struct Node: Codable, Sendable {
      let id: String
      let headRefOid: String
      let updatedAt: String
      let mergeable: String?
      let commits: GitHubPRInventoryPayload.Node.Commits?
      /// Absent from responses to queries written before labels were requested.
      var labels: Connection? = nil
    }
    let nodes: [Node?]
    let pageInfo: Page
  }
  struct ConnectionEnvelope: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
      struct NestedNode: Decodable, Sendable {
        let headRefOid: String?
        let updatedAt: String?
        let connections: [String: Connection]
        enum CodingKeys: String, CodingKey {
          case headRefOid, updatedAt, reviewRequests, labels, assignees, reviews, timelineItems
        }
        init(from decoder: any Decoder) throws {
          let c = try decoder.container(keyedBy: CodingKeys.self)
          headRefOid = try c.decodeIfPresent(String.self, forKey: .headRefOid)
          updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
          var fields: [String: Connection] = [:]
          for key in [CodingKeys.reviewRequests, .labels, .assignees, .reviews, .timelineItems] {
            fields[key.rawValue] = try c.decodeIfPresent(Connection.self, forKey: key)
          }
          connections = fields
        }
      }
      let node: NestedNode?
    }
    let data: Payload?
    let errors: [ErrorItem]?
  }
  struct Node: Codable, Sendable {
    let id: String
    let number: Int
    let url: URL
    let title: String
    let bodyText: String?
    /// The body's end, where agents usually sign their pull requests ("🤖 Generated with …").
    let bodyTail: String?
    let state: String
    let isDraft: Bool
    let headRefOid: String
    let headRepository:HeadRepository?
    struct HeadRepository:Codable,Sendable { let databaseId:Int64? }
    let headRefName: String?
    let baseRefOid: String
    let baseRefName: String
    let createdAt: String
    let updatedAt: String
    let mergedAt: String?
    let author: Item?
    let reviewDecision: String?
    let mergeable: String?
    let changedFiles: Int?
    let additions: Int?
    let deletions: Int?
    let baseRef: BaseRef?
    let autoMergeRequest: AutoMerge?
    let autoMergeKnown: Bool
    let comments: Count?
    let commits: Commits?
    var connections: [String: Connection] = [:]
    struct BaseRef: Codable, Sendable {
      struct Rule: Codable, Sendable { let requiredApprovingReviewCount: Int? }
      let branchProtectionRule: Rule?
    }
    struct AutoMerge: Codable, Sendable { let enabledAt: String? }
    struct Count: Codable, Sendable { let totalCount: Int }
    struct Commits: Codable, Sendable {
      struct Entry: Codable, Sendable {
        struct Commit: Codable, Sendable {
          struct Rollup: Codable, Sendable { let state: String }
          let statusCheckRollup: Rollup?
          /// The commit message's `Co-authored-by:` trailers only; the rest of the message is not kept.
          let coauthors: [String]?
          enum CodingKeys: String, CodingKey { case statusCheckRollup, message, coauthors }
          init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            statusCheckRollup = try c.decodeIfPresent(Rollup.self, forKey: .statusCheckRollup)
            if let message = try c.decodeIfPresent(String.self, forKey: .message) {
              coauthors = AgentClassifier.coauthors(inCommitMessage: message)
            } else {
              coauthors = try c.decodeIfPresent([String].self, forKey: .coauthors)
            }
          }
          func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(statusCheckRollup, forKey: .statusCheckRollup)
            try c.encodeIfPresent(coauthors, forKey: .coauthors)
          }
        }
        let commit: Commit
      }
      let nodes: [Entry?]
    }
    enum CodingKeys: String, CodingKey {
      case id, number, url, title, bodyText, bodyTail, state, isDraft, headRefOid, headRefName, headRepository, baseRefOid, baseRefName,
        createdAt, updatedAt, mergedAt, author, reviewDecision, mergeable, changedFiles, additions,
        deletions, autoMergeRequest, comments, commits, baseRef, reviewRequests, labels, assignees,
        reviews, timelineItems
    }
    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(String.self, forKey: .id)
      number = try c.decode(Int.self, forKey: .number)
      url = try c.decode(URL.self, forKey: .url)
      title = try c.decode(String.self, forKey: .title)
      let body = try c.decodeIfPresent(String.self, forKey: .bodyText)
      bodyText = body.map { String($0.prefix(600)) }
      bodyTail = try c.decodeIfPresent(String.self, forKey: .bodyTail) ?? body.flatMap { $0.count > 600 ? String($0.suffix(400)) : nil }
      state = try c.decode(String.self, forKey: .state)
      isDraft = try c.decode(Bool.self, forKey: .isDraft)
      headRefOid = try c.decode(String.self, forKey: .headRefOid)
      headRefName = try c.decodeIfPresent(String.self, forKey: .headRefName)
      headRepository = try c.decodeIfPresent(HeadRepository.self,forKey:.headRepository)
      baseRefOid = try c.decode(String.self, forKey: .baseRefOid)
      baseRefName = try c.decode(String.self, forKey: .baseRefName)
      createdAt = try c.decode(String.self, forKey: .createdAt)
      updatedAt = try c.decode(String.self, forKey: .updatedAt)
      mergedAt = try c.decodeIfPresent(String.self, forKey: .mergedAt)
      author = try c.decodeIfPresent(Item.self, forKey: .author)
      reviewDecision = try c.decodeIfPresent(String.self, forKey: .reviewDecision)
      mergeable = try c.decodeIfPresent(String.self, forKey: .mergeable)
      changedFiles = try c.decodeIfPresent(Int.self, forKey: .changedFiles)
      additions = try c.decodeIfPresent(Int.self, forKey: .additions)
      deletions = try c.decodeIfPresent(Int.self, forKey: .deletions)
      baseRef = try c.decodeIfPresent(BaseRef.self, forKey: .baseRef)
      autoMergeKnown = c.contains(.autoMergeRequest)
      autoMergeRequest = try c.decodeIfPresent(AutoMerge.self, forKey: .autoMergeRequest)
      comments = try c.decodeIfPresent(Count.self, forKey: .comments)
      commits = try c.decodeIfPresent(Commits.self, forKey: .commits)
      for key in [CodingKeys.reviewRequests, .labels, .assignees, .reviews, .timelineItems] {
        connections[key.rawValue] = try c.decodeIfPresent(Connection.self, forKey: key)
      }
    }

    func encode(to encoder: any Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encodeIfPresent(id, forKey: .id)
      try c.encodeIfPresent(number, forKey: .number)
      try c.encodeIfPresent(url, forKey: .url)
      try c.encodeIfPresent(title, forKey: .title)
      try c.encodeIfPresent(bodyText, forKey: .bodyText)
      try c.encodeIfPresent(bodyTail, forKey: .bodyTail)
      try c.encodeIfPresent(state, forKey: .state)
      try c.encodeIfPresent(isDraft, forKey: .isDraft)
      try c.encodeIfPresent(headRefOid, forKey: .headRefOid)
      try c.encodeIfPresent(headRefName, forKey: .headRefName)
      try c.encodeIfPresent(headRepository,forKey:.headRepository)
      try c.encodeIfPresent(baseRefOid, forKey: .baseRefOid)
      try c.encodeIfPresent(baseRefName, forKey: .baseRefName)
      try c.encodeIfPresent(createdAt, forKey: .createdAt)
      try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
      try c.encodeIfPresent(mergedAt, forKey: .mergedAt)
      try c.encodeIfPresent(author, forKey: .author)
      try c.encodeIfPresent(reviewDecision, forKey: .reviewDecision)
      try c.encodeIfPresent(mergeable, forKey: .mergeable)
      try c.encodeIfPresent(changedFiles, forKey: .changedFiles)
      try c.encodeIfPresent(additions, forKey: .additions)
      try c.encodeIfPresent(deletions, forKey: .deletions)
      try c.encodeIfPresent(baseRef, forKey: .baseRef)
      if autoMergeKnown { try c.encode(autoMergeRequest, forKey: .autoMergeRequest) }
      try c.encodeIfPresent(comments, forKey: .comments)
      try c.encodeIfPresent(commits, forKey: .commits)
      for key in [CodingKeys.reviewRequests, .labels, .assignees, .reviews, .timelineItems] {
        try c.encodeIfPresent(connections[key.rawValue], forKey: key)
      }
    }
  }
  struct Checkpoint: Codable, Sendable {
    var outerCursor: String?
    var outerFinished = false
    var pending: [Node] = []
    var recentComplete: [Node] = []
    var viewer: Viewer?
    var traversalPartial = false
    var teamIDs: Set<String> = []
    var teamNext: URL?
    var teamComplete = false
    var teamsFetchedAt: Date?
    // Incremental inventory. New fields are optional so older checkpoints still decode.
    /// Newest `updatedAt` below which every PR's current revision is already committed.
    var watermark: String? = nil
    /// Top `updatedAt` of the current head walk's first page; becomes the watermark when it completes.
    var walkTop: String? = nil
    var walkStartedAt: Date? = nil
    var walkFull: Bool? = nil
    /// Start of the last completed full pass (initial walk or periodic sweep).
    var fullPassAt: Date? = nil
    /// Periodic full sweep below the watermark; it never makes current data partial.
    var sweepCursor: String? = nil
    var sweepStartedAt: Date? = nil
    var sweeping: Bool? = nil
    /// Merge-evidence reads by PR id → (inputs signature, attempt time), so unchanged PRs are not re-read.
    var evidenceTried: [String: EvidenceAttempt]? = nil
    struct EvidenceAttempt: Codable, Sendable { var signature: String; var at: Date }
    /// PR id → when its last authoritative evidence, invalidated before it could be re-read, was blocked
    /// (pending). A later re-read that finds it eligible is still a readiness transition.
    var evidenceBlocked: [String: Date]? = nil
    /// Ids in `pending` that came from sweep pages: their cached complete rows stay until the nested
    /// connections finish, and they never make the inventory partial.
    var sweepPending: Set<String>? = nil
    /// Cursor of the next older open-PR volatile page; nil restarts after the head read's first page.
    var openCursor: String? = nil
    /// Open PRs whose volatile read showed a newer `updatedAt` or another head than the cache while the
    /// ordered walk had not read them: id → that observation, re-read by node.
    var staleOpen: [String: Observation]? = nil
    /// Observations already re-read by node (id → signature), so one provider observation costs one read.
    var staleRead: [String: String]? = nil
    /// Failed or partial by-node reads (id → attempts, last attempt): retried at the next cycle, then on a cooldown.
    var staleRetry: [String: Retry]? = nil
    struct Retry: Codable, Sendable { var count: Int; var at: Date }
    /// Scheduled incremental head reads since the last one that carried the open-PR volatile batch.
    var readsSinceOpenBatch: Int? = nil
    /// `InventoryProbe` signature observed just before the last complete read, and when that read was: a later
    /// probe with the same signature means nothing changed, so the read can be skipped until `probeTrust`.
    var probeSignature: String? = nil
    var fullReadAt: Date? = nil
    struct Observation: Codable, Sendable, Equatable {
      var updatedAt: String; var head: String
      var signature: String { updatedAt + "|" + head }
    }
  }
}
