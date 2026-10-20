import Foundation

/// "Latest request wins": every `begin()` supersedes the requests before it, so an async result that arrives after a
/// newer request started (another PR, a refresh, a retry) is dropped instead of overwriting what the newer one shows.
/// Replaces hand-rolled `UUID`/`Int` tokens compared after each `await`.
///
///     let token=loads.begin()
///     let value=try await read()
///     guard loads.isCurrent(token) else { return }
///
/// or, when the whole read is one call, `if let value=try await loads.run({ try await read() }) { apply(value) }`.
@MainActor final class LatestRequest {
    struct Token:Hashable,Sendable { fileprivate let generation:UInt64 }
    private var generation:UInt64=0
    init() {}
    /// Starts a request; earlier tokens stop being current.
    @discardableResult func begin() -> Token { generation &+= 1;return Token(generation:generation) }
    func isCurrent(_ token:Token) -> Bool { token.generation == generation }
    /// The current request's token without superseding it: work that must not outlive the next `begin()` or `cancel()`
    /// (e.g. a write issued against the read it was based on).
    var latest:Token { Token(generation:generation) }
    /// Supersedes every outstanding request without starting a new one (e.g. the account or head changed).
    func cancel() { generation &+= 1 }
    /// Runs `work` as the newest request and returns its result only if no newer request began meanwhile; nil when superseded.
    func run<Value>(_ work:@MainActor () async throws -> Value) async rethrows -> Value? {
        let token=begin()
        let value=try await work()
        return isCurrent(token) ? value : nil
    }
}
