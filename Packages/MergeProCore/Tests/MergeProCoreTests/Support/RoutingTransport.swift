import Foundation
import MergeProCore

/// Routing GitHub transport: answers each request from the first route matching its method, path and query,
/// recording every request. Unmatched requests go to `fallback` (a 404 unless another transport is given).
actor RoutingTransport: GitHubTransport {
    struct Route: Sendable {
        enum Path: Sendable { case any, exact(String), suffix(String) }
        let method: String?
        let path: Path
        /// Query items that must be present; a nil value accepts any value.
        let query: [String: String?]
        let answer: @Sendable (URLRequest) async throws -> GitHubResponse
        func matches(_ request: URLRequest) -> Bool {
            guard let url = request.url else { return false }
            if let method, (request.httpMethod ?? "GET") != method { return false }
            switch path {
            case .any: break
            case .exact(let value): if url.path != value { return false }
            case .suffix(let value): if !url.path.hasSuffix(value) { return false }
            }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return query.allSatisfy { name, value in items.contains { $0.name == name && (value == nil || $0.value == value) } }
        }
    }
    private var recorder = TransportRecorder()
    private var routes: [Route] = []
    private let fallback: (any GitHubTransport)?

    /// Unmatched requests answer 404, or go to `fallback` (e.g. a stateful provider simulator).
    init(fallback: (any GitHubTransport)? = nil) { self.fallback = fallback }

    func send(_ request: URLRequest) async throws -> GitHubResponse {
        let parked = recorder.record(request)
        if parked { _ = await withCheckedContinuation { recorder.park($0) } }
        if let route = routes.first(where: { $0.matches(request) }) { return try await route.answer(request) }
        if let fallback { return try await fallback.send(request) }
        return json(#"{"message":"Not Found"}"#, status: 404)
    }

    // MARK: Routes (first match wins)

    /// Routes an exact path (or, with `suffix`, any path ending in it), optionally narrowed by method and query items.
    func route(method: String? = nil, path: String? = nil, suffix: String? = nil, query: [String: String?] = [:], _ response: GitHubResponse) {
        route(method: method, path: path, suffix: suffix, query: query) { _ in response }
    }
    func route(method: String? = nil, path: String? = nil, suffix: String? = nil, query: [String: String?] = [:], answer: @escaping @Sendable (URLRequest) async throws -> GitHubResponse) {
        let match: Route.Path = path.map { .exact($0) } ?? suffix.map { .suffix($0) } ?? .any
        routes.append(Route(method: method, path: match, query: query, answer: answer))
    }

    // MARK: Holds and synchronization

    /// Parks the next `count` requests matching `matches` (after recording them) until `release`.
    func hold(_ count: Int = 1, where matches: @escaping @Sendable (URLRequest) -> Bool = { _ in true }) { recorder.hold(count, where: matches) }
    func release() { recorder.release(nil) }
    func waitUntilHolding(_ count: Int = 1) async { await withCheckedContinuation { recorder.wait($0) { holding in holding >= count } } }

    // MARK: Recorded requests

    var requests: [URLRequest] { recorder.requests }
    func methods() -> [String] { recorder.requests.map { $0.httpMethod ?? "GET" } }
}
