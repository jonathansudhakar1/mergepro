import Foundation
import os

/// MergePro diagnostics, shared by Core and the App (`AppLog`). Never log tokens, Authorization headers, response
/// bodies, PR titles or bodies, paths or file contents. Interpolate dynamic values with `privacy: .private` unless
/// they are counts, durations, feature IDs or status codes; errors appear only as `kind(_:)`. Keep logging off hot
/// per-row paths.
public enum Log {
    public static let subsystem = "app.mergepro.mac"
    /// A logger of this subsystem. Core's categories are bare ("sync"); the App's are prefixed "app-".
    public static func logger(_ category: String) -> Logger { Logger(subsystem: subsystem, category: category) }
    public static let sync = logger("sync")
    public static let inventory = logger("inventory")
    public static let writes = logger("writes")
    public static let merge = logger("merge")
    public static let storage = logger("storage")
    public static let keychain = logger("keychain")
    public static let notifications = logger("notifications")
    public static let actions = logger("actions")
    public static let localGit = logger("local-git")

    /// Error kind only: the type and case name, never associated values or messages (which can carry
    /// paths, provider text or response fragments).
    public static func kind(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let failure = error as? GitHubFailure {
            switch failure {
            case .invalidAuthentication: return "GitHubFailure.invalidAuthentication"
            case .scopeRequired: return "GitHubFailure.scopeRequired"
            case .organizationRestricted: return "GitHubFailure.organizationRestricted"
            case .resourceDenied: return "GitHubFailure.resourceDenied"
            case .rateLimited: return "GitHubFailure.rateLimited"
            case .unsafeURL: return "GitHubFailure.unsafeURL"
            case .invalidResponse: return "GitHubFailure.invalidResponse"
            }
        }
        if let decoding = error as? DecodingError {
            switch decoding {
            case .typeMismatch: return "DecodingError.typeMismatch"
            case .valueNotFound: return "DecodingError.valueNotFound"
            case .keyNotFound: return "DecodingError.keyNotFound"
            case .dataCorrupted: return "DecodingError.dataCorrupted"
            @unknown default: return "DecodingError"
            }
        }
        let value = error as NSError
        return "\(String(reflecting: type(of: error))) \(value.domain) \(value.code)"
    }
    /// Records a handled failure as static text plus the error's kind. Cancellation is not a failure and is not recorded.
    public static func failed(_ logger: Logger, _ what: StaticString, _ error: any Error) {
        guard !(error is CancellationError) else { return }
        logger.error("\(what.description, privacy: .public): \(kind(error), privacy: .public)")
    }
}
