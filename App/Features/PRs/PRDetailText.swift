import MergeProCore
import SwiftUI

/// Readable text for the PR window's own values (tabs, file statuses) and a fallback for provider
/// enum values without dedicated text yet ("CHANGES_REQUESTED" → "Changes requested").
enum PRDetailText {
    static func title(_ tab:PRDetailTab) -> String {
        switch tab {
        case .overview:"Overview"
        case .conversation:"Conversation"
        case .files:"Files changed"
        case .commits:"Commits"
        case .checks:"Checks"
        case .deployments:"Deployments"
        }
    }
    /// ⌃⌘1…⌃⌘6 in tab order, from `KeyboardShortcutCatalog` (which lists them and keeps them apart from menu chords).
    static func shortcut(_ tab:PRDetailTab) -> KeyboardShortcut? {
        guard let index=PRDetailTab.allCases.firstIndex(of:tab),index < KeyboardShortcutCatalog.prWindowTabs.count else { return nil }
        return KeyboardShortcutCatalog.prWindowTabs[index].shortcut
    }
    /// GitHub's page for a tab, or nil when the tab has no page of its own.
    static func webPath(_ tab:PRDetailTab) -> String? {
        switch tab { case .files:"files";case .commits:"commits";case .checks:"checks";default:nil }
    }
    static func state(_ pr:PullRequest) -> String {
        if pr.isDraft && pr.state == .open { return "Draft" }
        switch pr.state { case .open:return "Open";case .closed:return "Closed";case .merged:return "Merged" }
    }
    static func status(_ status:DiffFile.Status) -> String {
        switch status {
        case .added:"Added"
        case .removed:"Deleted"
        case .modified:"Modified"
        case .renamed:"Renamed"
        case .copied:"Copied"
        case .changed:"Changed"
        case .unchanged:"Unchanged"
        }
    }
    static func changes(_ file:DiffFile) -> String {
        "\(file.additions) \(file.additions == 1 ? "addition" : "additions"), \(file.deletions) \(file.deletions == 1 ? "deletion" : "deletions")"
    }
    static func reaction(_ reaction:PRReaction) -> String {
        switch reaction {
        case .thumbsUp:"👍 Thumbs up"
        case .thumbsDown:"👎 Thumbs down"
        case .laugh:"😄 Laugh"
        case .hooray:"🎉 Hooray"
        case .confused:"😕 Confused"
        case .heart:"❤️ Heart"
        case .rocket:"🚀 Rocket"
        case .eyes:"👀 Eyes"
        }
    }
    /// GitHub's comment minimize classifiers, in the order GitHub's own menu lists them.
    static let moderationReasons=["OFF_TOPIC","OUTDATED","RESOLVED","DUPLICATE","SPAM","ABUSE"]
    static func moderationReason(_ classifier:String) -> String {
        switch classifier {
        case "OFF_TOPIC":"Off-topic";case "OUTDATED":"Outdated";case "RESOLVED":"Resolved"
        case "DUPLICATE":"Duplicate";case "SPAM":"Spam";case "ABUSE":"Abuse"
        default:"Other reason"
        }
    }
    static func providerValue(_ raw:String) -> String {
        let words=raw.replacingOccurrences(of:"_",with:" ").lowercased()
        return words.prefix(1).uppercased()+words.dropFirst()
    }
}
