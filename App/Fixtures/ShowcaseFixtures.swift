import Foundation
import MergeProCore

/// Realistic sample data for App Store and website screenshots (`MERGEPRO_SHOWCASE=1`). Offline, like every fixture.
enum ShowcaseFixtures {
    static var enabled: Bool { PRNativeFixtures.enabled && ProcessInfo.processInfo.environment["MERGEPRO_SHOWCASE"] == "1" }
    static let account = AccountScope(host: "github.com", accountID: "showcase")
    static let login = "alex-rivera"

    /// The stored shape of `PRInventoryStatus`, which has no public initializer.
    private struct InventoryStatus: Encodable { let complete: Bool; let fetchedCount: Int; let fetchedAt: Date; let lastSuccessAt: Date }
    private struct Sample {
        var repo: String, number: Int, title: String, author: String
        var state: PullRequest.State = .open, draft = false
        var review = "REVIEW_REQUIRED", checks = "SUCCESS", mergeable = "MERGEABLE"
        var labels: [String] = [], needsMe = false, mine = false
        var add = 40, del = 12, files = 4, comments = 2, hours: Double = 5
        var summary = ""
    }
    private static let labelColors = ["bug": "d73a4a", "enhancement": "a2eeef", "performance": "fbca04", "dependencies": "0366d6",
                                      "security": "b60205", "ui": "c5def5", "infra": "5319e7", "tests": "0e8a16", "docs": "0075ca"]
    private static let samples: [Sample] = [
        .init(repo: "acme/api", number: 305, title: "Back off on secondary rate limits", author: "maria-chen", labels: ["performance"], needsMe: true, add: 86, del: 12, files: 3, comments: 4, hours: 2, summary: "Honor Retry-After on secondary limits and cap the exponential backoff at 60 seconds."),
        .init(repo: "acme/web", number: 1182, title: "Paginate repository search results", author: "kenji-tanaka", review: "APPROVED", labels: ["enhancement"], add: 214, del: 58, files: 7, comments: 6, hours: 20, summary: "Cursor pagination for search, with a skeleton state while the next page loads."),
        .init(repo: "acme/ios", number: 311, title: "Fix flaky checkout UI test", author: "sam-okafor", checks: "FAILURE", labels: ["tests", "bug"], needsMe: true, add: 18, del: 9, files: 2, comments: 3, hours: 6, summary: "Wait for the payment sheet before tapping Pay; the test raced the animation."),
        .init(repo: "acme/api", number: 318, title: "Spike: streaming responses", author: login, draft: true, checks: "PENDING", labels: ["enhancement"], mine: true, add: 402, del: 37, files: 11, comments: 1, hours: 30, summary: "Experiment with chunked responses for the export endpoint."),
        .init(repo: "acme/infra", number: 94, title: "Bump Terraform AWS provider to 6.2", author: "dependabot", labels: ["dependencies", "infra"], add: 6, del: 6, files: 1, comments: 0, hours: 9, summary: "Bumps hashicorp/aws from 6.1.0 to 6.2.0."),
        .init(repo: "acme/web", number: 1190, title: "Cache avatars on disk", author: login, review: "APPROVED", labels: ["performance"], mine: true, add: 120, del: 44, files: 5, comments: 5, hours: 3, summary: "Store avatars in a size-capped disk cache keyed by URL and ETag."),
        .init(repo: "acme/ios", number: 307, title: "Document device flow sign-in", author: "lena-park", state: .merged, review: "APPROVED", labels: ["docs"], add: 64, del: 3, files: 2, comments: 2, hours: 26),
        .init(repo: "acme/api", number: 299, title: "Bump dependencies and regenerate lockfile", author: "dependabot", review: "APPROVED", labels: ["dependencies"], add: 310, del: 298, files: 2, comments: 0, hours: 50),
        .init(repo: "acme/web", number: 1176, title: "Try the new onboarding copy", author: "priya-nair", draft: true, labels: ["ui"], add: 48, del: 31, files: 6, comments: 3, hours: 44),
        .init(repo: "acme/api", number: 296, title: "Rotate signing keys without downtime", author: "maria-chen", review: "APPROVED", labels: ["security"], needsMe: true, add: 156, del: 40, files: 6, comments: 9, hours: 14, summary: "Serve both keys during the overlap window; drop the old key after 24 hours."),
        .init(repo: "acme/infra", number: 91, title: "Move CI runners to arm64", author: login, checks: "PENDING", labels: ["infra", "performance"], mine: true, add: 74, del: 66, files: 9, comments: 7, hours: 8),
        .init(repo: "acme/ios", number: 315, title: "Dark mode polish for settings", author: "lena-park", mergeable: "CONFLICTING", labels: ["ui"], needsMe: true, add: 92, del: 57, files: 8, comments: 2, hours: 11),
        .init(repo: "acme/web", number: 1170, title: "Remove legacy feature flags", author: "kenji-tanaka", state: .merged, review: "APPROVED", add: 12, del: 420, files: 14, comments: 1, hours: 70),
        .init(repo: "acme/api", number: 290, title: "Paginate the audit log endpoint", author: "sam-okafor", state: .merged, review: "APPROVED", labels: ["enhancement"], add: 133, del: 21, files: 5, comments: 3, hours: 52),
    ]

    static func seed(_ database: DatabaseStore) throws {
        guard enabled, try database.applicationSetting(.prFixtureSeeded) == nil else { return }
        try database.saveAccount(Account(scope: account, login: login, tokenReference: nil))
        let now = Date()
        let repos = Dictionary(grouping: samples, by: \.repo).keys.sorted()
        for (index, name) in repos.enumerated() {
            let key = RepositoryKey(account: account, repositoryID: "\(100 + index)")
            try database.saveRepository(Repository(key: key, name: name, isPrivate: name != "acme/web", capabilities: ProviderCapabilities()))
            try database.setTracked(key, tracked: true)
            // A successful inventory read, so the board shows the repositories as current.
            let status = InventoryStatus(complete: true, fetchedCount: 1, fetchedAt: now, lastSuccessAt: now)
            try PollCycleStore(database: database).saveSnapshot(.init(
                key: ProviderKey(host: account.host, accountID: account.accountID, repositoryID: key.repositoryID, objectID: "pull-request-inventory"),
                feature: GitHubPRInventoryFetcher().featureID, payload: try JSONEncoder.stable.encode(status)))
        }
        let rows = samples.map { sample -> PullRequest in
            let repositoryID = "\(100 + repos.firstIndex(of: sample.repo)!)"
            var m = PRMetadata(number: sample.number, webURL: URL(string: "https://github.com/\(sample.repo)/pull/\(sample.number)")!, repositoryName: sample.repo)
            m.descriptionPreview = sample.summary.isEmpty ? nil : sample.summary
            m.authorID = sample.author; m.authorLogin = sample.author
            m.actorType = sample.author == "dependabot" ? "Bot" : "User"
            m.authorClassification = sample.author == "dependabot" ? "automation" : "human"
            m.viewerID = login; m.viewerIsAuthor = sample.mine
            m.createdAt = now.addingTimeInterval(-sample.hours * 3600 - 7200)
            m.updatedAt = now.addingTimeInterval(-sample.hours * 3600)
            m.fetchedAt = now
            m.columnChangedAt = now.addingTimeInterval(-sample.hours * 1800)
            if sample.state == .merged { m.mergedAt = m.updatedAt }
            m.reviewDecision = sample.review
            m.headBranch = sample.title.lowercased().split(separator: " ").prefix(3).joined(separator: "-")
            m.baseBranch = "main"; m.headRepositoryID = repositoryID
            m.mergeable = sample.mergeable; m.checks = sample.checks
            m.autoMergeKnown = true
            m.labels = sample.labels; m.labelColors = labelColors.filter { sample.labels.contains($0.key) }
            m.files = sample.files; m.additions = sample.add; m.deletions = sample.del; m.comments = sample.comments
            m.requests = sample.needsMe ? [.init(id: login, name: login, kind: .direct, isForViewer: true)] : []
            return PullRequest(key: ProviderKey(host: account.host, accountID: account.accountID, repositoryID: repositoryID, objectID: "pull-request:\(sample.repo):\(sample.number)"),
                               headRevision: RevisionID(String(format: "%040x", sample.number * 7919)), title: sample.title, state: sample.state, isDraft: sample.draft, metadata: m)
        }
        try database.savePullRequests(rows)
        try database.setApplicationSetting("true", for: .prFixtureSeeded)
    }

    static let retryPolicy = """
    import Foundation

    /// How long to wait before retrying a GitHub request.
    struct RetryPolicy {
        var base: Duration = .seconds(2)

        func delay(after response: HTTPURLResponse, attempt: Int) -> Duration {
            // Honor Retry-After on secondary rate limits.
            if let value = response.value(forHTTPHeaderField: "Retry-After"),
               let seconds = Int(value) {
                return .seconds(seconds)
            }
            return min(.seconds(60), base * attempt)
        }
    }
    """
    static func detail(_ pr: PullRequest) -> PRDetailSnapshot {
        let patch = [
            "@@ -3,8 +3,13 @@ import Foundation",
            " /// How long to wait before retrying a GitHub request.",
            " struct RetryPolicy {",
            "-    var base: Duration = .seconds(1)",
            "+    var base: Duration = .seconds(2)",
            " ",
            "-    func delay(after response: HTTPURLResponse) -> Duration {",
            "-        return .seconds(1)",
            "+    func delay(after response: HTTPURLResponse, attempt: Int) -> Duration {",
            "+        // Honor Retry-After on secondary rate limits.",
            "+        if let value = response.value(forHTTPHeaderField: \"Retry-After\"),",
            "+           let seconds = Int(value) {",
            "+            return .seconds(seconds)",
            "+        }",
            "+        return min(.seconds(60), base * attempt)",
            "     }",
            " }",
        ].joined(separator: "\n")
        let tests = """
        @@ -0,0 +1,14 @@
        +import XCTest
        +@testable import Sync
        +
        +final class RetryPolicyTests: XCTestCase {
        +    func testHonorsRetryAfter() {
        +        let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 403,
        +                                       httpVersion: nil, headerFields: ["Retry-After": "30"])!
        +        XCTAssertEqual(RetryPolicy().delay(after: response, attempt: 1), .seconds(30))
        +    }
        +    func testCapsBackoffAtOneMinute() {
        +        let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 500, httpVersion: nil, headerFields: [:])!
        +        XCTAssertEqual(RetryPolicy().delay(after: response, attempt: 100), .seconds(60))
        +    }
        +}
        """
        let body = "## What\n\nHonor `Retry-After` on GitHub's secondary rate limits and cap the exponential backoff at 60 seconds.\n\n## Why\n\nBulk refreshes across several accounts were hitting secondary limits and retrying too eagerly.\n\n## Testing\n\n- New unit tests for `RetryPolicy`\n- Ran a full refresh across 3 accounts with no 403s"
        return .init(body: body, baseSHA: String(repeating: "b", count: 40), headSHA: pr.headRevision.rawValue,
                     files: [.init(path: "Sources/Sync/RetryPolicy.swift", status: .modified, patch: patch, additions: 8, deletions: 3),
                             .init(path: "Tests/SyncTests/RetryPolicyTests.swift", status: .added, patch: tests, additions: 14),
                             .init(path: "docs/CHANGELOG.md", status: .modified, patch: "@@ -1,3 +1,4 @@\n # Changelog\n \n+- Back off on secondary rate limits (#305)\n ## 2.4.0", additions: 1)],
                     expectedFiles: 3)
    }
    static func blob(path: String) -> Data {
        if path.hasSuffix("RetryPolicy.swift") { return Data(retryPolicy.utf8) }
        return Data("# Changelog\n\n- Back off on secondary rate limits (#305)\n## 2.4.0\n".utf8)
    }
}
