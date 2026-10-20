import XCTest
@testable import MergeProCore

/// Recorded-response coverage for the light label/assignee and review-administration readers: one
/// identity-checked GraphQL read whose nulls, missing pageInfo and partial errors stay explicit.
final class LightReaderRecordedResponseTests: XCTestCase {
    static let head = String(repeating: "a", count: 40), target = String(repeating: "c", count: 40)
    let key = ProviderKey(host: "github.com", accountID: "42", repositoryID: "7", objectID: "PR_node")
    let credential = GitHubCredential(accessToken: "fixture", scopes: ["repo"])
    var pr: PullRequest { PullRequest(key: key, headRevision: .init(Self.head), title: "Fixture", state: .open, isDraft: false, metadata: PRMetadata(number: 7, webURL: URL(string: "https://github.com/o/r/pull/7")!, repositoryName: "o/r")) }
    func command(_ intent: PRWriteIntent) -> PRWriteCommand { .init(key: key, repository: "o/r", number: 7, revision: .init(head: Self.head, origin: "", target: Self.target), intent: intent) }

    static let reviewR1 = #"{"id":"R1","state":"APPROVED","submittedAt":"2026-10-01T09:00:00Z","viewerDidAuthor":false,"viewerCanDelete":false,"author":{"login":"bob","id":"U2"},"commit":{"oid":"\#(head)"},"pullRequest":{"id":"PR_node"}}"#
    static let reviews = """
    [\(reviewR1),
     {"id":"R2","state":"PENDING","submittedAt":null,"viewerDidAuthor":true,"viewerCanDelete":true,"author":{"login":"viewer","id":"U_viewer"},"commit":{"oid":"\(head)"}},
     {"id":"R3","state":"CHANGES_REQUESTED","submittedAt":"2026-10-01T08:00:00Z","viewerDidAuthor":false,"author":{"login":"ghost-bot"},"commit":null},
     {"id":"R4","state":"SOMETHING_NEW","viewerDidAuthor":false},
     {"state":"COMMENTED","viewerDidAuthor":false}]
    """
    struct Fixture: Sendable {
        var permission: String? = "TRIAGE"
        var rule = #"{"restrictsReviewDismissals":true}"#
        var labelsPageInfo: String? = #"{"hasNextPage":false}"#
        var review: String? = LightReaderRecordedResponseTests.reviewR1
        var errors: String?
        var viewer = #"{"id":"U_viewer","databaseId":42,"login":"viewer"}"#
        var number = 7
        var headRefOid: String? = LightReaderRecordedResponseTests.head
        var prLabelNodes = #"[{"id":"L1","name":"bug","color":"cccccc"},{"id":null,"name":"orphan","color":null}]"#
    }
    func body(_ f: Fixture, review requested: Bool) -> String {
        let node = """
        {"id":"PR_node","number":\(f.number),"state":"OPEN",\(f.headRefOid.map { #""headRefOid":"\#($0)","# } ?? "")"baseRefOid":"\(Self.target)","viewerDidAuthor":false,
         "repository":{"databaseId":7,"nameWithOwner":"o/r"\(f.permission.map { #","viewerPermission":"\#($0)""# } ?? ""),
           "labels":{"nodes":[{"id":"L1","name":"bug","color":"d73a4a"},{"id":"L2","name":"docs","color":"0075ca"},{"id":"L3","name":null,"color":"ffffff"}],"pageInfo":{"hasNextPage":true}},
           "assignableUsers":{"nodes":[{"id":"U1","login":"alice"},{"id":"U2","login":null}],"pageInfo":{"hasNextPage":false}}},
         "viewerCanLabel":true,"labels":{"nodes":\(f.prLabelNodes)\(f.labelsPageInfo.map { #","pageInfo":\#($0)"# } ?? "")},
         "viewerCanAssign":false,"assignees":{"nodes":[{"id":"U1","login":"alice"}]},
         "reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","id":"U2","login":"bob"}},{"requestedReviewer":{"__typename":"Team","id":"T1","slug":"core","name":"Core"}},
           {"requestedReviewer":{"__typename":"Team","id":"T2","name":"No slug"}},{"requestedReviewer":{"__typename":"Mannequin"}},{"requestedReviewer":null}],"pageInfo":{"hasNextPage":false}},
         "latest":{"nodes":\(Self.reviews),"pageInfo":{"hasNextPage":false}},
         "pending":{"nodes":\(Self.reviews),"pageInfo":{"hasNextPage":false}},
         "reviews":{"nodes":\(Self.reviews),"pageInfo":{"hasPreviousPage":true}},
         "reviewDecision":"APPROVED","baseRef":{"branchProtectionRule":\(f.rule)},
         "viewerCanSubscribe":true,"viewerSubscription":"SUBSCRIBED"}
        """
        let review = requested ? #","review":\#(f.review ?? "null")"# : ""
        return #"{"data":{"viewer":\#(f.viewer),"node":\#(node)\#(review),"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-10-07T00:00:00Z"}}\#(f.errors.map { #","errors":\#($0)"# } ?? "")}"#
    }
    func transport(_ f: Fixture) -> RecordedGitHub {
        let text = (body(f, review: false), body(f, review: true))
        return RecordedGitHub { _, query, variables in
            guard query?.contains("PRWriteLight") == true else { return nil }
            return recorded(variables["review"] == nil ? text.0 : text.1)
        }
    }
    func labels(_ f: Fixture = Fixture()) -> GitHubPRLabelReader { .init(client: .init(transport: transport(f)), credential: credential) }
    func admin(_ f: Fixture = Fixture()) -> GitHubPRReviewAdministrationReader { .init(client: .init(transport: transport(f)), credential: credential) }
    func ids(_ reviews: [PRReviewSummary]) -> [String] { reviews.map { "\($0.id):\($0.state.rawValue):\($0.authorLogin ?? "nil"):\($0.authorID ?? "nil"):\($0.submittedAt.map { String($0.timeIntervalSince1970) } ?? "nil"):\($0.commitOID == Self.head ? "head" : "nil"):\($0.viewerDidAuthor):\($0.viewerCanDismiss.map(String.init) ?? "nil"):\($0.viewerCanDiscard)" } }

    func testLabelDeltaReadsRefsColorsAndCompleteness() async throws {
        let c = command(.metadata(.labelChanges(add: [.init(id: "L1", name: "bug")], remove: [.init(id: "L2", name: "docs")])))
        let truth = try await labels().read(c, operation: PRWriteOperation(command: c))
        XCTAssertTrue(truth.canLabel); XCTAssertTrue(truth.isOpen); XCTAssertFalse(truth.viewerIsAuthor)
        XCTAssertEqual(truth.labelRefs, [.init(id: "L1", name: "bug")])
        XCTAssertEqual(truth.labelColors, ["bug": "cccccc"])
        XCTAssertTrue(truth.labelsComplete)
        XCTAssertEqual(truth.matchingOperationIDs, ["PR_node"])
        XCTAssertEqual(truth.revision, .init(head: Self.head, origin: "", target: Self.target))
        XCTAssertFalse(truth.canUpdate || truth.canReview || truth.canComment || truth.canReopen, "a light read grants nothing it did not read")
        for pageInfo in [nil, #"{"hasNextPage":true}"#] {
            var partial = Fixture(); partial.labelsPageInfo = pageInfo
            let incomplete = try await labels(partial).read(c, operation: PRWriteOperation(command: c))
            XCTAssertFalse(incomplete.labelsComplete, pageInfo ?? "missing pageInfo")
            XCTAssertEqual(incomplete.matchingOperationIDs, [])
        }
        var flagless = Fixture(); flagless.labelsPageInfo = "{}"
        let present = try await labels(flagless).read(c, operation: nil)
        XCTAssertTrue(present.labelsComplete, "pageInfo without a next page is complete")
    }
    /// One null entry (a label the token cannot see) no longer fails the whole read: it is dropped and the
    /// connection is reported incomplete, so pickers and confirmations treat the list as partial.
    func testNullConnectionEntryIsDroppedAndMarksTheListIncomplete() async throws {
        var fixture = Fixture()
        fixture.prLabelNodes = #"[null,{"id":"L1","name":"bug","color":"cccccc"}]"#
        let options = try await labels(fixture).options(pr)
        XCTAssertEqual(options.labels, [.init(id: "L1", name: "bug")])
        XCTAssertFalse(options.labelsComplete, "a dropped null entry is unknown, not absent")
        let c = command(.metadata(.labelChanges(add: [.init(id: "L1", name: "bug")], remove: [])))
        let truth = try await labels(fixture).read(c, operation: PRWriteOperation(command: c))
        XCTAssertEqual(truth.labelRefs, [.init(id: "L1", name: "bug")])
        XCTAssertFalse(truth.labelsComplete)
        XCTAssertEqual(truth.matchingOperationIDs, [], "an incomplete list confirms nothing")
        let decoded = try JSONDecoder().decode(PRWriteReadPayload.Connection<PRWriteReadPayload.Label>.self,
                                               from: Data(#"{"nodes":[null,{"name":"a"}],"pageInfo":{"hasNextPage":false}}"#.utf8))
        XCTAssertEqual(decoded.values.compactMap(\.name), ["a"])
        XCTAssertFalse(decoded.complete())
        let clean = try JSONDecoder().decode(PRWriteReadPayload.Connection<PRWriteReadPayload.Label>.self,
                                             from: Data(#"{"nodes":[{"name":"a"}],"pageInfo":{"hasNextPage":false}}"#.utf8))
        XCTAssertTrue(clean.complete())
    }
    func testAssigneeDeltaWithoutPageInfoStaysIncomplete() async throws {
        let c = command(.metadata(.assigneeChanges(add: [.init(id: "U1", login: "alice")], remove: [])))
        let truth = try await labels().read(c, operation: PRWriteOperation(command: c))
        XCTAssertFalse(truth.canAssign)
        XCTAssertEqual(truth.assigneeRefs, [.init(id: "U1", login: "alice")])
        XCTAssertFalse(truth.assigneesComplete)
        XCTAssertEqual(truth.matchingOperationIDs, [])
    }
    func testPickerOptions() async throws {
        let options = try await labels().options(pr)
        XCTAssertEqual(options.labels, [.init(id: "L1", name: "bug")]); XCTAssertTrue(options.labelsComplete)
        XCTAssertEqual(options.availableLabels, [.init(id: "L1", name: "bug"), .init(id: "L2", name: "docs")]); XCTAssertFalse(options.availableLabelsComplete)
        XCTAssertEqual(options.labelColors, ["bug": "cccccc", "docs": "0075ca"])
        XCTAssertEqual(options.assignees, [.init(id: "U1", login: "alice")]); XCTAssertFalse(options.assigneesComplete)
        XCTAssertEqual(options.assignableUsers, [.init(id: "U1", login: "alice")]); XCTAssertTrue(options.assignableUsersComplete)
        XCTAssertTrue(options.canLabel); XCTAssertFalse(options.canAssign)
    }
    func testReviewRequestDeltaAndLatestReviews() async throws {
        let c = command(.metadata(.reviewRequestChanges(addUsers: [.init(id: "U2", login: "bob")], addTeams: [], removeUsers: [.init(id: "U3", login: "carol")], removeTeams: [])))
        let truth = try await admin().read(c, operation: PRWriteOperation(command: c))
        XCTAssertTrue(truth.canRequestReviews)
        XCTAssertEqual(truth.requestedUsers, [.init(id: "U2", login: "bob")])
        XCTAssertEqual(truth.requestedTeams, [.init(id: "T1", slug: "core")])
        XCTAssertTrue(truth.requestsComplete); XCTAssertTrue(truth.reviewsComplete)
        XCTAssertEqual(ids(truth.reviews), [
            "R1:APPROVED:bob:U2:1790845200.0:head:false:false:false",
            "R2:PENDING:viewer:U_viewer:nil:head:true:false:true",
            "R3:CHANGES_REQUESTED:ghost-bot:nil:1790841600.0:nil:false:false:false",
            "R4:UNKNOWN:nil:nil:nil:nil:false:false:false",
        ])
        XCTAssertEqual(truth.matchingOperationIDs, ["PR_node"])
        var unknownRole = Fixture(); unknownRole.permission = nil
        let denied = try await admin(unknownRole).read(c, operation: nil)
        XCTAssertFalse(denied.canRequestReviews)
        XCTAssertEqual(denied.reviews.first?.viewerCanDismiss, nil, "unknown permission keeps dismissal unknown")
    }
    func testDiscardPendingReview() async throws {
        let c = command(.discardPendingReview(reviewID: "R2"))
        let truth = try await admin().read(c, operation: PRWriteOperation(command: c))
        XCTAssertEqual(truth.allowedObjectIDs, ["R2"])
        XCTAssertEqual(truth.pendingReviewID, "R2"); XCTAssertEqual(truth.pendingReviewHead, Self.head)
        XCTAssertTrue(truth.reviewsComplete); XCTAssertEqual(truth.matchingOperationIDs, [])
        let gone = command(.discardPendingReview(reviewID: "R9"))
        let absent = try await admin().read(gone, operation: PRWriteOperation(command: gone))
        XCTAssertEqual(absent.allowedObjectIDs, []); XCTAssertEqual(absent.matchingOperationIDs, ["R9"])
    }
    func testDismissalCapabilityStaysUnknownUnlessProven() async throws {
        let c = command(.dismissReview(reviewID: "R1", message: "stale"))
        for (permission, rule, allowed, dismiss) in [
            ("TRIAGE", #"{"restrictsReviewDismissals":false}"#, false, false as Bool?),
            ("WRITE", #"{"restrictsReviewDismissals":true}"#, true, nil),
            ("WRITE", "null", true, nil),
            ("WRITE", #"{"restrictsReviewDismissals":false}"#, true, true),
            ("WRITE", "{}", true, nil),
            ("ADMIN", #"{"restrictsReviewDismissals":true}"#, true, true),
        ] {
            var f = Fixture(); f.permission = permission; f.rule = rule
            let truth = try await admin(f).read(c, operation: PRWriteOperation(command: c))
            XCTAssertEqual(truth.allowedObjectIDs.contains("R1"), allowed, "\(permission) \(rule)")
            XCTAssertEqual(truth.reviews.first?.viewerCanDismiss, dismiss, "\(permission) \(rule)")
            XCTAssertEqual(truth.reviewDecision, "APPROVED"); XCTAssertTrue(truth.reviewsComplete)
            XCTAssertEqual(truth.matchingOperationIDs, [])
        }
        for review in [nil, #"{}"#, Self.reviewR1.replacingOccurrences(of: #""pullRequest":{"id":"PR_node"}"#, with: #""pullRequest":{"id":"PR_other"}"#), Self.reviewR1.replacingOccurrences(of: #","pullRequest":{"id":"PR_node"}"#, with: "")] {
            var f = Fixture(); f.permission = "ADMIN"; f.review = review
            let truth = try await admin(f).read(c, operation: PRWriteOperation(command: c))
            XCTAssertEqual(truth.allowedObjectIDs, [], review ?? "null")
            XCTAssertEqual(truth.reviews.count, 0, review ?? "null"); XCTAssertFalse(truth.reviewsComplete)
        }
        var dismissed = Fixture(); dismissed.permission = "WRITE"; dismissed.review = Self.reviewR1.replacingOccurrences(of: "APPROVED", with: "DISMISSED")
        let done = try await admin(dismissed).read(c, operation: PRWriteOperation(command: c))
        XCTAssertEqual(done.matchingOperationIDs, ["R1"]); XCTAssertEqual(done.allowedObjectIDs, [], "a dismissed review cannot be dismissed again")
    }
    func testSubscriptionAndAdministration() async throws {
        let c = command(.subscription(state: .subscribed))
        let truth = try await admin().read(c, operation: PRWriteOperation(command: c))
        XCTAssertTrue(truth.canSubscribe); XCTAssertEqual(truth.viewerSubscription, .subscribed); XCTAssertEqual(truth.matchingOperationIDs, ["PR_node"])
        var f = Fixture(); f.permission = "WRITE"; f.rule = #"{"restrictsReviewDismissals":false}"#
        let administration = try await admin(f).administration(pr)
        XCTAssertEqual(administration.viewerLogin, "viewer")
        XCTAssertEqual(ids(administration.reviews), [
            "R1:APPROVED:bob:U2:1790845200.0:head:false:true:false",
            "R2:PENDING:viewer:U_viewer:nil:head:true:false:true",
            "R3:CHANGES_REQUESTED:ghost-bot:nil:1790841600.0:nil:false:true:false",
            "R4:UNKNOWN:nil:nil:nil:nil:false:false:false",
        ])
        XCTAssertFalse(administration.reviewsComplete, "an earlier page exists")
        XCTAssertEqual(administration.requestedUsers, [.init(id: "U2", login: "bob")]); XCTAssertEqual(administration.requestedTeams, [.init(id: "T1", slug: "core")])
        XCTAssertTrue(administration.requestsComplete); XCTAssertTrue(administration.canRequestReviews)
        XCTAssertEqual(administration.viewerSubscription, .subscribed); XCTAssertTrue(administration.canSubscribe)
        XCTAssertEqual(administration.reviewDecision, "APPROVED")
        XCTAssertEqual(administration.pendingReview?.id, "R2")
    }
    func testIdentityAndPartialErrorsAreRejected() async throws {
        let c = command(.subscription(state: .subscribed))
        var cases: [(Fixture, PRWriteFailure)] = []
        var f = Fixture(); f.errors = #"[{"type":"FORBIDDEN","path":["node","labels"],"message":"Resource not accessible"}]"#; cases.append((f, .unavailable))
        f = Fixture(); f.errors = "[]"; cases.append((f, .unavailable))
        f = Fixture(); f.errors = "null"; cases.append((f, .unavailable))
        f = Fixture(); f.viewer = #"{"id":"U_viewer","databaseId":43,"login":"viewer"}"#; cases.append((f, .accountChanged))
        f = Fixture(); f.viewer = #"{"id":"U_viewer","databaseId":42}"#; cases.append((f, .accountChanged))
        f = Fixture(); f.viewer = #"{"id":"U_viewer","databaseId":null,"login":"viewer"}"#; cases.append((f, .accountChanged))
        f = Fixture(); f.number = 8; cases.append((f, .accountChanged))
        f = Fixture(); f.headRefOid = nil; cases.append((f, .accountChanged))
        for (fixture, expected) in cases {
            do { _ = try await admin(fixture).read(c, operation: nil); XCTFail("\(fixture)") } catch { XCTAssertEqual(error as? PRWriteFailure, expected, "\(fixture)") }
        }
        let empty = RecordedGitHub { _, _, _ in recorded(#"{"data":null}"#) }
        do { _ = try await GitHubPRLabelReader(client: .init(transport: empty), credential: credential).options(pr); XCTFail("null data") } catch { XCTAssertEqual(error as? PRWriteFailure, .unavailable) }
        let text = body(Fixture(), review: false).replacingOccurrences(of: #""databaseId":42"#, with: #""databaseId":"42""#).replacingOccurrences(of: #""databaseId":7"#, with: #""databaseId":"7""#)
        let stringID = RecordedGitHub { _, _, _ in recorded(text) }
        let truth = try await GitHubPRReviewAdministrationReader(client: .init(transport: stringID), credential: credential).read(c, operation: nil)
        XCTAssertTrue(truth.canSubscribe, "string database IDs compare like numeric ones")
    }
}
