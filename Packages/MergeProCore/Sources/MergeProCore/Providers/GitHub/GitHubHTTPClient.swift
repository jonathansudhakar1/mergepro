import Foundation

public struct GitHubResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let data: Data
    public let responseURL: URL?
    public init(status: Int, headers: [String: String] = [:], data: Data = Data(), responseURL: URL? = nil) {
        self.status = status; self.headers = headers; self.data = data; self.responseURL = responseURL
    }
    public func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}
public protocol GitHubTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GitHubResponse
}
public enum GitHubFailure: Error, Equatable, Sendable {
    case invalidAuthentication, scopeRequired, organizationRestricted, resourceDenied, rateLimited(until: Date?), unsafeURL, invalidResponse
}
public struct GitHubHTTPClient: Sendable {
    public let origin: URL
    public let transport: any GitHubTransport
    private let clock: any DeviceFlowClock
    public init(origin: URL = URL(string: "https://api.github.com")!, transport: any GitHubTransport, clock: any DeviceFlowClock = SystemDeviceFlowClock()) { self.origin = origin; self.transport = transport; self.clock = clock }
    public static let apiVersion = "2026-03-10"
    public func isSafeAPIURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil &&
        url.host?.lowercased() == origin.host?.lowercased() && (url.port ?? 443) == (origin.port ?? 443) &&
        origin.scheme?.lowercased() == "https"
    }
    public func get(_ url: URL, token: String, etag: String? = nil, lastModified: String? = nil) async throws -> GitHubResponse {
        guard !token.isEmpty else { throw GitHubFailure.unsafeURL }
        var destination = url
        var refetched304 = false
        for _ in 0..<6 {
            try Task.checkCancellation()
            guard isSafeAPIURL(destination) else { throw GitHubFailure.unsafeURL }
            var request = URLRequest(url: destination)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let lastModified { request.setValue(lastModified,forHTTPHeaderField:"If-Modified-Since") }
            if let etag { request.setValue(etag,forHTTPHeaderField:"If-None-Match") }
            request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
            let response = try await transport.send(request)
            try validateOrigin(response,requested:destination)
            // A positively observed trusted 401 must reach the token-specific session owner.
            if response.status == 401 { throw GitHubFailure.invalidAuthentication }
            try Task.checkCancellation()
            if [301, 302, 303, 307, 308].contains(response.status) {
                guard let location = response.header("Location"), let next = URL(string: location, relativeTo: destination)?.absoluteURL,
                      isSafeAPIURL(next) else { throw GitHubFailure.unsafeURL }
                destination = next
                continue
            }
            // No conditional headers are sent by this discovery client; 304 has no usable body.
            if response.status == 304 {
                if etag != nil || lastModified != nil { return response }
                guard !refetched304 else { throw GitHubFailure.invalidResponse }
                refetched304 = true
                continue
            }
            try Self.validate(response,now:await clock.date())
            return response
        }
        throw GitHubFailure.unsafeURL
    }
    /// Narrow read-query surface. Never accepts mutations or follows cross-origin redirects.
    public func readQuery(_ query: String, variables: [String:String?], token: String) async throws -> GitHubResponse {
        guard !token.isEmpty else { throw GitHubFailure.unsafeURL }
        guard query.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("query "),
              !query.contains("mutation"), !query.contains("subscription") else { throw GitHubFailure.unsafeURL }
        var destination = origin.appendingPathComponent("graphql")
        let jsonVariables = variables.mapValues { $0.map { $0 as Any } ?? NSNull() }
        let body = try JSONSerialization.data(withJSONObject:["query":query,"variables":jsonVariables])
        for _ in 0..<6 {
            try Task.checkCancellation()
            guard isSafeAPIURL(destination), destination.path == origin.appendingPathComponent("graphql").path else { throw GitHubFailure.unsafeURL }
            var request = URLRequest(url:destination); request.httpMethod = "POST"; request.httpBody = body
            request.setValue("Bearer " + token,forHTTPHeaderField:"Authorization")
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
            let response = try await transport.send(request)
            try validateOrigin(response,requested:destination)
            if response.status == 401 { throw GitHubFailure.invalidAuthentication }
            try Task.checkCancellation()
            if [301,302,307,308].contains(response.status) {
                guard let location = response.header("Location"),let next = URL(string:location,relativeTo:destination)?.absoluteURL,isSafeAPIURL(next) else { throw GitHubFailure.unsafeURL }
                destination = next; continue
            }
            try Self.validate(response,now:await clock.date()); return response
        }
        throw GitHubFailure.unsafeURL
    }
    /// Explicit write surface. Never redirects or retries a mutation; correlation is not idempotency.
    public func mutate(path:String,method:String,body:Data?,token:String,acceptedStatuses:Set<Int>=[]) async throws -> GitHubResponse {
        guard !token.isEmpty,["POST","PATCH","PUT","DELETE"].contains(method),!path.hasPrefix("/"),!path.contains(".."),!path.contains("?") else { throw GitHubFailure.unsafeURL }
        let url=origin.appendingPathComponent(path)
        guard isSafeAPIURL(url) else { throw GitHubFailure.unsafeURL }
        var request=URLRequest(url:url);request.httpMethod=method;request.httpBody=body
        request.setValue("Bearer " + token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        request.setValue(Self.apiVersion,forHTTPHeaderField:"X-GitHub-Api-Version")
        let response=try await transport.send(request)
        try validateOrigin(response,requested:url)
        if response.status == 401 { throw GitHubFailure.invalidAuthentication }
        // Even cancellation after dispatch must retain positively returned provider evidence.
        if !acceptedStatuses.contains(response.status) { try Self.validate(response,now:await clock.date()) }
        return response
    }
    /// GitHub paginates `/repos/{owner}/{name}/…` lists through `/repositories/{id}/…` Link URLs.
    /// Accept only the same tail under the expected repository ID; any other path stays rejected.
    static func samePaginatedPath(_ candidate: URL, as requested: URL, repositoryID: String?) -> Bool {
        if candidate.path == requested.path { return true }
        let parts = requested.path.split(separator: "/", omittingEmptySubsequences: false)
        guard let repositoryID, !repositoryID.isEmpty, repositoryID.allSatisfy({ $0.isASCII && $0.isNumber }), parts.count >= 4, parts[0].isEmpty, parts[1] == "repos" else { return false }
        return candidate.path == (["", "repositories", Substring(repositoryID)] + parts.dropFirst(4)).joined(separator: "/")
    }
    private func validateOrigin(_ response: GitHubResponse, requested: URL) throws {
        // Injected transports may omit responseURL and must honor the request destination.
        // The production no-redirect URLSession transport always supplies the observed URL.
        if let actual = response.responseURL {
            guard isSafeAPIURL(actual), actual == requested else { throw GitHubFailure.unsafeURL }
        }
    }
    private static func scopes(_ value: String) -> Set<String> {
        Set(value.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
    }
    static func validate(_ response: GitHubResponse, now: Date) throws {
        if response.status == 401 { throw GitHubFailure.invalidAuthentication }
        if response.status == 429 || response.status == 403 && (response.header("Retry-After") != nil || response.header("X-RateLimit-Remaining") == "0" ||
            String(decoding: response.data, as: UTF8.self).localizedCaseInsensitiveContains("rate limit")) {
            let until: Date?
            if let seconds = response.header("Retry-After").flatMap(Double.init) { until = now.addingTimeInterval(max(0,seconds)) }
            else if response.header("X-RateLimit-Remaining") == "0", let epoch = response.header("X-RateLimit-Reset").flatMap(Double.init) { until = max(now,Date(timeIntervalSince1970:epoch)) }
            else { until = now.addingTimeInterval(60) }
            throw GitHubFailure.rateLimited(until: until)
        }
        if response.status == 403 {
            if response.header("X-GitHub-SSO") != nil { throw GitHubFailure.organizationRestricted }
            if let accepted = response.header("X-Accepted-OAuth-Scopes"), let granted = response.header("X-OAuth-Scopes") {
                let needed = scopes(accepted)
                var available = scopes(granted)
                if available.contains("user") { available.formUnion(["read:user", "read:org", "user:email", "user:follow"]) }
                if available.contains("admin:org") { available.formUnion(["write:org", "read:org"]) }
                if available.contains("write:org") { available.insert("read:org") }
                if available.contains("repo") { available.formUnion(["public_repo", "repo:status", "repo_deployment", "repo:invite"]) }
                if !needed.isEmpty, needed.isDisjoint(with:available) { throw GitHubFailure.scopeRequired }
            }
            throw GitHubFailure.resourceDenied
        }
        if response.status == 404 { throw GitHubFailure.resourceDenied }
        guard (200..<300).contains(response.status) else { throw GitHubFailure.invalidResponse }
    }
}

/// Prevent Foundation from following redirects or supplying ambient credentials/cookies.
/// The API client validates and constructs each redirected request itself.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
public final class URLSessionGitHubTransport: GitHubTransport, Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> GitHubResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubFailure.invalidResponse }
        let headers = Dictionary(uniqueKeysWithValues: http.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) })
        return GitHubResponse(status: http.statusCode, headers: headers, data: data, responseURL:http.url)
    }
}
