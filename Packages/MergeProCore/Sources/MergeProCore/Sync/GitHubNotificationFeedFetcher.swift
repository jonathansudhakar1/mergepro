import Foundation

/// Thread signals restricted to explicitly tracked memberships. This is deliberately independent
/// from PR inventory reconciliation: unchanged notifications never imply an unchanged PR inventory.
/// One account-wide `/notifications` read per cycle (conditional, so an unchanged feed is a free 304) serves
/// every tracked repository; threads of other repositories are dropped, never recorded.
public struct GitHubNotificationFeedFetcher: PollFeatureFetcher {
    public let featureID = "github-notification-signals"
    public let fetchScope: PollFetchScope = .account
    public var pollInterval: TimeInterval? { interval }
    public let interval: TimeInterval
    public var usesCachedPullRequests: Bool { false }
    /// A changed feed is walked back only until it reaches threads the previous first page already held, and
    /// never past this many pages (the first read of an account starts from its newest threads).
    public static let maximumPages = 5
    public init(interval: TimeInterval = 60) { self.interval = interval }
    public func fetch(_ context: PollFetchContext) async throws -> PollFetchResult {
        guard !context.repositories.isEmpty else { return PollFetchResult() }
        guard let operation = context.operation, let client = context.client else { throw GitHubFailure.invalidAuthentication }
        let endpoint = client.origin.appendingPathComponent("notifications")
        let first = endpoint.appending(queryItems:[URLQueryItem(name:"all",value:"true"),URLQueryItem(name:"per_page",value:"50")])
        let cached = context.cachedResponses[first.absoluteString]
        // Newest update the previous first page held: a changed feed is read back only to there.
        var seen: Date?
        if let cached {
            do { seen = try JSONDecoder().decode([Thread].self,from:cached.body).compactMap { GitHubDate.parse($0.updated_at) }.max() }
            catch { Log.notifications.info("Stored notification page did not decode; reading the feed without a stop marker: \(Log.kind(error), privacy: .public)") }
        }
        var url: URL? = first; var visited = Set<URL>(); var events: [ChangeEvent] = []; var responses: [PollResponseCache] = []
        while let page = url, visited.count < Self.maximumPages {
            try context.checkDeadline()
            guard visited.insert(page).inserted, client.isSafeAPIURL(page), GitHubHTTPClient.samePaginatedPath(page,as:endpoint,repositoryID:nil) else { throw GitHubFailure.unsafeURL }
            let validator = page == first ? cached : nil
            let response = try await client.get(page,token:operation.credential.accessToken,etag:validator?.etag,lastModified:validator?.lastModified)
            await context.budget.observePollInterval(response,account:context.account,feature:featureID)
            try context.checkDeadline()
            let body: Data
            if response.status == 304 {
                // Nothing in the feed changed since the stored first page: no older page can have changed either.
                guard let validator else { throw GitHubFailure.invalidResponse }
                body = validator.body; url = nil
            } else { body = response.data; url = try GitHubPagination.next(response.header("Link"),client:client,requested:endpoint) }
            let threads = try JSONDecoder().decode([Thread].self,from:body)
            for thread in threads {
                let key = RepositoryKey(account:context.account,repositoryID:String(thread.repository.id))
                guard context.repositories.contains(key), let date = GitHubDate.parse(thread.updated_at) else { continue }
                let object = ProviderKey(host:context.account.host,accountID:context.account.accountID,repositoryID:key.repositoryID,objectID:"notification-thread:" + thread.id)
                let components = [object.host,object.accountID,object.repositoryID,object.objectID,thread.reason,thread.updated_at]
                // Length-prefix all components: hostile provider strings cannot collide at separators.
                let eventKey = components.map { "\($0.utf8.count):\($0)" }.joined()
                events.append(ChangeEvent(key:eventKey,object:object,category:Self.category(thread.reason),occurredAt:date,
                    title:thread.subject.title,locator:Self.locator(thread.subject,client:client)))
            }
            // Only the first page's validators and body are kept; an unchanged 304 page is already stored.
            if page == first, response.status != 304 {
                responses.append(PollResponseCache(url:page,etag:response.header("ETag"),body:body,lastModified:response.header("Last-Modified")))
            }
            // Threads are newest first: stop once this page reaches what the previous first page already held.
            if let seen, let oldest = threads.compactMap({ GitHubDate.parse($0.updated_at) }).min(), oldest <= seen { url = nil }
        }
        let newRepos = context.repositories.subtracting(context.baselinedRepositories)
        return PollFetchResult(events:events,responses:responses,baselinedRepositories:context.repositories,
                               baselineEventKeys:Set(events.filter { newRepos.contains($0.object.repository) }.map(\.key)))
    }
    private static func category(_ reason: String) -> String {
        switch reason {
        case "review_requested": "review request signals"
        case "ci_activity": "CI activity signals"
        case "mention", "team_mention": "mention signals"
        case "assign": "assignment signals"
        default: "repository activity signals"
        }
    }
    private static func locator(_ subject: Thread.Subject, client: GitHubHTTPClient) -> EventLocator {
        guard let raw = subject.url, let apiURL = URL(string:raw),client.isSafeAPIURL(apiURL) else { return EventLocator(subjectType:subject.type) }
        let parts = apiURL.path.split(separator:"/").map(String.init)
        guard parts.count == 5, parts[0] == "repos",Int(parts[4]) != nil else { return EventLocator(subjectType:subject.type) }
        let path: String
        if subject.type == "PullRequest", parts[3] == "pulls" { path = "pull" }
        else if subject.type == "Issue", parts[3] == "issues" { path = "issues" }
        else { return EventLocator(subjectType:subject.type) }
        var url = URL(string:"https://github.com")!
        for component in [parts[1],parts[2],path,parts[4]] { url.appendPathComponent(component) }
        return EventLocator(subjectType:subject.type,subjectNumber:parts[4],webURL:url)
    }
    private struct Thread: Decodable {
        let id: String
        let reason: String
        let updated_at: String
        let repository: Repo
        let subject: Subject
        struct Repo: Decodable { let id: Int64 }
        struct Subject: Decodable { let title: String; let type: String; let url: String? }
    }
}
