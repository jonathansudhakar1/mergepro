import Foundation

/// One glyph-and-text status: ✓ passing, ✗ failing, ◷ pending, ? unknown.
public enum PRStatusTone:String,Sendable { case passing,failing,pending,unknown }
public struct PRStatusValue:Sendable,Equatable {
    public let tone:PRStatusTone
    public let text:String
    public init(tone:PRStatusTone,text:String) { self.tone=tone;self.text=text }
}

/// Readable status for raw inventory values (check rollup, review decision, mergeability) and merge verification.
/// Unknown stays explicit; raw GraphQL values never reach the screen.
public enum PRStatusSummary {
    public static func checks(_ raw:String?) -> PRStatusValue {
        switch raw?.uppercased() {
        case "SUCCESS"?:.init(tone:.passing,text:"Checks passing")
        case "FAILURE"?,"ERROR"?:.init(tone:.failing,text:"Checks failing")
        case "PENDING"?:.init(tone:.pending,text:"Checks running")
        case "EXPECTED"?:.init(tone:.pending,text:"Checks expected")
        default:.init(tone:.unknown,text:"Checks unknown")
        }
    }
    public static func review(_ raw:String?) -> PRStatusValue {
        switch raw?.uppercased() {
        case "APPROVED"?:.init(tone:.passing,text:"Approved")
        case "CHANGES_REQUESTED"?:.init(tone:.failing,text:"Changes requested")
        case "REVIEW_REQUIRED"?:.init(tone:.pending,text:"Review required")
        default:.init(tone:.unknown,text:"Review unknown")
        }
    }
    public static func mergeable(_ raw:String?) -> PRStatusValue {
        switch raw?.uppercased() {
        case "MERGEABLE"?:.init(tone:.passing,text:"No conflicts")
        case "CONFLICTING"?:.init(tone:.failing,text:"Conflicts")
        default:.init(tone:.unknown,text:"Conflicts unknown")
        }
    }
    /// "Verified ready · 3 min. ago", the first known blocker, "Waiting on requirements · …", or "Not verified".
    public static func merge(_ eligibility:MergeEligibility,now:Date=Date()) -> PRStatusValue {
        if let blocker=eligibility.blockers.first { return .init(tone:.failing,text:blocker) }
        guard let at=eligibility.verifiedAt else { return .init(tone:.unknown,text:"Not verified") }
        let age=now.timeIntervalSince(at) < 60 ? "just now" : at.formatted(.relative(presentation:.named,unitsStyle:.abbreviated))
        return eligibility.verifiedReady ? .init(tone:.passing,text:"Verified ready · "+age) : .init(tone:.pending,text:"Waiting on requirements · "+age)
    }
    /// The head's check rollup failed, or a required check is known to be failing.
    public static func checksFailing(_ metadata:PRMetadata?) -> Bool {
        checks(metadata?.checks).tone == .failing || metadata?.failingRequiredCheck == true
    }
    /// The next moment after `date` at which `merge`'s age wording for a read at `verifiedAt` can change: each minute
    /// for the first hour ("just now", "1 min. ago" …), then each hour for a day, then each day.
    public static func nextAgeChange(after date:Date,verifiedAt:Date) -> Date {
        let age=date.timeIntervalSince(verifiedAt)
        let step:TimeInterval=age < 3_600 ? 60 : age < 86_400 ? 3_600 : 86_400
        return verifiedAt.addingTimeInterval(((max(0,age)/step).rounded(.down)+1)*step)
    }
    /// The table's merge column, from the same eligibility cards and menus use (the action account's): a verified
    /// result or known blocker as is, otherwise GitHub's conflict state with the verification, e.g.
    /// "No conflicts · Not verified".
    public static func mergeColumn(_ eligibility:MergeEligibility,mergeable raw:String?,now:Date=Date()) -> PRStatusValue {
        let verification=merge(eligibility,now:now)
        let conflicts=mergeable(raw)
        if verification.tone == .failing || verification.tone == .passing { return verification }
        return conflicts.tone == .unknown ? verification : .init(tone:conflicts.tone,text:conflicts.text+" · "+verification.text)
    }
}

extension MergeEligibility {
    /// The first moment after `now` at which evaluating the same merge evidence gives a different result: a read
    /// goes stale `MergePolicy.maximumAge` after `verifiedAt` (its blockers then stop counting and the merge sheet
    /// reads GitHub again), and a read stamped ahead of this clock becomes fresh. Nil without evidence or once it is
    /// stale. Text age ("just now", "3 min. ago") changes every minute regardless; views render it from `verifiedAt`.
    public func evidenceChange(after now:Date) -> Date? {
        guard let at=verifiedAt else { return nil }
        // Mirrors MergePolicy.isFresh: fresh while at-5s <= now <= at+maximumAge.
        let becomesFresh=at.addingTimeInterval(-5)
        if now < becomesFresh { return becomesFresh }
        let lastFresh=at.addingTimeInterval(MergePolicy.maximumAge)
        guard now <= lastFresh else { return nil }
        return Date(timeIntervalSinceReferenceDate:lastFresh.timeIntervalSinceReferenceDate.nextUp)
    }
    /// The earliest `evidenceChange(after:)` among `values`.
    public static func nextEvidenceChange<S:Sequence>(_ values:S,after now:Date) -> Date? where S.Element == MergeEligibility {
        values.lazy.compactMap { $0.evidenceChange(after:now) }.min()
    }
}

/// The PR actions every card, table row, menu and keyboard command offers for the rows they act on, so the
/// same selection enables the same actions everywhere. Nothing here writes; each action opens its own sheet.
public struct PRRowActionState:Sendable,Equatable {
    public enum Draft:Sendable,Equatable { case markReady,convertToDraft }
    public let count:Int
    public let canOpen:Bool
    /// One row uses the normal review flow; several open rows use the batch approval sheet.
    public let canApprove:Bool
    public let approveIsBatch:Bool
    /// Review composers act on exactly one pull request.
    public let canRequestChanges:Bool
    public let canComment:Bool
    /// One row opens the merge sheet unless a known blocker exists; several rows open batch merge with the
    /// blocked rows skipped (and listed), so at least one row must be free of known blockers.
    public let canMerge:Bool
    public let mergeIsBatch:Bool
    public let mergeTitle:String
    public let canEditLabels:Bool
    public let canClose:Bool
    public let draft:Draft?
    public let canCopyLink:Bool
    /// Enable or disable auto-merge for one open, non-draft row (the merge sheet verifies).
    public let autoMerge:MergeAction?
    public let canUpdateBranch:Bool
    /// Only when GitHub last reported the row queued; the sheet reads the queue again.
    public let canRemoveFromQueue:Bool
    public let checksFailing:Bool
    public init(rows:[PullRequest],eligibility:(PullRequest) -> MergeEligibility) {
        count=rows.count
        let single=rows.count == 1 ? rows.first : nil
        let openRows=rows.filter { $0.state == .open }
        let open=single.map { $0.state == .open } ?? false
        canOpen=single != nil
        canApprove = !openRows.isEmpty
        approveIsBatch=rows.count>1
        canRequestChanges=open
        canComment=single != nil
        mergeIsBatch=rows.count>1
        let values=rows.map(eligibility)
        canMerge=values.contains(where:\.opensMergeSheet)
        mergeTitle=rows.count>1 ? "Merge \(rows.count) selected…" : (values.first?.label ?? "Merge")+"…"
        canEditLabels=single != nil
        canClose=open
        draft=open ? (single?.isDraft == true ? .markReady : .convertToDraft) : nil
        canCopyLink = !rows.isEmpty && rows.allSatisfy { $0.metadata != nil }
        let m=single?.metadata
        let autoMergeOn=(m?.autoMergeKnown == true && m?.autoMerge == true) || m?.mergeEvidence?.autoMergeEnabled == true
        autoMerge=open && single?.isDraft == false ? (autoMergeOn ? .disableAutoMerge : .enableAutoMerge) : nil
        canUpdateBranch=open
        canRemoveFromQueue=open && m?.mergeEvidence?.queued == true
        checksFailing=single != nil && PRStatusSummary.checksFailing(m)
    }
}

extension PRSelection {
    /// The rows a keyboard command, the Pull Request menu or the list's selection bar acts on, as keys in `order`
    /// (the rows on screen). In the list (`selectionOnly`) the highlighted rows are the selection, so commands act on
    /// the selection alone: a row ⌘-clicked out of it is never acted on, and an empty selection acts on nothing.
    /// On the board j/k move focus without selecting, so commands act on a multi-selection, else on the focused card
    /// (`visibleFocus`), else on the selection.
    public func commandKeys(order:[ProviderKey],visibleFocus:ProviderKey?,selectionOnly:Bool) -> [ProviderKey] {
        let chosen=order.filter(selected.contains)
        if selectionOnly || chosen.count>1 { return chosen }
        return visibleFocus.map { [$0] } ?? chosen
    }
    /// Moves focus `direction` rows through `order` (j/k), clamped at the ends; the first move lands on the first
    /// row. `selecting` (the table) makes the moved-to row the selection, so A/M/Return act on the highlighted row;
    /// the board moves focus only and keeps a multi-selection.
    @discardableResult public mutating func move(_ direction:Int,in order:[ProviderKey],selecting:Bool) -> ProviderKey? {
        guard !order.isEmpty else { return nil }
        let index=focused.flatMap { order.firstIndex(of:$0) }
        let next=order[index.map { min(order.count-1,max(0,$0+direction)) } ?? 0]
        focused=next
        if selecting { selected=[next] }
        return next
    }
}
