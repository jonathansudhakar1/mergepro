import Foundation
import MergeProCore
import os

/// App diagnostics for errors the App handles by design (a fallback, a retry or a status line), on Core's `Log`
/// subsystem and rules: never log tokens, response bodies, PR titles or bodies, paths or file contents. Messages are
/// static text plus the error's kind. App categories are prefixed "app-".
enum AppLog {
    static let subsystem = Log.subsystem
    static let storage = Log.logger("app-storage")
    static let sync = Log.logger("app-sync")
    static let workspace = Log.logger("app-workspace")
    static let local = Log.logger("app-local")
    static let repositories = Log.logger("app-repositories")
    static let actions = Log.logger("app-actions")

    /// Error kind only (`Log.kind(_:)`): the type and case, or domain and code, never messages or associated values
    /// (which can carry paths, provider text or response fragments).
    static func kind(_ error: any Error) -> String { Log.kind(error) }
    /// Records a handled failure; cancellation is not a failure and is not recorded.
    static func failed(_ logger: Logger, _ what: StaticString, _ error: any Error) { Log.failed(logger, what, error) }
    /// `body`'s value, or `fallback` after recording why it failed. For reads whose failure the UI already tolerates
    /// (an empty list, a default) and best-effort writes, where `try?` would hide the failure entirely.
    static func value<T>(_ logger: Logger, _ what: StaticString, fallback: T, isolation: isolated (any Actor)? = #isolation,
                         _ body: () async throws -> T) async -> T {
        do { return try await body() } catch { failed(logger, what, error); return fallback }
    }
}
