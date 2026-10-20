import MergeProCore
import SwiftUI

/// Approve from the PR window without the full composer: an optional comment, ⌘Return approves, and the
/// popover closes only when GitHub confirms. The approval goes through the review service and the durable
/// write ledger like every review; an unknown outcome stays visible with "Read provider result" and is
/// never resent. Only the head shown in the window is approved.
struct QuickApprovePopover:View {
    let pr:PullRequest
    let account:PRDetailAccountModel
    /// Opens the full composer (Request changes, pending comments, templates).
    var openComposer:() -> Void
    /// Called after GitHub confirmed the approval.
    var approved:() -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var summary=""
    @State private var busy=false
    @State private var message:String?
    @State private var unknownOutcome=false
    @FocusState private var summaryFocused:Bool
    private var ownPullRequest:Bool { account.actionPR?.metadata?.viewerIsAuthor == true }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Label("Approve",systemImage:"checkmark.seal").font(.headline)
                Spacer()
                if !account.login.isEmpty { Text("as \(account.login)").font(.caption).foregroundStyle(.secondary) }
            }
            TextEditor(text:$summary).font(.body).frame(width:360,height:90).border(.separator).focused($summaryFocused)
                .accessibilityLabel("Approval comment, optional").accessibilityIdentifier("quickApproveSummary")
            Text("Comment optional · approves \(pr.headRevision.rawValue.prefix(8)), the revision shown in this window.").font(.caption).foregroundStyle(.secondary)
            if ownPullRequest { Text("You can't approve your own pull request.").font(.callout).foregroundStyle(.orange) }
            if let error=account.actionError { Text(error).font(.callout).foregroundStyle(.orange) }
            if let message { WorkspaceNotice(message:message,symbol:unknownOutcome ? "exclamationmark.triangle" : "info.circle",tint:.orange) }
            if unknownOutcome,let key=account.actionPR?.key {
                PRWriteStatusView(key:key,storage:account.storage,changeSignal:account.operationRevision) { await account.reconciled() }.font(.caption)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Full review…") { dismiss();openComposer() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Approve") { Task { await approve() } }.buttonStyle(.borderedProminent).keyboardShortcut(.return,modifiers:.command)
                    .disabled(busy || unknownOutcome || ownPullRequest || account.actionPR == nil).help("Approve (⌘Return)").accessibilityIdentifier("quickApprove")
            }.controlSize(.small)
        }
        .padding(14)
        .onAppear { summaryFocused=true }
        .task { await account.resolve() }
    }
    private func approve() async {
        guard let actionPR=await account.resolve() else { message=account.actionError ?? "Action account unavailable.";return }
        busy=true;message=nil;defer { busy=false }
        do {
            // The action account's revision must be the head the reviewer is looking at.
            let snapshot=try await account.storage.detail(actionPR,maxAge:120)
            if let refusal=PRDisplayedHead.refusal(shown:pr.headRevision.rawValue,actual:snapshot.headSHA,acting:"approving") { message=refusal;return }
            let result=try await account.storage.submitQuickReview(actionPR,revision:PRWriteRevision(snapshot),decision:.approve,summary:summary)
            account.wrote()
            if result.state == .confirmed {
                account.status="Approved\(account.login.isEmpty ? "" : " as \(account.login)")."
                AccessibilityNotification.Announcement("Approved").post()
                approved();dismiss()
            } else {
                unknownOutcome=true
                message="\(prWriteStateText(result.state)): GitHub may have received this approval. Read the provider result before trying again; nothing was resent."
                AccessibilityNotification.Announcement("Approval outcome unknown").post()
            }
        } catch {
            account.wrote()
            message=Self.explain(error)
            AccessibilityNotification.Announcement("Approval not submitted").post()
        }
    }
    static func explain(_ error:any Error) -> String {
        switch error as? PRWriteFailure {
        case .unsentComments?:"Your review draft has comments that aren't sent yet. Use Full review… to send them with your approval. Nothing was sent."
        case .revisionChanged?:"Your review draft or the pull request changed revision. Use Full review… to check your draft against this revision. Nothing was sent."
        case .pendingExists?:"You have a pending review on GitHub. Use Full review… to finish or discard it. Nothing was sent."
        case .viewedIncomplete?:"Settings require every file marked viewed on GitHub before approving this risk-flagged pull request. Nothing was sent."
        default:prDetailErrorMessage(error)
        }
    }
}
