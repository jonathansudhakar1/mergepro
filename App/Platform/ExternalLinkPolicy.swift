import AppKit

/// Opens links that come from provider content (PR bodies, comments, check and event URLs).
/// Only https without credentials is opened; destinations outside GitHub ask first and show the real host.
@MainActor enum ExternalLinkPolicy {
    static func isGitHubHost(_ host: String) -> Bool { host == "github.com" || host.hasSuffix(".github.com") }
    /// Returns whether the link was opened.
    @discardableResult static func open(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if !isGitHubHost(host) {
            let alert = NSAlert()
            alert.messageText = "Open a link to \(host)?"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        return NSWorkspace.shared.open(url)
    }
}
