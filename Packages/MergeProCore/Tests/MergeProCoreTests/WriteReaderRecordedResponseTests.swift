import XCTest
@testable import MergeProCore

/// Serves recorded GitHub responses: GraphQL by operation name (and connection field), REST by path.
actor RecordedGitHub: GitHubTransport {
    typealias Handler = @Sendable (_ path: String, _ query: String?, _ variables: [String: String]) -> GitHubResponse?
    private let handler: Handler
    private(set) var queries: [String] = []
    private(set) var paths: [String] = []
    init(_ handler: @escaping Handler) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> GitHubResponse {
        let path = request.url?.path ?? ""
        paths.append(path)
        var query: String?, variables: [String: String] = [:]
        if path == "/graphql", let body = request.httpBody, let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            query = envelope["query"] as? String
            for (name, value) in envelope["variables"] as? [String: Any] ?? [:] { if let value = value as? String { variables[name] = value } }
            queries.append(query ?? "")
        }
        guard let response = handler(path, query, variables) else { return GitHubResponse(status: 404, data: Data(#"{"message":"Not Found"}"#.utf8)) }
        return response
    }
}
func recorded(_ body: String, status: Int = 200, link: String? = nil) -> GitHubResponse {
    GitHubResponse(status: status, headers: link.map { ["Link": $0] } ?? [:], data: Data(body.utf8))
}

/// Recorded-response coverage for the full write reader: realistic GitHub payloads with nulls, missing
/// fields and partial GraphQL errors. A missing completeness or capability field stays unknown/denied.
final class WriteReaderRecordedResponseTests: XCTestCase {
    static let head = String(repeating: "a", count: 40), origin = String(repeating: "b", count: 40), target = String(repeating: "c", count: 40)
    let key = ProviderKey(host: "github.com", accountID: "42", repositoryID: "7", objectID: "PR_node")
    let credential = GitHubCredential(accessToken: "fixture", scopes: ["repo"])
    func command(_ intent: PRWriteIntent) -> PRWriteCommand {
        .init(key: key, repository: "o/r", number: 7, revision: .init(head: Self.head, origin: Self.origin, target: Self.target), intent: intent)
    }

    // MARK: Recorded payloads

    static let identity = """
    {"data":{"viewer":{"id":"U_viewer","databaseId":42,"login":"viewer"},
     "node":{"id":"PR_node","number":7,"url":"https://github.com/o/r/pull/7","title":"Fixture title","body":"Fixture body","state":"OPEN","isDraft":false,
      "headRefOid":"\(head)","baseRefOid":"\(target)","baseRefName":"main","headRefName":"feature","locked":false,
      "author":{"login":"author"},"viewerDidAuthor":false,"viewerCanUpdate":true,"viewerCanReopen":false,"viewerCanClose":true,"viewerCanAssign":true,"viewerCanLabel":true,
      "reviewDecision":"REVIEW_REQUIRED","changedFiles":2,"additions":5,"deletions":1,"updatedAt":"2026-10-01T10:00:00Z","mergedAt":null,
      "repository":{"databaseId":7,"nameWithOwner":"O/R","viewerPermission":"WRITE"},
      "baseRef":{"branchProtectionRule":{"requiresCodeOwnerReviews":true,"requiredApprovingReviewCount":2}},
      "milestone":null,
      "labels":{"nodes":[{"name":"bug","color":"d73a4a"},{"name":"docs","color":"0075ca"}],"pageInfo":{"hasNextPage":false}},
      "assignees":{"nodes":[{"login":"author"}],"pageInfo":{"hasNextPage":false}}},
     "rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-10-01T11:00:00Z"}}}
    """
    /// Same PR with nulls and absent fields: no protection rule, no label pageInfo, a further assignee page,
    /// no changed-file count, no close/assign capability, a deleted author and a merge time.
    static let sparseIdentity = """
    {"data":{"viewer":{"id":"U_viewer","databaseId":42,"login":"viewer"},
     "node":{"id":"PR_node","number":7,"url":null,"title":"Fixture title","body":null,"state":"MERGED","isDraft":true,
      "headRefOid":"\(head)","baseRefOid":"\(target)","baseRefName":"main","headRefName":"feature","locked":true,
      "author":null,"viewerDidAuthor":true,"viewerCanUpdate":false,
      "reviewDecision":null,"mergedAt":"2026-10-02T10:00:00Z","updatedAt":"2026-10-02T10:00:00Z",
      "repository":{"databaseId":7,"nameWithOwner":"o/r"},
      "baseRef":{"branchProtectionRule":null},
      "labels":{"nodes":[{"name":"bug","color":"d73a4a"}]},
      "assignees":{"nodes":[{"login":"author"}],"pageInfo":{"hasNextPage":true}}}}}
    """
    static let overview = #"{"body":"Fixture body","head":{"sha":"\#(head)"},"base":{"sha":"\#(target)"},"changed_files":2}"#
    static let files = #"""
    [{"sha":"1111111111111111111111111111111111111111","filename":"Sources/a.swift","status":"modified","additions":3,"deletions":1,"changes":4,"patch":"@@ -1,2 +1,4 @@\n line\n-old\n+new\n+added\n+more"},
     {"sha":"2222222222222222222222222222222222222222","filename":"README.md","status":"added","additions":2,"deletions":0,"changes":2,"patch":"@@ -0,0 +1,2 @@\n+a\n+b"}]
    """#
    static let compare = #"{"merge_base_commit":{"sha":"\#(origin)"}}"#
    static func connection(_ field: String, _ nodes: String, pageInfo: String? = #"{"hasNextPage":false,"endCursor":null}"#) -> String {
        #"{"data":{"node":{"id":"PR_node","headRefOid":"\#(head)","baseRefOid":"\#(target)","\#(field)":{"nodes":\#(nodes)\#(pageInfo.map { #","pageInfo":\#($0)"# } ?? "")}},"rateLimit":{"cost":1,"remaining":4998,"resetAt":"2026-10-01T11:00:00Z"}}}"#
    }
    static let reviews = """
    [{"id":"R1","body":"Looks good","state":"APPROVED","createdAt":"2026-10-01T09:00:00Z","submittedAt":"2026-10-01T09:00:00Z","author":{"login":"reviewer"},"commit":{"oid":"\(head)"}},
     {"id":"R2","body":"","state":"PENDING","createdAt":"2026-10-01T09:30:00Z","submittedAt":null,"author":{"login":"viewer"},"commit":{"oid":"\(head)"}},
     {"id":"R3","body":"Ghost review","state":"COMMENTED","createdAt":"2026-10-01T08:00:00Z","author":null,"commit":null}]
    """
    static let threads = """
    [{"id":"T1","path":"Sources/a.swift","subjectType":"LINE","line":2,"startLine":null,"diffSide":"RIGHT","startDiffSide":null,"originalLine":2,"originalStartLine":null,
      "isOutdated":false,"isResolved":false,"viewerCanReply":true,"viewerCanResolve":true,"viewerCanUnresolve":false,
      "comments":{"nodes":[{"id":"RC1","body":"Same text","url":"https://github.com/o/r/pull/7#discussion_r1","createdAt":"2099-01-01T00:00:00Z","author":{"login":"viewer"},
        "viewerDidAuthor":true,"viewerCanUpdate":true,"viewerCanDelete":true,"viewerCanReact":true,"viewerCanMinimize":false,"viewerCanUnminimize":false,"isMinimized":false,
        "reactionGroups":[],"commit":{"oid":"\(head)"},"originalCommit":{"oid":"\(head)"},"diffHunk":"@@ -1,2 +1,4 @@","line":2,"startLine":null,"originalLine":2,"originalStartLine":null,
        "pullRequestReview":null}],"pageInfo":{"hasNextPage":false,"endCursor":null}}},
     {"id":"T2","path":"README.md","subjectType":"FILE","line":null,"diffSide":"RIGHT","isOutdated":true,"isResolved":true,"viewerCanReply":false,"viewerCanResolve":false,"viewerCanUnresolve":true,
      "comments":{"nodes":[{"id":"RC2","body":"File note","createdAt":"2026-10-01T08:00:00Z","author":{"login":"reviewer"},"viewerDidAuthor":false,"isMinimized":true,
        "reactionGroups":[{"content":"HEART","viewerHasReacted":false}],"commit":null,"originalCommit":{"oid":"\(origin)"},"pullRequestReview":{"id":"R1"}}],
        "pageInfo":{"hasNextPage":false,"endCursor":"t2"}}}]
    """
    static let conversation = """
    [{"id":"IC1","body":"Same text","url":"https://github.com/o/r/pull/7#issuecomment-1","createdAt":"2099-01-01T00:00:00Z","author":{"login":"viewer"},
      "viewerDidAuthor":true,"viewerCanUpdate":true,"viewerCanDelete":true,"viewerCanReact":true,"viewerCanMinimize":true,"viewerCanUnminimize":false,"isMinimized":false,
      "reactionGroups":[{"content":"THUMBS_UP","viewerHasReacted":true},{"content":"HEART","viewerHasReacted":false}]},
     {"id":"IC2","body":"Older","url":null,"createdAt":"2020-01-01T00:00:00Z","author":{"login":"viewer"},"viewerDidAuthor":true,"viewerCanUpdate":false,"viewerCanDelete":false,"reactionGroups":[]}]
    """
    static let viewed = #"[{"path":"Sources/a.swift","viewerViewedState":"VIEWED"},{"path":"README.md","viewerViewedState":"UNVIEWED"}]"#
    static let requests = #"[{"requestedReviewer":{"__typename":"User","id":"U_req","login":"requested"}},{"requestedReviewer":{"__typename":"Team","id":"T_team","slug":"core","name":"Core"}},{"requestedReviewer":null}]"#
    static let after = #"{"data":{"viewer":{"databaseId":42},"node":{"id":"PR_node","headRefOid":"\#(head)","baseRefOid":"\#(target)"}}}"#
    static let rules = #"[{"type":"pull_request","ruleset_id":3,"parameters":{"require_code_owner_review":false,"required_approving_review_count":1}},{"type":"pull_request","parameters":{}},{"type":"deletion"}]"#

    struct Script: Sendable {
        var identity = WriteReaderRecordedResponseTests.identity
        var reviews: String = WriteReaderRecordedResponseTests.connection("reviews", WriteReaderRecordedResponseTests.reviews)
        var threads: String = WriteReaderRecordedResponseTests.connection("reviewThreads", WriteReaderRecordedResponseTests.threads)
        var conversation: String = WriteReaderRecordedResponseTests.connection("comments", WriteReaderRecordedResponseTests.conversation)
        var viewed: String = WriteReaderRecordedResponseTests.connection("files", WriteReaderRecordedResponseTests.viewed)
        var requests: String = WriteReaderRecordedResponseTests.connection("reviewRequests", WriteReaderRecordedResponseTests.requests)
        var after = WriteReaderRecordedResponseTests.after
        var rules = recorded(WriteReaderRecordedResponseTests.rules)
    }
    func transport(_ script: Script) -> RecordedGitHub {
        RecordedGitHub { path, query, _ in
            if let query {
                if query.contains("WriteIdentity") { return recorded(script.identity) }
                if query.contains("WriteAfter") { return recorded(script.after) }
                if query.contains("reviewThreads(first:") { return recorded(script.threads) }
                if query.contains("reviews(first:") { return recorded(script.reviews) }
                if query.contains("comments(first:") { return recorded(script.conversation) }
                if query.contains("files(first:") { return recorded(script.viewed) }
                if query.contains("reviewRequests(first:") { return recorded(script.requests) }
                return nil
            }
            switch path {
            case "/repos/o/r/pulls/7": return recorded(Self.overview)
            case "/repos/o/r/pulls/7/files": return recorded(Self.files)
            case "/repos/o/r/compare/\(Self.target)...\(Self.head)": return recorded(Self.compare)
            case "/repos/o/r/rules/branches/main": return script.rules
            default: return nil
            }
        }
    }
    func read(_ intent: PRWriteIntent, _ script: Script = Script(), operation: Bool = false) async throws -> PRWriteTruth {
        let command = command(intent)
        return try await GitHubPRWriteReader(client: .init(transport: transport(script)), credential: credential).read(command, operation: operation ? PRWriteOperation(command: command) : nil)
    }

    /// Every field the reader derives, in a stable order.
    func summary(_ t: PRWriteTruth) -> [String] {
        func set(_ value: Set<String>) -> String { value.sorted().joined(separator: ",") }
        func date(_ value: Date?) -> String { value.map { String($0.timeIntervalSince1970) } ?? "nil" }
        var lines = [
            "revision=\(t.revision.head == Self.head)/\(t.revision.origin == Self.origin)/\(t.revision.target == Self.target)",
            "author=\(t.viewerIsAuthor) review=\(t.canReview) comment=\(t.canComment) update=\(t.canUpdate) reopen=\(t.canReopen) label=\(t.canLabel) open=\(t.isOpen)",
            "close=\(t.canClose) assign=\(t.canAssign) requestReviews=\(t.canRequestReviews) draft=\(t.canChangeDraft)",
            "pending=\(t.pendingReviewID ?? "nil") pendingHead=\(t.pendingReviewHead.map { $0 == Self.head ? "head" : $0 } ?? "nil")",
            "files=\(set(t.files)) viewed=\(set(t.viewed)) filesComplete=\(t.filesComplete) risk=\(t.riskFlagged)",
            "own=\(set(t.ownCommentIDs)) allowed=\(set(t.allowedObjectIDs)) threadIDs=\(set(t.threadIDs)) existing=\(set(t.existingObjectIDs))",
            "threadsComplete=\(t.threadsComplete) requestsComplete=\(t.requestsComplete) labelsComplete=\(t.labelsComplete) assigneesComplete=\(t.assigneesComplete)",
            "affected=\(set(t.affectedReviewRequestIDs)) matches=\(t.matchingOperationIDs.joined(separator: ",")) placed=\(t.placementConfirmed) outdated=\(t.placementOutdated)",
            "codeOwner=\(t.codeOwnerRequirements ?? "nil")",
        ]
        for thread in t.threads {
            lines.append("thread \(thread.id) path=\(thread.path) resolved=\(thread.resolved) outdated=\(thread.outdated) reply=\(thread.canReply) resolve=\(thread.canResolve) unresolve=\(thread.canUnresolve) complete=\(thread.complete)")
            for c in thread.comments { lines.append("  " + comment(c)) }
        }
        for c in t.conversation { lines.append("conversation " + comment(c)) }
        if let pr = t.normalized, let m = pr.metadata {
            lines.append("pr title=\(pr.title) state=\(pr.state) draft=\(pr.isDraft) head=\(pr.headRevision.rawValue == Self.head)")
            lines.append("meta url=\(m.webURL.absoluteString) viewer=\(m.viewerID ?? "nil") viewerIsAuthor=\(m.viewerIsAuthor) author=\(m.authorLogin ?? "nil") head=\(m.headBranch) base=\(m.baseBranch) baseRevision=\(m.baseRevision == Self.target)")
            lines.append("meta labels=\(m.labels.joined(separator: ",")) colors=\(m.labelColors.map { $0.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",") } ?? "nil") assignees=\(m.assignees.joined(separator: ","))")
            lines.append("meta decision=\(m.reviewDecision ?? "nil") files=\(m.files.map(String.init) ?? "nil") +\(m.additions.map(String.init) ?? "nil") -\(m.deletions.map(String.init) ?? "nil") required=\(m.requiredReviewCount.map(String.init) ?? "nil") partial=\(m.partial)")
            lines.append("meta updated=\(date(m.updatedAt)) merged=\(date(m.mergedAt))")
            lines.append("meta requests=\(m.requests.map { "\($0.id)/\($0.name)/\($0.kind)/\($0.isForViewer)/\($0.viewerStatus.map { "\($0)" } ?? "nil")" }.joined(separator: ",")) reviewers=\(m.reviewers.joined(separator: ","))")
        }
        return lines
    }
    func comment(_ c: PRWritableComment) -> String {
        let coordinates = c.coordinates.map { "\($0.path ?? "nil")@\($0.current.reviewedHeadSHA.map { $0 == Self.head ? "head" : $0 == Self.origin ? "origin" : $0 } ?? "nil"):\($0.current.startLine.map(String.init) ?? "nil")-\($0.current.endLine.map(String.init) ?? "nil")/\($0.current.side ?? "nil")|orig \($0.original.reviewedHeadSHA.map { $0 == Self.head ? "head" : $0 == Self.origin ? "origin" : $0 } ?? "nil"):\($0.original.startLine.map(String.init) ?? "nil")-\($0.original.endLine.map(String.init) ?? "nil")" } ?? "nil"
        return "\(c.id) body=\(c.body) author=\(c.author ?? "nil") url=\(c.url?.absoluteString ?? "nil") kind=\(c.kind) own=\(c.own) edit=\(c.canEdit) delete=\(c.canDelete) react=\(c.canReact) moderate=\(c.canModerate) unminimize=\(c.canUnminimize) minimized=\(c.minimized) review=\(c.reviewID ?? "nil") hunk=\(c.diffHunk ?? "nil") at=\(coordinates)"
    }

    // MARK: Tests

    func testRecordedReadDerivesEveryField() async throws {
        let truth = try await read(.metadata(.reviewers(users: ["requested"], teams: ["core"], remove: false)), operation: true)
        XCTAssertEqual(summary(truth), Self.expectedFull)
    }
    func testSparseIdentityKeepsMissingFieldsUnknown() async throws {
        var script = Script()
        script.identity = Self.sparseIdentity
        script.reviews = Self.connection("reviews", Self.reviews, pageInfo: nil)
        script.threads = Self.connection("reviewThreads", Self.threads.replacingOccurrences(of: #"{"hasNextPage":false,"endCursor":"t2"}"#, with: #"{"hasNextPage":true,"endCursor":"t2"}"#))
        script.rules = recorded(Self.rules, link: #"<https://api.github.com/repositories/7/rules/branches/main?page=2>; rel="next""#)
        let truth = try await read(.metadata(.labels(["bug"])), script, operation: true)
        XCTAssertEqual(summary(truth), Self.expectedSparse)
    }
    /// A conversation write matches only the issue comment, never a review comment with the same text
    /// (a review comment always carries the `pullRequestReview` key, even when null).
    func testConversationMatchExcludesReviewComments() async throws {
        let truth = try await read(.conversation("Same text"), operation: true)
        XCTAssertEqual(truth.matchingOperationIDs, ["IC1"])
        let reply = try await read(.reply(threadID: "T1", body: "Same text", pendingReviewID: nil), operation: true)
        XCTAssertEqual(reply.matchingOperationIDs, ["RC1"])
        XCTAssertEqual(reply.allowedObjectIDs, ["T1"])
    }
    func testObjectCapabilitiesComeFromTheirOwnFields() async throws {
        let cases: [(PRWriteIntent, Set<String>, [String])] = [
            (.reaction(subjectID: "IC1", reaction: .thumbsUp, remove: false), ["IC1"], ["IC1"]),
            (.reaction(subjectID: "RC2", reaction: .heart, remove: true), [], ["RC2"]),
            (.editComment(id: "IC1", kind: .conversation, body: "Same text"), ["IC1"], ["IC1"]),
            (.editComment(id: "IC2", kind: .conversation, body: "Older"), [], ["IC2"]),
            (.deleteComment(id: "RC1", kind: .review), ["RC1"], []),
            (.resolve(threadID: "T1", resolved: true), ["T1"], []),
            (.resolve(threadID: "T2", resolved: false), ["T2"], []),
            (.moderate(subjectID: "IC1", classifier: "OFF_TOPIC"), ["IC1"], []),
            (.moderate(subjectID: "RC2", classifier: nil), [], []),
            (.metadata(.closed(true)), [], []),
            (.metadata(.assignees(["author"])), [], ["PR_node"]),
            (.metadata(.milestone(nil)), [], ["PR_node"]),
            (.viewed(path: "Sources/a.swift", viewed: true), [], ["PR_node"]),
            (.viewed(path: "README.md", viewed: true), [], []),
        ]
        for (intent, allowed, matches) in cases {
            let truth = try await read(intent, operation: true)
            XCTAssertEqual(truth.allowedObjectIDs, allowed, "\(intent)")
            XCTAssertEqual(truth.matchingOperationIDs, matches, "\(intent)")
        }
        let close = try await read(.metadata(.closed(true)))
        XCTAssertTrue(close.canUpdate)
        let assign = try await read(.metadata(.assignees([])))
        XCTAssertTrue(assign.canUpdate)
    }
    func testPartialGraphQLErrorsAndIdentityChangesAreRejected() async throws {
        for (identity, expected) in [
            (#"{"data":{"viewer":{"id":"U_viewer","databaseId":42,"login":"viewer"},"node":null},"errors":[{"type":"NOT_FOUND","path":["node"],"message":"Could not resolve"}]}"#, PRWriteFailure.unavailable),
            (#"{"data":{},"errors":[]}"#, .unavailable),
            (#"{"data":{},"errors":null}"#, .unavailable),
            (#"{"errors":[{"message":"Something went wrong"}]}"#, .unavailable),
            (#"{"data":null}"#, .unavailable),
            (Self.identity.replacingOccurrences(of: #""databaseId":42"#, with: #""databaseId":43"#), .accountChanged),
            (Self.identity.replacingOccurrences(of: #""number":7"#, with: #""number":8"#), .accountChanged),
            (Self.identity.replacingOccurrences(of: #""nameWithOwner":"O/R""#, with: #""nameWithOwner":"o/other""#), .accountChanged),
            (Self.identity.replacingOccurrences(of: #""login":"viewer""#, with: #""login":null"#), .accountChanged),
            (#"{"data":{"viewer":{"id":"U_viewer","databaseId":42,"login":"viewer"},"node":null}}"#, .accountChanged),
        ] {
            var script = Script()
            script.identity = identity
            do { _ = try await read(.conversation("x"), script); XCTFail(identity) } catch { XCTAssertEqual(error as? PRWriteFailure, expected, identity) }
        }
        var partial = Script()
        partial.threads = #"{"data":{"node":{"id":"PR_node","reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false}}}},"errors":[{"message":"timeout"}]}"#
        do { _ = try await read(.conversation("x"), partial); XCTFail("partial connection accepted") } catch { XCTAssertEqual(error as? PRWriteFailure, .unavailable) }
        var moved = Script()
        moved.after = Self.after.replacingOccurrences(of: Self.head, with: Self.origin)
        do { _ = try await read(.conversation("x"), moved); XCTFail("moved head accepted") } catch { XCTAssertEqual(error as? PRWriteFailure, .revisionChanged) }
        var foreign = Script()
        foreign.reviews = Self.connection("reviews", "[]").replacingOccurrences(of: #""id":"PR_node""#, with: #""id":"PR_other""#)
        do { _ = try await read(.conversation("x"), foreign); XCTFail("foreign connection accepted") } catch { XCTAssertEqual(error as? PRWriteFailure, .unavailable) }
        var twoPending = Script()
        twoPending.reviews = Self.connection("reviews", Self.reviews.replacingOccurrences(of: #""R1","body":"Looks good","state":"APPROVED""#, with: #""R1","body":"Looks good","state":"PENDING""#).replacingOccurrences(of: #""author":{"login":"reviewer"}"#, with: #""author":{"login":"viewer"}"#))
        do { _ = try await read(.conversation("x"), twoPending); XCTFail("two pending reviews accepted") } catch { XCTAssertEqual(error as? PRWriteFailure, .pendingExists) }
    }
    /// Connection completeness: a missing pageInfo, a further page or a repeated cursor is incomplete.
    func testConnectionCompleteness() async throws {
        var noPageInfo = Script()
        noPageInfo.requests = Self.connection("reviewRequests", Self.requests, pageInfo: nil)
        let missing = try await read(.conversation("x"), noPageInfo)
        XCTAssertFalse(missing.requestsComplete)
        XCTAssertTrue(missing.normalized?.metadata?.partial == true)
        var repeated = Script()
        repeated.viewed = Self.connection("files", Self.viewed, pageInfo: #"{"hasNextPage":true,"endCursor":null}"#)
        let stuck = try await read(.conversation("x"), repeated)
        XCTAssertFalse(stuck.filesComplete)
        var absentFlag = Script()
        absentFlag.viewed = Self.connection("files", Self.viewed, pageInfo: "{}")
        let flagless = try await read(.conversation("x"), absentFlag)
        XCTAssertEqual(flagless.viewed, ["Sources/a.swift"])
    }
    func testBranchRuleFailuresDegradeOnlyTheCodeOwnerSummary() async throws {
        var failing = Script()
        failing.rules = recorded(#"{"message":"Server Error"}"#, status: 500)
        let truth = try await read(.conversation("x"), failing)
        XCTAssertEqual(truth.codeOwnerRequirements, "Classic protection requires CODEOWNERS: true; effective rules unavailable")
        var revoked = Script()
        revoked.rules = recorded(#"{"message":"Bad credentials"}"#, status: 401)
        do { _ = try await read(.conversation("x"), revoked); XCTFail("401 swallowed") } catch { XCTAssertEqual(error as? GitHubFailure, .invalidAuthentication) }
    }

    /// A null pageInfo is unknown, not complete; a null list element is dropped and leaves its list incomplete.
    func testNullPageInfoIsIncompleteAndNullNodesLeaveTheListIncomplete() async throws {
        var nullPageInfo = Script()
        nullPageInfo.requests = Self.connection("reviewRequests", Self.requests, pageInfo: "null")
        nullPageInfo.identity = Self.identity.replacingOccurrences(of: #""labels":{"nodes":[{"name":"bug","color":"d73a4a"},{"name":"docs","color":"0075ca"}],"pageInfo":{"hasNextPage":false}}"#, with: #""labels":{"nodes":[],"pageInfo":null}"#)
        let truth = try await read(.conversation("x"), nullPageInfo)
        XCTAssertFalse(truth.requestsComplete)
        XCTAssertFalse(truth.labelsComplete)
        XCTAssertNil(truth.normalized?.metadata?.labelColors)
        var nullNode = Script()
        nullNode.conversation = Self.connection("comments", "[null]")
        let dropped = try await read(.conversation("x"), nullNode)
        XCTAssertTrue(dropped.conversation.isEmpty)
        XCTAssertFalse(dropped.threadsComplete, "one unreadable entry leaves the conversation incomplete, never the whole read unavailable")
        var wrongType = Script()
        wrongType.identity = Self.identity.replacingOccurrences(of: #""changedFiles":2"#, with: #""changedFiles":"two""#)
        do { _ = try await read(.conversation("x"), wrongType); XCTFail("mistyped field accepted") } catch { XCTAssertEqual(error as? PRWriteFailure, .unavailable) }
    }
    /// Provider timestamps with fractional seconds now parse (formerly dropped as unknown).
    func testFractionalTimestampsParse() async throws {
        var script = Script()
        script.identity = Self.identity.replacingOccurrences(of: #""updatedAt":"2026-10-01T10:00:00Z""#, with: #""updatedAt":"2026-10-01T10:00:00.500Z""#)
        script.conversation = Self.connection("comments", Self.conversation.replacingOccurrences(of: "2099-01-01T00:00:00Z", with: "2099-01-01T00:00:00.123Z"))
        let truth = try await read(.conversation("Same text"), script, operation: true)
        XCTAssertEqual(truth.normalized?.metadata?.updatedAt, Date(timeIntervalSince1970: 1_790_848_800.5))
        XCTAssertEqual(truth.matchingOperationIDs, ["IC1"])
    }

    static let expectedFull: [String] = [
        "revision=true/true/true",
        "author=false review=true comment=true update=true reopen=false label=true open=true",
        "close=true assign=true requestReviews=true draft=true",
        "pending=R2 pendingHead=head",
        "files=README.md,Sources/a.swift viewed=Sources/a.swift filesComplete=true risk=true",
        "own=IC1,IC2,RC1 allowed= threadIDs=T1,T2 existing=IC1,IC2,R1,R2,R3,RC1,RC2,T1,T2",
        "threadsComplete=true requestsComplete=true labelsComplete=true assigneesComplete=true",
        "affected=T_team,U_req matches=PR_node placed=true outdated=false",
        "codeOwner=Classic protection requires CODEOWNERS: true; effective rules CODEOWNERS: false, unknown",
        "thread T1 path=Sources/a.swift resolved=false outdated=false reply=true resolve=true unresolve=false complete=true",
        "  RC1 body=Same text author=viewer url=https://github.com/o/r/pull/7#discussion_r1 kind=review own=true edit=true delete=true react=true moderate=false unminimize=false minimized=false review=nil hunk=@@ -1,2 +1,4 @@ at=Sources/a.swift@head:nil-2/RIGHT|orig head:nil-2",
        "thread T2 path=README.md resolved=true outdated=true reply=false resolve=false unresolve=true complete=true",
        "  RC2 body=File note author=reviewer url=nil kind=review own=false edit=false delete=false react=false moderate=false unminimize=false minimized=true review=R1 hunk=nil at=README.md@nil:nil-nil/RIGHT|orig origin:nil-nil",
        "conversation IC1 body=Same text author=viewer url=https://github.com/o/r/pull/7#issuecomment-1 kind=conversation own=true edit=true delete=true react=true moderate=true unminimize=false minimized=false review=nil hunk=nil at=nil",
        "conversation IC2 body=Older author=viewer url=nil kind=conversation own=true edit=false delete=false react=false moderate=false unminimize=false minimized=false review=nil hunk=nil at=nil",
        "pr title=Fixture title state=open draft=false head=true",
        "meta url=https://github.com/o/r/pull/7 viewer=U_viewer viewerIsAuthor=false author=author head=feature base=main baseRevision=true",
        "meta labels=bug,docs colors=bug:d73a4a,docs:0075ca assignees=author",
        "meta decision=REVIEW_REQUIRED files=2 +5 -1 required=2 partial=false",
        "meta updated=1790848800.0 merged=nil",
        "meta requests=U_req/requested/direct/false/notForViewer,T_team/Core/team/false/unknown reviewers=Core,requested,reviewer,viewer",
    ]
    static let expectedSparse: [String] = [
        "revision=true/true/true",
        "author=true review=false comment=false update=false reopen=false label=false open=false",
        "close=false assign=false requestReviews=false draft=false",
        "pending=R2 pendingHead=head",
        "files=README.md,Sources/a.swift viewed=Sources/a.swift filesComplete=true risk=true",
        "own=IC1,IC2,RC1 allowed= threadIDs=T1,T2 existing=IC1,IC2,R1,R2,R3,RC1,RC2,T1,T2",
        "threadsComplete=false requestsComplete=true labelsComplete=false assigneesComplete=false",
        "affected= matches= placed=true outdated=false",
        "codeOwner=Classic CODEOWNERS requirement unavailable; effective rules CODEOWNERS: false, unknown (partial; more rules unavailable)",
        "thread T1 path=Sources/a.swift resolved=false outdated=false reply=true resolve=true unresolve=false complete=true",
        "  RC1 body=Same text author=viewer url=https://github.com/o/r/pull/7#discussion_r1 kind=review own=true edit=true delete=true react=true moderate=false unminimize=false minimized=false review=nil hunk=@@ -1,2 +1,4 @@ at=Sources/a.swift@head:nil-2/RIGHT|orig head:nil-2",
        "thread T2 path=README.md resolved=true outdated=true reply=false resolve=false unresolve=true complete=false",
        "  RC2 body=File note author=reviewer url=nil kind=review own=false edit=false delete=false react=false moderate=false unminimize=false minimized=true review=R1 hunk=nil at=README.md@nil:nil-nil/RIGHT|orig origin:nil-nil",
        "conversation IC1 body=Same text author=viewer url=https://github.com/o/r/pull/7#issuecomment-1 kind=conversation own=true edit=true delete=true react=true moderate=true unminimize=false minimized=false review=nil hunk=nil at=nil",
        "conversation IC2 body=Older author=viewer url=nil kind=conversation own=true edit=false delete=false react=false moderate=false unminimize=false minimized=false review=nil hunk=nil at=nil",
        "pr title=Fixture title state=merged draft=true head=true",
        "meta url=https://github.com/o/r/pull/7 viewer=U_viewer viewerIsAuthor=true author=nil head=feature base=main baseRevision=true",
        "meta labels=bug colors=nil assignees=author",
        "meta decision=nil files=nil +nil -nil required=nil partial=true",
        "meta updated=1790935200.0 merged=1790935200.0",
        "meta requests=U_req/requested/direct/false/notForViewer,T_team/Core/team/false/unknown reviewers=Core,requested,reviewer,viewer",
    ]
}
