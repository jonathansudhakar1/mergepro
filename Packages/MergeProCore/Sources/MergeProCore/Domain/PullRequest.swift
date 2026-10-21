import Foundation

public struct PullRequest: Equatable, Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case open, closed, merged }
    public let key: ProviderKey
    public var id: ProviderKey { key }
    public let headRevision: RevisionID
    public let title: String
    public let state: State
    public let isDraft: Bool
    /// Optional to preserve v1 cached payload decoding. Unknown fields never imply eligibility.
    public let metadata: PRMetadata?
    public init(key: ProviderKey, headRevision: RevisionID, title: String, state: State, isDraft: Bool, metadata: PRMetadata? = nil) {
        self.key = key; self.headRevision = headRevision; self.title = title
        self.state = state; self.isDraft = isDraft; self.metadata = metadata
    }
    public var needsViewer: Bool { state == .open && (metadata?.requests.contains(where: { $0.isForViewer }) ?? false) }
}
public struct PRReviewRequest: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case direct, team }
    public var id: String
    public var name: String
    public var kind: Kind
    public enum ViewerStatus: String, Codable, Sendable { case needsReview, alreadyReviewed, unknown, notForViewer }
    public var viewerStatus: ViewerStatus?
    public var isForViewer: Bool
    public init(id: String, name: String, kind: Kind, isForViewer: Bool, viewerStatus: ViewerStatus? = nil) { self.viewerStatus = viewerStatus; self.id = id; self.name = name; self.kind = kind; self.isForViewer = isForViewer }
}
public struct PRMetadata: Equatable, Codable, Sendable {
    public var number: Int
    public var webURL: URL
    public var repositoryName: String
    public var descriptionPreview: String?
    public var authorID: String?
    public var authorLogin: String?
    public var actorType: String?
    public var viewerID: String?
    public var viewerIsAuthor = false
    public var headRepositoryID:String?
    public var headBranch = ""
    public var baseBranch = ""
    public var baseRevision = ""
    public var createdAt: Date?
    public var updatedAt: Date?
    /// Inventory updatedAt is not claimed to include every check/comment activity.
    public var lastActivityAt: Date?
    public var mergedAt: Date?
    public var fetchedAt: Date?
    public var columnChangedAt: Date?
    public var reviewDecision: String?
    public var requiredReviewCount: Int?
    public var approvalCount: Int?
    public var outstandingChanges: Bool?
    public var reviewEvidenceComplete = false
    public var requests: [PRReviewRequest] = []
    public var assignees: [String] = []
    public var reviewers: [String] = []
    public var labels: [String] = []
    /// Label name → 6-digit hex color from the inventory; optional so older cached rows decode.
    public var labelColors: [String: String]?
    public var checks: String?
    public var failingRequiredCheck: Bool?
    public var mergeable: String?
    public var autoMerge = false
    public var autoMergeKnown: Bool?
    public var files: Int?
    public var additions: Int?
    public var deletions: Int?
    public var comments: Int?
    public var partial = false
    /// Classification, risk and merge eligibility; absent means unknown.
    public var authorClassification: String?
    /// Agent-authorship signals: the head commit's `Co-authored-by:` trailers and the end of the body (where agents
    /// usually sign, e.g. "🤖 Generated with …"); nil when not read.
    public var coauthors: [String]?
    public var bodyTail: String?
    public var riskFlags: [String]?
    public var mergeEvidence: MergeEvidence?
    public var nativeStack: PRStack?
    public var mergeEligible: Bool?
    public init(number: Int, webURL: URL, repositoryName: String) { self.number = number; self.webURL = webURL; self.repositoryName = repositoryName }
    public var size: Int? { if let additions, let deletions { additions + deletions } else { nil } }
    public var sizeClass: String { guard let size else { return "Unknown" }; return size < 10 ? "XS" : size < 100 ? "S" : size < 500 ? "M" : size < 1000 ? "L" : "XL" }
    public var activityDate: Date? { lastActivityAt ?? updatedAt }
}
