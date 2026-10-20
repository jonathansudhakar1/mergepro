import XCTest
@testable import MergeProCore

/// Scripted responses in order; records every request so tests can prove an unsafe link was never read.
actor PagingTransport: GitHubTransport {
    private var responses: [GitHubResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [GitHubResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> GitHubResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw GitHubFailure.invalidResponse }
        return responses.removeFirst()
    }
    func paths() -> [String] { requests.compactMap { $0.url?.path } }
}
func pagingPage(_ body: String, link: String? = nil) -> GitHubResponse {
    GitHubResponse(status: 200, headers: link.map { ["Link": $0] } ?? [:], data: Data(body.utf8))
}

/// Pins every Link-following site's safety checks: only a same-origin, credential-free HTTPS link on
/// the requested list's path (or its pinned `/repositories/{id}/…` form) is ever requested.
final class PaginationCharacterizationTests: XCTestCase {
    let account = AccountScope(host: "github.com", accountID: "42")
    var repo: Repository { Repository(key: .init(account: account, repositoryID: "7"), name: "o/r", isPrivate: false, capabilities: []) }
    let credential = GitHubCredential(accessToken: "fixture", scopes: ["repo"])
    func next(_ url: String) -> String { "<\(url)>; rel=\"next\"" }
    /// Off-origin, downgraded, credentialed, other-port, relative and malformed targets.
    let unsafeTargets = [
        "<https://evil.test/PATH?page=2>; rel=\"next\"",
        "<http://api.github.com/PATH?page=2>; rel=\"next\"",
        "<https://user:secret@api.github.com/PATH?page=2>; rel=\"next\"",
        "<https://api.github.com:444/PATH?page=2>; rel=\"next\"",
        "</PATH?page=2>; rel=\"next\"",
        "not-a-link; rel=\"next\"",
    ]

    // MARK: Actions (pinned repository ID)

    func runJSON(_ id: Int) -> String { #"{"id":\#(id),"workflow_id":2,"name":"CI","head_branch":"main","head_sha":"abc","event":"push","status":"completed","conclusion":null,"run_attempt":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}"# }
    func actions(_ transport: PagingTransport) -> GitHubActionsProvider { GitHubActionsProvider(client: .init(transport: transport), credential: credential) }

    func testActionsFollowSamePathAndPinnedRepositoryLinks() async throws {
        let transport = PagingTransport([
            pagingPage(#"{"workflow_runs":[\#(runJSON(1))]}"#, link: next("https://api.github.com/repos/o/r/actions/runs?per_page=100&page=2")),
            pagingPage(#"{"workflow_runs":[\#(runJSON(2))]}"#, link: next("https://api.github.com/repositories/7/actions/runs?per_page=100&page=3")),
            pagingPage(#"{"workflow_runs":[\#(runJSON(3))]}"#),
        ])
        let runs = try await actions(transport).runs(repository: repo)
        XCTAssertEqual(Set(runs.map(\.runID)), [1, 2, 3])
        let paths = await transport.paths()
        XCTAssertEqual(paths, ["/repos/o/r/actions/runs", "/repos/o/r/actions/runs", "/repositories/7/actions/runs"])
    }
    func testActionsRejectUnsafeOrForeignLinksBeforeRequestingThem() async throws {
        let path = "repos/o/r/actions/runs"
        let foreign = [
            next("https://api.github.com/repositories/8/actions/runs?page=2"),
            next("https://api.github.com/repos/o/other/actions/runs?page=2"),
            next("https://api.github.com/repos/o/r/actions/workflows?page=2"),
        ]
        for link in unsafeTargets.map({ $0.replacingOccurrences(of: "PATH", with: path) }) + foreign {
            let transport = PagingTransport([pagingPage(#"{"workflow_runs":[]}"#, link: link)])
            do { _ = try await actions(transport).runs(repository: repo); XCTFail("followed \(link)") } catch { XCTAssertEqual(error as? GitHubFailure, .unsafeURL, link) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1, link)
        }
    }

    // MARK: Notification feed (account path only)

    func thread(_ id: Int) -> String { #"{"id":"\#(id)","reason":"mention","updated_at":"2026-01-01T00:00:00Z","repository":{"id":7},"subject":{"title":"T","type":"PullRequest","url":"https://api.github.com/repos/o/r/pulls/\#(id)"}}"# }
    func feedContext(_ transport: PagingTransport) -> PollFetchContext {
        PollFetchContext(cycleID: UUID(), account: account, repositories: [repo.key], featureID: "github-notification-signals", cachedPullRequests: [], cachedSnapshots: [], repositoryMetadata: [:], deadline: .now.advanced(by: .seconds(10)), operation: .init(account: account, credential: credential, generation: UUID()), client: .init(transport: transport), budget: .init(minimumSpacing: .zero), baselinedRepositories: [], suppressNotifications: false, cachedResponses: [:])
    }
    func testNotificationFeedFollowsOnlyTheAccountFeedPath() async throws {
        let transport = PagingTransport([pagingPage("[\(thread(1))]", link: next("https://api.github.com/notifications?all=true&per_page=50&page=2")), pagingPage("[\(thread(2))]")])
        let result = try await GitHubNotificationFeedFetcher().fetch(feedContext(transport))
        XCTAssertEqual(result.events.count, 2)
        for link in unsafeTargets.map({ $0.replacingOccurrences(of: "PATH", with: "notifications") }) + [next("https://api.github.com/repositories/7/notifications?page=2"), next("https://api.github.com/notifications/threads?page=2")] {
            let unsafe = PagingTransport([pagingPage("[\(thread(1))]", link: link)])
            do { _ = try await GitHubNotificationFeedFetcher().fetch(feedContext(unsafe)); XCTFail("followed \(link)") } catch { XCTAssertEqual(error as? GitHubFailure, .unsafeURL, link) }
            let count = await unsafe.requests.count
            XCTAssertEqual(count, 1, link)
        }
    }

    // MARK: Merge evidence REST lists (pinned repository ID when given)

    func mergeReader(_ transport: PagingTransport) -> GitHubMergeReader { GitHubMergeReader(client: .init(transport: transport), credential: credential) }
    func testMergeRuleListsRejectUnsafeOrForeignLinks() async throws {
        let rules = URL(string: "https://api.github.com/repos/o/r/rulesets?per_page=100")!
        let transport = PagingTransport([pagingPage(#"[{"id":1}]"#, link: next("https://api.github.com/repositories/7/rulesets?per_page=100&page=2")), pagingPage(#"[{"id":2}]"#)])
        let values = try await mergeReader(transport).restList(rules, repositoryID: "7")
        XCTAssertEqual(values.count, 2)
        let absolute = unsafeTargets.filter { !$0.hasPrefix("</") }.map { $0.replacingOccurrences(of: "PATH", with: "repos/o/r/rulesets") }
        for link in absolute + [next("https://api.github.com/repositories/8/rulesets?page=2"), next("https://api.github.com/repos/o/r/branches?page=2")] {
            let unsafe = PagingTransport([pagingPage(#"[{"id":1}]"#, link: link), pagingPage(#"[{"id":2}]"#)])
            do { _ = try await mergeReader(unsafe).restList(rules, repositoryID: "7"); XCTFail("followed \(link)") } catch {}
            let count = await unsafe.requests.count
            XCTAssertEqual(count, 1, link)
        }
        // Without a pinned repository ID only the requested path itself is accepted.
        let teams = URL(string: "https://api.github.com/user/teams?per_page=100")!
        let byID = PagingTransport([pagingPage("[]", link: next("https://api.github.com/repositories/7/user/teams?page=2")), pagingPage("[]")])
        do { _ = try await mergeReader(byID).restList(teams); XCTFail("followed a repository-ID link without a pinned repository") } catch {}
        let count = await byID.requests.count
        XCTAssertEqual(count, 1)
    }

    // MARK: Repository discovery

    func repoJSON(_ id: Int) -> String { #"{"id":\#(id),"full_name":"o/r\#(id)","private":false,"permissions":{"pull":true,"push":false}}"# }
    func testDiscoveryNeverRequestsUnsafeLinks() async throws {
        for link in unsafeTargets.map({ $0.replacingOccurrences(of: "PATH", with: "user/repos") }) where !link.hasPrefix("</") {
            let transport = PagingTransport([pagingPage("[\(repoJSON(1))]", link: link), pagingPage("[]"), pagingPage("[]")])
            let result = try await RepositoryDiscovery(client: .init(transport: transport)).discover(account: account, credential: credential)
            XCTAssertFalse(result.isComplete, link)
            XCTAssertEqual(result.repositories.count, 1, link)
            let paths = await transport.paths()
            XCTAssertEqual(paths, ["/user/repos", "/user/orgs", "/user/teams"], link)
        }
    }

    // MARK: Tightened by the shared helper

    /// Merge rule lists and discovery formerly resolved relative targets, and discovery accepted any
    /// same-origin path. Every site now requires an absolute target on the requested path.
    func testRelativeAndOffPathContinuationsAreRejectedEverywhere() async throws {
        let rules = URL(string: "https://api.github.com/repos/o/r/rulesets?per_page=100")!
        let relative = PagingTransport([pagingPage(#"[{"id":1}]"#, link: "</repos/o/r/rulesets?page=2>; rel=\"next\""), pagingPage(#"[{"id":2}]"#)])
        do { _ = try await mergeReader(relative).restList(rules, repositoryID: "7"); XCTFail("followed a relative link") } catch { XCTAssertEqual(error as? GitHubFailure, .unsafeURL) }
        let count = await relative.requests.count
        XCTAssertEqual(count, 1)
        for link in ["</user/repos?page=2>; rel=\"next\"", next("https://api.github.com/user/orgs?page=2"), next("https://api.github.com/repositories/1/user/repos?page=2")] {
            let transport = PagingTransport([pagingPage("[\(repoJSON(1))]", link: link), pagingPage("[]"), pagingPage("[]")])
            let result = try await RepositoryDiscovery(client: .init(transport: transport)).discover(account: account, credential: credential)
            XCTAssertFalse(result.isComplete, link)
            let paths = await transport.paths()
            XCTAssertEqual(paths, ["/user/repos", "/user/orgs", "/user/teams"], link)
        }
    }
    /// RFC 8288 forms the former per-site parsers mishandled: unquoted and multi-valued `rel`, commas
    /// inside the target, and the `next` link listed after others.
    func testRFC8288FormsAreFollowed() async throws {
        let link = #"<https://api.github.com/repositories/7/actions/runs?per_page=100&page=9>; rel="last", <https://api.github.com/repositories/7/actions/runs?status=a,b&page=2>; rel=next"#
        let transport = PagingTransport([pagingPage(#"{"workflow_runs":[\#(runJSON(1))]}"#, link: link), pagingPage(#"{"workflow_runs":[\#(runJSON(2))]}"#)])
        let runs = try await actions(transport).runs(repository: repo)
        XCTAssertEqual(Set(runs.map(\.runID)), [1, 2])
        let feed = PagingTransport([pagingPage("[\(thread(1))]", link: #"<https://api.github.com/notifications?page=2>; rel="next last""#), pagingPage("[\(thread(2))]")])
        let result = try await GitHubNotificationFeedFetcher().fetch(feedContext(feed))
        XCTAssertEqual(result.events.count, 2)
    }

    // MARK: Hint-only readers (continuations are built at the trusted origin, links never followed)

    func testHintOnlyReadersTreatAnyAdvertisedNextAsMore() async throws {
        let commits = #"[{"sha":"abc","commit":{"message":"m","author":{"name":"n","date":"2026-01-01T00:00:00Z"}}}]"#
        let sha = String(repeating: "a", count: 40)
        for link in [next("https://api.github.com/repositories/7/commits?page=2"), next("https://evil.test/x"), "<x>; rel=\"next\""] {
            let transport = PagingTransport([pagingPage(commits, link: link)])
            let page = try await GitHubRepoReader(client: .init(transport: transport)).commits(repository: "o/r", sha: sha, page: 3, token: "fixture")
            XCTAssertEqual(page.nextPage, 4, link)
            let urls = await transport.requests.compactMap(\.url)
            XCTAssertEqual(urls.map(\.host), ["api.github.com"])
        }
        for link in [nil, "<https://api.github.com/repos/o/r/commits?page=1>; rel=\"prev\"", "<https://api.github.com/repos/o/r/commits?page=1>; rel=\"first\""] {
            let transport = PagingTransport([pagingPage(commits, link: link)])
            let page = try await GitHubRepoReader(client: .init(transport: transport)).commits(repository: "o/r", sha: sha, page: 3, token: "fixture")
            XCTAssertNil(page.nextPage, link ?? "no header")
        }
    }
}
