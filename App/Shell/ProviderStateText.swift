import Foundation
import MergeProCore

/// Shared user-facing text for provider raw values (review decisions, check states, write and merge
/// outcomes), so screens never show raw enum or GraphQL values. Add functions here; don't change
/// another feature's function without checking its callers.
enum ProviderStateText {
    // MARK: Repositories and local Git (Repos and Local workspaces)
    /// A commit's check rollup as `RepositoryBrowserService.commitChecks` reports it ("No checks" when none ran).
    static func commitChecks(_ raw:String) -> PRStatusValue { raw == "No checks" ? .init(tone:.unknown,text:"No checks") : checks(raw) }
    /// GitHub's compare status for base...head.
    static func comparisonStatus(_ raw:String) -> String {
        switch raw.lowercased() {
        case "ahead":"Ahead";case "behind":"Behind";case "diverged":"Diverged";case "identical":"Identical"
        default:"Comparison status unknown"
        }
    }
    /// A changed file's status in GitHub commit and compare responses.
    static func changedFileStatus(_ raw:String) -> String {
        switch raw.lowercased() {
        case "added":"Added";case "removed":"Removed";case "modified":"Modified";case "renamed":"Renamed"
        case "copied":"Copied";case "changed":"Changed";case "unchanged":"Unchanged"
        default:"Change unknown"
        }
    }
    /// The Git operation a local worktree is in the middle of (`LocalGitOperation` raw values).
    static func gitOperation(_ raw:String) -> String {
        switch raw.lowercased() {
        case "merge":"Merge";case "rebase":"Rebase";case "cherry-pick":"Cherry-pick";case "revert":"Revert"
        default:"Git operation"
        }
    }
    /// A porcelain v2 "XY" status pair as words, e.g. "Added, modified" for a staged new file edited again.
    static func gitFileChange(index:String,worktree:String) -> String {
        func word(_ code:String) -> String? {
            switch code {
            case ".", " ", "":nil
            case "M":"modified";case "T":"type changed";case "A":"added";case "D":"deleted";case "R":"renamed"
            case "C":"copied";case "U":"conflicted";case "?":"untracked"
            default:"changed"
            }
        }
        let words=[word(index),word(worktree)].compactMap { $0 }.reduce(into:[String]()) { if !$0.contains($1) { $0.append($1) } }
        let text=words.isEmpty ? "changed" : words.joined(separator:", ")
        return text.prefix(1).uppercased()+text.dropFirst()
    }
    // MARK: Pull request status (PR workspace: cards, table, menus)
    static func checks(_ raw:String?) -> PRStatusValue { PRStatusSummary.checks(raw) }
    static func review(_ raw:String?) -> PRStatusValue { PRStatusSummary.review(raw) }
    static func mergeable(_ raw:String?) -> PRStatusValue { PRStatusSummary.mergeable(raw) }
    /// "Verified ready · 3 min. ago", a known blocker, "Waiting on requirements · …" or "Not verified".
    static func mergeVerification(_ eligibility:MergeEligibility,now:Date=Date()) -> PRStatusValue { PRStatusSummary.merge(eligibility,now:now) }
    static func column(_ column:PRColumn) -> String {
        switch column { case .draft:"Draft";case .open:"Open";case .approved:"Approved";case .merged:"Merged" }
    }
    static func tableColumn(_ column:PRViewConfiguration.TableColumn) -> String {
        switch column {
        case .repository:"Repository";case .number:"Number";case .title:"Title";case .author:"Author"
        case .checks:"Checks";case .review:"Review";case .size:"Size";case .age:"Age";case .updated:"Updated"
        case .labels:"Labels";case .mergeability:"Mergeability"
        }
    }
    static func sort(_ sort:PRViewConfiguration.Sort) -> String {
        switch sort {
        case .updated:"Updated";case .created:"Created";case .timeInColumn:"Time in column";case .size:"Size"
        case .checks:"Checks";case .repository:"Repository";case .number:"Number";case .title:"Title"
        case .author:"Author";case .review:"Review";case .age:"Age";case .labels:"Labels";case .mergeability:"Mergeability"
        }
    }
    static func grouping(_ grouping:PRViewConfiguration.Grouping) -> String {
        switch grouping { case .none:"None";case .org:"Organization";case .repository:"Repository";case .author:"Author";case .authorType:"Author type" }
    }
    // MARK: Writes and merges
    static func writeState(_ state:PRWriteOperation.State) -> String { prWriteStateText(state) }
    static func mergeOutcome(_ outcome:MergeOutcome) -> String {
        switch outcome {
        case .pending:"Merge requested; GitHub is still processing it"
        case .queued:"Added to the merge queue"
        case .merged(let sha):sha.isEmpty ? "Merged" : "Merged as \(sha.prefix(7))"
        case .failed(let reason):"Not merged: \(reason)"
        case .autoMergeEnabled:"Auto-merge enabled"
        case .autoMergeDisabled:"Auto-merge disabled"
        case .queueRemoved:"Removed from the merge queue"
        case .branchUpdated(let head):head.isEmpty ? "Branch updated" : "Branch updated to \(head.prefix(7))"
        }
    }
    /// A merge-ledger operation: its provider outcome when known, else its write state, then any message.
    static func mergeOperation(_ operation:PRWriteOperation) -> String {
        [operation.mergeOutcome.map(mergeOutcome) ?? writeState(operation.state),operation.message].compactMap { $0 }.joined(separator:" · ")
    }
    /// What a ledger operation asked for, e.g. "Merge" or "Labels change".
    static func writeIntent(_ intent:PRWriteIntent) -> String {
        switch intent {
        case .merge:return "Merge"
        case .review(let decision,_),.submitPending(_,let decision,_):
            switch decision { case .approve:return "Approval";case .requestChanges:return "Change request";case .comment:return "Review comment" }
        case .createPending:return "Pending review"
        case .thread,.reply:return "Review comment"
        case .conversation:return "Comment"
        case .editComment:return "Comment edit"
        case .deleteComment:return "Comment deletion"
        case .resolve(_,let resolved):return resolved ? "Resolve conversation" : "Unresolve conversation"
        case .reaction:return "Reaction"
        case .moderate:return "Comment moderation"
        case .viewed:return "Viewed state"
        case .discardPendingReview:return "Discard pending review"
        case .dismissReview:return "Review dismissal"
        case .subscription:return "Subscription change"
        case .metadata(let mutation):
            switch mutation {
            case .title:return "Title change";case .body:return "Description change";case .base:return "Base branch change"
            case .labels,.labelChanges:return "Labels change";case .assignees,.assigneeChanges:return "Assignees change"
            case .milestone:return "Milestone change";case .reviewers,.reviewRequestChanges:return "Review request change"
            case .draft(let draft):return draft ? "Convert to draft" : "Ready for review"
            case .closed(let closed):return closed ? "Close" : "Reopen"
            }
        }
    }
}
