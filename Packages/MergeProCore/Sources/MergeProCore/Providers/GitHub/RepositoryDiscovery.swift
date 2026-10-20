import Foundation

public struct GitHubOrganization: Codable, Equatable, Sendable { public let id: String; public let login: String }
public struct GitHubTeam: Codable, Equatable, Sendable { public let id: String; public let name: String; public let organizationID: String }
public struct GitHubDiscoveryResult: Sendable {
    public let repositories: [Repository]
    public let organizations: [GitHubOrganization]
    public let teams: [GitHubTeam]
    public let issues: [String]
    public let isComplete: Bool
    public let retryAt: Date?
}
public struct RepositoryDiscovery: Sendable {
    private let client: GitHubHTTPClient
    public init(client: GitHubHTTPClient) { self.client = client }
    public func discover(account: AccountScope, credential: GitHubCredential) async throws -> GitHubDiscoveryResult {
        var issues: [String] = []; var retryAt: Date?
        let repos: [RepoPayload] = try await pages("/user/repos?per_page=100&visibility=all&affiliation=owner,collaborator,organization_member&sort=full_name&direction=asc", token:credential.accessToken, issues:&issues, retryAt:&retryAt)
        let orgs: [OrgPayload] = try await pages("/user/orgs?per_page=100", token:credential.accessToken, issues:&issues, retryAt:&retryAt)
        let teams: [TeamPayload] = try await pages("/user/teams?per_page=100", token:credential.accessToken, issues:&issues, retryAt:&retryAt)
        let repositories = repos.map { repo in
            var capabilities: ProviderCapabilities = []
            if repo.permissions?.pull == true { capabilities.formUnion([.readPullRequests, .readWorkflows]) }
            // The user's push permission and the granted repo scope are both required. These
            // are discovery hints; later writes must revalidate endpoint and branch eligibility.
            if repo.permissions?.push == true && credential.scopes.contains("repo") { capabilities.formUnion([.review, .merge, .runWorkflows]) }
            return Repository(key:RepositoryKey(account:account, repositoryID:String(repo.id)), name:repo.full_name, isPrivate:repo.private, capabilities:capabilities)
        }
        return GitHubDiscoveryResult(repositories:repositories, organizations:orgs.map { GitHubOrganization(id:String($0.id), login:$0.login) },
                                     teams:teams.map { GitHubTeam(id:String($0.id), name:$0.name, organizationID:String($0.organization.id)) }, issues:issues, isComplete:issues.isEmpty, retryAt:retryAt)
    }
    private func pages<T: Decodable>(_ path: String, token: String, issues: inout [String], retryAt: inout Date?) async throws -> [T] {
        guard retryAt == nil, let requested = URL(string:path, relativeTo:client.origin)?.absoluteURL else { return [] }
        var url: URL? = requested
        var visited: Set<URL> = []; var results: [T] = []
        while let current = url {
            try Task.checkCancellation()
            guard client.isSafeAPIURL(current), visited.insert(current).inserted else { issues.append("Repository discovery is incomplete: GitHub returned an unsafe or repeated page link."); break }
            do {
                let response = try await client.get(current, token:token)
                if response.header("X-GitHub-SSO")?.contains("partial-results") == true { issues.append("Some organization resources were omitted. Establish organization SSO, confirm OAuth App approval, then reconnect this account.") }
                results.append(contentsOf:try JSONDecoder().decode([T].self, from:response.data))
                url = try GitHubPagination.next(response.header("Link"), client:client, requested:requested)
            } catch {
                if error is CancellationError { throw error }
                if error as? GitHubFailure == .invalidAuthentication { throw error }
                switch error as? GitHubFailure {
                case .organizationRestricted: issues.append("Organization access is restricted. Establish SSO, ask an owner to approve the OAuth App, then reconnect this account.")
                case .scopeRequired: issues.append("GitHub did not grant the scope required for this discovery endpoint. Reconnect and review the requested permissions.")
                case .resourceDenied: issues.append("Some GitHub resources are unavailable. Check your repository role and organization OAuth App approval.")
                case .rateLimited(let until): retryAt = until; issues.append("GitHub rate limited discovery. Retry after the server's waiting period.")
                default: issues.append("GitHub discovery is incomplete. Retry to load the remaining pages; saved repositories are retained.")
                }
                break
            }
        }
        return results
    }
}
private struct RepoPayload: Decodable {
    let id: Int64; let full_name: String; let `private`: Bool; let permissions: Permissions?
    struct Permissions: Decodable { let pull: Bool?; let push: Bool?; let admin: Bool? }
}
private struct OrgPayload: Decodable { let id: Int64; let login: String }
private struct TeamPayload: Decodable { let id: Int64; let name: String; let organization: OrgPayload }
