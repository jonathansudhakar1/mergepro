import Foundation

/// Decodes a bounded GraphQL read. Any `errors` member (even empty or null), a missing or null
/// `data` object, an oversized body or an undecodable shape makes the read unavailable.
enum GitHubGraphQLResponse {
    private struct Envelope<Payload: Decodable>: Decodable {
        let data: Payload?
        let hasErrors: Bool
        private enum Keys: String, CodingKey { case data, errors }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            data = try container.decodeIfPresent(Payload.self, forKey: .data)
            hasErrors = container.contains(.errors)
        }
    }
    static func data<Payload: Decodable>(_ type: Payload.Type, from response: GitHubResponse) throws -> Payload {
        guard response.data.count <= 8_000_000 else { throw PRWriteFailure.unavailable }
        let envelope: Envelope<Payload>
        do { envelope = try JSONDecoder().decode(Envelope<Payload>.self, from: response.data) } catch {
            Log.writes.error("GraphQL read response did not decode: \(Log.kind(error), privacy: .public)")
            throw PRWriteFailure.unavailable
        }
        guard !envelope.hasErrors else {
            Log.writes.info("GraphQL read returned errors; read unavailable")
            throw PRWriteFailure.unavailable
        }
        guard let data = envelope.data else { throw PRWriteFailure.unavailable }
        return data
    }
}

/// Typed responses for the write readers (`GitHubPRWriteReader`, `GitHubPRLightQuery` and the
/// readers built on it). Every field is optional: a field the provider omitted stays nil, and each
/// reader decides explicitly what nil means (unknown, incomplete or denied); nothing defaults here.
enum PRWriteReadPayload {
    /// GitHub `databaseId`, compared as text like provider keys: a number, or a numeric string.
    struct DatabaseID: Decodable, Equatable {
        let text: String
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) { text = String(number) } else { text = try container.decode(String.self) }
        }
    }
    struct Connection<Node: Decodable>: Decodable {
        struct PageInfo: Decodable { let hasNextPage: Bool?; let hasPreviousPage: Bool?; let endCursor: String? }
        /// The non-null entries. GitHub returns a null entry for an item the token cannot see; one null
        /// never fails the read, but it makes the connection incomplete (`droppedNulls`).
        let nodes: [Node]?
        let pageInfo: PageInfo?
        /// True when the provider listed null entries that `nodes` omits: the list is known to be partial.
        let droppedNulls: Bool
        private enum CodingKeys: String, CodingKey { case nodes, pageInfo }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decodeIfPresent([Node?].self, forKey: .nodes)
            nodes = raw?.compactMap { $0 }
            droppedNulls = (raw?.count ?? 0) != (nodes?.count ?? 0)
            pageInfo = try container.decodeIfPresent(PageInfo.self, forKey: .pageInfo)
        }
        var values: [Node] { nodes ?? [] }
        /// A first-page connection is complete only when the provider returned pageInfo without a further
        /// page, and listed no entry that had to be dropped.
        func complete(backward: Bool = false) -> Bool {
            guard let pageInfo, !droppedNulls else { return false }
            return (backward ? pageInfo.hasPreviousPage : pageInfo.hasNextPage) != true
        }
        /// More entries exist than `values` holds: a further page, or dropped null entries. Missing pageInfo
        /// alone is not reported here (callers that need it use `complete`).
        var knownPartial: Bool { pageInfo?.hasNextPage == true || droppedNulls }
    }
    struct Viewer: Decodable { let id: String?; let databaseId: DatabaseID?; let login: String? }
    /// An author, assignee or assignable user: `login`, plus `id` where the query selects it.
    struct Actor: Decodable { let login: String?; let id: String? }
    struct ObjectID: Decodable { let id: String? }
    struct Commit: Decodable { let oid: String? }
    struct Label: Decodable { let id: String?; let name: String?; let color: String? }
    struct Milestone: Decodable { let number: Int? }
    struct ProtectionRule: Decodable { let requiresCodeOwnerReviews: Bool?; let requiredApprovingReviewCount: Int?; let restrictsReviewDismissals: Bool? }
    struct BaseRef: Decodable { let branchProtectionRule: ProtectionRule? }
    struct Repository: Decodable {
        let databaseId: DatabaseID?
        let nameWithOwner: String?
        let viewerPermission: String?
        let labels: Connection<Label>?
        let assignableUsers: Connection<Actor>?
    }
    struct Review: Decodable {
        let id: String?
        let body: String?
        let state: String?
        let createdAt: String?
        let submittedAt: String?
        let viewerDidAuthor: Bool?
        let viewerCanDelete: Bool?
        let author: Actor?
        let commit: Commit?
        let pullRequest: ObjectID?
    }
    struct RequestedReviewer: Decodable {
        let typename: String?
        let id: String?
        let login: String?
        let slug: String?
        let name: String?
        private enum CodingKeys: String, CodingKey { case typename = "__typename", id, login, slug, name }
    }
    struct ReviewRequest: Decodable { let requestedReviewer: RequestedReviewer? }
    struct ReactionGroup: Decodable { let content: String?; let viewerHasReacted: Bool? }
    /// An issue or review comment. `hasReviewField` records whether `pullRequestReview` was returned at
    /// all (even as null): only review comments select it, which separates them from conversation comments.
    @dynamicMemberLookup struct Comment: Decodable {
        struct Fields: Decodable {
            let id: String?
            let body: String?
            let url: String?
            let createdAt: String?
            let author: Actor?
            let viewerDidAuthor: Bool?
            let viewerCanUpdate: Bool?
            let viewerCanDelete: Bool?
            let viewerCanReact: Bool?
            let viewerCanMinimize: Bool?
            let viewerCanUnminimize: Bool?
            let isMinimized: Bool?
            let reactionGroups: [ReactionGroup]?
            let commit: Commit?
            let originalCommit: Commit?
            let diffHunk: String?
            let line: Int?
            let startLine: Int?
            let originalLine: Int?
            let originalStartLine: Int?
            let pullRequestReview: ObjectID?
        }
        let fields: Fields
        let hasReviewField: Bool
        private enum Presence: String, CodingKey { case pullRequestReview }
        init(from decoder: any Decoder) throws {
            fields = try Fields(from: decoder)
            hasReviewField = try decoder.container(keyedBy: Presence.self).contains(.pullRequestReview)
        }
        subscript<Value>(dynamicMember path: KeyPath<Fields, Value>) -> Value { fields[keyPath: path] }
    }
    struct Thread: Decodable {
        let id: String?
        let path: String?
        let subjectType: String?
        let line: Int?
        let startLine: Int?
        let diffSide: String?
        let startDiffSide: String?
        let originalLine: Int?
        let originalStartLine: Int?
        let isOutdated: Bool?
        let isResolved: Bool?
        let viewerCanReply: Bool?
        let viewerCanResolve: Bool?
        let viewerCanUnresolve: Bool?
        let comments: Connection<Comment>?
    }
    struct FileViewState: Decodable { let path: String?; let viewerViewedState: String? }
    /// One pull request node; each query selects a subset of these fields.
    struct PullRequestNode: Decodable {
        let id: String?
        let number: Int?
        let url: String?
        let title: String?
        let body: String?
        let state: String?
        let isDraft: Bool?
        let locked: Bool?
        let headRefOid: String?
        let baseRefOid: String?
        let headRefName: String?
        let baseRefName: String?
        let author: Actor?
        let viewerDidAuthor: Bool?
        let viewerCanUpdate: Bool?
        let viewerCanReopen: Bool?
        let viewerCanClose: Bool?
        let viewerCanAssign: Bool?
        let viewerCanLabel: Bool?
        let viewerCanSubscribe: Bool?
        let viewerSubscription: String?
        let reviewDecision: String?
        let changedFiles: Int?
        let additions: Int?
        let deletions: Int?
        let updatedAt: String?
        let mergedAt: String?
        let repository: Repository?
        let baseRef: BaseRef?
        let milestone: Milestone?
        let labels: Connection<Label>?
        let assignees: Connection<Actor>?
        let reviewRequests: Connection<ReviewRequest>?
        let reviews: Connection<Review>?
        /// Light-query aliases of `latestReviews` and PENDING `reviews`.
        let latest: Connection<Review>?
        let pending: Connection<Review>?
        let reviewThreads: Connection<Thread>?
        let comments: Connection<Comment>?
        let files: Connection<FileViewState>?
    }
    /// `data` of every write-reader query: the viewer, the pull request node and, for dismissal, the review.
    struct QueryData: Decodable {
        let viewer: Viewer?
        let node: PullRequestNode?
        let review: Review?
    }
    /// One applicable branch rule from `GET /repos/{owner}/{repo}/rules/branches/{branch}`.
    struct BranchRule: Decodable {
        struct Parameters: Decodable { let require_code_owner_review: Bool? }
        let type: String?
        let parameters: Parameters?
    }
}
