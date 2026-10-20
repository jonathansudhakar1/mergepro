import Foundation
import MergeProCore

/// A response with a UTF-8 body, as GitHub sends it.
func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> GitHubResponse {
    GitHubResponse(status: status, headers: headers, data: Data(body.utf8))
}
/// A response whose body is `object` serialized with `JSONSerialization`.
func json(object: Any, status: Int = 200, headers: [String: String] = [:]) throws -> GitHubResponse {
    GitHubResponse(status: status, headers: headers, data: try JSONSerialization.data(withJSONObject: object))
}

/// What a fake transport does with one request: answer it, or fail as the network or provider would.
enum TransportOutcome: Sendable {
    case respond(GitHubResponse)
    case fail(any Error & Sendable)
    /// The request reached GitHub but its answer was lost (the write may have applied).
    static let lostResponse = TransportOutcome.fail(URLError(.networkConnectionLost))
    func resolve() throws -> GitHubResponse {
        switch self {
        case .respond(let response): return response
        case .fail(let error): throw error
        }
    }
}

/// Request log and holds shared by `ScriptedTransport` and `RoutingTransport`.
/// Tests synchronize on a held request (`waitUntilHolding`) instead of sleeping.
struct TransportRecorder {
    private(set) var requests: [URLRequest] = []
    /// When each request reached the transport, in arrival order.
    private(set) var arrivals: [ContinuousClock.Instant] = []
    private var holds: [(remaining: Int, matches: @Sendable (URLRequest) -> Bool)] = []
    private var held: [CheckedContinuation<GitHubResponse?, Never>] = []
    private var waiters: [(ready: @Sendable (Int) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
    var holding: Int { held.count }

    mutating func hold(_ count: Int, where matches: @escaping @Sendable (URLRequest) -> Bool) {
        holds.append((count, matches))
    }
    /// Records the request; true when a hold rule claims it.
    mutating func record(_ request: URLRequest) -> Bool {
        requests.append(request); arrivals.append(.now)
        guard let index = holds.firstIndex(where: { $0.remaining > 0 && $0.matches(request) }) else { return false }
        holds[index].remaining -= 1
        return true
    }
    mutating func park(_ continuation: CheckedContinuation<GitHubResponse?, Never>) {
        held.append(continuation); notify()
    }
    /// Lets the earliest held request continue, answering `response` instead of its own outcome when given.
    mutating func release(_ response: GitHubResponse?) {
        guard !held.isEmpty else { return }
        held.removeFirst().resume(returning: response)
    }
    mutating func wait(_ continuation: CheckedContinuation<Void, Never>, until ready: @escaping @Sendable (_ holding: Int) -> Bool) {
        if ready(held.count) { continuation.resume() } else { waiters.append((ready, continuation)) }
    }
    private mutating func notify() {
        let holding = held.count
        let ready = waiters.filter { $0.ready(holding) }
        waiters.removeAll { $0.ready(holding) }
        for waiter in ready { waiter.continuation.resume() }
    }
}

/// Scripted FIFO GitHub transport: records every request and answers each with the next scripted outcome.
/// Once the script runs out it answers `fallback`, or fails with `GitHubFailure.invalidResponse` if there is none.
/// `hold` parks matching requests until `release`, so a test can act while a request is in flight.
actor ScriptedTransport: GitHubTransport {
    private var recorder = TransportRecorder()
    private var script: [TransportOutcome]
    private var fallback: TransportOutcome?
    private var beforeAnswer: (@Sendable (URLRequest) throws -> Void)?

    init(_ responses: [GitHubResponse] = [], fallback: GitHubResponse? = nil, holdingFirst holds: Int = 0) {
        script = responses.map(TransportOutcome.respond); self.fallback = fallback.map(TransportOutcome.respond)
        if holds > 0 { recorder.hold(holds) { _ in true } }
    }
    /// 200 responses with these bodies, in order.
    init(bodies: [String]) { self.init(bodies.map { json($0) }) }
    /// Holds the first request until `release(_:)` supplies its answer; later requests answer `[]`.
    static func suspended() -> ScriptedTransport { ScriptedTransport(fallback: json("[]"), holdingFirst: 1) }

    func send(_ request: URLRequest) async throws -> GitHubResponse {
        let parked = recorder.record(request)
        var outcome: TransportOutcome
        if script.isEmpty { outcome = fallback ?? .fail(GitHubFailure.invalidResponse) } else { outcome = script.removeFirst() }
        if parked, let replacement = await withCheckedContinuation({ recorder.park($0) }) { outcome = .respond(replacement) }
        try beforeAnswer?(request)
        return try outcome.resolve()
    }

    // MARK: Script

    /// Every request after the script answers this (e.g. a write receipt, a denial or `.lostResponse`).
    func answerRemaining(_ outcome: TransportOutcome) { fallback = outcome }
    func answerRemaining(_ response: GitHubResponse) { fallback = .respond(response) }
    /// Runs before each answer is returned (e.g. an account switch while the request is in flight); a throw fails the request.
    func beforeAnswering(_ action: @escaping @Sendable (URLRequest) throws -> Void) { beforeAnswer = action }

    // MARK: Holds and synchronization

    /// Parks the next `count` requests matching `matches` (after recording them) until `release`.
    func hold(_ count: Int = 1, where matches: @escaping @Sendable (URLRequest) -> Bool = { _ in true }) { recorder.hold(count, where: matches) }
    /// Lets the earliest held request continue, answering `response` instead of its scripted outcome when given.
    func release(_ response: GitHubResponse? = nil) { recorder.release(response) }
    /// Suspends until `count` requests are parked by a hold.
    func waitUntilHolding(_ count: Int = 1) async { await withCheckedContinuation { recorder.wait($0) { holding in holding >= count } } }

    // MARK: Recorded requests

    var requests: [URLRequest] { recorder.requests }
    var count: Int { recorder.requests.count }
    func captured() -> [URLRequest] { recorder.requests }
    func paths() -> [String] { recorder.requests.map { $0.url!.path } }
    func urls() -> [String] { recorder.requests.map { $0.url!.absoluteString } }
    func arrivals() -> [ContinuousClock.Instant] { recorder.arrivals }
    /// When the first request for `path` arrived.
    func arrival(_ path: String) -> ContinuousClock.Instant? {
        recorder.requests.firstIndex { $0.url?.path == path }.map { recorder.arrivals[$0] }
    }
}
